# MyLazyGit

A minimal Neovim UI inspired by [lazygit](https://github.com/jesseduffield/lazygit) that focuses on the handful of git commands most people reach for every day. It runs entirely inside Neovim, so you can stage files, create commits, and sync with remotes without leaving your editor.

## Features

- Floating status window with the familiar `git status --short` view
- Always-on log/diff panel showing `git log --oneline` and a trimmed `git diff`, with color cues for pushed (green) vs local-only (red) commits
- Stage/unstage files via picker prompts, with multi-select support when staging
- Create commits with `vim.ui.input`
- Run `git init`, `git pull --rebase`, `git push`, and `git fetch` against a configurable remote
- Create GitHub pull requests from inside Neovim via `gh pr create`
- One-key merge workflow that rebases a feature branch on main before merging it back
- Refresh view at any time to keep the status in sync

## Installation

Use your favorite plugin manager. Example with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
  'morre95/mylazygit.nvim',
  config = function()
    local branch = vim.fn.systemlist("git branch --show-current")[1] or "main"
    local remote_name = vim.fn.systemlist("git remote -v | cut -f1 | uniq")[1] or "origin"
    require('mylazygit').setup({
      remote = remote_name,        -- change if you use something else
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

Key | Action
--- | ---
`r` | Refresh the status view
`s` | Stage files (multi-select; keep choosing until you press Esc)
`a` | Stage everything (`git add .`)
`gsr` | Restore tracked files with unstaged changes (`git restore -- <file>`)
`u` | Unstage a file
`c` | Commit staged changes (prompts for message)
`p` | Pull with rebase from the configured remote/branch (`git pull --rebase`)
`P` | Push to the configured remote/branch
`f` | Fetch the configured remote
`gpr` | Create a GitHub pull request (prompts for title/base/body; requires `gh`)
`n` | Create and switch to a new branch (`git switch -c`)
`b` | Switch to an existing branch (picker)
`gbR` | Select and switch to a remote branch (creates a local tracking branch)
`R` | Run `git remote add` (prompts for name + URL)
`U` | Run `git remote set-url` (prompts for name + URL)
`i` | Run `git init`
`w` | Run the merge workflow (`checkout main` → `pull --rebase` → `checkout branch` → `pull --rebase` → `rebase` → `merge`)
`q` | Close the window

## AI-generated commit messages

MyLazyGit can ask [OpenRouter](https://openrouter.ai) for concise commit messages that describe your staged diff.

- Export `OPENROUTER_API_KEY` (or set `ai.api_key` in the plugin setup).
- Run `:MyLazyGitAICommit` to stage files as usual, then let the model draft the commit message. You can edit the suggestion before it commits.
- Use `:MyLazyGitAISwitchModel` to swap to any other OpenRouter model id on the fly.

The AI helper defaults to `meta-llama/llama-3.3-70b-instruct:free`, a low-cost instruct model that’s broadly available without relying on `:free` suffixed variants (those are limited per [OpenRouter’s free-usage limits](https://openrouter.ai/docs/api/reference/limits)). Override anything inside `ai` if you prefer a different model or tuning:

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
- Branch detection relies on `git rev-parse --abbrev-ref HEAD`. When HEAD is detached, the `branch_fallback` option is used instead.
- Log colors can be customized by redefining the `MyLazyGitPushed` and `MyLazyGitUnpushed` highlight groups.
- Pull request creation uses the [GitHub CLI](https://cli.github.com/) (`gh`). Install it and run `gh auth login` before using the `gpr` keymap.
- This is intentionally tiny and focused; for the full TUI experience, use the original [lazygit](https://github.com/jesseduffield/lazygit).
