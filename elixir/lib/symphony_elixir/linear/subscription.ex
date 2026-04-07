defmodule SymphonyElixir.Linear.Subscription do
  @moduledoc """
  WebSocket client for Linear issueCreated/issueUpdated subscriptions.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Linear.Client}

  @connect_retry_base_ms 5_000
  @connect_retry_max_ms 60_000
  @ws_subprotocol "graphql-transport-ws"

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    config = Config.settings!()

    if config.tracker.kind != "linear" do
      :ignore
    else
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      orchestrator: Keyword.get(opts, :orchestrator, SymphonyElixir.Orchestrator),
      ws_pid: nil,
      connect_attempt: 0
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    config = Config.settings!()
    api_key = config.tracker.api_key
    project_slug = config.tracker.project_slug

    if is_nil(api_key) or is_nil(project_slug) do
      schedule_connect_retry(state)
    else
      case Client.resolve_project_id(project_slug) do
        {:ok, project_id} ->
          url = subscription_endpoint(config.tracker.endpoint)
          Logger.info("Connecting Linear subscription to #{url} project_id=#{project_id}")

          ws_state = %{
            api_key: api_key,
            project_id: project_id,
            owner: self(),
            orchestrator: state.orchestrator,
            reconnect_attempt: 0
          }

          case WebSockex.start_link(url, SymphonyElixir.Linear.SubscriptionSocket, ws_state,
                 extra_headers: [
                   {"Sec-WebSocket-Protocol", @ws_subprotocol},
                   {"Authorization", api_key}
                 ]
               ) do
            {:ok, ws_pid} ->
              Process.monitor(ws_pid)
              {:noreply, %{state | ws_pid: ws_pid, connect_attempt: 0}}

            {:error, reason} ->
              Logger.warning("Linear subscription WebSocket failed to connect: #{inspect(reason)}")
              schedule_connect_retry(state)
          end

        {:error, reason} ->
          Logger.warning("Linear subscription: failed to resolve project ID: #{inspect(reason)}")
          schedule_connect_retry(state)
      end
    end
  end

  def handle_info(:ws_subscribed, state) do
    Logger.info("Linear subscription active")

    {:noreply, state}
  end

  def handle_info({:ws_event, event_type, identifier}, state) do
    Logger.info("Linear subscription event: #{event_type} issue=#{identifier || "unknown"}")
    notify_orchestrator(state.orchestrator)

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{ws_pid: pid} = state) do
    Logger.warning("Linear subscription WebSocket exited: #{inspect(reason)}")

    schedule_connect_retry(%{state | ws_pid: nil})
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_connect_retry(state) do
    attempt = state.connect_attempt + 1
    delay = min(@connect_retry_base_ms * attempt, @connect_retry_max_ms)
    Logger.info("Linear subscription retrying connection in #{delay}ms (attempt #{attempt})")
    Process.send_after(self(), :connect, delay)
    {:noreply, %{state | connect_attempt: attempt}}
  end

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

defmodule SymphonyElixir.Linear.SubscriptionSocket do
  @moduledoc false

  use WebSockex
  require Logger

  # Queries use inline filter to avoid needing the exact input type name
  @issue_created_sub_template "subscription { issueCreated(filter: { projectId: { eq: \"~PROJECT_ID~\" } }) { id identifier title state { name } } }"
  @issue_updated_sub_template "subscription { issueUpdated(filter: { projectId: { eq: \"~PROJECT_ID~\" } }) { id identifier title state { name } } }"

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
    created_query = String.replace(@issue_created_sub_template, "~PROJECT_ID~", state.project_id)
    updated_query = String.replace(@issue_updated_sub_template, "~PROJECT_ID~", state.project_id)

    created_msg =
      Jason.encode!(%{
        "type" => "subscribe",
        "id" => "issue_created",
        "payload" => %{"query" => created_query}
      })

    updated_msg =
      Jason.encode!(%{
        "type" => "subscribe",
        "id" => "issue_updated",
        "payload" => %{"query" => updated_query}
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

    attempt = state.reconnect_attempt + 1
    delay = min(5_000 * attempt, 60_000)
    Logger.info("Linear subscription reconnecting in #{delay}ms (attempt #{attempt})")
    Process.sleep(delay)

    {:reconnect, %{state | reconnect_attempt: attempt}}
  end

  defp handle_ws_message(%{"type" => "connection_ack"}, state) do
    Logger.info("Linear subscription authenticated, subscribing to events")
    send(self(), :subscribe)
    send(state.owner, :ws_subscribed)
    {:ok, state}
  end

  defp handle_ws_message(%{"type" => "next", "id" => sub_id, "payload" => payload}, state) do
    identifier = extract_identifier(sub_id, payload)
    event_type = if sub_id == "issue_created", do: "created", else: "updated"

    Logger.info("Linear subscription event: #{event_type} issue=#{identifier || "unknown"}")

    send(state.owner, {:ws_event, event_type, identifier})
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
end
