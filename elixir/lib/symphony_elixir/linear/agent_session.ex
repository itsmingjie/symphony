defmodule SymphonyElixir.Linear.AgentSession do
  @moduledoc """
  Linear Agent Sessions API client.

  Wraps GraphQL mutations for creating agent sessions, emitting activities,
  and updating session metadata (plans, external URLs).
  """

  alias SymphonyElixir.Linear.Client

  @create_session_mutation """
  mutation SymphonyCreateAgentSession($input: AgentSessionCreateOnIssue!) {
    agentSessionCreateOnIssue(input: $input) {
      success
      agentSession {
        id
        status
      }
    }
  }
  """

  @create_activity_mutation """
  mutation SymphonyCreateAgentActivity($input: AgentActivityCreateInput!) {
    agentActivityCreate(input: $input) {
      success
      agentActivity {
        id
      }
    }
  }
  """

  @update_session_mutation """
  mutation SymphonyUpdateAgentSession($id: String!, $input: AgentSessionUpdateInput!) {
    agentSessionUpdate(id: $id, input: $input) {
      success
    }
  }
  """

  @spec create_on_issue(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_on_issue(issue_id, opts \\ []) when is_binary(issue_id) do
    run_mutation(
      @create_session_mutation,
      %{input: %{issueId: issue_id}},
      :session_create_failed,
      opts,
      fn response ->
        case get_in(response, ["data", "agentSessionCreateOnIssue", "agentSession", "id"]) do
          session_id when is_binary(session_id) and session_id != "" ->
            {:ok, session_id}

          _ ->
            {:error, mutation_error(:session_create_failed, response)}
        end
      end
    )
  end

  @spec create_activity(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_activity(session_id, content, opts \\ [])
      when is_binary(session_id) and is_map(content) do
    {signal, content} = Map.pop(content, :signal)
    {signal_metadata, content} = Map.pop(content, :signalMetadata)

    run_mutation(
      @create_activity_mutation,
      %{
        input: %{
          agentSessionId: session_id,
          content: content,
          signal: signal,
          signalMetadata: signal_metadata
        }
      },
      :activity_create_failed,
      opts,
      fn response ->
        if get_in(response, ["data", "agentActivityCreate", "success"]) == true do
          activity_id = get_in(response, ["data", "agentActivityCreate", "agentActivity", "id"])
          {:ok, activity_id || "ok"}
        else
          {:error, mutation_error(:activity_create_failed, response)}
        end
      end
    )
  end

  @spec update_session(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def update_session(session_id, input, opts \\ [])
      when is_binary(session_id) and is_map(input) do
    run_mutation(
      @update_session_mutation,
      %{id: session_id, input: input},
      :session_update_failed,
      opts,
      fn response ->
        if get_in(response, ["data", "agentSessionUpdate", "success"]) == true do
          :ok
        else
          {:error, mutation_error(:session_update_failed, response)}
        end
      end
    )
  end

  defp run_mutation(query, variables, operation, opts, handle_success) do
    graphql_fun = Keyword.get(opts, :graphql_fun, &Client.graphql/2)

    case graphql_fun.(query, variables) do
      {:ok, response} -> handle_success.(response)
      {:error, reason} -> {:error, {operation, reason}}
    end
  end

  defp mutation_error(operation, %{"errors" => errors})
       when is_list(errors) and errors != [] do
    {operation, {:linear_graphql_errors, errors}}
  end

  defp mutation_error(operation, response) do
    {operation, {:linear_unexpected_payload, summarize_response(response)}}
  end

  defp summarize_response(response) do
    inspect(response, limit: 20, printable_limit: 1_000)
  end
end
