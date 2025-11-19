local M = {}

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize(args)
	local cleaned = {}
	for _, value in ipairs(args) do
		if value and value ~= "" then
			table.insert(cleaned, value)
		end
	end
	return cleaned
end

local function system(args, opts)
	opts = opts or {}
	local cmd = { "git" }
	vim.list_extend(cmd, normalize(args))

	local output = vim.fn.systemlist(cmd)
	local ok = vim.v.shell_error == 0
	if not ok and not opts.silent then
		vim.notify(table.concat(output, "\n"), vim.log.levels.ERROR, { title = "MyLazyGit" })
	end

	return ok, output
end

function M.is_repo()
	local ok = select(1, system({ "rev-parse", "--is-inside-work-tree" }, { silent = true }))
	return ok
end

function M.status()
	local ok, output = system({ "status", "--short" }, { silent = true })
	if not ok then
		return {}
	end
	return output
end

function M.stage(paths)
	paths = type(paths) == "table" and paths or { paths }
	return system(vim.list_extend({ "add" }, paths))
end

function M.unstage(paths)
	paths = type(paths) == "table" and paths or { paths }
	return system(vim.list_extend({ "restore", "--staged" }, paths))
end

function M.commit(message)
	return system({ "commit", "-m", message })
end

function M.init()
	return system({ "init" })
end

function M.pull(remote, branch)
	return system({ "pull", remote, branch })
end

function M.pull_rebase(remote, branch)
	return system({ "pull", "--rebase", remote, branch })
end

function M.push(remote, branch)
	return system({ "push", remote, branch })
end

function M.merge(branch)
	if not branch or branch == "" then
		return false, { "Branch name required for merge" }
	end
	return system({ "merge", branch })
end

function M.rebase(branch)
	if not branch or branch == "" then
		return false, { "Branch name required for rebase" }
	end
	return system({ "rebase", branch })
end

local function local_branch_ref(branch)
	if not branch or branch == "" then
		return nil
	end
	return string.format("refs/heads/%s", branch)
end

function M.has_local_branch(branch)
	local ref = local_branch_ref(branch)
	if not ref then
		return false
	end
	return select(1, system({ "show-ref", "--verify", ref }, { silent = true }))
end

function M.branch_upstream(branch)
	if not branch or branch == "" then
		return nil
	end
	local spec = string.format("%s@{upstream}", branch)
	local ok, output = system({ "rev-parse", "--abbrev-ref", spec }, { silent = true })
	if not ok or not output[1] then
		return nil
	end
	local full = trim(output[1])
	if full == "" then
		return nil
	end
	local remote, upstream_branch = full:match("^([^/]+)/(.+)$")
	if not remote or remote == "" or not upstream_branch or upstream_branch == "" then
		return nil
	end
	return { remote = remote, branch = upstream_branch }
end

function M.merge_workflow(opts)
	opts = opts or {}
	local main_branch = opts.main_branch
	local feature_branch = opts.feature_branch
	local rebase_args = vim.deepcopy(opts.rebase_args or {})

	if not main_branch or main_branch == "" then
		return false, { "Main branch is required for merge workflow" }
	end
	if not feature_branch or feature_branch == "" then
		return false, { "Feature branch is required for merge workflow" }
	end
	if not M.has_local_branch(main_branch) then
		return false, { string.format("Local branch %s not found", main_branch) }
	end
	if not M.has_local_branch(feature_branch) then
		return false, { string.format("Local branch %s not found", feature_branch) }
	end

	local function pull_step(branch)
		local upstream = M.branch_upstream(branch)
		if not upstream then
			return nil
		end
		local label = string.format("pull %s (%s/%s)", branch, upstream.remote, upstream.branch)
		return {
			label = label,
			args = { "pull", upstream.remote, upstream.branch },
		}
	end

	local steps = {
		{ label = string.format("checkout %s", main_branch), args = { "checkout", main_branch } },
	}
	local pull_main = pull_step(main_branch)
	if pull_main then
		table.insert(steps, pull_main)
	end
	table.insert(steps, { label = string.format("checkout %s", feature_branch), args = { "checkout", feature_branch } })
	local pull_feature = pull_step(feature_branch)
	if pull_feature then
		table.insert(steps, pull_feature)
	end

	local rebase_cmd = { "rebase" }
	if type(rebase_args) == "table" then
		vim.list_extend(rebase_cmd, rebase_args)
	end
	table.insert(rebase_cmd, main_branch)
	table.insert(steps, { label = string.format("rebase %s onto %s", feature_branch, main_branch), args = rebase_cmd })

	table.insert(steps, { label = string.format("checkout %s", main_branch), args = { "checkout", main_branch } })
	table.insert(steps, { label = string.format("merge %s", feature_branch), args = { "merge", feature_branch } })

	for _, step in ipairs(steps) do
		local ok, output = system(step.args)
		if not ok then
			local msg = string.format("Merge workflow failed while attempting to %s", step.label)
			local details = output or {}
			table.insert(details, 1, msg)
			return false, details
		end
	end

	return true, { string.format("Merge workflow completed for %s -> %s", feature_branch, main_branch) }
end

function M.switch(branch)
	return system({ "switch", branch })
end

function M.switch_create(branch)
	return system({ "switch", "-c", branch })
end

