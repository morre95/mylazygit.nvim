local git = require("mylazygit.git")
local ui = require("mylazygit.ui")
local helpers = require("mylazygit.helpers")
local conflict = require("mylazygit.conflict")

local M = {}

local config = {
	remote = "origin",
	branch_fallback = "main",
	merge_workflow = {
		main_branch = "main",
		rebase_args = {},
	},
	log_limit = 5,
	max_commit_lines = 100,
	max_branch_lines = 100,
	diff_args = { "--stat" },
	diff_max_lines = 80,
}

local state = {
	status = {},
	active_bottom_view = "local_branches",
}

local bottom_view_names = {
	local_branches = true,
	remote_branches = true,
	diff_preview = true,
}

local function normalize_bottom_view(view)
	if view and bottom_view_names[view] then
		return view
	end
	return "local_branches"
end

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

local function format_preview_title(file)
	if not file or file == "" then
		return " Preview "
	end
	local shortened = vim.fn.fnamemodify(file, ":.")
	return string.format(" Preview: %s ", shortened)
end

local function format_commit_preview_title(entry)
	if not entry or not entry.hash then
		return " Commit Preview "
	end
	local message = entry.message and vim.trim(entry.message) or ""
	if #message > 60 then
		message = message:sub(1, 57) .. "..."
	end
	if message ~= "" then
		return string.format(" Commit %s · %s ", entry.hash, message)
	end
	return string.format(" Commit %s ", entry.hash)
end

local function show_preview_for_file(file)
	if not file or file == "" then
		ui.reset_preview()
		return
	end

	if not git.is_repo() then
		ui.reset_preview()
		return
	end

	local diff_lines = git.diff({ "--", file })
	if vim.tbl_isempty(diff_lines) then
		diff_lines = git.diff({ "--cached", "--", file })
	end

	if vim.tbl_isempty(diff_lines) then
		diff_lines = { string.format("No staged or unstaged changes for %s", file) }
	end

	ui.show_preview(diff_lines, {
		title = format_preview_title(file),
		filetype = "diff",
	})
end

local function show_preview_for_commit(entry)
	if not git.is_repo() then
		ui.reset_preview()
		return
	end

	if not entry or not entry.hash then
		ui.show_preview({
			"Select a commit to view its `git log -p` output.",
		}, { title = " Commit Preview ", filetype = "git" })
		return
	end

	local log_lines = git.log_patch(entry.hash)
	if vim.tbl_isempty(log_lines) then
		log_lines = { string.format("No `git log -p` output for %s", entry.hash) }
	end

	ui.show_preview(log_lines, {
		title = format_commit_preview_title(entry),
		filetype = "diff",
	})
end

local function show_branch_log(branch)
	if not git.is_repo() then
		ui.reset_preview()
		return
	end

	if not branch or branch == "" then
		ui.show_preview({
			"Select a local branch to see its `git log --graph --decorate` output.",
		}, { title = " Branch Log ", filetype = "git" })
		return
	end

	local log_lines = git.branch_log(branch, config.max_branch_lines)
	if vim.tbl_isempty(log_lines) then
		log_lines = { string.format("No commits found on %s.", branch) }
	end

	ui.show_preview(log_lines, {
		title = string.format(" git log %s ", branch),
		filetype = "git",
	})
end

ui.set_handlers({
	on_worktree_select = show_preview_for_file,
	on_commit_select = show_preview_for_commit,
	on_local_branch_select = show_branch_log,
})

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

