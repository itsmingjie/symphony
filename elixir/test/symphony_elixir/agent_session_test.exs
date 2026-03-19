defmodule SymphonyElixir.AgentSessionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.AgentSession

  test "create_on_issue sends issue id inside the input variable" do
    graphql_fun = fn query, variables ->
      send(self(), {:graphql_request, query, variables})

      {:ok,
       %{
         "data" => %{
           "agentSessionCreateOnIssue" => %{
             "agentSession" => %{"id" => "session-123"}
           }
         }
       }}
    end

    assert {:ok, "session-123"} =
             AgentSession.create_on_issue("issue-123", graphql_fun: graphql_fun)

    assert_receive {:graphql_request, query, %{input: %{issueId: "issue-123"}}}
    assert query =~ "mutation SymphonyCreateAgentSession($input: AgentSessionCreateOnIssue!)"
    assert query =~ "agentSessionCreateOnIssue(input: $input)"
  end

  test "create_on_issue surfaces graphql errors from a 200 response" do
    graphql_errors = [
      %{
        "message" => "Only OAuth applications can create agent sessions.",
        "extensions" => %{"code" => "FORBIDDEN"}
      }
    ]

    graphql_fun = fn _query, _variables ->
      {:ok, %{"errors" => graphql_errors}}
    end

    assert {:error, {:session_create_failed, {:linear_graphql_errors, ^graphql_errors}}} =
             AgentSession.create_on_issue("issue-123", graphql_fun: graphql_fun)
  end

  test "create_on_issue preserves unexpected payload details when the session id is missing" do
    graphql_fun = fn _query, _variables ->
      {:ok, %{"data" => %{"agentSessionCreateOnIssue" => %{"success" => false}}}}
    end

    assert {:error, {:session_create_failed, {:linear_unexpected_payload, payload}}} =
             AgentSession.create_on_issue("issue-123", graphql_fun: graphql_fun)

    assert payload =~ "agentSessionCreateOnIssue"
    assert payload =~ "success"
  end

  test "create_on_issue preserves non-200 Linear response details" do
    graphql_fun = fn _query, _variables ->
      {:error,
       {:linear_api_status, 400,
        %{
          "errors" => [
            %{"message" => "Unknown argument \"issueId\" on field \"Mutation.agentSessionCreateOnIssue\"."}
          ]
        }}}
    end

    assert {:error,
            {:session_create_failed,
             {:linear_api_status, 400,
              %{
                "errors" => [
                  %{"message" => "Unknown argument \"issueId\" on field \"Mutation.agentSessionCreateOnIssue\"."}
                ]
              }}}} = AgentSession.create_on_issue("issue-123", graphql_fun: graphql_fun)
  end

  test "create_activity sends the session payload inside the input variable" do
    graphql_fun = fn query, variables ->
      send(self(), {:graphql_request, query, variables})

      {:ok,
       %{
         "data" => %{
           "agentActivityCreate" => %{
             "success" => true,
             "agentActivity" => %{"id" => "activity-123"}
           }
         }
       }}
    end

    assert {:ok, "activity-123"} =
             AgentSession.create_activity(
               "session-123",
               %{type: "thought", body: "Started", signal: "auth"},
               graphql_fun: graphql_fun
             )

    assert_receive {:graphql_request, query,
                    %{
                      input: %{
                        agentSessionId: "session-123",
                        content: %{type: "thought", body: "Started"},
                        signal: "auth",
                        signalMetadata: nil
                      }
                    }}

    assert query =~ "mutation SymphonyCreateAgentActivity($input: AgentActivityCreateInput!)"
    assert query =~ "agentActivityCreate(input: $input)"
  end

  test "create_activity separates signalMetadata from content" do
    graphql_fun = fn _query, variables ->
      send(self(), {:graphql_variables, variables})

      {:ok,
       %{
         "data" => %{
           "agentActivityCreate" => %{
             "success" => true,
             "agentActivity" => %{"id" => "activity-456"}
           }
         }
       }}
    end

    metadata = %{"url" => "https://example.com/auth"}

    assert {:ok, "activity-456"} =
             AgentSession.create_activity(
               "session-123",
               %{type: "thought", body: "Need auth", signal: "auth", signalMetadata: metadata},
               graphql_fun: graphql_fun
             )

    assert_receive {:graphql_variables,
                    %{
                      input: %{
                        agentSessionId: "session-123",
                        content: %{type: "thought", body: "Need auth"},
                        signal: "auth",
                        signalMetadata: ^metadata
                      }
                    }}
  end
end