function M.branches()
	local ok, output = system({ "branch", "--format", "%(refname:short)" }, { silent = true })
	if not ok then
		return {}
	end

	local branches = {}
	for _, line in ipairs(output) do
		local name = trim(line)
		if name ~= "" then
			table.insert(branches, name)
		end
	end

	table.sort(branches)
	return branches
end

function M.remote_branches()
	local ok, output = system({ "branch", "-r", "--format", "%(refname:short)" }, { silent = true })
	if not ok then
		return {}
	end

	local branches = {}
	for _, line in ipairs(output) do
		local name = trim(line)
		if name ~= "" and not name:match("/HEAD$") then
			table.insert(branches, name)
		end
	end

	table.sort(branches)
	return branches
end

function M.remote_add(name, url)
	return system({ "remote", "add", name, url })
end

function M.remote_set_url(name, url)
	return system({ "remote", "set-url", name, url })
end

function M.remote_get_url()
	local ok, output = system({
		"config",
		"--get",
		"remote.origin.url",
	})
	if ok and output[1] and output[1] ~= "" then
		return trim(output[1])
	end
	return false
end

function M.delete_branch(name, force)
	if not name or name == "" then
		return false, { "Branch name required" }
	end

	local flag = force and "-D" or "-d"
	return system({ "branch", flag, name })
end

local function upstream_ref(remote, branch)
	local ok, output = system({ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, { silent = true })
	if ok and output[1] and output[1] ~= "" then
		return trim(output[1])
	end
	if remote and branch then
		return string.format("%s/%s", remote, branch)
	end
end

function M.fetch(remote)
	return system({ "fetch", remote or "origin" })
end

function M.log(limit)
	limit = limit or -1
	local ok, output = system({
		"log",
		-- string.format("-n%d", limit),
		string.format("--max-count=%d", limit),
		"--pretty=format:%h%x01%s",
	}, { silent = true })
	if not ok then
		return {}
	end

	local entries = {}
	for _, line in ipairs(output) do
		local sep = line:find("\1", 1, true)
		if sep then
			table.insert(entries, {
				hash = line:sub(1, sep - 1),
				message = line:sub(sep + 1),
			})
		else
			table.insert(entries, { hash = line, message = "" })
		end
	end
	return entries
end

function M.branch_log(branch, limit)
	if not branch or branch == "" then
		return {}
	end

	limit = limit or -1
	local ok, output = system({
		"log",
		-- string.format("-n%d", limit),
		string.format("--max-count=%d", limit),
		"--graph",
		"--decorate",
		"--oneline",
		"--color=never",
		branch,
	}, { silent = true })

	if not ok then
		return {}
	end

	if vim.tbl_isempty(output) then
		return {
			string.format("No commits found on branch %s.", branch),
		}
	end

	return output
end

function M.unpushed(remote, branch)
	local upstream = upstream_ref(remote, branch)
	if not upstream then
		return {}
	end

	local ok, output = system({
		"log",
		"--pretty=format:%h",
		string.format("%s..HEAD", upstream),
	}, { silent = true })

	if not ok then
		return {}
	end

	return output
end

function M.diff(args)
	local cmd = { "diff" }
	if args then
		vim.list_extend(cmd, args)
	end
	local ok, output = system(cmd, { silent = true })
	if not ok then
		return {}
	end
	return output
end

function M.log_patch(hash)
	if not hash or hash == "" then
		return {}
	end
	local ok, output = system({ "log", "-p", "-1", hash }, { silent = true })
	if not ok then
		return {}
	end
	return output
end

function M.current_branch()
	local ok, output = system({ "rev-parse", "--abbrev-ref", "HEAD" }, { silent = true })
	if not ok or #output == 0 then
		return nil
	end
	local branch = trim(output[1])
	if branch == "HEAD" then
		return nil
	end
	return branch
end

function M.parse_status()
	local status = {}
	for _, line in ipairs(M.status()) do
		local staged = line:sub(1, 1)
		local unstaged = line:sub(2, 2)
		local file = trim(line:sub(4))
		table.insert(status, {
			staged = staged,
			unstaged = unstaged,
			file = file,
		})
	end
	return status
end

function M.check_conflicts(remote, branch)
	remote = remote or "origin"
	branch = branch or "main"

	-- First, fetch the latest changes
	local fetch_ok, fetch_output = system({ "fetch", remote })
	if not fetch_ok then
		return false, fetch_output
	end

	-- Get the merge base
	local base_ok, base_output = system({ "merge-base", "HEAD", string.format("%s/%s", remote, branch) }, { silent = true })
	if not base_ok or not base_output[1] then
		return false, { "Could not determine merge base" }
	end
	local merge_base = trim(base_output[1])

	-- Run merge-tree to check for conflicts
	local merge_tree_ok, merge_tree_output = system({
		"merge-tree",
		merge_base,
		"HEAD",
		string.format("%s/%s", remote, branch)
	}, { silent = true })

	-- Check if there are conflict markers in the output
	-- Markers can appear with diff prefixes like "+<<<<<<<" or directly as "<<<<<<<"
	local has_conflicts = false
	for _, line in ipairs(merge_tree_output) do
		if line:match("^[+%-]?<<<<<<<") or line:match("^[+%-]?=======") or line:match("^[+%-]?>>>>>>>") then
			has_conflicts = true
			break
		end
	end

	return true, {
		has_conflicts = has_conflicts,
		output = merge_tree_output,
		remote = remote,
		branch = branch,
	}
end

return M
