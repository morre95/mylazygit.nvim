# Issue tracker: GitHub

Issues and specs live in GitHub Issues for `morre95/mylazygit.nvim`.
Use the `gh` CLI for tracker operations; specify `--repo morre95/mylazygit.nvim` when the working directory does not identify the repository.

## Conventions

- Create an issue with `gh issue create --title "..." --body-file <file>`. Use a temporary UTF-8 file for multiline bodies, preserving actual newlines.
- Read an issue with `gh issue view <number> --json number,title,body,labels,comments`.
- List issues with `gh issue list --state open --json number,title,body,labels`, adding label filters as appropriate. Fetch comments for each issue when the skill requires the full discussion.
- Comment with `gh issue comment <number> --body-file <file>`.
- Apply or remove labels with `gh issue edit <number> --add-label "..." --remove-label "..."`.
- Close with `gh issue close <number>`, adding the requested explanatory comment when applicable.
- GitHub shares one number space for issues and pull requests. Resolve a bare reference against the actual object; do not treat a pull request as a spec issue without checking its contents.

## Publishing specs and tickets

When a skill says to publish to the tracker, create a GitHub issue.
Use the spec or ticket template from the invoked skill and apply `ready-for-agent` when that skill requires it.
Fetch referenced issues with their full body and comments before synthesizing work.
A source draft or conversation has no parent issue until a spec issue is actually published.

## Parent and blocking relationships

Use native GitHub sub-issues when a ticket has a parent spec.
Prefer `gh issue create --parent <parent> ...` or `gh issue edit <parent> --add-sub-issue <child>` when supported by the installed CLI.
Otherwise use `gh api --method POST repos/morre95/mylazygit.nvim/issues/<parent>/sub_issues -F sub_issue_id=<child-database-id>`.
If sub-issues are unavailable, put `Part of #<parent>` in the child body.
Do not otherwise edit or close a parent unless the invoked skill or user authorizes it.

Use native blocking relationships when available:
`gh api --method POST repos/morre95/mylazygit.nvim/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-database-id>`.
Obtain the database ID with `gh api repos/morre95/mylazygit.nvim/issues/<number> --jq .id`; this is not the issue number or GraphQL node ID.
If native dependencies are unavailable, record `Blocked by: #<number>` references in each ticket body.
Create blockers before their dependents and work the frontier: tickets whose blockers are all complete.

## Pull requests as a triage surface

**PRs as a request surface: no.**

## Wayfinding

A wayfinding map is an issue labelled `wayfinder:map`; its child tickets use `wayfinder:<type>` labels as required by the wayfinder skill.
Use the same parent and native blocking conventions above.
Claim work with `gh issue edit <number> --add-assignee @me`.
Resolve a decision ticket by posting its answer, closing it, and recording the result in the map as directed by the invoked skill.
