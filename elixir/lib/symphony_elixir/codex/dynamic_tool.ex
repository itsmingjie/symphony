defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Linear.{AgentSession, Client}

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.

  Use `issue(id: $id)` with the internal Linear issue id from the Symphony prompt context.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @linear_agent_activity_tool "linear_agent_activity"
  @linear_agent_activity_description """
  Emit an agent activity to the current Linear agent session. Activities are displayed in the \
  Linear issue UI with rich semantic structure.

  Activity types:
  - "thought": Internal planning notes, progress updates, reasoning steps
  - "action": Tool invocations or significant operations being performed
  - "response": Final result or completion message
  - "error": Failure or blocker report
  - "elicitation": Request for clarification or user input
  """
  @linear_agent_activity_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["type"],
    "properties" => %{
      "type" => %{
        "type" => "string",
        "enum" => ["thought", "action", "response", "error", "elicitation"],
        "description" => "The semantic type of this activity."
      },
      "body" => %{
        "type" => "string",
        "description" => "Markdown body for thought, response, error, and elicitation types."
      },
      "action" => %{
        "type" => "string",
        "description" => "Action name (for action type only)."
      },
      "parameter" => %{
        "type" => "string",
        "description" => "Action parameter (for action type only)."
      },
      "result" => %{
        "type" => "string",
        "description" => "Action result (for action type only)."
      },
      "signal" => %{
        "type" => "string",
        "enum" => ["auth", "select"],
        "description" => "Optional signal metadata type."
      },
      "signalMetadata" => %{
        "type" => ["object", "null"],
        "description" => "Optional signal metadata (e.g. auth URL, select options).",
        "additionalProperties" => true
      }
    }
  }

  @linear_agent_session_update_tool "linear_agent_session_update"
  @linear_agent_session_update_description """
  Update the current Linear agent session metadata. Use this to set a structured plan \
  (task checklist) and/or manage external URL links on the session.

  Plan items have a content string and a status: "pending", "inProgress", "completed", or "canceled". \
  The entire plan array is replaced on each update, so always send the full plan.
  """
  @linear_agent_session_update_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "plan" => %{
        "type" => "array",
        "description" => "Structured plan checklist. Replaces the entire plan on each update.",
        "items" => %{
          "type" => "object",
          "required" => ["content", "status"],
          "properties" => %{
            "content" => %{"type" => "string", "description" => "Plan item text."},
            "status" => %{
              "type" => "string",
              "enum" => ["pending", "inProgress", "completed", "canceled"],
              "description" => "Plan item status."
            }
          }
        }
      },
      "addedExternalUrls" => %{
        "type" => "array",
        "description" => "External URLs to add to the session.",
        "items" => %{
          "type" => "object",
          "required" => ["label", "url"],
          "properties" => %{
            "label" => %{"type" => "string"},
            "url" => %{"type" => "string"}
          }
        }
      },
      "removedExternalUrls" => %{
        "type" => "array",
        "description" => "External URLs to remove from the session (by URL).",
        "items" => %{"type" => "string"}
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @linear_agent_activity_tool ->
        execute_agent_activity(arguments, opts)

      @linear_agent_session_update_tool ->
        execute_agent_session_update(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @linear_agent_activity_tool,
        "description" => @linear_agent_activity_description,
        "inputSchema" => @linear_agent_activity_input_schema
      },
      %{
        "name" => @linear_agent_session_update_tool,
        "description" => @linear_agent_session_update_description,
        "inputSchema" => @linear_agent_session_update_input_schema
      }
    ]
  end

  # --- linear_graphql ---

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  @no_session_error "No agent session is active. Ensure your LINEAR_API_KEY is from a Linear OAuth application."

  # --- linear_agent_activity ---

  defp execute_agent_activity(arguments, opts) when is_map(arguments) do
    with_agent_session(opts, fn session_id ->
      case AgentSession.create_activity(
             session_id,
             take_atomized(arguments, ~w(type body action parameter result signal signalMetadata))
           ) do
        {:ok, activity_id} ->
          success_response(%{"activityId" => activity_id, "status" => "created"})

        {:error, reason} ->
          failure_response(tool_error_payload({:agent_activity_failed, reason}))
      end
    end)
  end

  defp execute_agent_activity(_arguments, _opts) do
    failure_response(%{"error" => %{"message" => "`linear_agent_activity` expects a JSON object."}})
  end

  # --- linear_agent_session_update ---

  defp execute_agent_session_update(arguments, opts) when is_map(arguments) do
    with_agent_session(opts, fn session_id ->
      input = take_atomized(arguments, ~w(plan addedExternalUrls removedExternalUrls))

      if input == %{} do
        failure_response(%{
          "error" => %{
            "message" => "`linear_agent_session_update` requires at least one of: `plan`, `addedExternalUrls`, `removedExternalUrls`."
          }
        })
      else
        case AgentSession.update_session(session_id, input) do
          :ok -> success_response(%{"status" => "updated"})
          {:error, reason} -> failure_response(tool_error_payload({:agent_session_update_failed, reason}))
        end
      end
    end)
  end

  defp execute_agent_session_update(_arguments, _opts) do
    failure_response(%{"error" => %{"message" => "`linear_agent_session_update` expects a JSON object."}})
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    with {:ok, query} <- normalize_query(arguments),
         {:ok, variables} <- normalize_variables(arguments) do
      {:ok, query, variables}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp with_agent_session(opts, fun) do
    case Keyword.get(opts, :agent_session_id) do
      nil -> failure_response(%{"error" => %{"message" => @no_session_error}})
      session_id -> fun.(session_id)
    end
  end

  defp take_atomized(arguments, keys) do
    arguments
    |> Map.take(keys)
    |> Map.new(fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp success_response(payload) do
    dynamic_tool_response(true, encode_payload(payload))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status, body}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status,
        "body" => body
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:agent_activity_failed, reason}) do
    %{
      "error" => %{
        "message" => "Failed to create agent activity.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:agent_session_update_failed, reason}) do
    %{
      "error" => %{
        "message" => "Failed to update agent session.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
