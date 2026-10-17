local git_module = require("mylazygit.git")
local ui = require("mylazygit.ui")
local helpers = require("mylazygit.helpers")
local conflict = require("mylazygit.conflict")
local ai = require("mylazygit.ai")

local plugin = {}
local active_controller
local controllers = {}

local config = {
	remote = "origin",
	branch_fallback = "main",
	merge_workflow = {
		main_branch = "main",
	},
	-- Published cleanup and gPF protect these branches, main and merge_workflow.main_branch.
	protected_branches = {},
	log_limit = 5,
	max_commit_lines = 100,
	max_branch_lines = 10,
	diff_args = { "--stat" },
	diff_max_lines = 80,
	ai = {},
}

local function create_controller(git)
local M = {}
-- Delayed choices keep their captured repository intent, including source refs and index.
local function guarded(callback)
	local expected = git.repository_state()
	return function(...)
		if not git.validate_state(expected) then M.refresh(); return end
		return git.with_expected(expected, callback, ...)
	end
end
local prompts = {
	input = function(opts, callback) return git.without_mutation(vim.ui.input, opts, git.user_callback(guarded(callback))) end,
	select = function(items, opts, callback) return git.without_mutation(vim.ui.select, items, opts, git.user_callback(guarded(callback))) end,
}
local inputs = {
	centered_input = function(opts, callback) return git.without_mutation(helpers.centered_input, opts, git.user_callback(guarded(callback))) end,
	centered_dual_input = function(opts, callback) return git.without_mutation(helpers.centered_dual_input, opts, git.user_callback(guarded(callback))) end,
}
local function confirm(...)
	return git.without_mutation(vim.fn.confirm, ...)
end
local state = {
	status = {},
	commits = {},
	active_bottom_view = "local_branches",
	temp_checkout = {
		return_ref = nil,
	},
}

git.on_mutation(function() if active_controller == M then M.refresh() end end)

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

local function define_highlights()
	vim.api.nvim_set_hl(0, "MyLazyGitPushed", { fg = "#98C379", default = true })
	vim.api.nvim_set_hl(0, "MyLazyGitUnpushed", { fg = "#CD5C5C", default = true })
	vim.api.nvim_set_hl(0, "MyLazyGitUnknown", { fg = "#ABB2BF", default = true })
	vim.api.nvim_set_hl(0, "MyLazyGitStagedIndicator", { fg = "#98C379", default = true })
	vim.api.nvim_set_hl(0, "MyLazyGitUnstagedIndicator", { fg = "#E5C07B", default = true })
	vim.api.nvim_set_hl(0, "MyLazyGitUntrackedIndicator", { fg = "#9E9E9E", default = true })
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

