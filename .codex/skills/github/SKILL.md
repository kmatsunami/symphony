---
name: github
description: |
  Use Symphony's `github_rest` client tool for GitHub issue, comment, and
  workflow-label operations during app-server sessions.
---

# GitHub REST

Use this skill for tracker operations when Symphony is running with
`tracker.kind: github`.

## Primary tool

Use the `github_rest` client tool exposed by Symphony's app-server session.
It reuses Symphony's configured GitHub auth for the session.

Tool input:

```json
{
  "method": "GET",
  "path": "/repos/owner/repo/issues/123",
  "query": {
    "optional": "query parameters"
  },
  "body": {
    "optional": "json body"
  }
}
```

Tool behavior:

- `path` must be an absolute GitHub API path such as `/repos/owner/repo/issues/123`.
- Supported methods: `GET`, `POST`, `PATCH`, `PUT`, `DELETE`.
- Keep requests narrowly scoped; ask only for the fields you need.

## Workflow conventions

- Workflow state lives in exactly one label matching `status: <State>` unless the repository
  overrides `tracker.state_label_prefix`.
- Preserve non-workflow labels when changing state.
- Use one persistent issue comment headed by `## Codex Workpad` as the live scratchpad.
- Prefer editing the existing workpad comment rather than creating new progress comments.

## Common operations

### Read the tracked issue

```json
{
  "method": "GET",
  "path": "/repos/owner/repo/issues/123"
}
```

### List issue comments

```json
{
  "method": "GET",
  "path": "/repos/owner/repo/issues/123/comments"
}
```

### Create a workpad or status comment

```json
{
  "method": "POST",
  "path": "/repos/owner/repo/issues/123/comments",
  "body": {
    "body": "## Codex Workpad\n- [ ] Plan ..."
  }
}
```

### Update an existing issue comment

```json
{
  "method": "PATCH",
  "path": "/repos/owner/repo/issues/comments/456789",
  "body": {
    "body": "## Codex Workpad\n- [x] Plan ..."
  }
}
```

### Move workflow state by replacing the status label

Keep unrelated labels, replace the single workflow label, and close the issue only for terminal
states:

```json
{
  "method": "PATCH",
  "path": "/repos/owner/repo/issues/123",
  "body": {
    "labels": ["bug", "status: In Progress"],
    "state": "open"
  }
}
```

Terminal example:

```json
{
  "method": "PATCH",
  "path": "/repos/owner/repo/issues/123",
  "body": {
    "labels": ["bug", "status: Done"],
    "state": "closed",
    "state_reason": "completed"
  }
}
```

### Create a follow-up issue

```json
{
  "method": "POST",
  "path": "/repos/owner/repo/issues",
  "body": {
    "title": "Follow-up: ...",
    "body": "Context, acceptance criteria, and link back to the originating issue.",
    "labels": ["status: Backlog"]
  }
}
```

## Practical guidance

- Use issue comments for tracker-side notes; use PR comments only for PR review discussion.
- When linking a PR to an issue, prefer `Closes #123` or another explicit issue reference in the PR
  body so the relationship appears in the GitHub timeline.
- If you must reset the workpad for a rework attempt, mark the previous comment as `Superseded`
  before creating a new `## Codex Workpad` comment.
