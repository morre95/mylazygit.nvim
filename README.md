# MyLazyGit

A minimal Neovim UI inspired by [lazygit](https://github.com/jesseduffield/lazygit) that focuses on the handful of git commands most people reach for every day. It runs entirely inside Neovim, so you can stage files, create commits, and sync with remotes without leaving your editor.

## Features

- Floating status window with the familiar `git status --short` view
- Always-on log/diff panel showing `git log --oneline` and a trimmed `git diff`, with color cues for pushed (green) vs local-only (red) commits
- Stage/unstage files via picker prompts, with multi-select support when staging
- Create commits with `vim.ui.input`
- Run `git init`, `git pull --rebase`, `git push`, and `git fetch` against a configurable remote
- Create GitHub pull requests from inside Neovim via `gh pr create`
- Create a GitHub repository from the current local repo via `gh repo create --source . --push` with private/public visibility
- One-key merge workflow that rebases a feature branch on main before merging it back
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
      branch_fallback = branch, -- used when HEAD is detached
      merge_workflow = {
        main_branch = branch,   -- base branch for the workflow helper
        rebase_args = {},       -- extra args for `git rebase` (e.g. { '-i' })
      },
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

> **Note:** The workflow operates only on local branches. It will pull a branch only when it has an upstream configured (`branch@{upstream}`); otherwise the pull step is skipped. Pull steps are run with `--rebase` to keep history linear and avoid merge commits like `Merge branch 'main' of ...` after conflict resolution. Interactive rebases (e.g. `rebase_args = { '-i' }`) still require a working `$GIT_SEQUENCE_EDITOR` inside Neovim (many users rely on `nvr --remote-wait`); without that setup Git will block waiting for an editor.

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
`A` | Amend latest commit (`git commit --amend`)
`gss` | Squash a range of recent commits into one
`gct` | Temporarily detach and checkout selected commit
`gcr` | Return to branch/commit from temporary checkout
`p` | Pull with rebase from configured remote/branch (`git pull --rebase`)
`P` | Push current branch (`git push`)
`gPF` | Force push current branch (`git push --force`)
`f` | Fetch configured remote
`gpr` | Create GitHub pull request via `gh pr create`
`ghr` | Create GitHub repo via `gh repo create --source . --push`
`C` | Check merge conflicts with `git merge-tree` simulation
`X` | Open 3-way conflict resolver for conflicted files
`R` | Add remote (`git remote add`)
`U` | Update remote URL (`git remote set-url`)
`gbn` | Create and switch to a new branch (`git switch -c`)
`gbs` | Switch to an existing local branch
`gbR` | Fetch and switch to a remote branch (create tracking branch)
`gbd` | Delete local branch safely (`git branch -d`)
`gbD` | Force delete local branch (`git branch -D`)
`gbx` | Delete remote branch (`git push <remote> --delete <branch>`)
`gbm` | Merge selected local branch into current branch
`gbw` | Run merge workflow helper (sync/rebase/merge flow)
`gbr` | Rebase current branch onto selected branch
`gzz` | Stash push
`gzp` | Stash pop
`gzd` | Stash drop

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

- All git operations happen in the current working directory of Neovim. Change directories (`:cd`, `:lcd`, or via your file tree) before launching if needed.
- Branch detection relies on `git rev-parse --abbrev-ref HEAD`. When HEAD is detached, the UI now shows a clear detached warning (including the short HEAD hash) plus a reminder in the info area.
- Log colors can be customized by redefining the `MyLazyGitPushed` and `MyLazyGitUnpushed` highlight groups.
- Pull request creation uses the [GitHub CLI](https://cli.github.com/) (`gh`). Install it and run `gh auth login` before using the `gpr` keymap.
- When you trigger `gpr` from a branch that has not been pushed/upstreamed yet, mylazygit.nvim asks whether it should push with upstream first and then continue PR creation.
- Repository creation (`ghr`) also uses `gh` and runs `gh repo create --source . --push` with your chosen visibility (`private` or `public`).
- This is intentionally tiny and focused; for the full TUI experience, use the original [lazygit](https://github.com/jesseduffield/lazygit).
