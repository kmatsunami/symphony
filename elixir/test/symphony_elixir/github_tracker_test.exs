defmodule SymphonyElixir.GithubTrackerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Github.Client

  setup do
    github_request_fun = Application.get_env(:symphony_elixir, :github_request_fun)

    on_exit(fn ->
      if is_nil(github_request_fun) do
        Application.delete_env(:symphony_elixir, :github_request_fun)
      else
        Application.put_env(:symphony_elixir, :github_request_fun, github_request_fun)
      end
    end)

    :ok
  end

  test "github config validates repository and resolves auth from GITHUB_TOKEN" do
    previous_github_token = System.get_env("GITHUB_TOKEN")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_github_token) end)

    System.put_env("GITHUB_TOKEN", "github-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_repository: "kmatsunami/symphony"
    )

    assert Config.github_api_token() == "github-token"
    assert Config.github_repository() == "kmatsunami/symphony"
    assert Config.tracker_endpoint() == "https://api.github.com"
    assert :ok = Config.validate!()

    System.delete_env("GITHUB_TOKEN")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_repository: nil
    )

    assert {:error, :missing_github_api_token} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "github-token",
      tracker_project_slug: nil,
      tracker_repository: nil
    )

    assert {:error, :missing_github_repository} = Config.validate!()
  end

  test "github client fetches candidate issues, skips pull requests, and normalizes workflow state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "github-token",
      tracker_project_slug: nil,
      tracker_repository: "kmatsunami/symphony"
    )

    Application.put_env(:symphony_elixir, :github_request_fun, fn opts ->
      assert opts[:method] == :get
      assert opts[:url] == "https://api.github.com/repos/kmatsunami/symphony/issues"

      {:ok,
       %Req.Response{
         status: 200,
         body: [
           %{
             "number" => 101,
             "title" => "Todo issue",
             "body" => "description",
             "state" => "open",
             "labels" => [%{"name" => "status: Todo"}, %{"name" => "backend"}],
             "assignees" => [%{"login" => "kentoku"}],
             "html_url" => "https://github.com/kmatsunami/symphony/issues/101",
             "created_at" => "2026-01-01T00:00:00Z",
             "updated_at" => "2026-01-01T00:01:00Z"
           },
           %{
             "number" => 102,
             "title" => "Pull request masquerading as issue",
             "body" => nil,
             "state" => "open",
             "pull_request" => %{"url" => "https://api.github.com/repos/kmatsunami/symphony/pulls/102"},
             "labels" => [%{"name" => "status: In Progress"}],
             "assignees" => [],
             "html_url" => "https://github.com/kmatsunami/symphony/pull/102",
             "created_at" => "2026-01-01T00:00:00Z",
             "updated_at" => "2026-01-01T00:01:00Z"
           },
           %{
             "number" => 103,
             "title" => "Done issue should not dispatch",
             "body" => nil,
             "state" => "open",
             "labels" => [%{"name" => "status: Done"}],
             "assignees" => [],
             "html_url" => "https://github.com/kmatsunami/symphony/issues/103",
             "created_at" => "2026-01-01T00:00:00Z",
             "updated_at" => "2026-01-01T00:01:00Z"
           }
         ],
         headers: []
       }}
    end)

    assert {:ok, [issue]} = Client.fetch_candidate_issues()
    assert issue.id == "101"
    assert issue.identifier == "#101"
    assert issue.state == "Todo"
    assert issue.labels == ["status: todo", "backend"]
    assert issue.assignee_id == "kentoku"
  end

  test "github client preserves non-active open workflow states from status labels" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "github-token",
      tracker_project_slug: nil,
      tracker_repository: "kmatsunami/symphony"
    )

    Application.put_env(:symphony_elixir, :github_request_fun, fn opts ->
      assert opts[:method] == :get
      assert opts[:url] == "https://api.github.com/repos/kmatsunami/symphony/issues/104"

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "number" => 104,
           "title" => "Waiting for review",
           "body" => nil,
           "state" => "open",
           "labels" => [%{"name" => "status: Human Review"}],
           "assignees" => [],
           "html_url" => "https://github.com/kmatsunami/symphony/issues/104",
           "created_at" => "2026-01-01T00:00:00Z",
           "updated_at" => "2026-01-01T00:01:00Z"
         },
         headers: []
       }}
    end)

    assert {:ok, [issue]} = Client.fetch_issue_states_by_ids(["104"])
    assert issue.state == "Human Review"
  end

  test "github client updates state labels and closes terminal issues" do
    test_pid = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "github-token",
      tracker_project_slug: nil,
      tracker_repository: "kmatsunami/symphony"
    )

    Application.put_env(:symphony_elixir, :github_request_fun, fn opts ->
      send(test_pid, {:github_request, opts[:method], opts[:url], opts[:params], opts[:json]})

      case {opts[:method], opts[:url]} do
        {:get, "https://api.github.com/repos/kmatsunami/symphony/issues/101"} ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "number" => 101,
               "title" => "Tracked issue",
               "body" => "description",
               "state" => "open",
               "labels" => [%{"name" => "bug"}, %{"name" => "status: In Progress"}],
               "assignees" => [],
               "html_url" => "https://github.com/kmatsunami/symphony/issues/101",
               "created_at" => "2026-01-01T00:00:00Z",
               "updated_at" => "2026-01-01T00:01:00Z"
             },
             headers: []
           }}

        {:patch, "https://api.github.com/repos/kmatsunami/symphony/issues/101"} ->
          {:ok, %Req.Response{status: 200, body: %{"ok" => true}, headers: []}}
      end
    end)

    assert :ok = Client.update_issue_state("101", "Done")

    assert_received {:github_request, :get, "https://api.github.com/repos/kmatsunami/symphony/issues/101", nil, nil}

    assert_received {:github_request, :patch, "https://api.github.com/repos/kmatsunami/symphony/issues/101", nil,
                     %{
                       "labels" => ["bug", "status: Done"],
                       "state" => "closed",
                       "state_reason" => "completed"
                     }}
  end

  test "github dynamic tool advertises and executes the github_rest contract" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "github-token",
      tracker_project_slug: nil,
      tracker_repository: "kmatsunami/symphony"
    )

    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "body" => _,
                   "method" => _,
                   "path" => _,
                   "query" => _
                 },
                 "required" => ["path"],
                 "type" => "object"
               },
               "name" => "github_rest"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "GitHub"

    response =
      DynamicTool.execute(
        "github_rest",
        %{
          "method" => "PATCH",
          "path" => "/repos/kmatsunami/symphony/issues/101",
          "body" => %{"labels" => ["status: Done"]}
        },
        github_rest_client: fn method, path, opts ->
          assert method == "PATCH"
          assert path == "/repos/kmatsunami/symphony/issues/101"
          assert opts[:body] == %{"labels" => ["status: Done"]}
          {:ok, %{status: 200, body: %{"id" => 101, "state" => "closed"}, headers: []}}
        end
      )

    assert response["success"] == true
    assert [%{"text" => text}] = response["contentItems"]
    assert Jason.decode!(text) == %{"id" => 101, "state" => "closed"}
  end
end
