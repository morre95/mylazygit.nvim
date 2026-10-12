# MyLazyGit

A minimal Neovim UI inspired by [lazygit](https://github.com/jesseduffield/lazygit) that focuses on the handful of git commands most people reach for every day. It runs entirely inside Neovim, so you can stage files, create commits, and sync with remotes without leaving your editor.

## Features

- Floating status window with the familiar `git status --short` view
- Always-on log/diff panel showing `git log --oneline` and a trimmed `git diff`, with color cues for pushed (green) vs local-only (red) commits
- Stage/unstage files via picker prompts, with multi-select support when staging
- Create commits with `vim.ui.input`
- Run `git init`, `git pull --rebase`, `git push`, and `git fetch`, with separate resolved pull and push targets
- Create GitHub pull requests from inside Neovim via `gh pr create`
- Create a GitHub repository from the current local repo via `gh repo create --source . --push` with private/public visibility
- Merge workflow that preserves shared feature history, with a separate reviewed rebase choice
- Temporary detached-checkout of selected commits (`gct`) with quick return (`gcr`) for commit-by-commit inspection
- Refresh view at any time to keep the status in sync

## Installation

Use your favorite plugin manager. Example with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
  'morre95/mylazygit.nvim',
  config = function()
    local branch = vim.fn.systemlist({ "git", "branch", "--show-current" })[1] or "main"
    local remote_name = vim.fn.systemlist({ "git", "remote" })[1] or "origin"
    require('mylazygit').setup({
      remote = remote_name,     -- change if you use something else
      branch_fallback = branch, -- default for workflow/base branch selection; sync refuses detached HEAD
      merge_workflow = {
        main_branch = branch,   -- base branch for the workflow helper
      },
      protected_branches = {},  -- branches gPF never rewrites, besides main and main_branch
      log_limit = 5,            -- number of log messages shown in the panel
      max_commit_lines = 100,   -- number of commits shown in the panel
      max_branch_lines = 10,    -- number of branches shown in the panel
      diff_args = { '--stat' }, -- passed to `git diff`
      diff_max_lines = 80,      -- trim diff panel for readability
    })
  end,
}
```

> **Heads up**: if you're hacking on this locally (e.g. the repo lives under `~/lua/MyLazyGit`) and it's not pushed to GitHub, tell lazy.nvim to load from the local path:

```lua
return {
  dir = '~/lua/mylazygit.nvim',  -- absolute path to your clone
  name = 'mylazygit',
  config = function()
    require('mylazygit').setup()
  end,
}
```

`gbw` operates on two local branches with valid upstreams and a clean worktree/index. It first fetches and fast-forwards main; divergence stops for your decision. It then fetches and merges the feature upstream, merges main into the feature, and merges the feature into main. The default **Merge** choice preserves published commit identities and allows ordinary publication with `P`. Missing, invalid or deleted synchronization targets stop the workflow; they are never skipped. Git settings such as `pull.rebase`, `merge.ff`, autostash and branch merge options cannot silently select replay, squash or leave a successful merge uncommitted.

The separate **Rebase** choice uses the same cleanup review as `gbr`: private replay needs explicit confirmation; published replay requires **Rewrite**, with protected branches and unknown publication evidence refused. Published cleanup retains the remote commit reviewed before replay for later `gPF`. `merge_workflow.rebase_args` is no longer supported: remove nonempty legacy arguments and choose reviewed rebase explicitly. Nothing in setup enables automatic rebase.

Cancellation at branch/integration selection changes no refs or index. Rebase review happens after synchronization; cancelling there preserves feature history and reports the synchronization steps already completed. On any conflict, hook rejection or other failed step, the workflow stops and reports the current repository state and completed, failed and remaining steps. Resolve conflicts with `X`, then use `gx` to recover the interrupted Git operation. Recovery does not resume the workflow. Inspect the remaining work and make a new explicit decision; publication always remains manual. After successful integration, publish main with ordinary `P`; switch to the feature to publish with `P` for merges/private replay or `gPF` for a reviewed published rewrite.

The plugin registers a `:MyLazyGit` command. Map it or call it directly:

```lua
vim.keymap.set('n', '<leader>lg', '<cmd>MyLazyGit<cr>', { desc = 'Open MyLazyGit' })
```

## In-app key bindings

### Main MyLazyGit window

Key | Action
--- | ---
`q` / `<Esc>` | Close the MyLazyGit window
`r` | Refresh all panes (`git status`, log, branches, diff)
`?` | Open in-app keymap help popup
`i` | Run `git init`
`<Space>` | Toggle stage/unstage for the file under cursor
`[` / `]` | Cycle bottom pane view (local branches / remote branches / diff preview)
`gsf` | Stage selected files (`git add <file>`)
`gsr` | Restore selected tracked files (`git restore -- <file>`)
`gsR` | Restore all tracked files (destructive)
`gsa` | Stage everything (`git add .`)
`gsc` | Stage all + commit
`gsC` | Stage all + commit + pull rebase + optional push
`gsu` | Unstage selected files (`git restore --staged <file>`)
`gsU` | Unstage everything (`git restore --staged .`)
`gsp` | Pull with rebase (same behavior as `p`)
`c` | Commit staged changes
`aic` | Generate AI commit message from staged diff and commit (OpenRouter)
`A` | Review and amend latest commit (includes staged changes)
`gss` | Review and squash a range of recent commits into one
`gct` | Temporarily detach and checkout selected commit
`gcr` | Return to branch/commit from temporary checkout
`p` | Pull with rebase from the current branch upstream (full remote source ref)
`P` | Publish to the resolved push target; review first publication before proceeding
`gPp` | Choose an explicit push remote and destination branch, then confirm the full destination
`gPF` | Rewrite the push destination with a reviewed lease (`--force-with-lease=<ref>:<reviewed commit>`)
`f` | Fetch configured remote
`gpr` | Create GitHub pull request via `gh pr create`
`ghr` | Create GitHub repo via `gh repo create --source . --push`
`C` | Check merge conflicts with `git merge-tree` simulation
`X` | Open 3-way conflict resolver for conflicted files
`gx` | Continue, abort or skip the actual interrupted Git operation
`R` | Add remote (`git remote add`)
`U` | Update remote URL (`git remote set-url`)
`gbn` | Create and switch to a new branch (`git switch -c`)
`gbs` | Switch to an existing local branch
`gbN` | Rename a local branch (`git branch -m`)
`gbR` | Fetch and switch to a remote branch (create tracking branch)
`gbd` | Delete local branch safely (`git branch -d`)
`gbD` | Force delete local branch (`git branch -D`)
`gbx` | Confirm the exact remote and full branch, then delete it (`git push <remote> --delete refs/heads/<branch>`)
`gbm` | Merge selected local branch into current branch
`gbw` | Integrate feature with history-preserving merges, or choose reviewed rebase
`gbr` | Review and rebase current branch onto selected branch
`gzz` | Stash push
`gzp` | Stash pop
`gzd` | Stash drop

The header displays `Pull: <remote> refs/heads/<branch>` and `Push: <remote> refs/heads/<branch>` separately. Pull follows `branch.<local>.remote` and `branch.<local>.merge`, including different local/remote names and custom fetch mappings. Ordinary synchronization refuses detached HEAD.

Push selects `branch.<local>.pushRemote`, then `remote.pushDefault`, then the branch upstream remote. A single configured `remote.<remote>.push` mapping takes precedence over `push.default`. Branch shorthand such as `topic:team-topic` resolves to a full branch destination; shorthand naming a remote tag or colliding branch/tag refs is refused, so use an explicit `refs/heads/` destination to remove ambiguity. Explicit `current`, `upstream`/`tracking`, and `simple` policies are respected; `nothing`, `matching`, forced or ambiguous mappings stop with an actionable explanation. The explicit `simple` policy permits first publication to a distinct fork with confirmation, while a central destination still requires an upstream. Without explicit push policy, local `topic` tracking `origin/team-topic` publishes to `refs/heads/team-topic`; a distinct fork remote uses `refs/heads/topic`.

First publication and `gPp` overrides show the full remote and destination ref and default to cancellation. With no push mapping, use `gPp` to deliberately choose a remote and branch. Publication sets a pull upstream only when one is absent; publishing to a fork preserves an existing upstream. Ordinary push publishes one branch without force or automatic follow-tags; multiple push endpoints and mirror configuration are refused. Divergent remote history is rejected by Git. The `gsC` chain stops after a failed pull.

Local deletion (`gbd` / `gbD`) always stays local: deleting `team/task` leaves the remote `team` branch `task` untouched. Safe deletion refuses unmerged branches; force deletion has a separate confirmation. Both respect branches checked out in any worktree.

Remote deletion requires `gbx`. Its picker and confirmation identify the configured remote and full branch name separately, including names containing slashes. Cancelling the picker or confirmation changes no refs. Local branches and same-named remote tags remain intact. Tracking refs matching more than one configured remote prefix are omitted, so overlapping remote names cannot select a guessed destination.

Commit publication labels and colors describe the selected **push destination's cached remote-tracking history**. `[published]` (green) means the commit is reachable from that tracking history; `[local-only]` (red) means it is absent from that history; `[unknown]` (gray) means evidence is unavailable. Different pull/push remotes and differently named branches use the resolved destination rather than the local branch name. Missing upstreams, tracking refs or mappings, excluded/ambiguous mappings, split fetch/push endpoints, shallow ancestry and failed inspection remain unknown. These labels never confirm the live remote's current state.

The header shows `Fetch: unobserved`, `Fetch: cached <time>`, or a failed latest attempt with the last successful time when available. Freshness records successful plugin `fetch` actions for the actual fetched branch, endpoint, mapping and tracking commit. It is shared across sessions and linked worktrees in the same Neovim process and invalidated when that evidence changes. A fetch of another remote, an unpruned deleted branch, a new unobserved tracking ref, external fetches, implicit pull fetches and editor restarts do not gain a target fetch time. Cached evidence can become stale immediately after a teammate pushes; the header always says `live remote unverified`.

The remote deletion picker supports exactly one standard fetch mapping per configured remote: `refs/heads/*:refs/remotes/<remote>/*` (with an optional leading `+`). If any remote has custom, additional or missing fetch mappings, the entire picker is empty. Such mappings can populate another remote's tracking namespace, so this action declines to guess the actual destination. Other remote operations remain available.

### Conflict resolver (`X`) key bindings

Key | Action
--- | ---
`j` / `k` | Next/previous conflict
`l` | Accept local change (ours) for current conflict
`h` | Accept incoming change (theirs) for current conflict
`a` | Accept all local changes
`A` | Accept all incoming changes
`f` | Select a different conflicted file
`s` | Save resolved file and stage it
`q` / `<Esc>` | Quit resolver without saving

### Pane navigation key bindings (main window)

Key | Action
--- | ---
`<Tab>` / `<S-Tab>` | Move focus between panes
`<C-h>` | Jump back to previous pane focus
`<C-l>` | Jump to preview pane

## AI-generated commit messages

MyLazyGit can ask [OpenRouter](https://openrouter.ai) for concise commit messages that describe your staged diff.

- Export `OPENROUTER_API_KEY` (or set `ai.api_key` in the plugin setup).
- Press `aic` inside MyLazyGit (or run `:MyLazyGitAICommit`) to let the model draft the commit message. You can edit the suggestion before it commits.
- Use `:MyLazyGitAISwitchModel` to swap to any other OpenRouter model id on the fly.

The AI helper defaults to `google/gemini-2.5-flash-lite`. Override anything inside `ai` if you prefer a different model or tuning:

```lua
require('mylazygit').setup({
  ai = {
    api_key = os.getenv("OPENROUTER_API_KEY"),
    model = "openai/gpt-4o-mini",
    temperature = 0.3,
    max_tokens = 256,
    diff_max_lines = 400,
  },
})
```

The floating buffer is read-only and safe to keep open while editing. MyLazyGit automatically redraws after every git action so the status never goes stale.

## Notes

- Opening MyLazyGit captures the current Git worktree. Status, previews, staging, commits, network operations, GitHub commands, AI prompts, and conflict resolution continue using that worktree after `:cd`, `:lcd`, or a file-tree directory change. Change directories before launching to choose a worktree. Calling `:MyLazyGit` while it is open focuses the existing session. Close it and reopen to choose another worktree.
- Pending prompts and callbacks retain their original worktree even if another session opens; they cannot redraw the other session. Temporary checkout return points are remembered separately for each worktree until you return or exit Neovim.
- Raw force push is not offered. `gPF` publishes an intentional rewrite (after amend or rebase) to the resolved push destination: a review shows the push endpoint, the full destination ref, the remote commit being replaced and the local commit replacing it, and defaults to cancellation, which changes nothing. The push uses an explicit `--force-with-lease=<ref>:<reviewed commit>`; if a teammate advanced the branch since review, even when a fetch updated your tracking ref meanwhile, Git rejects it. A rejected rewrite is never renewed, retried with raw force or turned into an ordinary push; fetch and review again. `main`, `merge_workflow.main_branch` and every `protected_branches` entry (names or `refs/heads/` refs) are refused before review. A destination without remote history uses ordinary push instead.
- History cleanup (`A`, `gss`, `gbr`) classifies the commits it will replace using the same publication evidence as the commit display. Private commits require an explicit operation choice; any affected published commit requires an explicit **Rewrite** choice showing the destination, endpoint and reviewed remote commit. Unknown evidence stops cleanup, and published cleanup of `main`, `merge_workflow.main_branch` or `protected_branches` is refused. All choices default to cancellation, which preserves refs and staged work. Amend and squash include existing staged changes. Squash excludes the root commit and restores the original branch tip and index if the commit fails. Rebase changes only the reviewed current branch, even with `rebase.updateRefs` enabled; conflicts use `X` and `gx` for recovery.
- Private cleanup normally publishes with `P`. Published cleanup retains its original reviewed remote expectation in the Neovim session; later `gPF` uses that lease through UI reopen, further cleanup, conflict recovery and fetches. A teammate push rejects publication without overwriting their history. A failed lease stays rejected and is never automatically renewed.
- Branch detection reads the full local ref with `git symbolic-ref --quiet HEAD`, so a same-named remote-tracking ref cannot alter the local branch name. Detached HEAD shows a clear warning (including the short HEAD hash) plus a reminder in the info area.
- Log colors can be customized by redefining the `MyLazyGitPushed`, `MyLazyGitUnpushed` and `MyLazyGitUnknown` highlight groups.
- Pull request creation uses the [GitHub CLI](https://cli.github.com/) (`gh`). Install it and run `gh auth login` before using the `gpr` keymap.
- `gpr` uses the resolved push destination as its PR head and the pull upstream remote as its base repository (falling back to the configured remote when no upstream exists). For known GitHub fork URLs, it passes `--head user:branch` and `--repo owner/repo`, deriving the head owner from the effective push URL. Unknown or ambiguous fork identities stop with guidance before publication. GitHub CLI supports user-owned fork heads; organization-owned fork heads are unsupported. It confirms first publication before pushing and continuing PR creation; an existing pull upstream is preserved.
- Repository creation (`ghr`) also uses `gh` and runs `gh repo create --source . --push` with your chosen visibility (`private` or `public`).
- This is intentionally tiny and focused; for the full TUI experience, use the original [lazygit](https://github.com/jesseduffield/lazygit).

## Repository sessions and verification

Existing Git-module functions keep their invocation-time working-directory behavior. Callers needing a stable context can capture a session and use the same operations and return values:

```lua
local repo = require('mylazygit.git').session() -- optional directory argument
local root = repo.worktree()
local ok, output = repo.stage({ 'file.lua' })
```

Mutations are serialized per physical worktree, including legacy calls, AI commits, conflict saves and GitHub commands. A second mutation is rejected with a diagnostic while one runs; linked worktrees can act independently. Pending prompts revalidate branch, HEAD, staged content and selected refs before acting. Interrupted merges/rebases/cherry-picks/reverts reject unrelated mutations while permitting staging, conflict resolution and recovery. The header shows running operations or recovery state; `X` resolves files and `gx` offers continue, abort or skip where Git supports it. Failed operations refresh the UI even when they leave conflicts or other partial changes. Commit/pull/push stops immediately after a failed pull.

Every session mutation keeps its existing `ok, output` return values (or callback parameters) and adds a third outcome with `status` (`success`, `failed`, `rejected`, `cancelled`), `action`, `target`, `diagnostics`, current `state`, `recovery` actions and `changed`. `repo.repository_state()` exposes HEAD, branch, staged/worktree changes, refs, conflicts, interrupted operation (including its current commit/merge identity) and running mutation. `repo.cancel_mutation(action, target)` reports cancellation without changing Git state.

For dependent operations, use `repo.mutate(action, function() ... return ok, output end, opts)` or `repo.mutate_async(action, function(done) ... done(ok, output) end, callback, opts)`; nested session mutations share the reservation. Finish every asynchronous path with `done`, including cancellation (`done(false, diagnostics, "cancelled")`). Pass an earlier `repo.repository_state()` as `opts.expected` to reject stale intent and `opts.target` to describe the workflow. `repo.resolve_conflict(file, lines, opts)` reserves before writing and staging; `opts.contents` can guard against an edited conflict file. For custom prompts inside a reserved workflow, call providers through `repo.without_mutation(provider, ...)` and bind the intended callback with `repo.user_callback(callback)`; external UI actions then cannot borrow that reservation. `repo.recover(operation, action, callback, opts)` accepts `opts.expected` from the recovery prompt, rejects a replaced operation, and acts only on the actual interrupted operation and sets its editor environment locally.

Reservations coordinate this Neovim process's plugin actions. External Git processes remain subject to Git's own locking; state is rechecked before dependent plugin actions. Closing the UI does not cancel a Git process already running.

Resolved synchronization uses `repo.resolve_pull_target()` and `repo.resolve_push_target(opts)` to obtain a target or `nil, reason`. A target carries its source `head`, `local_branch`, `remote`, the full remote-side `ref`, and its short `branch`; push targets also carry `requires_confirmation` and `set_upstream`. Pass `{ inspect_remote = true }` when preparing publication to check the effective push URL and detect first publication; `{ remote = ..., ref = "refs/heads/..." }` selects an explicit override. After reviewing a required confirmation, set `target.confirmed = true`.

`repo.publication_snapshot(target, limit)` returns `{ state, head, target, tracking_ref, tracking_oid, reason, freshness, commits }`. Omitting `target` selects the resolved push destination; pass a current resolved pull or push target to inspect a different destination through the same classification. `state` classifies HEAD as `published`, `local-only`, or `unknown` independently of the display limit. Commit entries include full `oid`, display `hash`, `message`, and `publication` with the same three states. Missing or failed evidence keeps all entries unknown and supplies `reason`; a stale explicit source or push endpoint is also refused. Later history-rewrite decisions must consume this classification and must not treat unknown as permission. `freshness.state` is `unobserved`, `cached`, or `failed`, with optional `fetched_at` and `failed_at` Unix timestamps. Publication inspection reads cached refs without fetching. The legacy `unpushed` list remains available, but its empty list does not establish publication.

`repo.resolve_pr_target(push_target, base_remote)` returns an explicit GitHub `{ repo, head }` identity for PR creation, or `nil, reason` when a fork cannot be identified safely. Same-repository local transport adapters retain their unqualified head behavior.

Execute through `repo.pull_target(target, true)` (rebase) or `repo.push_target(target)`, with async counterparts `pull_target_async(target, true, callback)` and `push_target_async(target, callback)`. Execution revalidates source commit, branch, destination, push endpoint, and confirmation before running. Legacy explicit positional calls remain available, including branch and tag refspecs, but ordinary push refuses forced refspecs, mirror configuration and multiple endpoints.

Intentional rewrites use `repo.resolve_rewrite_target(opts)`, which resolves the push destination, refuses `main`, any additional protected branches in `opts.protected`, and missing remote history, and records the reviewed remote commit as `target.expected`. After review, set `target.confirmed = true` and execute `repo.push_rewrite_target(target)` or `repo.push_rewrite_target_async(target, callback)`. Execution revalidates source commit, branch, destination and protection, then leases exactly `target.ref:target.expected`; a stale lease fails without changing remote history.

History cleanup uses `repo.resolve_cleanup_target(operation, opts)` with `operation` equal to `amend`, `squash` (`opts.count`) or `rebase` (`opts.onto`, a local branch), and optional additional `opts.protected` branches. The returned target captures repository intent, affected-history classification and any reviewed publication lease. Set `target.confirmed = true` for the explicit operation choice; published history also requires `target.rewrite_confirmed = true`. Execute with `repo.cleanup_target(target, message)` and inspect its mutation outcome for recovery state. The compatible `commit_amend(message, target)` and `rebase(branch, target)` entrypoints require that review target. `repo.resolve_cleanup_publication(opts)` returns the retained pre-cleanup lease with the current source HEAD for a later confirmed rewrite; successful rewrite publication clears it. Reviews live for the current Neovim process and are scoped to the physical worktree and local branch.

`repo.merge_workflow({ main_branch = "main", feature_branch = "topic" })` runs the history-preserving workflow under one repository reservation. Both branches must have valid upstreams; main synchronization is fast-forward only. The third return value is the mutation outcome, including `state`, `recovery` and `workflow`: `completed` lists successful steps, `failed` identifies the stopped step, and `remaining` lists subsequent steps that did not run (excluding the failed step). Preflight refusal leaves all planned steps remaining. After execution starts, `workflow.publication` is `ordinary` or `reviewed-rewrite`; no workflow pushes automatically.

For explicit replay, pass `mode = "rebase"`, optional `protected` branches, and `review_cleanup = function(target) ... end`. The callback receives the existing cleanup review target after synchronization and must obtain an explicit choice, set `target.confirmed = true` (plus `target.rewrite_confirmed = true` for published history), and return true. A false/nil return cancels replay and returns status `cancelled`, with earlier synchronization still reported. The callback runs outside mutation ownership; cleanup revalidates its review afterward. Unknown publication evidence and protected published history are refused before the callback. After a published replay, switch to the feature and use `resolve_cleanup_publication` to retrieve the retained pre-cleanup lease. `mode = "merge"` is the default, regardless of Git rebase preferences or legacy setup arguments.

Branch deletion uses separate inputs: `repo.delete_local_branch(name, force)` acts only on local branches (`delete_branch` remains a compatible alias), while `repo.delete_remote_branch(remote, branch)` takes the configured remote and full branch name separately. `repo.remote_branch_destinations()` returns unambiguous `{ remote = ..., branch = ... }` entries for deletion pickers; `repo.remote_branches()` keeps its existing string interface.

Session paths resolve to the worktree root, including linked worktrees and sessions opened from subdirectories. Opening outside a repository captures that directory so `i` can initialize it.

Run the isolated integration harness from the project root:

```sh
./tests/run.sh
```

The harness requires Git, Neovim 0.10+ and a POSIX shell. It creates a temporary local bare remote and two clones per scenario, isolates Git configuration, and removes fixtures afterward. It verifies actual Git outcomes through session operations and UI actions, including held asynchronous publication barriers, overlap refusal, partial failures and recovery, delayed/stale prompts, session reopening, async fetch, checkout return, linked worktrees, publication classification/freshness, reviewed-lease rewrites (stale leases after a teammate push and fetch or a deleted/recreated branch, cancellation and protected branches), and synchronous execution fallbacks. GitHub and AI transport are replaced with local test adapters; no account or network is required. The plugin retains its existing older-Neovim fallback; the harness exercises that path on the installed Neovim by disabling `vim.system` for those scenarios.
