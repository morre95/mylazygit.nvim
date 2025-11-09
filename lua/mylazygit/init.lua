local git = require("mylazygit.git")
local ui = require("mylazygit.ui")

local M = {}

local config = {
	remote = "origin",
	branch_fallback = "main",
	log_limit = 5,
	diff_args = { "--stat" },
	diff_max_lines = 80,
}

local state = {
	status = {},
}

local keymap_mappings

local function ensure_highlight(name, opts)
	if vim.fn.hlexists(name) == 0 then
		vim.api.nvim_set_hl(0, name, opts)
	end
end

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "MyLazyGit" })
end

local function repo_required()
	if git.is_repo() then
		return true
	end
	notify("Not inside a git repository. Run `i` to init one.", vim.log.levels.WARN)
	return false
end

local function limit_lines(lines, max_lines)
	if not max_lines or #lines <= max_lines then
		return lines
	end

	local trimmed = {}
	for i = 1, max_lines - 1 do
		trimmed[i] = lines[i]
	end
	trimmed[max_lines] = string.format("... (%d more lines)", #lines - (max_lines - 1))
	return trimmed
end

local function collect_files(predicate)
	local files = {}
	for _, item in ipairs(state.status) do
		if not predicate or predicate(item) then
			table.insert(files, item.file)
		end
	end
	return files
end

local function has_staged_change(char)
	return char and char:match("%S") and char ~= "?" and char ~= "!"
end

local function has_unstaged_change(char)
	return char and char:match("%S") and char ~= "!"
end

local function select_multiple(files, prompt, on_done)
	if vim.tbl_isempty(files) then
		notify("No matching files for action: " .. prompt, vim.log.levels.WARN)
		return
	end

	local selected = {}

	local function step(available)
		if vim.tbl_isempty(available) then
			if #selected > 0 then
				on_done(selected)
			end
			return
		end

		vim.ui.select(available, { prompt = prompt .. " (Esc to finish)" }, function(choice)
			if not choice then
				if #selected > 0 then
					on_done(selected)
				else
					notify("Selection cancelled", vim.log.levels.INFO)
				end
				return
			end

			table.insert(selected, choice)
			local remaining = {}
			for _, item in ipairs(available) do
				if item ~= choice then
					table.insert(remaining, item)
				end
			end

			if vim.tbl_isempty(remaining) then
				on_done(selected)
			else
				step(remaining)
			end
		end)
	end

	step(files)
end

function M.refresh()
	if not ui.is_open() then
		return
	end

	local lines = { "MyLazyGit", "------------", "" }
	local highlights = {}

	if not git.is_repo() then
		table.insert(lines, "No git repository detected in current working directory.")
		table.insert(lines, "Press `i` to run `git init` or switch to a repo before opening MyLazyGit.")
		ui.render(lines)
		return
	end

	state.status = git.parse_status()

	local branch = git.current_branch()
	if branch then
		table.insert(lines, string.format("Branch: %s", branch))
	else
		table.insert(lines, string.format("Branch: detached HEAD (fallback: %s)", config.branch_fallback))
	end
	table.insert(lines, "")

	local staged, unstaged, untracked = 0, 0, 0
	for _, item in ipairs(state.status) do
		if item.staged and item.staged:match("%S") then
			staged = staged + 1
		end
		if item.unstaged and item.unstaged:match("%S") then
			unstaged = unstaged + 1
		end
		if item.staged == "?" and item.unstaged == "?" then
			untracked = untracked + 1
		end
		table.insert(lines, string.format("%s%s %s", item.staged, item.unstaged, item.file))
		local line_idx = #lines - 1
		if has_staged_change(item.staged) then
			table.insert(highlights, {
				line = line_idx,
				group = "MyLazyGitStagedIndicator",
				col_start = 0,
				col_end = 1,
			})
		end
		if has_unstaged_change(item.unstaged) then
			table.insert(highlights, {
				line = line_idx,
				group = "MyLazyGitUnstagedIndicator",
				col_start = 1,
				col_end = 2,
			})
		end
	end

	if #state.status == 0 then
		table.insert(lines, "Working tree clean")
	end

	table.insert(lines, "")
	table.insert(lines, string.format("Staged: %d | Unstaged: %d | Untracked: %d", staged, unstaged, untracked))
	table.insert(lines, "")

	local branch_for_log = git.current_branch() or config.branch_fallback
	table.insert(lines, string.format("Recent commits (last %d):", config.log_limit))
	local log_lines = git.log(config.log_limit)
	local unpushed_set = {}
	if branch_for_log then
		for _, hash in ipairs(git.unpushed(config.remote, branch_for_log)) do
			unpushed_set[hash] = true
		end
	end

	if vim.tbl_isempty(log_lines) then
		table.insert(lines, "  No commits found")
	else
		for _, entry in ipairs(log_lines) do
			table.insert(lines, string.format("  %s %s", entry.hash, entry.message))
			local group = unpushed_set[entry.hash] and "MyLazyGitUnpushed" or "MyLazyGitPushed"
			table.insert(highlights, {
				line = #lines - 1,
				group = group,
				col_start = 0,
				col_end = -1,
			})
		end
	end

	table.insert(lines, "")
	local diff_args = config.diff_args or {}
	local diff_label
	if #diff_args > 0 then
		diff_label = "Diff preview (git diff " .. table.concat(diff_args, " ") .. "):"
	else
		diff_label = "Diff preview (git diff):"
	end
	table.insert(lines, diff_label)
	local diff_lines = limit_lines(git.diff(diff_args), config.diff_max_lines)
	if vim.tbl_isempty(diff_lines) then
		table.insert(lines, "  Working tree clean (diff)")
	else
		for _, diff_line in ipairs(diff_lines) do
			table.insert(lines, "  " .. diff_line)
		end
	end

	table.insert(lines, "")
	table.insert(
		lines,
		"Keymap: [r]efresh [s]tage (multi) [a]dd-all [u]nstage [c]ommit [p]ull [P]ush [f]etch [i]nit [q]uit"
	)
	table.insert(
		lines,
		"[R]emote add [U](remote set-url) [n]ew branch [b]switch branch [d]elete branch [D]force delete [?]help"
	)

	ui.render(lines, highlights)
end

local function run_and_refresh(fn, success_msg)
	local ok = fn()
	if ok and success_msg then
		notify(success_msg)
	end
	if ok then
		M.refresh()
	end
end

local function choose_file(prompt, predicate, cb)
	predicate = predicate or function()
		return true
	end
	local files = collect_files(predicate)

	if vim.tbl_isempty(files) then
		notify("No matching files for action: " .. prompt, vim.log.levels.WARN)
		return
	end

	vim.ui.select(files, { prompt = prompt }, function(choice)
		if not choice then
			return
		end
		run_and_refresh(function()
			local ok = cb(choice)
			return ok
		end)
	end)
end

local function choose_files(prompt, predicate, cb, message_fn)
	local files = collect_files(predicate)
	select_multiple(files, prompt, function(selection)
		run_and_refresh(function()
			return cb(selection)
		end, message_fn and message_fn(selection) or nil)
	end)
end

local function stage_file()
	if not repo_required() then
		return
	end
	choose_files("Stage files", nil, function(files)
		return select(1, git.stage(files))
	end, function(selection)
		return string.format("Staged %d file(s)", #selection)
	end)
end

local function stage_all()
	if not repo_required() then
		return
	end
	run_and_refresh(function()
		return select(1, git.stage({ "." }))
	end, "Staged all changes (git add .)")
end

local function unstage_file()
	if not repo_required() then
		return
	end
	choose_file("Unstage file", function(item)
		return item.staged ~= " "
	end, function(file)
		return select(1, git.unstage(file))
	end)
end

local function commit_changes()
	if not repo_required() then
		return
	end
	vim.ui.input({ prompt = "Commit message: " }, function(msg)
		if not msg or vim.trim(msg) == "" then
			return
		end
		run_and_refresh(function()
			return select(1, git.commit(msg))
		end, "Commit created")
	end)
end

local function git_init()
	run_and_refresh(function()
		return select(1, git.init())
	end, "Initialized empty git repository")
end

local function git_pull()
	if not repo_required() then
		return
	end
	local branch = git.current_branch() or config.branch_fallback
	run_and_refresh(function()
		return select(1, git.pull(config.remote, branch))
	end, string.format("Pulled %s/%s", config.remote, branch))
end

local function git_push()
	if not repo_required() then
		return
	end
	local branch = git.current_branch() or config.branch_fallback
	run_and_refresh(function()
		return select(1, git.push(config.remote, branch))
	end, string.format("Pushed to %s/%s", config.remote, branch))
end

local function git_fetch()
	if not repo_required() then
		return
	end
	run_and_refresh(function()
		return select(1, git.fetch(config.remote))
	end, string.format("Fetched %s", config.remote))
end

local function switch_new_branch()
	if not repo_required() then
		return
	end
	vim.ui.input({ prompt = "New branch name: " }, function(name)
		name = name and vim.trim(name) or nil
		if not name or name == "" then
			return
		end
		run_and_refresh(function()
			return select(1, git.switch_create(name))
		end, string.format("Created and switched to %s", name))
	end)
end

local function switch_branch()
	if not repo_required() then
		return
	end
	local branches = git.branches()
	if vim.tbl_isempty(branches) then
		notify("No branches found", vim.log.levels.WARN)
		return
	end
	vim.ui.select(branches, { prompt = "Switch to branch" }, function(choice)
		if not choice then
			return
		end
		run_and_refresh(function()
			return select(1, git.switch(choice))
		end, string.format("Switched to %s", choice))
	end)
end

local function remote_add()
	if not repo_required() then
		return
	end
	vim.ui.input({ prompt = "Remote name: ", default = config.remote }, function(name)
		name = name and vim.trim(name) or nil
		if not name or name == "" then
			return
		end
		vim.ui.input({ prompt = "Remote URL: " }, function(url)
			url = url and vim.trim(url) or nil
			if not url or url == "" then
				return
			end
			run_and_refresh(function()
				return select(1, git.remote_add(name, url))
			end, string.format("Added remote %s", name))
		end)
	end)
end

local function remote_set_url()
	if not repo_required() then
		return
	end
	vim.ui.input({ prompt = "Remote name: ", default = config.remote }, function(name)
		name = name and vim.trim(name) or nil
		if not name or name == "" then
			return
		end
		vim.ui.input({ prompt = "New remote URL: " }, function(url)
			url = url and vim.trim(url) or nil
			if not url or url == "" then
				return
			end
			run_and_refresh(function()
				return select(1, git.remote_set_url(name, url))
			end, string.format("Updated %s URL", name))
		end)
	end)
end

local function show_keymap_popup()
	local mappings = keymap_mappings or {}
	if vim.tbl_isempty(mappings) then
		return
	end

	local lines = { "MyLazyGit Keymaps", "-----------------", "" }
	for _, map in ipairs(mappings) do
		local label = map.lhs and string.format("[%s]", map.lhs) or ""
		local desc = map.desc or ""
		table.insert(lines, string.format("%-8s %s", label, desc))
	end

	local width = 0
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	local height = #lines
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "mylazygit-help", { buf = buf })

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width + 2,
		height = height,
		row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 1),
		col = math.max(math.floor((vim.o.columns - (width + 2)) / 2), 1),
		border = "rounded",
		style = "minimal",
	})

	local function close_popup()
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	vim.keymap.set("n", "q", close_popup, { buffer = buf, silent = true, nowait = true })
	vim.keymap.set("n", "<Esc>", close_popup, { buffer = buf, silent = true, nowait = true })
