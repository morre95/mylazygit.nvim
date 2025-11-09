# MyLazyGit

A minimal Neovim UI inspired by [lazygit](https://github.com/jesseduffield/lazygit) that focuses on the handful of git commands most people reach for every day. It runs entirely inside Neovim, so you can stage files, create commits, and sync with remotes without leaving your editor.

## Features

- Floating status window with the familiar `git status --short` view
- Always-on log/diff panel showing `git log --oneline` and a trimmed `git diff`, with color cues for pushed (green) vs local-only (red) commits
- Stage/unstage files via picker prompts, with multi-select support when staging
- Create commits with `vim.ui.input`
- Run `git init`, `git pull`, `git push`, and `git fetch` against a configurable remote
- Refresh view at any time to keep the status in sync

## Installation

Use your favorite plugin manager. Example with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
  'morre95/mylazygit.nvim',
  config = function()
    require('mylazygit').setup({
      remote = 'origin',        -- change if you use something else
      branch_fallback = 'main', -- used when HEAD is detached
      log_limit = 5,            -- number of commits shown in the panel
      diff_args = { '--stat' }, -- passed to `git diff`
      diff_max_lines = 80,      -- trim diff panel for readability
    })
  end,
}
```

> **Heads up**: if you're hacking on this locally (e.g. the repo lives under `~/lua/MyLazyGit`) and it's not pushed to GitHub, tell lazy.nvim to load from the local path:

```lua
return {
  dir = '~/lua/MyLazyGit',  -- absolute path to your clone
  name = 'mylazygit',
  config = function()
    require('mylazygit').setup()
  end,
}
```

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
`u` | Unstage a file
`c` | Commit staged changes (prompts for message)
`p` | Pull from the configured remote/branch
`P` | Push to the configured remote/branch
`f` | Fetch the configured remote
`n` | Create and switch to a new branch (`git switch -c`)
`b` | Switch to an existing branch (picker)
`R` | Run `git remote add` (prompts for name + URL)
`U` | Run `git remote set-url` (prompts for name + URL)
`i` | Run `git init`
`q` | Close the window

The floating buffer is read-only and safe to keep open while editing. MyLazyGit automatically redraws after every git action so the status never goes stale.

## Notes

- All git operations happen in the current working directory of Neovim. Change directories (`:cd`, `:lcd`, or via your file tree) before launching if needed.
- Branch detection relies on `git rev-parse --abbrev-ref HEAD`. When HEAD is detached, the `branch_fallback` option is used instead.
- Log colors can be customized by redefining the `MyLazyGitPushed` and `MyLazyGitUnpushed` highlight groups.
- This is intentionally tiny and focused; for the full TUI experience, use the original [lazygit](https://github.com/jesseduffield/lazygit).
