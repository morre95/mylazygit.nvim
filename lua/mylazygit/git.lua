local function create_session(cwd)
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

local function normalize_external(args)
	local cleaned = {}
	for _, value in ipairs(args) do
		if value ~= nil then
			table.insert(cleaned, value)
		end
	end
	return cleaned
end

local function system(args, opts)
	opts = opts or {}
	local cmd = { "git", "-C", cwd }
	vim.list_extend(cmd, normalize(args))

	local output = vim.fn.systemlist(cmd)
	local ok = vim.v.shell_error == 0
	if not ok and not opts.silent then
		vim.notify(table.concat(output, "\n"), vim.log.levels.ERROR, { title = "MyLazyGit" })
	end

	return ok, output
end

local function system_external(bin, args, opts)
	opts = opts or {}
	local cmd = { bin }
	vim.list_extend(cmd, normalize_external(args or {}))

	local output = {}
	local function collect_output(_, lines)
		-- A stream with no output still delivers a single empty EOF entry.
		if #lines ~= 1 or lines[1] ~= "" then vim.list_extend(output, lines) end
	end
	local job = vim.fn.jobstart(cmd, {
		cwd = cwd,
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = collect_output,
		on_stderr = collect_output,
	})
	local ok = job > 0 and vim.fn.jobwait({ job })[1] == 0
	while output[#output] == "" do table.remove(output) end
	if not ok and not opts.silent then
		vim.notify(table.concat(output, "\n"), vim.log.levels.ERROR, { title = "MyLazyGit" })
	end

	return ok, output
end

--- Async git command using vim.system (Neovim 0.10+).
--- Falls back to synchronous `system()` on older versions.
--- @param args string[] git subcommand + arguments
--- @param opts? {silent?: boolean, loading_msg?: string}
--- @param callback fun(ok: boolean, output: string[])
local function system_async(args, opts, callback)
	opts = opts or {}

	-- Fallback: no vim.system (< 0.10)
	if not vim.system then
		local ok, output = system(args, opts)
		callback(ok, output)
		return
	end

	local cmd = { "git", "-C", cwd }
	vim.list_extend(cmd, normalize(args))

	if opts.loading_msg then
		vim.notify(opts.loading_msg, vim.log.levels.INFO, { title = "MyLazyGit" })
	end

	vim.system(cmd, { text = true, cwd = cwd }, function(result)
		vim.schedule(function()
			local ok = result.code == 0
			local raw = ok and (result.stdout or "") or (result.stderr or result.stdout or "")
			local output = vim.split(raw, "\n", { plain = true, trimempty = true })
			if not ok and not opts.silent then
				vim.notify(table.concat(output, "\n"), vim.log.levels.ERROR, { title = "MyLazyGit" })
			end
			callback(ok, output)
		end)
	end)
end

--- Async external command using vim.system.
--- @param bin string
--- @param args string[]
--- @param opts? {silent?: boolean, loading_msg?: string}
--- @param callback fun(ok: boolean, output: string[])
local function system_external_async(bin, args, opts, callback)
	opts = opts or {}

	if not vim.system then
		local ok, output = system_external(bin, args, opts)
		callback(ok, output)
		return
	end

	local cmd = { bin }
	vim.list_extend(cmd, normalize_external(args or {}))

	if opts.loading_msg then
		vim.notify(opts.loading_msg, vim.log.levels.INFO, { title = "MyLazyGit" })
	end

	vim.system(cmd, { text = true, cwd = cwd }, function(result)
		vim.schedule(function()
			local ok = result.code == 0
			local raw = ok and (result.stdout or "") or (result.stderr or result.stdout or "")
			local output = vim.split(raw, "\n", { plain = true, trimempty = true })
			if not ok and not opts.silent then
				vim.notify(table.concat(output, "\n"), vim.log.levels.ERROR, { title = "MyLazyGit" })
			end
			callback(ok, output)
		end)
	end)
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

function M.restore(paths)
        paths = type(paths) == "table" and paths or { paths }
        return system(vim.list_extend({ "restore", "--" }, paths))
end

function M.commit(message)
        return system({ "commit", "-m", message })
end

function M.reset_soft(count)
	count = tonumber(count)
	if not count or count < 1 then
		return false, { "Commit count required for soft reset" }
	end
	return system({ "reset", "--soft", string.format("HEAD~%d", count) })
end

function M.init()
	return system({ "init" })
end

function M.commit_amend(message)
	if message and vim.trim(message) ~= "" then
		return system({ "commit", "--amend", "-m", message })
	end
	return system({ "commit", "--amend", "--no-edit" })
end

-- Stash operations

function M.stash_push(message)
	if message and vim.trim(message) ~= "" then
		return system({ "stash", "push", "-m", message })
	end
	return system({ "stash", "push" })
end

function M.stash_pop(index)
	if index then
		return system({ "stash", "pop", string.format("stash@{%d}", index) })
	end
	return system({ "stash", "pop" })
end

function M.stash_drop(index)
	if index then
		return system({ "stash", "drop", string.format("stash@{%d}", index) })
	end
	return system({ "stash", "drop" })
end

function M.stash_list()
	local ok, output = system({ "stash", "list" }, { silent = true })
	if not ok then
		return {}
	end
	return output
end

-- Targets use remote-side full refs, independent of fetch/tracking namespaces.
local function config_values(key)
	local ok, values = system({ "config", "--get-all", key }, { silent = true })
	return ok and values or {}
end

local function config_one(key, multiple)
	if multiple then
		local values = config_values(key)
		if #values > 1 then return nil, "Ambiguous " .. key .. "; configure one value." end
		return values[1]
	end
	-- Scalar configuration follows Git's scope/last-value precedence.
	local ok, values = system({ "config", "--get", key }, { silent = true })
	return ok and values[1] or nil
end

local function legacy_push_args(remote, refspec)
	if not remote or not refspec or refspec == "" then
		return nil, "Explicit push remote and refspec required; resolve the current branch destination."
	end
	if refspec:sub(1, 1) == "+" or refspec:sub(1, 1) == "-" then
		return nil, "Ordinary push refuses forced refspecs or options."
	end
	local mirror, err = config_one("remote." .. remote .. ".mirror")
	if err then return nil, err end
	if mirror and mirror:lower() ~= "false" and mirror:lower() ~= "no" and mirror ~= "0" then
		return nil, "Ordinary push refuses remote mirror configuration."
	end
	local ok, urls = system({ "remote", "get-url", "--push", "--all", remote }, { silent = true })
	if not ok or #urls ~= 1 then return nil, "Ordinary push requires one configured push endpoint." end
	return { "push", "--no-follow-tags", "--set-upstream", "--", remote, refspec }
end

function M.pull(remote, branch)
	return system({ "pull", remote, branch })
end

function M.pull_rebase(remote, branch)
	return system({ "pull", "--rebase", remote, branch })
end

function M.push(remote, branch)
	local args, err = legacy_push_args(remote, branch)
	if not args then return false, { err } end
	return system(args)
end

local function upstream_target(branch)
	local remote, err = config_one("branch." .. branch .. ".remote")
	if err then return nil, err end
	local ref; ref, err = config_one("branch." .. branch .. ".merge", true)
	if err then return nil, err end
	if not remote or not ref then return nil, "No complete upstream for " .. branch .. "; configure branch remote and merge." end
	if not ref:match("^refs/heads/.+") then return nil, "Upstream must identify a full refs/heads/ branch." end
	return { remote = remote, ref = ref, branch = ref:sub(12), local_branch = branch }
end

function M.resolve_pull_target()
	local branch = M.current_branch()
	if not branch then return nil, "Cannot pull from detached HEAD; switch to a local branch." end
	local target, err = upstream_target(branch)
	if not target then return nil, err end
	if target.remote ~= "." and not M.remote_get_url(target.remote) then
		return nil, "Upstream remote " .. target.remote .. " is missing; configure its URL."
	end
	return target
end

function M.resolve_push_target(opts)
	opts = opts or {}
	local branch = M.current_branch()
	if not branch then return nil, "Cannot push from detached HEAD; switch to a local branch." end
	local upstream, upstream_error = upstream_target(branch)
	-- Partial/multiple upstream configuration is not an invitation to guess.
	local has_upstream_config = #config_values("branch." .. branch .. ".remote") > 0
		or #config_values("branch." .. branch .. ".merge") > 0
	if has_upstream_config and not upstream then return nil, upstream_error end
	local remote, err = config_one("branch." .. branch .. ".pushRemote")
	if err then return nil, err end
	if not remote then remote, err = config_one("remote.pushDefault") end
	if err then return nil, err end
	remote = opts.remote or remote or (upstream and upstream.remote)
	if not remote then return nil, "No push destination; use gPp to choose a remote and branch." end
	if not M.remote_get_url(remote) then return nil, "Push remote " .. remote .. " is missing; configure its URL." end
	local mirror; mirror, err = config_one("remote." .. remote .. ".mirror")
	if err then return nil, err end
	if mirror and mirror ~= "false" and mirror ~= "no" and mirror ~= "0" then
		return nil, "Ordinary push refuses remote mirror configuration; disable remote." .. remote .. ".mirror."
	end
	local urls_ok, endpoints = system({ "remote", "get-url", "--push", "--all", remote }, { silent = true })
	if not urls_ok or #endpoints ~= 1 then return nil, "Push remote has multiple or missing endpoints; configure one push URL." end
	local specs = config_values("remote." .. remote .. ".push")
	local ref = opts.ref
	if not ref and #specs > 0 then
		if #specs ~= 1 then return nil, "Ambiguous remote push refspecs; configure one current-branch mapping." end
		local source, destination = specs[1]:match("^([^:]+):([^:]+)$")
		if not source and (specs[1] == "HEAD" or specs[1] == branch or specs[1] == "refs/heads/" .. branch) then
			source, destination = "refs/heads/" .. branch, "refs/heads/" .. branch
		end
		if not source or source:sub(1, 1) == "+" or not destination:match("^refs/heads/") then
			return nil, "Unsupported or forced push refspec; configure one non-force refs/heads mapping."
		end
		local local_ref = "refs/heads/" .. branch
		if source:find("*", 1, true) then
			local prefix, suffix = source:match("^([^*]*)%*([^*]*)$")
			local dp, ds = destination:match("^([^*]*)%*([^*]*)$")
			if not prefix or not dp or local_ref:sub(1, #prefix) ~= prefix
				or (#suffix > 0 and local_ref:sub(-#suffix) ~= suffix) or #local_ref < #prefix + #suffix then
				return nil, "Push refspec does not map the current branch; configure its destination."
			end
			ref = dp .. local_ref:sub(#prefix + 1, #local_ref - #suffix) .. ds
		elseif source == local_ref or source == branch or source == "HEAD" then ref = destination
		else return nil, "Push refspec does not map the current branch; configure its destination." end
	end
	if not ref then
		local policy; policy, err = config_one("push.default")
		if err then return nil, err end
		if policy == "nothing" or policy == "matching" then
			return nil, "push.default=" .. policy .. " has no single destination; use gPp for an explicit override."
		elseif policy == "current" then ref = "refs/heads/" .. branch
		elseif policy == "upstream" or policy == "tracking" then
			if not upstream or upstream.remote ~= remote then return nil, "push.default=upstream requires the pull upstream remote; configure push policy." end
			ref = upstream.ref
		elseif policy == "simple" then
			if upstream and upstream.remote == remote and upstream.branch ~= branch then
				return nil, "push.default=simple refuses differently named upstream; choose a push mapping or gPp."
			end
			if not upstream then return nil, "push.default=simple requires an upstream; use gPp for first publication." end
			ref = "refs/heads/" .. branch
		elseif policy ~= nil then return nil, "Unsupported push.default=" .. policy .. "; configure a single branch destination."
		else ref = upstream and upstream.remote == remote and upstream.ref or ("refs/heads/" .. branch) end
	end
	if not ref:match("^refs/heads/.+") or not select(1, system({ "check-ref-format", ref }, { silent = true })) then
		return nil, "Push destination must be a valid full refs/heads/ branch."
	end
	local target = { remote = remote, ref = ref, branch = ref:sub(12), local_branch = branch,
		set_upstream = not upstream, endpoint = endpoints[1], override = opts.remote ~= nil or opts.ref ~= nil }
	target.requires_confirmation = target.override or not upstream
	if opts.inspect_remote then
		local exists, output = system({ "ls-remote", "--exit-code", "--heads", "--", target.endpoint, target.ref }, { silent = true })
		if not exists and vim.v.shell_error ~= 2 then
			return nil, "Cannot inspect push destination; verify URL/authentication: " .. table.concat(output, "\n")
		end
		target.remote_exists = exists
		if not exists then target.requires_confirmation = true end
	end
	return target
end

local function target_args(target, operation, rebase)
	if type(target) ~= "table" or M.current_branch() ~= target.local_branch then
		return nil, "Branch changed since target selection; retry the operation."
	end
	local resolved, err
	if operation == "push" then
		resolved, err = M.resolve_push_target(target.override and { remote = target.remote, ref = target.ref, inspect_remote = true } or { inspect_remote = true })
	else resolved, err = M.resolve_pull_target() end
	if not resolved then return nil, err end
	if resolved.remote ~= target.remote or resolved.ref ~= target.ref
		or (operation == "push" and (resolved.endpoint ~= target.endpoint or resolved.set_upstream ~= target.set_upstream)) then
		return nil, "Sync destination changed since selection; retry the operation."
	end
	if operation == "push" and resolved.requires_confirmation and not target.confirmed then
		return nil, "Confirm first publication or explicit override to " .. target.remote .. " " .. target.ref .. "."
	end
	local args = { operation }
	if operation == "push" then table.insert(args, "--no-follow-tags") end
	if operation == "pull" and rebase then table.insert(args, "--rebase") end
	if operation == "push" and resolved.set_upstream then table.insert(args, "--set-upstream") end
	-- Explicit non-force refspec prevents Git's default policy from publishing extra refs.
	vim.list_extend(args, { "--", target.remote, operation == "push" and
		("refs/heads/" .. target.local_branch .. ":" .. target.ref) or target.ref })
	return args
end

function M.pull_target(target, rebase)
	local args, err = target_args(target, "pull", rebase)
	if not args then return false, { err } end
	return system(args)
end

function M.push_target(target)
	local args, err = target_args(target, "push")
	if not args then return false, { err } end
	return system(args)
end

function M.pull_target_async(target, rebase, callback)
	local args, err = target_args(target, "pull", rebase)
	if not args then callback(false, { err }); return end
	system_async(args, { loading_msg = "Pulling " .. target.remote .. " " .. target.ref .. "..." }, callback)
end

function M.push_target_async(target, callback)
	local args, err = target_args(target, "push")
	if not args then callback(false, { err }); return end
	system_async(args, { loading_msg = "Pushing " .. target.remote .. " " .. target.ref .. "..." }, callback)
end

local force_push_unavailable = "Raw force push is unavailable pending a reviewed lease-based replacement."

function M.push_force(remote, branch)
	return false, { force_push_unavailable }
end

-- Async variants for network operations

function M.pull_async(remote, branch, callback)
	system_async({ "pull", remote, branch }, {
		loading_msg = string.format("Pulling from %s/%s...", remote or "origin", branch or ""),
	}, callback)
end

function M.pull_rebase_async(remote, branch, callback)
	system_async({ "pull", "--rebase", remote, branch }, {
		loading_msg = string.format("Pulling (rebase) from %s/%s...", remote or "origin", branch or ""),
	}, callback)
end

function M.push_async(remote, branch, callback)
	local args, err = legacy_push_args(remote, branch)
	if not args then callback(false, { err }); return end
	system_async(args, {
		loading_msg = string.format("Pushing to %s/%s...", remote or "origin", branch or ""),
	}, callback)
end

function M.push_set_upstream_async(remote, branch, callback)
	local args, err = legacy_push_args(remote, branch)
	if not args then callback(false, { err }); return end
	system_async(args, {
		loading_msg = string.format("Pushing (set upstream) to %s/%s...", remote or "origin", branch or ""),
	}, callback)
end

function M.push_force_async(remote, branch, callback)
	callback(false, { force_push_unavailable })
end

function M.fetch_async(remote, callback)
	system_async({ "fetch", remote or "origin" }, {
		loading_msg = string.format("Fetching %s...", remote or "origin"),
	}, callback)
end

function M.create_pull_request_async(opts, callback)
	opts = opts or {}

	if vim.fn.executable("gh") ~= 1 then
		callback(false, {
			"GitHub CLI (`gh`) is not installed or not available in $PATH.",
			"Install from https://cli.github.com and run `gh auth login`.",
		})
		return
	end

	local title = trim(opts.title or "")
	if title == "" then
		callback(false, { "PR title is required" })
		return
	end

	local body = opts.body or ""
	local args = { "pr", "create", "--title", title, "--body", body }

	if opts.base and trim(opts.base) ~= "" then
		table.insert(args, "--base")
		table.insert(args, trim(opts.base))
	end

	if opts.head and trim(opts.head) ~= "" then
		table.insert(args, "--head")
		table.insert(args, trim(opts.head))
	end

	if opts.draft then
		table.insert(args, "--draft")
	end

	system_external_async("gh", args, {
		loading_msg = "Creating pull request...",
	}, callback)
end

function M.create_github_repo_async(opts, callback)
	opts = opts or {}

	if vim.fn.executable("gh") ~= 1 then
		callback(false, {
			"GitHub CLI (`gh`) is not installed or not available in $PATH.",
			"Install from https://cli.github.com and run `gh auth login`.",
		})
		return
	end

	local visibility = trim(opts.visibility or "private")
	if visibility ~= "private" and visibility ~= "public" then
		callback(false, { "Repository visibility must be `private` or `public`" })
		return
	end

	local remote = trim(opts.remote or "origin")
	local args = {
		"repo",
		"create",
		"--source",
		".",
		"--remote",
		remote,
		"--push",
		string.format("--%s", visibility),
	}

	local repo_name = trim(opts.repo_name or "")
	if repo_name ~= "" then
		table.insert(args, 3, repo_name)
	end

	system_external_async("gh", args, {
		loading_msg = string.format("Creating %s GitHub repository...", visibility),
	}, callback)
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
	if not branch or branch == "" then return nil end
	local target = upstream_target(branch)
	if not target then return nil end
	return { remote = target.remote, branch = target.branch }
end

function M.pr_head_branch(branch, remote)
	if not branch or branch == "" then
		return nil
	end

	local target_remote = remote or "origin"
	local upstream = M.branch_upstream(branch)
	if upstream and upstream.branch and upstream.branch ~= "" then
		if upstream.branch == branch then
			return branch
		end

		if upstream.remote == target_remote and M.has_remote_branch(target_remote, branch) then
			return branch
		end
	end

	if M.has_remote_branch(target_remote, branch) then
		return branch
	end

	if M.remote_branch_exists(target_remote, branch) then
		return branch
	end

	return nil
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
		local label = string.format("pull --rebase %s (%s/%s)", branch, upstream.remote, upstream.branch)
		return {
			label = label,
			args = { "pull", "--rebase", upstream.remote, upstream.branch },
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

function M.checkout_detached(ref)
	if not ref or ref == "" then
		return false, { "Commit/reference required for detached checkout" }
	end
	return system({ "checkout", "--detach", ref })
end

function M.checkout(ref)
	if not ref or ref == "" then
		return false, { "Commit/reference required for checkout" }
	end
	return system({ "checkout", ref })
end

function M.switch_create(branch)
        return system({ "switch", "-c", branch })
end

function M.switch_remote(remote_branch)
        if not remote_branch or remote_branch == "" then
                return false, { "Remote branch required" }
        end

        local remote, branch = remote_branch:match("^([^/]+)/(.+)$")
        if not remote or remote == "" or not branch or branch == "" then
                return false, { string.format("Invalid remote branch: %s", remote_branch) }
        end

        if M.has_local_branch(branch) then
                return M.switch(branch)
        end

        return system({ "switch", "-c", branch, "--track", remote_branch })
end

function M.fetch_and_switch_remote(remote_branch)
	if not remote_branch or remote_branch == "" then
		return false, { "Remote branch required" }
	end

	local remote, branch = remote_branch:match("^([^/]+)/(.+)$")
	if not remote or remote == "" or not branch or branch == "" then
		return false, { string.format("Invalid remote branch: %s", remote_branch) }
	end

	local fetched, output = system({ "fetch", remote, branch })
	if not fetched then
		return false, output
	end

	return M.switch_remote(remote_branch)
end

function M.branches()
	local ok, output = system({ "branch", "--format", "%(refname)" }, { silent = true })
	if not ok then
		return {}
	end

	local branches = {}
	for _, line in ipairs(output) do
		local name = trim(line):gsub("^refs/heads/", "")
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

-- A tracking ref is selectable only when one configured remote owns its prefix.
-- Overlapping remote names (team and team/upstream) must not imply a destination.
function M.remote_branch_destinations()
	local remotes_ok, remotes = system({ "remote" }, { silent = true })
	if not remotes_ok then
		return {}
	end
	-- A custom mapping can populate any remote's namespace. Fail closed unless
	-- every configured remote has exactly the standard branch-to-tracking map.
	for _, remote in ipairs(remotes) do
		local ok, specs = system({ "config", "--get-all", "remote." .. remote .. ".fetch" }, { silent = true })
		local canonical = "refs/heads/*:refs/remotes/" .. remote .. "/*"
		if not ok or #specs ~= 1 or (specs[1] ~= canonical and specs[1] ~= "+" .. canonical) then
			return {}
		end
	end
	local refs_ok, refs = system({ "for-each-ref", "--format=%(refname) %(symref)", "refs/remotes/" }, { silent = true })
	if not refs_ok then
		return {}
	end

	local destinations = {}
	for _, line in ipairs(refs) do
		local ref, symbolic = line:match("^(%S+)%s*(.*)$")
		if ref and symbolic == "" then
			local destination, matches = nil, 0
			for _, remote in ipairs(remotes) do
				local prefix = "refs/remotes/" .. remote .. "/"
				if ref:sub(1, #prefix) == prefix then
					matches = matches + 1
					destination = { remote = remote, branch = ref:sub(#prefix + 1) }
				end
			end
			if matches == 1 then
				table.insert(destinations, destination)
			end
		end
	end
	return destinations
end

function M.has_remote_branch(remote, branch)
	remote = trim(remote or "")
	branch = trim(branch or "")
	if remote == "" or branch == "" then
		return false
	end
	local ref = string.format("refs/remotes/%s/%s", remote, branch)
	return select(1, system({ "show-ref", "--verify", ref }, { silent = true }))
end

function M.remote_branch_exists(remote, branch)
	remote = trim(remote or "")
	branch = trim(branch or "")
	if remote == "" or branch == "" then
		return false
	end

	local ok = select(1, system({
		"ls-remote",
		"--exit-code",
		"--heads",
		remote,
		string.format("refs/heads/%s", branch),
	}, { silent = true }))

	return ok
end

function M.remotes()
	local ok, remotes = system({ "remote" }, { silent = true })
	return ok and remotes or {}
end

function M.remote_add(name, url)
	return system({ "remote", "add", name, url })
end

function M.remote_set_url(name, url)
	return system({ "remote", "set-url", name, url })
end

function M.remote_get_url(name)
	local remote = name or "origin"
	local ok, output = system({
		"config",
		"--get",
		string.format("remote.%s.url", remote),
	}, { silent = true })
	if ok and output[1] and output[1] ~= "" then
		return trim(output[1])
	end
	return nil
end

function M.delete_local_branch(name, force)
	if not name or name == "" then
		return false, { "Branch name required" }
	end

	local flag = force and "-D" or "-d"
	return system({ "branch", flag, name })
end

-- Preserve the legacy local-only entry point.
M.delete_branch = M.delete_local_branch

function M.rename_branch(old_name, new_name)
	old_name = trim(old_name or "")
	new_name = trim(new_name or "")

	if old_name == "" then
		return false, { "Branch name required" }
	end
	if new_name == "" then
		return false, { "New branch name required" }
	end

	return system({ "branch", "-m", old_name, new_name })
end

function M.delete_remote_branch(remote, branch)
	remote = trim(remote or "")
	branch = trim(branch or "")

	if remote == "" then
		return false, { "Remote name required" }
	end
	if branch == "" then
		return false, { "Branch name required" }
	end

	return system({ "push", remote, "--delete", "refs/heads/" .. branch })
end

local function upstream_ref(remote, branch)
	if branch and branch ~= "" then
		local spec = string.format("%s@{upstream}", branch)
		local ok, output = system({ "rev-parse", "--abbrev-ref", spec }, { silent = true })
		if ok and output[1] and trim(output[1]) ~= "" then
			return trim(output[1])
		end
	end
	if remote and branch then
		-- Fallback: check if remote/branch ref exists
		local ref = string.format("refs/remotes/%s/%s", remote, branch)
		local ok = select(1, system({ "show-ref", "--verify", ref }, { silent = true }))
		if ok then
			return string.format("%s/%s", remote, branch)
		end
	end
	return nil
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
	local ok, output = system({ "symbolic-ref", "--quiet", "HEAD" }, { silent = true })
	if not ok or #output == 0 then
		return nil
	end
	return trim(output[1]):match("^refs/heads/(.+)$")
end

function M.current_head_short()
	local ok, output = system({ "rev-parse", "--short", "HEAD" }, { silent = true })
	if not ok or not output[1] then
		return nil
	end
	local head = trim(output[1])
	if head == "" then
		return nil
	end
	return head
end

function M.parse_status()
	local status = {}
	for _, line in ipairs(M.status()) do
		local staged = line:sub(1, 1)
		local unstaged = line:sub(2, 2)
		local file = trim(line:sub(4))

		-- Handle renamed/copied files: "R  old -> new" or "C  old -> new"
		local arrow_pos = file:find(" -> ", 1, true)
		if arrow_pos and (staged == "R" or staged == "C") then
			file = trim(file:sub(arrow_pos + 4))
		end

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

	local remote_ref = string.format("%s/%s", remote, branch)

	-- Try modern merge-tree (Git 2.38+) first
	local ok, merge_tree_output = system({
		"merge-tree",
		"--write-tree",
		"--no-messages",
		"HEAD",
		remote_ref,
	}, { silent = true })

	if ok then
		-- Exit code 0 means no conflicts
		return true, {
			has_conflicts = false,
			output = merge_tree_output,
			remote = remote,
			branch = branch,
		}
	end

	-- Modern merge-tree returns exit code 1 for conflicts.
	-- Check if the output looks like modern merge-tree (starts with a tree hash).
	if merge_tree_output[1] and merge_tree_output[1]:match("^%x+$") then
		return true, {
			has_conflicts = true,
			output = merge_tree_output,
			remote = remote,
			branch = branch,
		}
	end

	-- Fallback: legacy 3-arg merge-tree for older Git versions
	local base_ok, base_output =
		system({ "merge-base", "HEAD", remote_ref }, { silent = true })
	if not base_ok or not base_output[1] then
		return false, { "Could not determine merge base" }
	end
	local merge_base = trim(base_output[1])

	local _, legacy_output = system({
		"merge-tree",
		merge_base,
		"HEAD",
		remote_ref,
	}, { silent = true })

	local has_conflicts = false
	for _, line in ipairs(legacy_output) do
		if line:match("^[+%-]?<<<<<<<") or line:match("^[+%-]?=======") or line:match("^[+%-]?>>>>>>>") then
			has_conflicts = true
			break
		end
	end

	return true, {
		has_conflicts = has_conflicts,
		output = legacy_output,
		remote = remote,
		branch = branch,
	}
end

function M.create_pull_request(opts)
	opts = opts or {}

	if vim.fn.executable("gh") ~= 1 then
		return false, {
			"GitHub CLI (`gh`) is not installed or not available in $PATH.",
			"Install from https://cli.github.com and run `gh auth login`.",
		}
	end

	local title = trim(opts.title or "")
	if title == "" then
		return false, { "PR title is required" }
	end

	local body = opts.body or ""
	local args = { "pr", "create", "--title", title, "--body", body }

	if opts.base and trim(opts.base) ~= "" then
		table.insert(args, "--base")
		table.insert(args, trim(opts.base))
	end

	if opts.head and trim(opts.head) ~= "" then
		table.insert(args, "--head")
		table.insert(args, trim(opts.head))
	end

	if opts.draft then
		table.insert(args, "--draft")
	end

	return system_external("gh", args)
end

function M.worktree()
	return cwd
end

return M
end

local M = {}

--- Capture a worktree once. Legacy functions below capture cwd on each call.
--- A directory outside a repository remains usable for the init action.
function M.session(path)
	path = vim.fn.fnamemodify(path or vim.fn.getcwd(), ":p")
	if path ~= "/" then path = path:gsub("/$", "") end
	local output = vim.fn.systemlist({ "git", "-C", path, "rev-parse", "--show-toplevel" })
	if vim.v.shell_error == 0 and output[1] then
		path = output[1]
	end
	return create_session(path)
end

for name in pairs(create_session(".")) do
	M[name] = function(...)
		-- Legacy relative arguments are interpreted from the invocation directory.
		return create_session(vim.fn.getcwd())[name](...)
	end
end

return M
