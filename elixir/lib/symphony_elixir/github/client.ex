defmodule SymphonyElixir.Github.Client do
  @moduledoc """
  Thin GitHub Issues REST client for polling candidate work.
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker.Issue}

  @api_version "2022-11-28"
  @issue_page_size 100
  @max_error_body_log_bytes 1_000

  @type response :: %{
          status: pos_integer(),
          body: term(),
          headers: [{binary(), binary()}]
        }

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, repo} <- configured_repository(),
         {:ok, assignee_filter} <- routing_assignee_filter(),
         {:ok, issues} <- list_repository_issues(repo, "open") do
      {:ok, filter_issues_by_states(normalize_issues(issues, assignee_filter), Config.tracker_active_states())}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    with {:ok, repo} <- configured_repository(),
         {:ok, assignee_filter} <- routing_assignee_filter(),
         {:ok, issues} <- list_repository_issues(repo, "all") do
      {:ok, filter_issues_by_states(normalize_issues(issues, assignee_filter), state_names)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    with {:ok, repo} <- configured_repository(),
         {:ok, assignee_filter} <- routing_assignee_filter(),
         {:ok, issues} <- fetch_issue_states(repo, issue_ids, assignee_filter) do
      {:ok, Enum.reverse(issues)}
    end
  end

  @spec rest(String.t() | atom(), String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def rest(method, path, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, request_method} <- normalize_method(method),
         {:ok, url} <- build_url(path),
         {:ok, headers} <- github_headers() do
      request_opts =
        [
          method: request_method,
          url: url,
          headers: headers,
          connect_options: [timeout: 30_000]
        ]
        |> maybe_put_query(Keyword.get(opts, :query))
        |> maybe_put_json_body(Keyword.get(opts, :body))

      request_fun = Application.get_env(:symphony_elixir, :github_request_fun, &Req.request/1)

      case request_fun.(request_opts) do
        {:ok, %Req.Response{status: status, body: body, headers: headers}} when status in 200..299 ->
          {:ok, %{status: status, body: body, headers: headers}}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("GitHub REST request failed status=#{status} body=#{summarize_error_body(body)}")
          {:error, {:github_api_status, status, body}}

        {:error, reason} ->
          Logger.error("GitHub REST request failed: #{inspect(reason)}")
          {:error, {:github_api_request, reason}}
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, repo} <- configured_repository(),
         {:ok, issue_number} <- normalize_issue_number(issue_id),
         {:ok, _response} <-
           rest("POST", "/repos/#{repo}/issues/#{issue_number}/comments", body: %{"body" => body}) do
      :ok
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, repo} <- configured_repository(),
         {:ok, issue_number} <- normalize_issue_number(issue_id),
         {:ok, issue} <- fetch_issue(repo, issue_id),
         workflow_label <- state_label_name(state_name),
         labels <- replace_state_labels(raw_label_names(issue), workflow_label),
         body <- issue_update_body(state_name, labels),
         {:ok, _response} <- rest("PATCH", "/repos/#{repo}/issues/#{issue_number}", body: body) do
      :ok
    end
  end

  defp configured_repository do
    case Config.github_repository() do
      repository when is_binary(repository) and repository != "" -> {:ok, repository}
      _ -> {:error, :missing_github_repository}
    end
  end

  defp list_repository_issues(repo, state) do
    do_list_repository_issues(repo, state, 1, [])
  end

  defp do_list_repository_issues(repo, state, page, acc) do
    query = %{
      "state" => state,
      "sort" => "created",
      "direction" => "asc",
      "per_page" => @issue_page_size,
      "page" => page
    }

    case rest("GET", "/repos/#{repo}/issues", query: query) do
      {:ok, %{body: issues}} when is_list(issues) ->
        filtered_issues = Enum.reject(issues, &pull_request?/1)
        updated_acc = Enum.reverse(filtered_issues, acc)

        if length(issues) < @issue_page_size do
          {:ok, Enum.reverse(updated_acc)}
        else
          do_list_repository_issues(repo, state, page + 1, updated_acc)
        end

      {:ok, %{body: body}} ->
        {:error, {:github_unknown_payload, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_issue(repo, issue_id) do
    with {:ok, issue_number} <- normalize_issue_number(issue_id),
         {:ok, %{body: body}} <- rest("GET", "/repos/#{repo}/issues/#{issue_number}") do
      {:ok, body}
    end
  end

  defp normalize_method(method) when is_atom(method), do: normalize_method(Atom.to_string(method))

  defp normalize_method(method) when is_binary(method) do
    case method |> String.trim() |> String.upcase() do
      "GET" -> {:ok, :get}
      "POST" -> {:ok, :post}
      "PATCH" -> {:ok, :patch}
      "PUT" -> {:ok, :put}
      "DELETE" -> {:ok, :delete}
      _ -> {:error, :invalid_github_rest_method}
    end
  end

  defp normalize_method(_method), do: {:error, :invalid_github_rest_method}

  defp build_url(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        {:error, :invalid_github_rest_path}

      String.starts_with?(trimmed, "http://") or String.starts_with?(trimmed, "https://") ->
        {:error, :invalid_github_rest_path}

      String.starts_with?(trimmed, "/") ->
        {:ok, String.trim_trailing(Config.github_endpoint(), "/") <> trimmed}

      true ->
        {:error, :invalid_github_rest_path}
    end
  end

  defp maybe_put_query(opts, nil), do: opts

  defp maybe_put_query(opts, query) when is_map(query) and map_size(query) > 0 do
    Keyword.put(opts, :params, query)
  end

  defp maybe_put_query(opts, _query), do: opts

  defp maybe_put_json_body(opts, nil), do: opts
  defp maybe_put_json_body(opts, body) when is_map(body), do: Keyword.put(opts, :json, body)
  defp maybe_put_json_body(opts, _body), do: opts

  defp github_headers do
    case Config.github_api_token() do
      nil ->
        {:error, :missing_github_api_token}

      token ->
        {:ok,
         [
           {"Authorization", "Bearer " <> token},
           {"Accept", "application/vnd.github+json"},
           {"X-GitHub-Api-Version", @api_version}
         ]}
    end
  end

  defp normalize_issues(issues, assignee_filter) do
    issues
    |> Enum.map(&normalize_issue(&1, assignee_filter))
    |> Enum.reject(&is_nil/1)
  end

  defp filter_issues_by_states(issues, state_names) do
    wanted_states =
      state_names
      |> Enum.map(&normalize_issue_state/1)
      |> MapSet.new()

    Enum.filter(issues, fn %Issue{state: state} ->
      MapSet.member?(wanted_states, normalize_issue_state(state))
    end)
  end

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    if pull_request?(issue) do
      nil
    else
      assignees = assignee_entries(issue)
      issue_number = issue["number"]

      %Issue{
        id: issue_number |> normalize_issue_identifier_value(),
        identifier: format_issue_identifier(issue_number),
        title: issue["title"],
        description: issue["body"],
        priority: nil,
        state: derive_workflow_state(issue),
        branch_name: nil,
        url: issue["html_url"],
        assignee_id: primary_assignee_login(assignees),
        blocked_by: [],
        labels: extract_labels(issue),
        assigned_to_worker: assigned_to_worker?(assignees, assignee_filter),
        created_at: parse_datetime(issue["created_at"]),
        updated_at: parse_datetime(issue["updated_at"])
      }
    end
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp derive_workflow_state(issue) do
    labels = raw_label_names(issue)

    case extract_state_label(labels) do
      state when is_binary(state) ->
        state

      _ ->
        case normalize_issue_state(issue["state"]) do
          "closed" -> default_terminal_state(issue["state_reason"])
          _ -> default_active_state()
        end
    end
  end

  defp extract_state_label(labels) when is_list(labels) do
    Enum.find_value(labels, &state_label_value/1)
  end

  defp state_label_value(label) when is_binary(label) do
    normalized_label = normalize_label_name(label)
    normalized_prefix = Config.github_state_label_prefix() |> normalize_label_name()

    if String.starts_with?(normalized_label, normalized_prefix) do
      label
      |> String.trim()
      |> String.slice(String.length(String.trim(Config.github_state_label_prefix()))..-1//1)
      |> to_string()
      |> String.trim()
      |> case do
        "" -> nil
        state_name -> state_name
      end
    else
      nil
    end
  end

  defp state_label_value(_label), do: nil

  defp default_active_state do
    List.first(Config.tracker_active_states()) || "Todo"
  end

  defp default_terminal_state("not_planned") do
    preferred_terminal_state(["Cancelled", "Canceled", "Closed", "Done"])
  end

  defp default_terminal_state(_state_reason) do
    preferred_terminal_state(["Done", "Closed", "Cancelled", "Canceled", "Duplicate"])
  end

  defp preferred_terminal_state(preferred_names) do
    terminal_states = Config.tracker_terminal_states()

    Enum.find(preferred_names, fn preferred ->
      Enum.any?(terminal_states, fn candidate ->
        normalize_issue_state(candidate) == normalize_issue_state(preferred)
      end)
    end) || List.first(terminal_states) || "Done"
  end

  defp state_label_name(state_name) when is_binary(state_name) do
    [Config.github_state_label_prefix(), state_name]
    |> Enum.join(" ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp replace_state_labels(labels, workflow_label) do
    labels
    |> Enum.reject(&state_label?/1)
    |> Kernel.++([workflow_label])
    |> Enum.uniq()
  end

  defp state_label?(label) when is_binary(label) do
    prefix = Config.github_state_label_prefix() |> normalize_label_name()
    String.starts_with?(normalize_label_name(label), prefix)
  end

  defp state_label?(_label), do: false

  defp issue_update_body(state_name, labels) do
    desired_state = desired_issue_state(state_name)

    %{"labels" => labels, "state" => desired_state}
    |> maybe_put_state_reason(state_name, desired_state)
  end

  defp desired_issue_state(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    if Enum.any?(Config.tracker_terminal_states(), &(normalize_issue_state(&1) == normalized_state)) do
      "closed"
    else
      "open"
    end
  end

  defp maybe_put_state_reason(body, _state_name, "open"), do: body

  defp maybe_put_state_reason(body, state_name, "closed") do
    normalized_state = normalize_issue_state(state_name)
    state_reason = if normalized_state in ["done", "closed"], do: "completed", else: "not_planned"

    Map.put(body, "state_reason", state_reason)
  end

  defp fetch_issue_states(repo, issue_ids, assignee_filter) do
    issue_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
      fetch_issue_state(repo, issue_id, assignee_filter, acc)
    end)
  end

  defp fetch_issue_state(repo, issue_id, assignee_filter, acc) do
    case fetch_issue(repo, issue_id) do
      {:ok, issue} ->
        {:cont, {:ok, maybe_prepend_normalized_issue(acc, issue, assignee_filter)}}

      {:error, {:github_api_status, 404, _body}} ->
        {:cont, {:ok, acc}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp maybe_prepend_normalized_issue(acc, issue, assignee_filter) do
    case normalize_issue(issue, assignee_filter) do
      nil -> acc
      normalized_issue -> [normalized_issue | acc]
    end
  end

  defp normalize_issue_number(issue_id) when is_binary(issue_id) do
    case Integer.parse(String.trim(issue_id)) do
      {issue_number, ""} when issue_number > 0 -> {:ok, issue_number}
      _ -> {:error, :invalid_github_issue_id}
    end
  end

  defp normalize_issue_number(issue_id) when is_integer(issue_id) and issue_id > 0, do: {:ok, issue_id}
  defp normalize_issue_number(_issue_id), do: {:error, :invalid_github_issue_id}

  defp normalize_issue_identifier_value(issue_number) when is_integer(issue_number), do: Integer.to_string(issue_number)
  defp normalize_issue_identifier_value(issue_number) when is_binary(issue_number), do: String.trim(issue_number)
  defp normalize_issue_identifier_value(_issue_number), do: nil

  defp format_issue_identifier(issue_number) when is_integer(issue_number), do: "##{issue_number}"
  defp format_issue_identifier(issue_number) when is_binary(issue_number), do: "##{String.trim(issue_number)}"
  defp format_issue_identifier(_issue_number), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp assignee_entries(%{"assignees" => assignees}) when is_list(assignees), do: assignees
  defp assignee_entries(_issue), do: []

  defp assigned_to_worker?(_assignees, nil), do: true

  defp assigned_to_worker?(assignees, %{match_values: match_values})
       when is_list(assignees) and is_struct(match_values, MapSet) do
    Enum.any?(assignees, fn assignee ->
      case assignee_login(assignee) do
        nil -> false
        login -> MapSet.member?(match_values, login)
      end
    end)
  end

  defp assigned_to_worker?(_assignees, _assignee_filter), do: false

  defp primary_assignee_login([assignee | _rest]), do: assignee_login(assignee)
  defp primary_assignee_login(_assignees), do: nil

  defp assignee_login(%{"login" => login}) when is_binary(login), do: String.downcase(String.trim(login))
  defp assignee_login(_assignee), do: nil

  defp routing_assignee_filter do
    case Config.github_assignee() do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case rest("GET", "/user") do
      {:ok, %{body: %{"login" => login}}} when is_binary(login) ->
        {:ok, %{configured_assignee: "me", match_values: MapSet.new([String.downcase(String.trim(login))])}}

      {:ok, _body} ->
        {:error, :missing_github_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp raw_label_names(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> String.trim(name)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp raw_label_names(_issue), do: []

  defp extract_labels(issue) do
    issue
    |> raw_label_names()
    |> Enum.map(&String.downcase/1)
  end

  defp normalize_label_name(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_issue_state(state_name), do: normalize_issue_state(to_string(state_name))

  defp pull_request?(%{"pull_request" => %{}}), do: true
  defp pull_request?(%{"pull_request" => _pull_request}), do: true
  defp pull_request?(_issue), do: false

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