local function select_multiple(files, prompt, on_done, format_item)
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

		prompts.select(available, { prompt = prompt .. " (Esc to finish)", format_item = format_item }, function(choice)
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
	if active_controller ~= M or not ui.is_open() then
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
				"[?]help [r]efresh [Space]stage/checkout [gct]temp-checkout [gcr]return [gsa]dd-all [c]ommit [aic]AI-commit [A]mend [gss]quash [p]ull [P]ush [f]etch [gzz]stash [gzp]pop [gpr]pr [ghr]repo [C]onflicts [q]uit",
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
	local detached_head = branch == nil
	local head_short = detached_head and git.current_head_short() or nil
	if branch then
		layout.info.branch = string.format("Branch: %s", branch)
	else
		layout.info.branch = string.format(
			"Branch: DETACHED HEAD at %s",
			head_short or "unknown"
		)
	end

	layout.info.branch = layout.info.branch .. " · " .. git.worktree()

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

	local lifecycle = git.repository_state()
	if lifecycle.running then table.insert(layout.info.details, "Running: " .. lifecycle.running)
	elseif lifecycle.operation or #lifecycle.conflicts > 0 then table.insert(layout.info.details, "Recovery: " .. (lifecycle.operation or "conflicts") .. " · [X] resolve · [gx] continue/abort")
	else layout.info.details[1] = layout.info.details[1] .. " · Repository: ready" end
	if lifecycle.workflow then
		table.insert(layout.info.details, "Workflow: " .. (lifecycle.workflow.status or "stopped") .. (lifecycle.workflow.failed and (" · " .. lifecycle.workflow.failed) or ""))
		table.insert(layout.info.details, "Remaining: " .. (#lifecycle.workflow.remaining > 0 and table.concat(lifecycle.workflow.remaining, "; ") or "none"))
	end
	local pull_target, pull_error = git.resolve_pull_target()
	local push_target, push_error = git.resolve_push_target()
	table.insert(layout.info.details, "Pull: " .. (pull_target and (pull_target.remote .. " " .. pull_target.ref) or pull_error))
	table.insert(layout.info.details, "Push: " .. (push_target and (push_target.remote .. " " .. push_target.ref) or push_error))
	local publication = git.publication_snapshot(nil, config.max_commit_lines)
	local freshness = publication.freshness
	local fetch_description = "unobserved"
	if freshness.fetched_at then fetch_description = "cached " .. os.date("%Y-%m-%d %H:%M:%S", freshness.fetched_at) end
	if freshness.state == "failed" then fetch_description = "failed latest attempt; " .. fetch_description end
	table.insert(layout.info.details, "Publication: " .. (publication.reason and ("unknown · " .. publication.reason) or publication.tracking_ref or "unknown")
		.. " · Fetch: " .. fetch_description .. " · live remote unverified")

	if detached_head then
		table.insert(layout.info.details, "⚠ Detached HEAD: commits here are not on a branch unless you create one.")
	end

	if state.temp_checkout.return_ref then
		table.insert(layout.info.details, string.format("Temporary checkout active · [gcr] returns to %s", state.temp_checkout.return_ref))
	end

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

	local log_lines = publication.commits

	local commit_lines, commit_highlights = {}, {}
	for idx, entry in ipairs(log_lines) do
		local line = string.format("%s [%s] %s", entry.hash, entry.publication, entry.message)
		table.insert(commit_lines, line)
		local group = ({ published = "MyLazyGitPushed", ["local-only"] = "MyLazyGitUnpushed", unknown = "MyLazyGitUnknown" })[entry.publication]
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
	state.commits = log_lines

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
	M.refresh()
end

local function run_async_and_refresh(async_fn, success_msg)
	async_fn(function(ok, output, result)
		if result and result.workflow then
			local lines = helpers.recovery_lines(output, result)
			notify(table.concat(lines, "\n"), ok and vim.log.levels.INFO or vim.log.levels.WARN)
		elseif ok and success_msg then
			notify(success_msg)
		elseif not ok and output then
			notify(table.concat(output, "\n"), vim.log.levels.WARN)
		end
		M.refresh()
	end)
	M.refresh()
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

local function restore_file()
	if not repo_required() then
		return
	end

	choose_files("Restore files", function(item)
		return has_unstaged_change(item.unstaged) and not has_untracked_change(item.staged, item.unstaged)
	end, function(files)
		return select(1, git.restore(files))
	end, function(selection)
		return string.format("Restored %d file(s)", #selection)
	end)
end

local function restore_all_files()
	if not repo_required() then
		return
	end

	local has_restorable = false
	for _, item in ipairs(state.status) do
		if has_unstaged_change(item.unstaged) and not has_untracked_change(item.staged, item.unstaged) then
			has_restorable = true
			break
		end
	end

	if not has_restorable then
		notify("No files with unstaged changes to restore", vim.log.levels.INFO)
		return
	end

	local confirmation = confirm(
		"Discard ALL unstaged changes? This cannot be undone.",
		"&Yes\n&No",
		2
	)
	if confirmation ~= 1 then
		notify("Restore cancelled", vim.log.levels.INFO)
		return
	end

	local files = collect_files(function(item)
		return has_unstaged_change(item.unstaged) and not has_untracked_change(item.staged, item.unstaged)
	end)

	run_and_refresh(function()
		return select(1, git.restore(files))
	end, string.format("Restored %d file(s)", #files))
end

local function unstage_file()
	if not repo_required() then
		return
	end
	choose_files("Unstage file", nil, function(item)
		return select(1, git.unstage(item))
	end, function(selection)
		return string.format("Unstaged %d file(s)", #selection)
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

	inputs.centered_input({ prompt = "Message", title = "Create Commit" }, function(msg)
		if not msg or vim.trim(msg) == "" then
			return
		end
		run_and_refresh(function()
			return select(1, git.commit(msg))
		end, "Commit created")
	end)
end

local function build_squash_message(entries, count)
	local parts = {}
	for i = count, 1, -1 do
		local msg = entries[i] and entries[i].message or ""
		msg = msg and vim.trim(msg) or ""
		if msg ~= "" then
			table.insert(parts, msg)
		end
	end
	return table.concat(parts, " | ")
end

local function cleanup_protected()
	return vim.list_extend({ config.merge_workflow.main_branch }, vim.deepcopy(config.protected_branches))
end

local function confirm_cleanup(target)
	local operation = target.operation
	local published = target.publication == "published"
	local review = published and string.format(
		"Rewrite published history with %s on %s?\nPublication: %s %s (%s)\nReviewed remote commit: %s\nLater gPF will lease this commit; ordinary push cannot publish the rewrite.",
		operation, target.local_branch, target.rewrite.remote, target.rewrite.ref, target.rewrite.endpoint, target.rewrite.expected)
		or string.format("%s unpublished history on %s?\n%s", operation, target.local_branch,
			target.rewrite and "Publish with gPF using the earlier cleanup's retained reviewed lease." or "Publish the result with ordinary push (P).")
	if operation == "amend" or operation == "squash" then review = review .. "\nExisting staged changes will be included." end
	if confirm(review, (published and "&Rewrite" or "&" .. operation) .. "\n&Cancel", 2) ~= 1 then notify("Cleanup cancelled"); return end
	target.confirmed, target.rewrite_confirmed = true, published
	return target
end

local function review_cleanup(operation, opts)
	opts = opts or {}
	opts.protected = cleanup_protected()
	local target, err = git.resolve_cleanup_target(operation, opts)
	if not target then notify(err, vim.log.levels.WARN); return end
	return confirm_cleanup(target)
end

local function execute_cleanup(target, message)
	local ok, output, outcome = git.cleanup_target(target, message)
	if ok then
		notify(target.operation .. " completed. " .. (target.rewrite and "Publish with gPF using the pre-cleanup reviewed lease." or "Publish with ordinary push (P)."))
	else
		local recovery = outcome and outcome.state.operation
		notify(table.concat(output or {}, "\n") .. (recovery and "\nResolve conflicts with X, then recover with gx. The reviewed publication lease is retained." or "\nInspect repository state and retry cleanup."), vim.log.levels.WARN)
	end
	M.refresh()
end

local function squash_commits()
	if not repo_required() then
		return
	end

	local entries = git.log(config.max_commit_lines)
	if vim.tbl_isempty(entries) then
		notify("No commits found to squash", vim.log.levels.WARN)
		return
	end

	local options = {}
	for idx, entry in ipairs(entries) do
		table.insert(options, { index = idx, hash = entry.hash, message = entry.message })
	end

	prompts.select(options, {
		prompt = "Squash commits (select oldest commit)",
		format_item = function(item)
			return string.format("%2d %s %s", item.index, item.hash, item.message or "")
		end,
	}, function(choice)
		if not choice then
			return
		end

		local count = choice.index
		local target = review_cleanup("squash", { count = count })
		if not target then return end
		local default_message = build_squash_message(entries, count)

		prompts.input({ prompt = "Commit message", default = default_message }, function(msg)
			if not msg or vim.trim(msg) == "" then
				notify("Squash cancelled (staged changes kept)", vim.log.levels.INFO)
				return
			end

			execute_cleanup(target, msg)
		end)
	end)
end

local function target_label(target)
	return target.remote .. " " .. target.ref
end

local function choose_push_target(opts, callback, always_confirm)
	local target, err = git.resolve_push_target(vim.tbl_extend("force", opts or {}, { inspect_remote = true }))
	if not target then notify(err, vim.log.levels.WARN); return end
	if target.requires_confirmation or always_confirm then
		local answer = confirm(string.format("Publish %s to remote %s, branch %s?",
			target.local_branch, target.remote, target.ref), "&Publish\n&Cancel", 2)
		if answer ~= 1 then notify("Push cancelled"); return end
		target.confirmed = true
	end
	callback(target)
end

local function push_to_target(target, callback)
	git.push_target_async(target, function(ok, output)
		if ok then notify("Pushed to " .. target_label(target))
		else notify(table.concat(output, "\n"), vim.log.levels.WARN) end
		M.refresh()
		if callback then callback(ok, target) end
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
	inputs.centered_input({ prompt = "Message", title = "Create Commit" }, function(msg)
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
	inputs.centered_input({ prompt = "Message", title = "Create Commit" }, function(msg)
		if not msg or vim.trim(msg) == "" then
			return
		end

		run_async_and_refresh(function(cb)
			git.mutate_async("commit pull push", function(done)
				local committed, output = git.commit(msg)
				if not committed then done(false, output); return end
				local target, err = git.resolve_pull_target()
				if not target then done(false, { err }); return end
				local pulled; pulled, output = git.pull_target(target, true)
				if not pulled then done(false, output); return end
				local selected = false
				choose_push_target({}, function(push_target)
					selected = true
					git.push_target_async(push_target, done)
				end, true)
				if not selected then done(false, { "Publication stopped after commit and pull; inspect targets and retry" }, "cancelled") end
			end, cb)
		end, "Committed, pulled and pushed")
	end)
end

local function git_init()
	run_and_refresh(function()
		return select(1, git.init())
	end, "Initialized empty git repository")
end

local function git_pull()
	if not repo_required() then return end
	local target, err = git.resolve_pull_target()
	if not target then notify(err, vim.log.levels.WARN); return end
	run_async_and_refresh(function(cb) git.pull_target_async(target, true, cb) end,
		"Pulled (rebase) " .. target_label(target))
end

local git_pull_rebase = git_pull

local function git_push()
	if not repo_required() then return end
	choose_push_target({}, function(target) push_to_target(target) end)
end

local function git_push_override()
	if not repo_required() then return end
	local branch = git.current_branch()
	if not branch then notify("Cannot push from detached HEAD; switch to a local branch.", vim.log.levels.WARN); return end
	prompts.select(git.remotes(), { prompt = "Choose explicit push remote" }, function(remote)
		if not remote then return end
		prompts.input({ prompt = "Destination branch: ", default = branch }, function(destination)
			if not destination or vim.trim(destination) == "" then return end
			if git.current_branch() ~= branch then notify("Branch changed since target selection; retry.", vim.log.levels.WARN); return end
			destination = vim.trim(destination)
			local ref = destination:match("^refs/") and destination or ("refs/heads/" .. destination)
			choose_push_target({ remote = remote, ref = ref }, function(target) push_to_target(target) end)
		end)
	end)
end

local function git_push_rewrite()
	if not repo_required() then return end
	local protected = cleanup_protected()
	local target, err = git.resolve_cleanup_publication({ protected = protected })
	if not target and not err then target, err = git.resolve_rewrite_target({ protected = protected }) end
	if not target then notify(err, vim.log.levels.WARN); return end
	local review = string.format(
		"Rewrite remote %s (%s), branch %s?\nReviewed remote commit: %s\nLocal %s commit %s replaces it only while the remote still has that commit.",
		target.remote, target.endpoint, target.ref, target.expected, target.local_branch, target.head)
	if confirm(review, "&Rewrite\n&Cancel", 2) ~= 1 then
		notify("Rewrite cancelled")
		return
	end
	target.confirmed = true
	git.push_rewrite_target_async(target, function(ok, output)
		local message = table.concat(output, "\n")
		if ok then
			notify("Rewrote " .. target_label(target))
		elseif message:find("(stale info)", 1, true) then
			notify(message .. "\nRewrite rejected; the remote kept its history. Fetch and review again.", vim.log.levels.WARN)
		else
			notify(message, vim.log.levels.WARN)
		end
		M.refresh()
	end)
end

local function git_fetch()
	if not repo_required() then
		return
	end
	run_async_and_refresh(function(cb)
		git.fetch_async(config.remote, cb)
	end, string.format("Fetched %s", config.remote))
end

local function create_github_repo()
	if not repo_required() then
		return
	end

	if git.remote_get_url(config.remote) then
		local confirm_existing = confirm(
			string.format("Remote '%s' already exists. Continue and let gh update it?", config.remote),
			"&Yes\n&No",
			2
		)
		if confirm_existing ~= 1 then
			notify("GitHub repo creation cancelled", vim.log.levels.INFO)
			return
		end
	end

	inputs.centered_dual_input({
		title = "Create GitHub Repo",
		prompt1 = "Repository (optional: owner/name)",
		prompt2 = "Visibility (private/public)",
		default1 = "",
		default2 = "private",
	}, function(repo_name, visibility)
		repo_name = repo_name and vim.trim(repo_name) or ""
		visibility = visibility and vim.trim(visibility:lower()) or "private"

		if visibility ~= "private" and visibility ~= "public" then
			notify("Visibility must be 'private' or 'public'", vim.log.levels.WARN)
			return
		end

		run_async_and_refresh(function(cb)
			git.create_github_repo_async({
				repo_name = repo_name ~= "" and repo_name or nil,
				visibility = visibility,
				remote = config.remote,
			}, cb)
		end, string.format("Created %s GitHub repo and pushed", visibility))
	end)
end

local function create_pull_request()
	if not repo_required() then
		return
	end

	local current_branch = git.current_branch()
	if not current_branch then
		notify("Cannot create a PR from detached HEAD", vim.log.levels.WARN)
		return
	end

	local function prompt_pr_form(pr_target, base_remote)
		local base_branch = (config.merge_workflow and config.merge_workflow.main_branch) or config.branch_fallback

		inputs.centered_dual_input({
			title = "Create Pull Request",
			prompt1 = "Title",
			prompt2 = "Base",
			default1 = string.format("%s", current_branch),
			default2 = base_branch or "main",
		}, function(title, base)
			title = title and vim.trim(title) or ""
			base = base and vim.trim(base) or ""

			if title == "" then
				notify("PR title is required", vim.log.levels.WARN)
				return
			end

			if base ~= "" and base == pr_target.head then
				notify("Base branch cannot be the same as the PR head in the same repository", vim.log.levels.WARN)
				return
			end

			if base ~= "" and not git.has_local_branch(base) and not git.has_remote_branch(base_remote, base) then
				notify(
					string.format("Base branch '%s' was not found locally or on %s", base, base_remote),
					vim.log.levels.WARN
				)
				return
			end

			prompts.input({ prompt = "PR body (optional): " }, function(body)
				body = body or ""
				run_async_and_refresh(function(cb)
					git.create_pull_request_async({
						title = title,
						body = body,
						base = base ~= "" and base or nil,
						head = pr_target.head,
						repo = pr_target.repo,
					}, cb)
				end, string.format("Created PR from %s to %s", current_branch, base ~= "" and base or "default"))
			end)
		end)
	end

	local target, err = git.resolve_push_target({ inspect_remote = true })
	if not target then notify(err, vim.log.levels.WARN); return end
	local upstream = git.branch_upstream(current_branch)
	local base_remote = upstream and upstream.remote or config.remote
	local pr_target; pr_target, err = git.resolve_pr_target(target, base_remote)
	if not pr_target then notify(err, vim.log.levels.WARN); return end
	if not target.requires_confirmation and target.remote_exists then
		prompt_pr_form(pr_target, base_remote)
		return
	end
	choose_push_target({}, function(selected)
		local selected_pr_target, reason = git.resolve_pr_target(selected, base_remote)
		if not selected_pr_target then notify(reason, vim.log.levels.WARN); return end
		push_to_target(selected, function(ok)
			if ok then prompt_pr_form(selected_pr_target, base_remote) end
		end)
	end)

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

	local conflicted_files, inspection_error = conflict.get_conflicted_files(git)
	if not conflicted_files then notify(inspection_error, vim.log.levels.WARN); return end

	if vim.tbl_isempty(conflicted_files) then
		notify("No files with conflicts found", vim.log.levels.INFO)
		return
	end

	if #conflicted_files == 1 then
		-- Only one file, open it directly
		conflict.open(conflicted_files[1], git)
	else
		-- Multiple files, let user choose
		prompts.select(conflicted_files, {
			prompt = string.format("Select file to resolve (%d conflicts)", #conflicted_files),
		}, function(choice)
			if choice then
				conflict.open(choice, git)
			end
		end)
	end
end

local function switch_new_branch()
	if not repo_required() then
		return
	end

	inputs.centered_input({ prompt = "New branch", title = "Name" }, function(name)
		name = name and vim.trim(name) or nil
		if not name or name == "" then
			return
		end
		run_and_refresh(function()
			return select(1, git.switch_create(name))
		end, string.format("Created and switched to %s", name))
	end)
end

local function switch_to_branch(branch)
	if not git.has_local_branch(branch) then
		notify(string.format("Branch %s not found", branch), vim.log.levels.WARN)
		return
	end

	run_and_refresh(function()
		return select(1, git.switch(branch))
	end, string.format("Switched to %s", branch))
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

	prompts.select(branches, { prompt = "Switch to branch" }, function(choice)
		if not choice then
			return
		end

		switch_to_branch(choice)
	end)
end

local function switch_remote_branch()
	if not repo_required() then
		return
	end

	local branches = git.remote_branches()
	if vim.tbl_isempty(branches) then
		notify("No remote branches found", vim.log.levels.WARN)
		return
	end

	prompts.select(branches, { prompt = "Switch to remote branch" }, function(choice)
		if not choice then
			return
		end

		run_and_refresh(function()
			return select(1, git.fetch_and_switch_remote(choice))
		end, string.format("Fetched and switched to %s", choice))
	end)
end

local function remote_add()
	if not repo_required() then
		return
	end

	inputs.centered_dual_input({
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
	local remote_url = git.remote_get_url(config.remote)
	if not remote_url then
		remote_url = ""
	end
	notify(remote_url)
	inputs.centered_dual_input({
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

	prompts.select(candidates, { prompt = "Merge branch into current" }, function(choice)
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
	prompts.select(candidates, { prompt = prompt }, function(choice)
		if not choice then
			return
		end
		if not git.has_local_branch(choice) then
			notify(string.format("Branch %s no longer exists locally.", choice), vim.log.levels.WARN)
			return
		end
		local choices = { "Merge (preserve shared history)", "Rebase (review cleanup)", "Cancel" }
		prompts.select(choices, { prompt = "Workflow integration choice" }, function(mode)
			if not mode or mode == choices[3] then notify("Merge workflow cancelled"); return end
			local ok, output, result = git.merge_workflow({
				main_branch = main_branch, feature_branch = choice,
				mode = mode == choices[2] and "rebase" or "merge",
				rebase_args = workflow_cfg.rebase_args, protected = cleanup_protected(),
				review_cleanup = function(target) return confirm_cleanup(target) ~= nil end,
			})
			local progress = result.workflow
			local lines = vim.deepcopy(output or {})
			if not ok then
				table.insert(lines, "Completed: " .. (#progress.completed > 0 and table.concat(progress.completed, "; ") or "none"))
				table.insert(lines, "Failed: " .. (progress.failed or result.status))
				table.insert(lines, "Remaining: " .. (#progress.remaining > 0 and table.concat(progress.remaining, "; ") or "none"))
				table.insert(lines, "Current branch: " .. (result.state.branch or "detached HEAD"))
				table.insert(lines, result.state.operation and "Resolve conflicts with X, then recover with gx. Continue resumes remaining workflow steps after revalidation; publication stays manual."
					or "Inspect repository state and decide how to finish the remaining work.")
			end
			if progress.publication == "reviewed-rewrite" then
				table.insert(lines, "Feature publication: after completing integration, switch to " .. choice .. " and use gPF with the pre-cleanup reviewed lease.")
			else table.insert(lines, "Publication remains manual; after completing integration, use P on the branch to publish.") end
			notify(table.concat(lines, "\n"), ok and vim.log.levels.INFO or vim.log.levels.WARN)
			M.refresh()
		end)
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

	prompts.select(candidates, { prompt = "Rebase current branch onto" }, function(choice)
		if not choice then
			return
		end
		local target = review_cleanup("rebase", { onto = choice })
		if target then execute_cleanup(target) end
	end)
end

local function recover_repository()
	local current = git.repository_state()
	if not vim.tbl_contains({ "merge", "rebase", "cherry-pick", "revert" }, current.operation) then
		notify(current.operation and "Inspect the sequencer externally to identify its operation before recovery." or "No merge/rebase/cherry-pick/revert to recover", vim.log.levels.INFO); return
	end
	local actions = { "continue", "abort" }
	if current.operation ~= "merge" then table.insert(actions, "skip") end
	table.insert(actions, "cancel")
	local effect = "Continue asks Git to finish the active " .. current.operation .. "; abort returns to its start and preserves completed synchronization."
	if current.operation ~= "merge" then effect = effect .. " Skip discards the current patch." end
	if current.workflow and current.workflow.status == "paused" then
		effect = effect .. " Continue/skip resumes remaining workflow steps only while prerequisites remain valid. Publication stays manual."
	end
	prompts.select(actions, { prompt = "Recover " .. current.operation .. ": " .. effect }, function(choice)
		if not choice or choice == "cancel" then M.refresh(); return end
		run_async_and_refresh(function(cb) git.recover(current.operation, choice, cb, { expected = current }) end, "Recovery completed")
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
			lines = { "Move the cursor to a keymap to see its explanation." }
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
			local title = string.format("Explanation: %s", m.desc or m.lhs or "")
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

local function delete_selected_branches(selection, format_branch, delete_one)
	local ok, output = git.mutate("delete_branches", function()
		local all_ok, lines = true, {}
		for _, branch in ipairs(selection) do
			local deleted, diagnostics = delete_one(branch)
			table.insert(lines, (deleted and "Deleted: " or "Failed: ") .. format_branch(branch))
			if not deleted then
				all_ok = false
				vim.list_extend(lines, diagnostics or {})
			end
		end
		return all_ok, lines
	end, { target = { branches = selection } })
	notify(table.concat(output or {}, "\n"), ok and vim.log.levels.INFO or vim.log.levels.WARN)
	M.refresh()
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
	local prompt = force and "Force delete local branch (-D)" or "Delete local branch (-d)"
	select_multiple(candidates, prompt, function(selection)
		local verb = force and "Force delete" or "Delete"
		local question = #selection == 1 and string.format("%s local branch %s?", verb, selection[1])
			or string.format("%s %d local branches?\n%s", verb, #selection, table.concat(selection, "\n"))
		local confirmation = confirm(question, "&Yes\n&No", 2)
		if confirmation ~= 1 then
			notify("Branch deletion cancelled", vim.log.levels.INFO)
			return
		end
		delete_selected_branches(selection, function(branch) return branch end, function(branch)
			return git.delete_local_branch(branch, force)
		end)
	end)
end

local function rename_branch()
	if not repo_required() then
		return
	end

	local branches = git.branches()
	if vim.tbl_isempty(branches) then
		notify("No branches found", vim.log.levels.WARN)
		return
	end

	prompts.select(branches, { prompt = "Rename local branch" }, function(choice)
		if not choice then
			return
		end

		inputs.centered_input({ prompt = "New branch name", title = "Rename Branch", default = choice }, function(name)
			name = name and vim.trim(name) or nil
			if not name or name == "" or name == choice then
				return
			end
			if not git.has_local_branch(choice) then
				notify(string.format("Branch %s no longer exists", choice), vim.log.levels.WARN)
				return
			end

			run_and_refresh(function()
				return select(1, git.rename_branch(choice, name))
			end, string.format("Renamed branch %s to %s", choice, name))
		end)
	end)
end

local function delete_branch_safe()
	delete_branch(false)
end

local function delete_branch_force()
	delete_branch(true)
end

local function delete_remote_branch()
	if not repo_required() then
		return
	end

	local branches = git.remote_branch_destinations()
	if vim.tbl_isempty(branches) then
		notify("No remote deletion destinations available. Only standard fetch mappings and unambiguous remote names are supported.", vim.log.levels.WARN)
		return
	end

	local function format_destination(destination)
		return string.format("remote: %s | branch: %s", destination.remote, destination.branch)
	end
	select_multiple(branches, "Delete remote branch", function(selection)
		local description
		if #selection == 1 then
			description = string.format("Delete remote branch %s on remote %s?", selection[1].branch, selection[1].remote)
		else
			local destinations = {}
			for _, destination in ipairs(selection) do table.insert(destinations, format_destination(destination)) end
			description = string.format("Delete %d remote branches?\n%s", #selection, table.concat(destinations, "\n"))
		end
		local confirmation = confirm(description, "&Yes\n&No", 2)
		if confirmation ~= 1 then
			notify("Remote branch deletion cancelled", vim.log.levels.INFO)
			return
		end

		delete_selected_branches(selection, format_destination, function(destination)
			return git.delete_remote_branch(destination.remote, destination.branch)
		end)
	end, format_destination)
end

local function amend_commit()
	if not repo_required() then
		return
	end

	local target = review_cleanup("amend")
	if not target then return end
	local entries = git.log(1)
	local default_msg = (entries[1] and entries[1].message) or ""

	inputs.centered_input({ prompt = "Amend message", title = "Amend Commit", default = default_msg }, function(msg)
		if not msg then
			return
		end
		execute_cleanup(target, msg)
	end)
end

local function temporary_checkout_commit()
	if not repo_required() then
		return
	end

	local line = ui.get_current_commit_line()
	local entry = line and state.commits[line] or nil
	if not entry or not entry.hash then
		notify("Select a commit in the Commits pane first", vim.log.levels.WARN)
		return
	end

	local return_ref = state.temp_checkout.return_ref or git.current_branch() or git.current_head_short()

	run_and_refresh(function()
		local ok, output, result = git.checkout_detached(entry.hash)
		if ok then state.temp_checkout.return_ref = return_ref end
		return ok, output, result
	end, string.format("Temporarily checked out %s (detached HEAD)", entry.hash))
end

local function return_from_temporary_checkout()
	if not repo_required() then
		return
	end

	local return_ref = state.temp_checkout.return_ref
	if not return_ref then
		notify("No temporary checkout return point recorded", vim.log.levels.INFO)
		return
	end

	run_and_refresh(function()
		local ok = select(1, git.checkout(return_ref))
		if ok then
			state.temp_checkout.return_ref = nil
		end
		return ok
	end, string.format("Returned to %s", return_ref))
end

local function toggle_stage_current()
	if not repo_required() then
		return
	end

	local line = ui.get_current_worktree_line()
	if not line then
		notify("No file selected", vim.log.levels.WARN)
		return
	end

	local item = state.status[line]
	if not item then
		return
	end

	if has_staged_change(item.staged) then
		run_and_refresh(function()
			return select(1, git.unstage({ item.file }))
		end, string.format("Unstaged %s", item.file))
	else
		run_and_refresh(function()
			return select(1, git.stage({ item.file }))
		end, string.format("Staged %s", item.file))
	end
end

local function activate_current_selection()
	local branch = ui.get_current_local_branch()
	if branch then
		if repo_required() then switch_to_branch(branch) end
	elseif ui.get_current_worktree_line() then
		toggle_stage_current()
	end
end

local function stash_push()
	if not repo_required() then
		return
	end

	inputs.centered_input({ prompt = "Message (optional)", title = "Stash Push" }, function(msg)
		if msg == nil then
			return
		end
		run_and_refresh(function()
			return select(1, git.stash_push(msg))
		end, "Changes stashed")
	end)
end

local function stash_pop()
	if not repo_required() then
		return
	end

	local stashes = git.stash_list()
	if vim.tbl_isempty(stashes) then
		notify("No stashes found", vim.log.levels.INFO)
		return
	end

	if #stashes == 1 then
		run_and_refresh(function()
			return select(1, git.stash_pop(0))
		end, "Stash popped")
		return
	end

	prompts.select(stashes, { prompt = "Pop stash" }, function(choice)
		if not choice then
			return
		end
		local idx = 0
		for i, s in ipairs(stashes) do
			if s == choice then
				idx = i - 1
				break
			end
		end
		run_and_refresh(function()
			return select(1, git.stash_pop(idx))
		end, "Stash popped")
	end)
end

local function stash_drop()
	if not repo_required() then
		return
	end

	local stashes = git.stash_list()
	if vim.tbl_isempty(stashes) then
		notify("No stashes found", vim.log.levels.INFO)
		return
	end

	prompts.select(stashes, { prompt = "Drop stash" }, function(choice)
		if not choice then
			return
		end
		local idx = 0
		for i, s in ipairs(stashes) do
			if s == choice then
				idx = i - 1
				break
			end
		end

		local confirmation = confirm(string.format("Drop %s?", choice), "&Yes\n&No", 2)
		if confirmation ~= 1 then
			notify("Stash drop cancelled", vim.log.levels.INFO)
			return
		end

		run_and_refresh(function()
			return select(1, git.stash_drop(idx))
		end, "Stash dropped")
	end)
end

keymap_mappings = {
	{ lhs = "gx", rhs = recover_repository, desc = "Recover interrupted operation", explain = "Continue or abort the actual interrupted merge, rebase, cherry-pick or revert. Resolve and stage conflicts with X first. Continue deliberately resumes a remembered integration workflow while prerequisites remain valid; abort preserves completed synchronization. Cancel leaves Git unchanged. Other mutations are rejected until recovery completes." },
	{
		lhs = "q",
		rhs = ui.close,
		desc = "Quit MyLazyGit",
		explain = "Close the MyLazyGit floating UI and return to your editor.\nAll unsaved selections are discarded. Your git state is unchanged.",
	},
	{
		lhs = "<Esc>",
		rhs = ui.close,
		desc = "Quit MyLazyGit",
		explain = "Close the MyLazyGit floating UI and return to your editor.\nAll unsaved selections are discarded. Your git state is unchanged.",
	},
	{
		lhs = "r",
		rhs = M.refresh,
		desc = "Refresh status",
		explain = "Re-read the git status and update every pane: worktree, commits, branches, diff preview, and info bar.\nUseful after making changes outside MyLazyGit or when the UI feels stale.",
	},
	{
		lhs = "i",
		rhs = git_init,
		desc = "Git init",
		explain = "Run `git init` in the current working directory.\nCreates a new empty Git repository with a .git folder. Use this when you open MyLazyGit in a directory that is not yet a git repo.",
	},

	-- Staging
	{
		lhs = "gsf",
		rhs = stage_file,
		desc = "Stage file",
		explain = "Opens a picker to select files one at a time for staging (git add <file>).\nKeep selecting files until you press Esc to finish. Only the selected files are staged.",
	},
	{
		lhs = "gsr",
		rhs = restore_file,
		desc = "Restore file",
		explain = "Discard unstaged changes for selected tracked files (git restore -- <file>).\nThis reverts the working copy to match the index. Untracked files are not affected.\nWarning: discarded changes cannot be recovered.",
	},
	{
		lhs = "gsR",
		rhs = restore_all_files,
		desc = "Restore all files",
		explain = "Discard ALL unstaged changes in every tracked file (git restore -- <files>).\nA confirmation prompt is shown before proceeding.\nUntracked files are not affected.\n\nWarning: this is destructive and cannot be undone.",
	},
	{
		lhs = "gsa",
		rhs = stage_all,
		desc = "Stage all files",
		explain = "Stage every change in the working tree at once (git add .).\nThis includes new, modified, and deleted files. Equivalent to running `git add .` from the repo root.",
	},
	{
		lhs = "gsc",
		rhs = stage_all_and_commit,
		desc = "Stage all and commit",
		explain = "Two-step shortcut:\n1. Stage all changes (git add .)\n2. Prompt for a commit message and create the commit\n\nHandy for quick saves when you want to commit everything in one action.",
	},
	{
		lhs = "gsC",
		rhs = stage_all_and_commit_and_pull,
		desc = "Stage, commit, pull and push",
		explain = "Full workflow shortcut:\n1. Stage all changes (git add .)\n2. Prompt for a commit message and commit\n3. Pull with rebase from the branch upstream; stop if pull fails\n4. Review the full resolved push destination, then optionally publish\n\nPull and push can use different remotes or branch names. Detached HEAD and missing or ambiguous mappings stop the workflow.",
	},
	{
		lhs = "gsu",
		rhs = unstage_file,
		desc = "Unstage file",
		explain = "Opens a picker to select staged files to remove from the index (git restore --staged <file>).\nThe file contents are not changed — only the staging is undone. The changes remain in your working tree.",
	},
	{
		lhs = "gsU",
		rhs = unstage_all_files,
		desc = "Unstage all files",
		explain = "Remove all files from the staging area at once (git restore --staged .).\nNo file contents are modified — this only undoes `git add`. Your working tree changes are preserved.",
	},
	{
		lhs = "gsp",
		rhs = git_pull_rebase,
		desc = "Pull rebase",
		explain = "Pull from the configured branch upstream, including differently named remote branches, and rebase local commits on top.\nThis avoids creating merge commits like 'Merge branch main into ...' and keeps a linear history.\nSame as [p] but placed under the `gs` prefix for discoverability.",
	},

	-- Commits
	{
		lhs = "c",
		rhs = commit_changes,
		desc = "Commit",
		explain = "Open a prompt to type a commit message, then create the commit (git commit -m <message>).\nMake sure you have staged changes first (use gsf, gsa, or Space). If nothing is staged the commit will fail.",
	},
	{
		lhs = "aic",
		rhs = function() ai.generate_commit_message(git) end,
		desc = "AI commit message",
		explain = "Generate a commit message from the staged diff using OpenRouter, then let you edit it before committing.\nIf nothing is staged and there are working-tree changes, you'll be prompted to stage all changes first.",
	},
	{
		lhs = "gss",
		rhs = squash_commits,
		desc = "Squash commits",
		explain = "Combine recent commits into one, including existing staged changes. Select the oldest included commit (the root cannot be included), explicitly choose private cleanup or Rewrite for published history, then edit the message.\nUnknown publication evidence and protected published branches are refused. Cancellation preserves refs and index; a failed commit restores the original branch tip and staged work. Publish private work with P; published cleanup uses gPF with the pre-cleanup reviewed lease.",
	},
	{
		lhs = "gct",
		rhs = temporary_checkout_commit,
		desc = "Temporary checkout commit",
		explain = "Detach HEAD at the commit under the cursor in the Commits pane (git checkout --detach <hash>).\nUse this to step through commits one-by-one with live preview updates while moving in the list.\nYour original location is remembered so you can quickly return with [gcr].",
	},
	{
		lhs = "gcr",
		rhs = return_from_temporary_checkout,
		desc = "Return from temp checkout",
		explain = "Return to where you were before starting temporary commit checkout.\nIf you started from a branch, this switches back to that branch.\nIf you started detached, it returns to the previously recorded commit hash.",
	},
	{
		lhs = "A",
		rhs = amend_commit,
		desc = "Amend commit",
		explain = "Modify the latest commit and include existing staged changes. Explicitly choose private amend or Rewrite for published history before editing the pre-filled message.\nUnknown publication evidence and protected published branches are refused. Cancellation changes no refs or index. Publish private work with P; published cleanup retains its reviewed remote expectation for gPF, even after a fetch.",
	},

	-- Remote operations
	{
		lhs = "p",
		rhs = git_pull,
		desc = "Pull",
		explain = "Pull the full source branch configured by branch.<name>.remote and branch.<name>.merge, shown as Pull in the header, and rebase your local commits on top.\nRebasing avoids automatic merge commits like 'Merge branch main into ...', keeping a clean linear history.\nThis is an async operation — the UI stays responsive while waiting for the network.",
	},
	{
		lhs = "P",
		rhs = git_push,
		desc = "Push",
		explain = "Push the separate destination shown in the header. Branch pushRemote overrides remote.pushDefault, then the pull remote.\nConfigured remote push refspecs and push.default are honored; without explicit policy, use the upstream branch (or the local name on a fork).\nFirst publication requires full-destination confirmation. Use [gPp] to choose an explicit remote and branch. Missing or ambiguous mappings stop with an explanation.\nExisting pull upstream is preserved. Divergent remote history is rejected without forcing.",
	},
	{
		lhs = "gPp", rhs = git_push_override, desc = "Choose explicit push destination",
		explain = "Choose a remote and full destination branch.\nReview and confirm the full destination before first publication or override.\nExisting pull upstream is preserved; ordinary push never forces.",
	},
	{
		lhs = "gPF",
		rhs = git_push_rewrite,
		desc = "Rewrite with reviewed lease",
		explain = "Publish an intentional history rewrite (e.g. after amend or rebase) to the push destination shown in the header.\nA review shows the push endpoint, the full destination ref, the remote commit it replaces and the local commit replacing it; cancel is the default and changes nothing.\nAfter published cleanup, this review retains the remote commit reviewed before cleanup. Git pushes with --force-with-lease=<ref>:<reviewed commit>. If a teammate advanced the branch since review, even when you fetched meanwhile, the rewrite is rejected and never retried as raw force or ordinary push.\nmain, merge_workflow.main_branch and setup() protected_branches are never rewritten.",
	},
	{
		lhs = "f",
		rhs = git_fetch,
		desc = "Fetch",
		explain = "Download objects and refs from the remote (git fetch <remote>).\nThis updates your remote-tracking branches (e.g. origin/main) without changing your working tree or local branches.\nUseful to see what others have pushed before you merge or rebase.",
	},
	{
		lhs = "gpr",
		rhs = create_pull_request,
		desc = "Create pull request",
		explain = "Create a GitHub pull request using the GitHub CLI (gh pr create).\nYou will be prompted for:\n  - PR title (defaults to the current branch name)\n  - Base branch (defaults to your configured main branch)\n  - Optional body text\n\nRequires: the `gh` CLI must be installed and authenticated (gh auth login).\nUses the resolved push destination branch as PR head. Known GitHub forks use user:branch and an explicit base repository; unknown fork identities stop with guidance. Organization-owned fork heads are unsupported by gh. First publication reviews the full destination before publishing, preserving an existing pull upstream. Missing or ambiguous mappings stop; use [gPp] to choose a destination.",
	},
	{
		lhs = "ghr",
		rhs = create_github_repo,
		desc = "Create GitHub repo",
		explain = "Create a new GitHub repository from the current local repo using `gh repo create --source . --push`.\nYou can choose visibility (private/public) and optionally provide an explicit repo name (`owner/name`).\nThe configured remote name is used (default: origin).\n\nRequires: the `gh` CLI must be installed and authenticated (gh auth login).",
	},

	-- Conflicts
	{
		lhs = "C",
		rhs = check_conflicts,
		desc = "Check conflicts",
		explain = "Preview merge conflicts without actually merging:\n1. Fetches latest changes from the remote\n2. Runs `git merge-tree` to simulate a merge\n3. Reports whether conflicts exist\n\nThis is completely safe — no files are changed, no merge is started.\nUse this before merging to see if the merge will be clean.",
	},
	{
		lhs = "X",
		rhs = resolve_conflicts,
		desc = "Resolve conflicts",
		explain = "Open the conflict resolver for unmerged files with merge, diff3 or zdiff3 markers.\n\nLayout:\n  Left pane — Theirs (Git's incoming marker side)\n  Middle pane — Result (live preview of the final file)\n  Right pane — Ours (Git's current marker side)\n\nTitles show the marker labels and the information panel names the operation. During merge, ours is local and theirs is incoming. During rebase, ours is the rebased base (upstream plus commits already replayed); theirs is the commit being replayed. The common ancestor in diff3/zdiff3 is excluded from either choice and remains visible in unresolved previews.\n\nKeybindings inside the resolver:\n  j/k — Navigate between conflicts\n  l   — Accept ours for current conflict\n  h   — Accept theirs for current conflict\n  a   — Accept ours for all conflicts\n  A   — Accept theirs for all conflicts\n  f   — Select another conflicted file\n  s   — Save and stage only after every conflict has a choice\n  q   — Quit without saving\n\nSaving preserves file bytes and checks for edits since loading. Changed files require quitting and reopening with X. Failed writes never stage; after a staging failure, fix the Git error and retry s. Remaining unmerged files are offered after saving. Commit/continue is offered only after the index has no unmerged entries and inspection succeeds.\n\nMalformed markers, binary conflicts and delete/modify conflicts remain unresolved with a diagnostic. Resolve these externally and stage explicitly.",
	},

	-- Remotes
	{
		lhs = "R",
		rhs = remote_add,
		desc = "Add remote",
		explain = "Register a new remote repository (git remote add <name> <url>).\nYou will be prompted for the remote name (e.g. origin) and the URL.\nAfter adding, you can push/pull from this remote.",
	},
	{
		lhs = "U",
		rhs = remote_set_url,
		desc = "Set remote url",
		explain = "Update the URL of an existing remote (git remote set-url <name> <url>).\nThe current URL is pre-filled for easy editing.\nUseful when a repository moves or when switching between HTTPS and SSH URLs.",
	},

	-- Branches
	{
		lhs = "gbn",
		rhs = switch_new_branch,
		desc = "New Branch",
		explain = "Create a new branch and switch to it (git switch -c <name>).\nThe branch is created from your current HEAD position.\nThis is the recommended way to start working on a new feature or fix.",
	},
	{
		lhs = "gbs",
		rhs = switch_branch,
		desc = "Switch branch",
		explain = "Switch to an existing local branch (git switch <name>).\nOpens a picker with all local branches. Your working tree must be clean or the switch may fail.\nTip: stash uncommitted changes first with [gzz] if needed.",
	},
	{
		lhs = "gbN",
		rhs = rename_branch,
		desc = "Rename branch",
		explain = "Rename a local branch (git branch -m <old> <new>).\nOpens a picker with all local branches, then prompts for the new name.\nThe currently checked-out branch can also be renamed.",
	},
	{
		lhs = "gbR",
		rhs = switch_remote_branch,
		desc = "Switch remote branch",
		explain = "Fetch a remote branch, then create/switch to a local tracking branch.\nRuns fetch first (git fetch <remote> <branch>) so your remote-tracking ref is up to date.\nIf the local branch already exists, it simply switches to it.\nOtherwise runs: git switch -c <branch> --track <remote/branch>\n\nUseful for checking out a colleague's branch for the first time.",
	},
	{
		lhs = "gbd",
		rhs = delete_branch_safe,
		desc = "Delete local branches safely",
		explain = "Safely delete local branches (git branch -d).\nChoose branches one by one, then Esc to finish; choosing every candidate also finishes. One confirmation lists the selected branches and defaults to No.\nLocal names containing slashes stay local, even when they resemble remote branches.\nGit refuses unmerged branches and branches checked out in any worktree. Each deletion result is reported; failures do not force deletion or prevent other selected attempts.",
	},
	{
		lhs = "gbD",
		rhs = delete_branch_force,
		desc = "Force delete local branches",
		explain = "Force-delete local branches (git branch -D).\nChoose branches one by one, then Esc to finish. A separate force confirmation lists all selected branches and defaults to No.\nBranches checked out in any worktree remain protected.\nRemote branches are unaffected. Each deletion result is reported.\n\nWarning: commits unique to deleted branches will become unreachable and may be garbage-collected.",
	},
	{
		lhs = "gbx",
		rhs = delete_remote_branch,
		desc = "Delete remote branches",
		explain = "Delete remote branches (git push <remote> --delete refs/heads/<branch>).\nChoose destinations one by one, then Esc to finish. One confirmation lists each configured remote and full branch name and defaults to No.\nEach result is reported; a rejected deletion does not prevent attempts on other selected destinations.\nTracking refs matching overlapping remote names are omitted rather than guessed.\nEvery configured remote must have exactly one standard fetch mapping: refs/heads/* to refs/remotes/<remote>/*.\nCustom, additional or missing mappings leave the entire deletion picker empty because they may populate another remote's namespace.\nCancelling before selection or declining confirmation changes no refs; local branches and same-named remote tags are unaffected.",
	},
	{
		lhs = "gbm",
		rhs = merge_branch,
		desc = "Merge branch",
		explain = "Merge another branch into your current branch (git merge <name>).\nOpens a picker with all local branches except the current one.\nIf there are conflicts, use [X] to open the conflict resolver.",
	},
	{
		lhs = "gbw",
		rhs = merge_workflow,
		desc = "Merge workflow",
		explain = "Choose history-preserving Merge (default) or an explicit reviewed Rebase.\nBoth local branches need valid upstreams and a clean worktree/index. Main updates by fast-forward only; divergence stops. Feature synchronization merges its upstream, then integration merges main into feature and feature into main, preserving published commit IDs.\nRebase uses cleanup review: private replay needs confirmation; published replay needs Rewrite and retains its pre-cleanup lease for gPF. Unknown/protected history is refused.\nThe first failure stops with current state, completed/failed/remaining steps and X/gx recovery. Continue with gx or the resolver confirmation resumes remaining steps after revalidation; further conflicts pause again. Abort preserves completed synchronization. Plans exist only for this editor process. Publication is manual.",
	},
	{
		lhs = "gbr",
		rhs = rebase_branch,
		desc = "Rebase branch",
		explain = "Choose a local branch and explicitly confirm replaying private commits or Rewrite when the replayed history includes published commits. Unknown evidence and protected published branches are refused; cancellation changes no refs or index.\nRebase changes only the reviewed current branch, regardless of rebase.updateRefs. Existing staged changes can prevent Git from rebasing and remain intact. Resolve conflicts with X, then continue, abort or skip with gx. Publish private replay with P; published replay retains the pre-rebase reviewed lease for gPF through conflict recovery and fetches.",
	},

	-- Stage a file or check out a local branch
	{
		lhs = "<Space>",
		rhs = activate_current_selection,
		desc = "Toggle stage / checkout branch",
		explain = "In Local Branches, check out the branch under the cursor (git switch <name>).\nMoving the cursor only previews branch history; press Space to switch. Git refuses a switch that would overwrite local changes.\nIn Worktree, toggle the staging state of the file under the cursor: staged files are unstaged, and unstaged or untracked files are staged.",
	},

	-- Stash
	{
		lhs = "gzz",
		rhs = stash_push,
		desc = "Stash push",
		explain = "Save your uncommitted changes to the stash (git stash push).\nYou can optionally provide a description message.\nStashing lets you temporarily shelve changes so you can switch branches or pull without conflicts.\nRetrieve them later with [gzp].",
	},
	{
		lhs = "gzp",
		rhs = stash_pop,
		desc = "Stash pop",
		explain = "Re-apply stashed changes and remove them from the stash (git stash pop).\nIf there is only one stash entry it is popped immediately.\nIf there are multiple entries, a picker lets you choose which one to pop.\nThe popped changes are applied to your working tree.",
	},
	{
		lhs = "gzd",
		rhs = stash_drop,
		desc = "Stash drop",
		explain = "Permanently delete a stash entry (git stash drop).\nA picker lets you choose which entry to drop, followed by a confirmation prompt.\n\nWarning: dropped stash entries cannot be recovered.",
	},

	-- Navigation
	{
		lhs = "[",
		rhs = ui.bottom_view_prev,
		desc = "Previous bottom pane view",
		explain = "Cycle the bottom-left pane to the previous view.\nThe pane rotates between: Local Branches, Remote Branches, and Diff Preview.\nThe current view number is shown in the pane title (e.g. [1/3]).",
	},
	{
		lhs = "]",
		rhs = ui.bottom_view_next,
		desc = "Next bottom pane view",
		explain = "Cycle the bottom-left pane to the next view.\nThe pane rotates between: Local Branches, Remote Branches, and Diff Preview.\nThe current view number is shown in the pane title (e.g. [2/3]).",
	},
	{
		lhs = "?",
		rhs = show_keymap_popup,
		desc = "Show keymap help",
		explain = "Open this help popup showing all available keymaps with explanations.\nNavigate with j/k to highlight a keymap and see its explanation on the right.\nPress q or Esc to close.",
	},
}

local function set_keymaps()
	ui.set_keymaps(keymap_mappings)
end

function M.open()
	active_controller = M
	ui.set_handlers({
		on_worktree_select = show_preview_for_file,
		on_commit_select = show_preview_for_commit,
		on_local_branch_select = show_branch_log,
	})
	ui.open()
	set_keymaps()
	M.refresh()
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts or {})
	local user_ai_on_change = type(config.ai) == "table" and config.ai.on_change or nil
	local ai_opts = vim.tbl_deep_extend("force", {}, config.ai or {}, {
		on_change = function(event, session)
			if active_controller and active_controller.worktree() == session.worktree() then
				active_controller.refresh()
			end
			if type(user_ai_on_change) == "function" then
				user_ai_on_change(event)
			end
		end,
	})
	ai.setup(ai_opts)

	if vim.fn.has("nvim-0.8") == 0 then
		notify("MyLazyGit requires Neovim 0.8 or newer", vim.log.levels.ERROR)
		return
	end

	define_highlights()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("MyLazyGitHighlights", { clear = true }),
		callback = define_highlights,
	})

	vim.api.nvim_create_user_command("MyLazyGit", function()
		plugin.open()
	end, {})
end

function M.worktree()
	return git.worktree()
end

return M
end

function plugin.open()
	-- Repeated opens focus the existing session even if Neovim changed directory.
	if ui.is_open() and active_controller then
		active_controller.open()
		return
	end
	local session = git_module.session()
	local root = session.worktree()
	controllers[root] = controllers[root] or create_controller(session)
	controllers[root].open()
end

function plugin.refresh()
	if active_controller then active_controller.refresh() end
end

function plugin.setup(opts)
	create_controller(git_module.session()).setup(opts)
end

return plugin