local function has_untracked_change(staged_char, unstaged_char)
	return staged_char == "?" and unstaged_char == "?"
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

	state.active_bottom_view = normalize_bottom_view(ui.get_bottom_view() or state.active_bottom_view)

	state.status = {}

	local layout = {
		info = {
			branch = "Branch: -",
			details = {},
		},
		worktree = {
			title = " Worktree (0) ",
			lines = {},
			items = {},
			highlights = {},
		},
		commits = {
			title = " Commits ",
			lines = {},
			highlights = {},
		},
		diff = {
			active_view = state.active_bottom_view,
			views = {
				local_branches = {
					title = " Local Branches ",
					lines = {},
					filetype = "mylazygit-branches",
				},
				remote_branches = {
					title = " Remote Branches ",
					lines = {},
					filetype = "mylazygit-branches",
				},
				diff_preview = {
					title = " Diff preview ",
					lines = {},
					filetype = "mylazygit-diffsummary",
				},
			},
		},
		keymap = {
			lines = {
				"Keymap: [?]help [r]efresh [s]tage [a]dd-all [u]nstage [c]ommit [p]ull [P]ush [f]etch [C]heck-conflicts [X]resolve [m]erge [i]nit [q]uit",
				"<Tab>/<S-Tab> cycle panes · [`/`] cycle Local/Remote/Diff bottom view · Use arrow keys to move",
			},
		},
	}

	if not git.is_repo() then
		layout.info.branch = "No git repository detected"
		layout.info.details = {
			"Press `i` to run git init or switch to a repository before opening MyLazyGit.",
		}
		layout.worktree.lines = { "Open a git repository to view worktree changes." }
		layout.commits.lines = { "Commits unavailable outside a repository." }
		layout.diff.views.local_branches.title = " Local Branches (0) "
		layout.diff.views.local_branches.lines = { "Local branches unavailable outside a repository." }
		layout.diff.views.remote_branches.title = " Remote Branches (0) "
		layout.diff.views.remote_branches.lines = { "Remote branches unavailable outside a repository." }
		layout.diff.views.diff_preview.lines = { "Diff preview unavailable outside a repository." }
		layout.preview = {
			title = " Preview ",
			lines = { "Git data unavailable until a repository is detected." },
		}
		ui.render(layout)
		return
	end

	state.status = git.parse_status()

	local branch = git.current_branch()
	if branch then
		layout.info.branch = string.format("Branch: %s", branch)
	else
		layout.info.branch = string.format("Branch: detached HEAD (fallback: %s)", config.branch_fallback)
	end

	local staged, unstaged, untracked = 0, 0, 0
	local worktree_lines, worktree_items, worktree_highlights = {}, {}, {}

	for idx, item in ipairs(state.status) do
		if item.staged and item.staged:match("%S") then
			staged = staged + 1
		end
		if item.unstaged and item.unstaged:match("%S") then
			unstaged = unstaged + 1
		end
		if item.staged == "?" and item.unstaged == "?" then
			untracked = untracked + 1
		end

		local line = string.format("%s%s %s", item.staged, item.unstaged, item.file)
		table.insert(worktree_lines, line)
		table.insert(worktree_items, {
			file = item.file,
			staged = item.staged,
			unstaged = item.unstaged,
		})

		local is_untracked = has_untracked_change(item.staged, item.unstaged)

		if has_staged_change(item.staged) then
			table.insert(worktree_highlights, {
				line = idx - 1,
				group = "MyLazyGitStagedIndicator",
				col_start = 0,
				col_end = -1,
			})
		end

		if is_untracked then
			table.insert(worktree_highlights, {
				line = idx - 1,
				group = "MyLazyGitUntrackedIndicator",
				col_start = 0,
				col_end = -1,
			})
		end

		if not is_untracked and has_unstaged_change(item.unstaged) then
			table.insert(worktree_highlights, {
				line = idx - 1,
				group = "MyLazyGitUnstagedIndicator",
				col_start = 0,
				col_end = -1,
			})
		end
	end

	layout.worktree.title = string.format(" Worktree (%d) ", #state.status)
	layout.worktree.lines = worktree_lines
	layout.worktree.items = worktree_items
	layout.worktree.highlights = worktree_highlights

	layout.info.details = {
		string.format(
			"Files %d · Staged %d · Unstaged %d · Untracked %d",
			#state.status,
			staged,
			unstaged,
			untracked
		),
	}

	local local_branches = git.branches()
	local local_branch_lines = {}

	for _, name in ipairs(local_branches) do
		local prefix = (branch and name == branch) and "*" or " "
		table.insert(local_branch_lines, string.format("%s %s", prefix, name))
	end

	if vim.tbl_isempty(local_branch_lines) then
		local_branch_lines = { "No local branches found. Create one with git switch -c <name>." }
	end

	layout.diff.views.local_branches.title = string.format(" Local Branches (%d) ", #local_branches)
	layout.diff.views.local_branches.lines = local_branch_lines
	layout.diff.views.local_branches.items = vim.list_extend({}, local_branches)

	local remote_branches = git.remote_branches()
	local remote_branch_lines = {}

	for _, name in ipairs(remote_branches) do
		table.insert(remote_branch_lines, string.format("  %s", name))
	end

	if vim.tbl_isempty(remote_branch_lines) then
		remote_branch_lines = {
			string.format("No remote branches found for %s.", config.remote),
			"Run git fetch to update remote references.",
		}
	end

	layout.diff.views.remote_branches.title = string.format(" Remote Branches (%d) ", #remote_branches)
	layout.diff.views.remote_branches.lines = remote_branch_lines

	local branch_for_log = branch or config.branch_fallback
	local log_lines = git.log(config.max_commit_lines)
	local unpushed_set = {}

	if branch_for_log then
		for _, hash in ipairs(git.unpushed(config.remote, branch_for_log)) do
			unpushed_set[hash] = true
		end
	end

	local commit_lines, commit_highlights = {}, {}
	for idx, entry in ipairs(log_lines) do
		local line = string.format("%s %s", entry.hash, entry.message)
		table.insert(commit_lines, line)
		local group = unpushed_set[entry.hash] and "MyLazyGitUnpushed" or "MyLazyGitPushed"
		table.insert(commit_highlights, {
			line = idx - 1,
			group = group,
			col_start = 0,
			col_end = -1,
		})
	end

	layout.commits.title = string.format(" Commits (%d) ", #commit_lines)
	layout.commits.lines = commit_lines
	layout.commits.highlights = commit_highlights
	layout.commits.items = log_lines

	local diff_args = config.diff_args or {}
	local diff_label = (#diff_args > 0) and ("git diff " .. table.concat(diff_args, " ")) or "git diff"
	local diff_lines = limit_lines(git.diff(diff_args), config.diff_max_lines)
	if vim.tbl_isempty(diff_lines) then
		diff_lines = { "Working tree clean." }
	end
	layout.diff.views.diff_preview.title = string.format(" Diff preview (%s) ", diff_label)
	layout.diff.views.diff_preview.lines = diff_lines

	ui.render(layout)
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

local function unstage_all_files()
	if not repo_required() then
		return
	end

	local has_any_staged = false
	for _, item in ipairs(state.status) do
		if has_staged_change(item.staged) then
			has_any_staged = true
			break
		end
	end

	if not has_any_staged then
		notify("No staged files to unstage", vim.log.levels.INFO)
		return
	end

	run_and_refresh(function()
		return select(1, git.unstage({ "." }))
	end, "Unstaged all files (git restore --staged .)")
end

local function commit_changes()
	if not repo_required() then
		return
	end

	helpers.centered_input({ prompt = "Message", title = "Create Commit" }, function(msg)
		if not msg or vim.trim(msg) == "" then
			return
		end
		run_and_refresh(function()
			return select(1, git.commit(msg))
		end, "Commit created")
	end)
end

local function stage_all_and_commit()
	if not repo_required() then
		return
	end

	-- First, stage all files
	local stage_ok = select(1, git.stage({ "." }))
	if not stage_ok then
		return
	end
	notify("Staged all changes (git add .)")
	M.refresh()

	-- Then, prompt for commit message and chain pull_rebase after commit
	helpers.centered_input({ prompt = "Message", title = "Create Commit" }, function(msg)
		if not msg or vim.trim(msg) == "" then
			return
		end

		-- Commit the changes
		local commit_ok = select(1, git.commit(msg))
		if not commit_ok then
			M.refresh()
			return
		end
		notify("Commit created")
		M.refresh()
	end)
end

local function stage_all_and_commit_and_pull()
	if not repo_required() then
		return
	end

	-- First, stage all files
	local stage_ok = select(1, git.stage({ "." }))
	if not stage_ok then
		return
	end
	notify("Staged all changes (git add .)")
	M.refresh()

	-- Then, prompt for commit message and chain pull_rebase after commit
	helpers.centered_input({ prompt = "Message", title = "Create Commit" }, function(msg)
		if not msg or vim.trim(msg) == "" then
			return
		end

		-- Commit the changes
		local commit_ok = select(1, git.commit(msg))
		if not commit_ok then
			M.refresh()
			return
		end
		notify("Commit created")
		M.refresh()

		-- Only after successful commit, run pull rebase
		local branch = git.current_branch() or config.branch_fallback
		local pull_ok = select(1, git.pull_rebase(config.remote, branch))
		if pull_ok then
			notify(string.format("Pulled and rebase %s/%s", config.remote, branch))
		end
		M.refresh()
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

local function check_conflicts()
	if not repo_required() then
		return
	end

	local branch = git.current_branch() or config.branch_fallback
	notify("Checking for conflicts...", vim.log.levels.INFO)

	local ok, result = git.check_conflicts(config.remote, branch)
	if not ok then
		notify(table.concat(result, "\n"), vim.log.levels.ERROR)
		return
	end

	M.refresh()

	if result.has_conflicts then
		notify(
			string.format(
				"⚠️  Conflicts detected when merging %s/%s into current branch",
				result.remote,
				result.branch
			),
			vim.log.levels.WARN
		)
	else
		notify(
			string.format("✓ No conflicts detected. Safe to merge %s/%s", result.remote, result.branch),
			vim.log.levels.INFO
		)
	end
end

local function resolve_conflicts()
	if not repo_required() then
		return
	end

	local conflicted_files = conflict.get_conflicted_files()

	if vim.tbl_isempty(conflicted_files) then
		notify("No files with conflicts found", vim.log.levels.INFO)
		return
	end

	if #conflicted_files == 1 then
		-- Only one file, open it directly
		conflict.open(conflicted_files[1])
	else
		-- Multiple files, let user choose
		vim.ui.select(conflicted_files, {
			prompt = string.format("Select file to resolve (%d conflicts)", #conflicted_files),
		}, function(choice)
			if choice then
				conflict.open(choice)
			end
		end)
	end

	M.refresh()
end

local function switch_new_branch()
	if not repo_required() then
		return
	end

	helpers.centered_input({ prompt = "New branch", title = "Name" }, function(name)
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

	helpers.centered_dual_input({
		title = "Add remote",
		prompt1 = "Name",
		prompt2 = "Url",
		default1 = config.remote,
	}, function(name, url)
		if name and url then
			url = vim.trim(url)
			name = vim.trim(name)
			run_and_refresh(function()
				return select(1, git.remote_add(name, url))
			end, string.format("Added remote %s", name))
		else
			notify("No remote added")
			return
		end
	end)
end

local function remote_set_url()
	if not repo_required() then
		return
	end
	local remote_url = git.remote_get_url()
	if not remote_url then
		remote_url = ""
	end
	notify(remote_url)
	helpers.centered_dual_input({
		title = "Set remote url",
		prompt1 = "Name",
		prompt2 = "Url",
		default1 = config.remote,
		default2 = remote_url,
	}, function(name, url)
		if name and url then
			url = vim.trim(url)
			name = vim.trim(name)
			run_and_refresh(function()
				return select(1, git.remote_set_url(name, url))
			end, string.format("Remote URL updated: %s", name))
		else
			notify("Remote url did not update!!!")
			return
		end
	end)
end

local function merge_branch()
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
		notify("No other branches to merge", vim.log.levels.WARN)
		return
	end

	vim.ui.select(candidates, { prompt = "Merge branch into current" }, function(choice)
		if not choice then
			return
		end
		run_and_refresh(function()
			return select(1, git.merge(choice))
		end, string.format("Merged branch %s", choice))
	end)
end

local function merge_workflow()
	if not repo_required() then
		return
	end

	local workflow_cfg = config.merge_workflow or {}
	local main_branch = workflow_cfg.main_branch or config.branch_fallback or "main"

	if not main_branch or main_branch == "" then
		notify("Set `merge_workflow.main_branch` in setup() to use this command.", vim.log.levels.ERROR)
		return
	end
	if not git.has_local_branch(main_branch) then
		notify(
			string.format("Local branch %s not found. Checkout or create it first.", main_branch),
			vim.log.levels.ERROR
		)
		return
	end

	local branches = git.branches()
	if vim.tbl_isempty(branches) then
		notify("No branches found", vim.log.levels.WARN)
		return
	end

	local candidates = {}
	for _, name in ipairs(branches) do
		if name ~= main_branch then
			table.insert(candidates, name)
		end
	end

	if vim.tbl_isempty(candidates) then
		notify(string.format("No branch to merge into %s", main_branch), vim.log.levels.WARN)
		return
	end

	local prompt = string.format("Workflow: merge branch into %s", main_branch)
	vim.ui.select(candidates, { prompt = prompt }, function(choice)
		if not choice then
			return
		end
		if not git.has_local_branch(choice) then
			notify(string.format("Branch %s no longer exists locally.", choice), vim.log.levels.WARN)
			return
		end
		run_and_refresh(function()
			return select(
				1,
				git.merge_workflow({
					main_branch = main_branch,
					feature_branch = choice,
					rebase_args = workflow_cfg.rebase_args,
				})
			)
		end, string.format("Workflow merged %s into %s", choice, main_branch))
	end)
end

local function rebase_branch()
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
		notify("No other branches to rebase onto", vim.log.levels.WARN)
		return
	end

	vim.ui.select(candidates, { prompt = "Rebase current branch onto" }, function(choice)
		if not choice then
			return
		end
		run_and_refresh(function()
			return select(1, git.rebase(choice))
		end, string.format("Rebased onto %s", choice))
	end)
end

local function show_keymap_popup()
	local mappings = keymap_mappings or {}
	if vim.tbl_isempty(mappings) then
		return
	end

	local header = { "MyLazyGit Keymaps", "-----------------", "" }
	local list_lines = {}
	for _, h in ipairs(header) do
		table.insert(list_lines, h)
	end

	for _, map in ipairs(mappings) do
		local label = map.lhs and string.format("[%s]", map.lhs) or ""
		local desc = map.desc or ""
		table.insert(list_lines, string.format("%-8s %s", label, desc))
	end

	-- Dimensioner
	local list_width = 0
	for _, line in ipairs(list_lines) do
		list_width = math.max(list_width, vim.fn.strdisplaywidth(line))
	end
	-- Rimliga min/max och preview-bredd
	list_width = math.min(math.max(list_width + 2, 32), math.floor(vim.o.columns * 0.45))
	local preview_width = math.min(math.max(48, math.floor(vim.o.columns * 0.45)), vim.o.columns - list_width - 8)

	local height = math.min(#list_lines, vim.o.lines - 6)

	-- Centrera två fönster som ett block
	local total_width = list_width + preview_width + 2 -- +2 som “mellanrum”
	local row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 1)
	local col_left = math.max(math.floor((vim.o.columns - total_width) / 2), 1)
	local col_right = col_left + list_width + 2

	-- Buffers
	local buf_list = vim.api.nvim_create_buf(false, true)
	local buf_prev = vim.api.nvim_create_buf(false, true)

	-- Buffers: metadata
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf_list })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf_prev })

	vim.api.nvim_buf_set_lines(buf_list, 0, -1, false, list_lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf_list })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf_prev })

	vim.api.nvim_set_option_value("filetype", "mylazygit-help", { buf = buf_list })
	vim.api.nvim_set_option_value("filetype", "mylazygit-explain", { buf = buf_prev })

	-- Fönster
	local win_list = vim.api.nvim_open_win(buf_list, true, {
		relative = "editor",
		width = list_width,
		height = height,
		row = row,
		col = col_left,
		border = "rounded",
		style = "minimal",
		zindex = 120,
	})

	local win_prev = vim.api.nvim_open_win(buf_prev, false, {
		relative = "editor",
		width = preview_width,
		height = height,
		row = row,
		col = col_right,
		border = "rounded",
		style = "minimal",
		zindex = 120,
	})

	-- Lite UX
	vim.api.nvim_set_option_value("cursorline", true, { win = win_list })
	vim.api.nvim_set_option_value("wrap", true, { win = win_prev })
	vim.api.nvim_set_option_value("linebreak", true, { win = win_prev })
	vim.api.nvim_set_option_value("breakindent", true, { win = win_prev })

	-- Hjälpare: räkna om cursorrad -> index i mappings
	local HEADER_LINES = #header
	local function current_mapping_index()
		local cur = vim.api.nvim_win_get_cursor(win_list)[1] -- 1-based
		local idx = cur - HEADER_LINES
		if idx < 1 or idx > #mappings then
			return nil
		end
		return idx
	end

	-- Rendera preview för ett visst index
	local function render_preview(idx)
		local lines
		if not idx then
			lines = { "Move the marker to keymap to get more explination." }
		else
			local m = mappings[idx] or {}
			local explain = m.explain
			if type(explain) == "string" then
				lines = vim.split(explain, "\n", { plain = true })
			elseif type(explain) == "table" then
				lines = explain
			else
				lines = { "No explanation available" }
			end
			-- Lägg till titelrad
			local title = string.format("Explination %s", m.desc or m.lhs or "")
			table.insert(lines, 1, title)
			table.insert(lines, 2, string.rep("—", math.min(#title, preview_width - 2)))
		end

		vim.api.nvim_set_option_value("modifiable", true, { buf = buf_prev })
		vim.api.nvim_buf_set_lines(buf_prev, 0, -1, false, lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf_prev })
		-- Scrolla till toppen vid uppdatering
		vim.api.nvim_win_set_cursor(win_prev, { 1, 0 })
	end

	-- Init-preview
	render_preview(current_mapping_index())

	-- Uppdatera preview när markören flyttas i list-fönstret
	local aug = vim.api.nvim_create_augroup("MyLazyGitKeymapPreview", { clear = false })
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = aug,
		buffer = buf_list,
		callback = function()
			render_preview(current_mapping_index())
		end,
	})

	local function close_all()
		pcall(vim.api.nvim_del_augroup_by_name, "MyLazyGitKeymapPreview")
		for _, w in ipairs({ win_list, win_prev }) do
			if w and vim.api.nvim_win_is_valid(w) then
				pcall(vim.api.nvim_win_close, w, true)
			end
		end
		for _, b in ipairs({ buf_list, buf_prev }) do
			if b and vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
	end

	for _, buf in ipairs({ buf_list, buf_prev }) do
		vim.keymap.set("n", "q", close_all, { buffer = buf, silent = true, nowait = true })
		vim.keymap.set("n", "<Esc>", close_all, { buffer = buf, silent = true, nowait = true })
	end

	-- Låt j/k fungera som vanligt i listan (de är redan standard i Normal-läge).
	-- Om du vill förhindra att man redigerar listan:
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf_list })
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
		local confirmation =
			vim.fn.confirm(string.format("%s branch %s?", force and "Force delete" or "Delete", choice), "&Yes\n&No", 2)
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