end

local function delete_branch(force)
	if not repo_required() then
		return
	end
	local branches = git.branches()
	if vim.tbl_isempty(branches) then
		notify("No branches found", vim.log.levels.WARN)
		return
	end
	local current = git.current_branch()
	local candidates = {}
	for _, name in ipairs(branches) do
		if not current or name ~= current then
			table.insert(candidates, name)
		end
	end
	if vim.tbl_isempty(candidates) then
		notify("No other branches to delete", vim.log.levels.WARN)
		return
	end
	local prompt = force and "Force delete branch (-D)" or "Delete branch (-d)"
	vim.ui.select(candidates, { prompt = prompt }, function(choice)
		if not choice then
			return
		end
		local confirmation = vim.fn.confirm(
			string.format("%s branch %s?", force and "Force delete" or "Delete", choice),
			"&Yes\n&No",
			2
		)
		if confirmation ~= 1 then
			notify("Branch deletion cancelled", vim.log.levels.INFO)
			return
		end
		run_and_refresh(function()
			return select(1, git.delete_branch(choice, force))
		end, string.format("%s branch %s", force and "Force deleted" or "Deleted", choice))
	end)
end

local function delete_branch_safe()
	delete_branch(false)
end

local function delete_branch_force()
	delete_branch(true)
end

