# Issue tracker: GitHub

Issues and specs live in GitHub Issues for `Insulinocytus/balatro-mcp`.
Use the `gh` CLI from this clone; it resolves the repository from the Git remote.

## Conventions

- Create: `gh issue create --title "..." --body "..."`.
  For multiline bodies, use `--body-file <path>`.
- Read: `gh issue view <number> --comments`.
  For structured data, use `--json number,title,body,labels,comments`.
- List: `gh issue list --state open --json number,title,body,labels,comments`.
  Add appropriate `--label` and `--state` filters; use `--jq` to filter JSON.
- Comment: `gh issue comment <number> --body "..."`.
- Apply or remove labels: `gh issue edit <number> --add-label "..."`
  or `--remove-label "..."`. Read `docs/agents/triage-labels.md` for role mappings.
- Close: `gh issue close <number> --comment "..."`.

## Pull requests as a triage surface

**PRs as a request surface: no.**

## Skill operations

- "Publish to the issue tracker": create a GitHub issue.
- "Fetch the relevant ticket": run `gh issue view <number> --comments`.

## Wayfinding operations

- Map: one issue labelled `wayfinder:map`, with Notes, Decisions-so-far, and Fog.
- Child ticket: link it as a GitHub sub-issue using `gh api`.
  If sub-issues are unavailable, use a task list in the map and
  `Part of #<map>` in the child body.
- Child labels: `wayfinder:<type>`, where type is
  `research`, `prototype`, `grilling`, or `task`.
- Blocking: use native issue dependencies.
  Add an edge with
  `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`.
  Get the numeric database ID with
  `gh api repos/<owner>/<repo>/issues/<number> --jq .id`.
  If dependencies are unavailable, use `Blocked by: #<number>` in the child body.
- Frontier: select the first open child in map order with no assignee
  and no open blockers. Native `issue_dependencies_summary.blocked_by`
  counts open blockers; otherwise inspect the `Blocked by` references.
- Claim: `gh issue edit <number> --add-assignee @me`, as the session's first write.
- Resolve: comment with the answer, close the child, then add a concise
  result and link to the map's Decisions-so-far.