-- NOTE: ta bort denna när du är färdig med testning
local function test_dual_input()
	helpers.centered_dual_input({
		title = "Test",
		prompt1 = "Name",
		prompt2 = "Email",
		default1 = "ett",
		default2 = "två",
	}, function(value1, value2)
		if value1 == "ett" then
			notify("Japp det är ett " .. value1, vim.log.levels.INFO)
		else
			notify("Ett är här: " .. value1)
		end

		if value2 == "två" then
			notify("Japp det är två " .. value2)
		else
			notify("Två är här: " .. value2, vim.log.levels.DEBUG)
		end
	end)
end

-- TODO: Add explination to keymaps
keymap_mappings = {
	{ lhs = "q", rhs = ui.close, desc = "Quit MyLazyGit", explain = "Quit and close this view" },
	{ lhs = "<Esc>", rhs = ui.close, desc = "Quit MyLazyGit", explain = "Quit and close this view" },
	{ lhs = "r", rhs = M.refresh, desc = "Refresh status", explain = "Refresh everything" },
	{ lhs = "gsf", rhs = stage_file, desc = "Stage file", explain = "Stage file by file" },
	{
		lhs = "gsa",
		rhs = stage_all,
		desc = "Stage all files",
		explain = "Stage all files at once. Same as 'git add .'",
	},
	{
		lhs = "gsc",
		rhs = stage_all_and_commit,
		desc = "Stage all and commit",
		explain = "This command is running 'git add .' and 'git commit -m <message>'",
	},
	{
		lhs = "gsC",
		rhs = stage_all_and_commit_and_pull,
		desc = "Stage all and commit and pull",
		explain = "This command is running 'git add .' and 'git commit -m <message>' and 'git pull --rebase'",
	},

	{ lhs = "gsu", rhs = unstage_file, desc = "Unstage file", explain = "" },
	{ lhs = "gsU", rhs = unstage_all_files, desc = "Unstage file", explain = "" },
	{ lhs = "c", rhs = commit_changes, desc = "Commit", explain = "" },
	{ lhs = "i", rhs = git_init, desc = "Git init", explain = "This command creates an empty Git repository." },
	{
		lhs = "p",
		rhs = git_pull,
		desc = "Pull",
		explain = "Git pull will incorporates changes from a remote repository into the current branch.",
	},
	{
		lhs = "P",
		rhs = git_push,
		desc = "Push",
		explain = "Git push will update the remote repository with the local changes",
	},
	{ lhs = "f", rhs = git_fetch, desc = "Fetch", explain = "git fetch" },
	{
		lhs = "C",
		rhs = check_conflicts,
		desc = "Check conflicts",
		explain = "Runs 'git fetch' and then 'git merge-tree' to check for conflicts before merging. This is a safe way to preview potential conflicts without actually performing a merge.",
	},
	{
		lhs = "X",
		rhs = resolve_conflicts,
		desc = "Resolve conflicts",
		explain = "Opens the 3-way conflict resolver showing local changes (right), incoming changes (left), and the result (middle). Navigate with j/k, accept changes with h (ours) or l (theirs), accept all with a/A, and save with s.",
	},
	{ lhs = "R", rhs = remote_add, desc = "Add remote", explain = "git remote add origin <Url>" },
	{ lhs = "U", rhs = remote_set_url, desc = "Set remote url", explain = "git remote set-url origin <Url>" },
	{
		lhs = "gbn",
		rhs = switch_new_branch,
		desc = "New Branch",
		explain = "git switch -c <branch-name>\nThe `git switch -c` command allows you to create a new branch and switch your working directory to it in one seamless action.",
	},
	{ lhs = "gbs", rhs = switch_branch, desc = "Switch branch", explain = "git switch <branch-name>" },
	{ lhs = "gbd", rhs = delete_branch_safe, desc = "Delete branch", explain = "git branch -d <branch-name>" },
	{ lhs = "gbD", rhs = delete_branch_force, desc = "Delete branch force", explain = "git branch -D <branch-name>" },
	{ lhs = "gbm", rhs = merge_branch, desc = "Merge branch", explain = "git merge <branch-name>" },
	{
		lhs = "gbw",
		rhs = merge_workflow,
		desc = "Merge workflow",
		explain = "Checkout main, pull, rebase branch, and merge back",
	},
	{ lhs = "gbr", rhs = rebase_branch, desc = "Git rebase branch", explain = "" },
	{ lhs = "[", rhs = ui.bottom_view_prev, desc = "Previous bottom pane view", explain = "" },
	{ lhs = "]", rhs = ui.bottom_view_next, desc = "Next bottom pane view", explain = "" },
	{ lhs = "?", rhs = show_keymap_popup, desc = "Show keymap help", explain = "" },
	{ lhs = "ö", rhs = test_dual_input, desc = "A test function", explain = "Should be deleted" },
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

	ensure_highlight("MyLazyGitPushed", { fg = "#98C379" })
	ensure_highlight("MyLazyGitUnpushed", { fg = "#CD5C5C" })
	ensure_highlight("MyLazyGitStagedIndicator", { fg = "#98C379" })
	ensure_highlight("MyLazyGitUnstagedIndicator", { fg = "#E5C07B" })
	ensure_highlight("MyLazyGitUntrackedIndicator", { fg = "#9E9E9E" })

	if vim.fn.has("nvim-0.8") == 0 then
		notify("MyLazyGit requires Neovim 0.8 or newer", vim.log.levels.ERROR)
		return
	end

	vim.api.nvim_create_user_command("MyLazyGit", function()
		M.open()
	end, {})
end

return M
