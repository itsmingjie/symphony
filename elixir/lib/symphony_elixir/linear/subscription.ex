defmodule SymphonyElixir.Linear.Subscription do
  @moduledoc """
  WebSocket client for Linear issueCreated/issueUpdated subscriptions.
  """

  use WebSockex
  require Logger

  alias SymphonyElixir.{Config, Linear.Client}

  @reconnect_base_ms 5_000
  @reconnect_max_ms 60_000

  @issue_created_sub """
  subscription SymphonyIssueCreated($filter: IssueSubscriptionFilter) {
    issueCreated(filter: $filter) {
      id
      identifier
      title
      state { name }
    }
  }
  """

  @issue_updated_sub """
  subscription SymphonyIssueUpdated($filter: IssueSubscriptionFilter) {
    issueUpdated(filter: $filter) {
      id
      identifier
      title
      state { name }
    }
  }
  """

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    config = Config.settings!()

    if config.tracker.kind != "linear" do
      :ignore
    else
      do_start_link(config, opts)
    end
  end

  defp do_start_link(config, opts) do
    api_key = config.tracker.api_key
    project_slug = config.tracker.project_slug

    if is_nil(api_key) or is_nil(project_slug) do
      :ignore
    else
      case Client.resolve_project_id(project_slug) do
        {:ok, project_id} ->
          url = subscription_endpoint(config.tracker.endpoint)
          orchestrator = Keyword.get(opts, :orchestrator, SymphonyElixir.Orchestrator)

          state = %{
            api_key: api_key,
            project_id: project_id,
            orchestrator: orchestrator,
            reconnect_attempt: 0
          }

          Logger.info("Connecting Linear subscription to #{url} project_id=#{project_id}")

          WebSockex.start_link(url, __MODULE__, state,
            extra_headers: [{"Sec-WebSocket-Protocol", "graphql-transport-ws"}],
            name: __MODULE__
          )

        {:error, reason} ->
          Logger.warning("Linear subscription: failed to resolve project ID: #{inspect(reason)}")
          :ignore
      end
    end
  end

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("Linear WebSocket connected")
    send(self(), :send_connection_init)
    {:ok, %{state | reconnect_attempt: 0}}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, decoded} ->
        handle_ws_message(decoded, state)

      {:error, reason} ->
        Logger.warning("Linear subscription: failed to decode message: #{inspect(reason)}")
        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_info(:send_connection_init, state) do
    msg =
      Jason.encode!(%{
        "type" => "connection_init",
        "payload" => %{"Authorization" => state.api_key}
      })

    {:reply, {:text, msg}, state}
  end

  def handle_info(:subscribe, state) do
    filter = %{"projectId" => %{"eq" => state.project_id}}

    created_msg =
      Jason.encode!(%{
        "type" => "subscribe",
        "id" => "issue_created",
        "payload" => %{
          "query" => @issue_created_sub,
          "variables" => %{"filter" => filter}
        }
      })

    updated_msg =
      Jason.encode!(%{
        "type" => "subscribe",
        "id" => "issue_updated",
        "payload" => %{
          "query" => @issue_updated_sub,
          "variables" => %{"filter" => filter}
        }
      })

    send(self(), {:send_frame, updated_msg})
    {:reply, {:text, created_msg}, state}
  end

  def handle_info({:send_frame, msg}, state) do
    {:reply, {:text, msg}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def handle_disconnect(disconnect_map, state) do
    Logger.warning("Linear subscription disconnected: #{inspect(disconnect_map[:reason])}")
    notify_orchestrator(state.orchestrator)

    attempt = state.reconnect_attempt + 1
    delay = min(@reconnect_base_ms * attempt, @reconnect_max_ms)
    Logger.info("Linear subscription reconnecting in #{delay}ms (attempt #{attempt})")
    Process.sleep(delay)

    {:reconnect, %{state | reconnect_attempt: attempt}}
  end

  defp handle_ws_message(%{"type" => "connection_ack"}, state) do
    Logger.info("Linear subscription authenticated, subscribing to events")
    send(self(), :subscribe)
    {:ok, state}
  end

  defp handle_ws_message(%{"type" => "next", "id" => sub_id, "payload" => payload}, state) do
    identifier = extract_identifier(sub_id, payload)
    event_type = if sub_id == "issue_created", do: "created", else: "updated"
    Logger.info("Linear subscription event: #{event_type} issue=#{identifier || "unknown"}")
    notify_orchestrator(state.orchestrator)
    {:ok, state}
  end

  defp handle_ws_message(%{"type" => "ping"}, state) do
    {:reply, {:text, Jason.encode!(%{"type" => "pong"})}, state}
  end

  defp handle_ws_message(%{"type" => "error", "id" => sub_id, "payload" => errors}, state) do
    Logger.error("Linear subscription error for #{sub_id}: #{inspect(errors)}")
    {:ok, state}
  end

  defp handle_ws_message(%{"type" => "complete", "id" => sub_id}, state) do
    Logger.info("Linear subscription completed: #{sub_id}")
    {:ok, state}
  end

  defp handle_ws_message(_msg, state), do: {:ok, state}

  defp extract_identifier("issue_created", %{"data" => %{"issueCreated" => %{"identifier" => id}}}),
    do: id

  defp extract_identifier("issue_updated", %{"data" => %{"issueUpdated" => %{"identifier" => id}}}),
    do: id

  defp extract_identifier(_sub_id, _payload), do: nil

  defp notify_orchestrator(orchestrator) do
    send(orchestrator, :linear_subscription_event)
  catch
    _, _ -> :ok
  end

  defp subscription_endpoint(http_endpoint) do
    uri = URI.parse(http_endpoint)
    scheme = if uri.scheme == "https", do: "wss", else: "ws"

    port_suffix =
      if uri.port && uri.port not in [80, 443] do
        ":#{uri.port}"
      else
        ""
      end

    "#{scheme}://#{uri.host}#{port_suffix}/graphqls"
  end
end
