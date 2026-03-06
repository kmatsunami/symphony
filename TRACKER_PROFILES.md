# Tracker Profiles

This fork ships two concrete tracker profiles for the Symphony contract:

- `linear`: the original GraphQL-backed profile from `openai/symphony`
- `github`: a GitHub Issues-backed profile that replaces Linear project/state operations with REST
  calls plus workflow labels

The orchestrator only depends on the normalized tracker contract:

- fetch candidate issues in active states
- fetch issues by state for cleanup
- fetch current issue state by id for reconciliation
- create a tracker comment
- update tracker state

Everything else is profile-specific.

## Linear Profile

Current contract:

- `tracker.kind: linear`
- `tracker.endpoint`: defaults to `https://api.linear.app/graphql`
- `tracker.api_key`: reads `LINEAR_API_KEY` by default
- `tracker.project_slug`: required
- `tracker.assignee`: optional; defaults from `LINEAR_ASSIGNEE` when unset
- active and terminal workflow states come from `tracker.active_states` / `tracker.terminal_states`
- optional in-session tool: `linear_graphql`

Normalization details:

- issue `id` is the Linear internal issue id
- issue `identifier` is the Linear ticket key such as `ENG-123`
- `blocked_by` is derived from inverse `blocks` relations
- `branch_name` comes from Linear branch metadata when present

## GitHub Profile

Current contract:

- `tracker.kind: github`
- `tracker.endpoint`: defaults to `https://api.github.com`
- `tracker.api_key`: reads `GITHUB_TOKEN`, falling back to `GH_TOKEN`
- `tracker.repository`: required, format `owner/repo`
- `tracker.assignee`: optional; defaults from `GITHUB_ASSIGNEE` when unset
- `tracker.state_label_prefix`: defaults to `status:`
- active and terminal workflow states come from `tracker.active_states` / `tracker.terminal_states`
- optional in-session tool: `github_rest`

Normalization details:

- issue `id` is the GitHub issue number as a string
- issue `identifier` is `#<number>`
- pull requests are excluded from tracker issue polling
- `branch_name` is `nil` because GitHub issues do not carry branch metadata
- `blocked_by` is currently `[]` because this profile does not infer dependency graphs
- any label matching `<state_label_prefix> <State>` is treated as the workflow state, including
  open but inactive states such as `Human Review`
- if no workflow label is present, open issues default to the first configured active state and
  closed issues default to a terminal state

## Replacement Decisions

Linear-specific behavior is replaced in GitHub as follows:

| Linear concept | GitHub replacement |
| --- | --- |
| Project slug filter | Repository scope via `tracker.repository` |
| Workflow state object | Issue label `status: <State>` |
| Terminal state transition | Replace workflow label and close the issue |
| Active state transition | Replace workflow label and keep the issue open |
| Comment thread updates | Issue comments on `/issues/<number>/comments` |
| Raw Linear GraphQL access | Raw GitHub REST access via `github_rest` |
| Tracker key like `ENG-123` | GitHub issue number rendered as `#123` |

## Known Differences

- GitHub does not provide native per-issue workflow states; labels are the source of truth.
- GitHub issues do not expose branch metadata in the tracker payload, so branch selection remains a
  workflow or repository concern.
- GitHub dependency links are not normalized into `blocked_by` in this profile.
- PR linkage is still managed by the agent workflow, typically through PR body references such as
  `Closes #123`.
