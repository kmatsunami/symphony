defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Github.Client, as: GithubClient
  alias SymphonyElixir.Linear.Client, as: LinearClient

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
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
  @github_rest_tool "github_rest"
  @github_rest_description """
  Execute a raw REST API request against GitHub using Symphony's configured auth.
  """
  @github_rest_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "description" => "HTTP method. Supported values: GET, POST, PATCH, PUT, DELETE."
      },
      "path" => %{
        "type" => "string",
        "description" => "Absolute GitHub API path, for example `/repos/owner/repo/issues/123`."
      },
      "query" => %{
        "type" => ["object", "null"],
        "description" => "Optional query string parameters.",
        "additionalProperties" => true
      },
      "body" => %{
        "type" => ["object", "null"],
        "description" => "Optional JSON request body.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @github_rest_tool ->
        execute_github_rest(arguments, opts)

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
    case Config.tracker_kind() do
      "github" ->
        [
          %{
            "name" => @github_rest_tool,
            "description" => @github_rest_description,
            "inputSchema" => @github_rest_input_schema
          }
        ]

      "linear" ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          }
        ]

      _ ->
        []
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &LinearClient.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(linear_tool_error_payload(reason))
    end
  end

  defp execute_github_rest(arguments, opts) do
    github_rest_client =
      Keyword.get(opts, :github_rest_client, fn method, path, client_opts ->
        GithubClient.rest(method, path, client_opts)
      end)

    with {:ok, method, path, query, body} <- normalize_github_rest_arguments(arguments),
         {:ok, response} <- github_rest_client.(method, path, query: query, body: body) do
      github_rest_response(response)
    else
      {:error, reason} ->
        failure_response(github_tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_github_rest_arguments(arguments) when is_map(arguments) do
    with {:ok, path} <- normalize_github_rest_path(arguments),
         {:ok, method} <- normalize_github_rest_method(arguments),
         {:ok, query} <- normalize_github_rest_map(arguments, "query"),
         {:ok, body} <- normalize_github_rest_map(arguments, "body") do
      {:ok, method, path, query, body}
    end
  end

  defp normalize_github_rest_arguments(_arguments), do: {:error, :invalid_github_rest_arguments}

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

  defp normalize_github_rest_path(arguments) do
    case Map.get(arguments, "path") || Map.get(arguments, :path) do
      path when is_binary(path) ->
        case String.trim(path) do
          "" -> {:error, :missing_github_rest_path}
          trimmed -> validate_github_rest_path(trimmed)
        end

      _ ->
        {:error, :missing_github_rest_path}
    end
  end

  defp normalize_github_rest_method(arguments) do
    case Map.get(arguments, "method") || Map.get(arguments, :method) || "GET" do
      method when is_binary(method) ->
        case String.trim(method) do
          "" -> {:ok, "GET"}
          trimmed -> validate_github_rest_method(trimmed)
        end

      _ ->
        {:error, :invalid_github_rest_method}
    end
  end

  defp normalize_github_rest_map(arguments, key) do
    case Map.get(arguments, key) || Map.get(arguments, String.to_atom(key)) || %{} do
      nil -> {:ok, %{}}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, String.to_atom("invalid_github_rest_#{key}")}
    end
  end

  defp validate_github_rest_path(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "/") -> {:ok, path}
      String.starts_with?(path, "http://") -> {:error, :invalid_github_rest_path}
      String.starts_with?(path, "https://") -> {:error, :invalid_github_rest_path}
      true -> {:error, :invalid_github_rest_path}
    end
  end

  defp validate_github_rest_method(method) when is_binary(method) do
    normalized = String.upcase(method)

    if normalized in ["GET", "POST", "PATCH", "PUT", "DELETE"] do
      {:ok, normalized}
    else
      {:error, :invalid_github_rest_method}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(response)
        }
      ]
    }
  end

  defp github_rest_response(%{status: status, body: body}) do
    payload =
      case body do
        nil -> %{"status" => status}
        "" -> %{"status" => status}
        _ -> body
      end

    %{
      "success" => true,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
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

  defp tool_error_payload(:missing_github_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
      }
    }
  end

  defp tool_error_payload(:missing_github_repository) do
    %{
      "error" => %{
        "message" => "Symphony is missing `tracker.repository` for GitHub operations."
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

  defp tool_error_payload({:github_api_status, status, body}) do
    %{
      "error" => %{
        "message" => "GitHub REST request failed with HTTP #{status}.",
        "status" => status,
        "body" => body
      }
    }
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub REST request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:missing_github_rest_path) do
    %{
      "error" => %{
        "message" => "`github_rest` requires a non-empty `path` string."
      }
    }
  end

  defp tool_error_payload(:invalid_github_rest_arguments) do
    %{
      "error" => %{
        "message" => "`github_rest` expects an object with `path` and optional `method`, `query`, and `body`."
      }
    }
  end

  defp tool_error_payload(:invalid_github_rest_method) do
    %{
      "error" => %{
        "message" => "`github_rest.method` must be one of GET, POST, PATCH, PUT, or DELETE."
      }
    }
  end

  defp tool_error_payload(:invalid_github_rest_path) do
    %{
      "error" => %{
        "message" => "`github_rest.path` must be an absolute GitHub API path such as `/repos/owner/repo/issues/123`."
      }
    }
  end

  defp tool_error_payload(:invalid_github_rest_query) do
    %{
      "error" => %{
        "message" => "`github_rest.query` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_github_rest_body) do
    %{
      "error" => %{
        "message" => "`github_rest.body` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Tracker tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp linear_tool_error_payload(reason), do: linear_tool_error_payload(reason, tool_error_payload(reason))

  defp linear_tool_error_payload(reason, payload)
       when reason in [:missing_query, :invalid_arguments, :invalid_variables, :missing_linear_api_token] do
    payload
  end

  defp linear_tool_error_payload(reason, payload)
       when is_tuple(reason) and tuple_size(reason) > 0 and
              elem(reason, 0) in [:linear_api_status, :linear_api_request] do
    payload
  end

  defp linear_tool_error_payload(reason, _payload) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp github_tool_error_payload(reason), do: github_tool_error_payload(reason, tool_error_payload(reason))

  defp github_tool_error_payload(reason, payload)
       when reason in [
              :missing_github_api_token,
              :missing_github_repository,
              :missing_github_rest_path,
              :invalid_github_rest_arguments,
              :invalid_github_rest_method,
              :invalid_github_rest_path,
              :invalid_github_rest_query,
              :invalid_github_rest_body
            ] do
    payload
  end

  defp github_tool_error_payload(reason, payload)
       when is_tuple(reason) and tuple_size(reason) > 0 and
              elem(reason, 0) in [:github_api_status, :github_api_request] do
    payload
  end

  defp github_tool_error_payload(reason, _payload) do
    %{
      "error" => %{
        "message" => "GitHub REST tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