keymap_mappings = {
	{ lhs = "q", rhs = ui.close, desc = "Quit MyLazyGit" },
	{ lhs = "r", rhs = M.refresh, desc = "Refresh status" },
	{ lhs = "s", rhs = stage_file, desc = "Stage file" },
	{ lhs = "a", rhs = stage_all, desc = "Stage all (git add .)" },
	{ lhs = "u", rhs = unstage_file, desc = "Unstage file" },
	{ lhs = "c", rhs = commit_changes, desc = "Commit" },
	{ lhs = "i", rhs = git_init, desc = "Git init" },
	{ lhs = "p", rhs = git_pull, desc = "Git pull" },
	{ lhs = "P", rhs = git_push, desc = "Git push" },
	{ lhs = "f", rhs = git_fetch, desc = "Git fetch" },
	{ lhs = "n", rhs = switch_new_branch, desc = "Git switch -c" },
	{ lhs = "b", rhs = switch_branch, desc = "Git switch branch" },
	{ lhs = "R", rhs = remote_add, desc = "Git remote add" },
	{ lhs = "U", rhs = remote_set_url, desc = "Git remote set-url" },
	{ lhs = "d", rhs = delete_branch_safe, desc = "Git branch -d" },
	{ lhs = "D", rhs = delete_branch_force, desc = "Git branch -D" },
	{ lhs = "?", rhs = show_keymap_popup, desc = "Show keymap help" },
}

local function set_keymaps()
	ui.set_keymaps(keymap_mappings)
end

function M.open()
	ui.open()
	set_keymaps()
	M.refresh()
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts or {})

	ensure_highlight("MyLazyGitPushed", { link = "DiffAdded" })
	ensure_highlight("MyLazyGitUnpushed", { link = "DiffRemoved" })
	ensure_highlight("MyLazyGitStagedIndicator", { fg = "#98C379" })
	ensure_highlight("MyLazyGitUnstagedIndicator", { fg = "#E5C07B" })

	if vim.fn.has("nvim-0.8") == 0 then
		notify("MyLazyGit requires Neovim 0.8 or newer", vim.log.levels.ERROR)
		return
	end

	vim.api.nvim_create_user_command("MyLazyGit", function()
		M.open()
	end, {})
end

return M
