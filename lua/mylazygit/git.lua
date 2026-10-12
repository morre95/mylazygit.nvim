local reservations = {}
local observers = {}
local fetch_records = {}
local cleanup_reviews = {}

local function create_session(cwd)
local M = {}
local function pack(...) return { n = select("#", ...), ... } end
local token
local expected_intent
local cleanup_key = (vim.uv or vim.loop).fs_realpath(cwd) or cwd

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

	local saved = {}
	for name, value in pairs(opts.env or {}) do saved[name] = vim.env[name] or false; vim.env[name] = value end
	local owner, intent = token, expected_intent
	token, expected_intent = nil, nil
	local launched, output = pcall(vim.fn.systemlist, cmd)
	token, expected_intent = owner, intent
	local code = launched and vim.v.shell_error or nil
	local ok = code == 0
	for name, value in pairs(saved) do vim.env[name] = value or nil end
	if not launched then output = { tostring(output) } end
	if not ok and not opts.silent then
		vim.notify(table.concat(output, "\n"), vim.log.levels.ERROR, { title = "MyLazyGit" })
	end

	return ok, output, code
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
	local owner, intent = token, expected_intent
	token, expected_intent = nil, nil
	local launched, job = pcall(vim.fn.jobstart, cmd, {
		cwd = cwd,
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = collect_output,
		on_stderr = collect_output,
	})
	local waited, code = false, nil
	if launched and job > 0 then
		waited, code = pcall(function() return vim.fn.jobwait({ job })[1] end)
	end
	token, expected_intent = owner, intent
	local ok = launched and waited and code == 0
	if not launched then output = { tostring(job) } end
	if launched and not waited and code then output = { tostring(code) } end
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

	vim.system(cmd, { text = true, cwd = cwd, env = opts.env }, function(result)
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

	vim.system(cmd, { text = true, cwd = cwd, env = opts.env }, function(result)
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

local function head_oid()
	local ok, output = system({ "rev-parse", "--verify", "HEAD" }, { silent = true })
	return ok and output[1] or nil
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

function M.commit_amend(message, target)
	if not target or target.operation ~= "amend" then
		return false, { "Review amend with resolve_cleanup_target and confirm cleanup_target before changing history." }
	end
	return M.cleanup_target(target, message)
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
local function inspect_config(key, all)
	local ok, values, code = system({ "config", all and "--get-all" or "--get", key }, { silent = true })
	if ok then return values end
	-- Exit 1 only establishes absence when Git actually ran and emitted no error.
	if code == 1 and (#values == 0 or (#values == 1 and values[1] == "")) then return {} end
	return {}, "Cannot inspect " .. key .. ": " .. table.concat(values, "\n")
end

local function config_values(key)
	return inspect_config(key, true)
end

local function config_one(key, multiple)
	local values, err = inspect_config(key, multiple)
	if err then return nil, err end
	if multiple and #values > 1 then return nil, "Ambiguous " .. key .. "; configure one value." end
	-- Scalar configuration follows Git's scope/last-value precedence.
	return values[1]
end

local function push_endpoint(remote)
	local key = "remote." .. remote .. ".mirror"
	local bool_ok, mirror, code = system({ "config", "--bool", "--get", key }, { silent = true })
	if not bool_ok and (code ~= 1 or #mirror > 0) then
		return nil, "Invalid " .. key .. "; configure a valid false boolean for ordinary push."
	end
	if mirror[1] == "true" then
		return nil, "Ordinary push refuses remote mirror configuration; disable " .. key .. "."
	end
	local ok, urls = system({ "remote", "get-url", "--push", "--all", remote }, { silent = true })
	if not ok or #urls ~= 1 then return nil, "Ordinary push requires one configured push endpoint." end
	return urls[1]
end

local function legacy_push_args(remote, refspec)
	if not remote or not refspec or refspec == "" then
		return nil, "Explicit push remote and refspec required; resolve the current branch destination."
	end
	if refspec:sub(1, 1) == "+" or refspec:sub(1, 1) == "-" then
		return nil, "Ordinary push refuses forced refspecs or options."
	end
	local endpoint, err = push_endpoint(remote)
	if not endpoint then return nil, err end
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
	if err then return nil, err, true end
	local ref; ref, err = config_one("branch." .. branch .. ".merge", true)
	if err then return nil, err, true end
	if not remote or not ref then return nil, "No complete upstream for " .. branch .. "; configure branch remote and merge." end
	if not ref:match("^refs/heads/.+") then return nil, "Upstream must identify a full refs/heads/ branch." end
	return { remote = remote, ref = ref, branch = ref:sub(12), local_branch = branch }
end

function M.resolve_pull_target()
	local selected_head = head_oid()
	if not selected_head then return nil, "Cannot inspect source HEAD; publication state is unknown." end
	local branch = M.current_branch()
	if not branch then return nil, "Cannot pull from detached HEAD; switch to a local branch." end
	local target, err = upstream_target(branch)
	if not target then return nil, err end
	if target.remote ~= "." and not M.remote_get_url(target.remote) then
		return nil, "Upstream remote " .. target.remote .. " is missing; configure its URL."
	end
	target.head = selected_head
	return target
end

local function configured_branch_destination(destination, endpoint)
	if destination:match("^refs/heads/") then return destination end
	if destination:match("^refs/") then return nil, "Configured push destination must identify a branch." end
	local full = "refs/heads/" .. destination
	if not select(1, system({ "check-ref-format", full }, { silent = true })) then
		return nil, "Configured push destination must be a valid branch."
	end
	-- Git's unqualified destination can name an existing tag or be ambiguous.
	-- Inspect its DWIM candidates before selecting a branch namespace.
	local ok, refs = system({ "ls-remote", "--", endpoint }, { silent = true })
	if not ok then return nil, "Cannot inspect configured push destination; verify its URL/authentication." end
	local candidates = { [destination] = true, ["refs/" .. destination] = true,
		["refs/tags/" .. destination] = true, [full] = true,
		["refs/remotes/" .. destination] = true, ["refs/remotes/" .. destination .. "/HEAD"] = true }
	local matches = {}
	for _, line in ipairs(refs) do
		local ref = line:match("^%S+%s+(%S+)$")
		if ref and candidates[ref] then matches[ref] = true end
	end
	local names = vim.tbl_keys(matches)
	if #names > 1 then return nil, "Configured push destination is ambiguous; use a full refs/heads/ branch." end
	if #names == 1 then
		if not names[1]:match("^refs/heads/") then return nil, "Configured push destination identifies a non-branch ref; use refs/heads/." end
		return names[1]
	end
	return full
end

function M.resolve_push_target(opts)
	local selected_head = head_oid()
	if not selected_head then return nil, "Cannot inspect source HEAD; publication state is unknown." end
	opts = opts or {}
	local branch = M.current_branch()
	if not branch then return nil, "Cannot push from detached HEAD; switch to a local branch." end
	local upstream, upstream_error, invalid_upstream = upstream_target(branch)
	if invalid_upstream then return nil, upstream_error end
	-- Partial/multiple upstream configuration is not an invitation to guess.
	local upstream_remotes, err = config_values("branch." .. branch .. ".remote")
	if err then return nil, err end
	local upstream_refs; upstream_refs, err = config_values("branch." .. branch .. ".merge")
	if err then return nil, err end
	local has_upstream_config = #upstream_remotes > 0 or #upstream_refs > 0
	if has_upstream_config and not upstream then return nil, upstream_error end
	local remote, err = config_one("branch." .. branch .. ".pushRemote")
	if err then return nil, err end
	if not remote then remote, err = config_one("remote.pushDefault") end
	if err then return nil, err end
	remote = opts.remote or remote or (upstream and upstream.remote)
	if not remote then return nil, "No push destination; use gPp to choose a remote and branch." end
	if not M.remote_get_url(remote) then return nil, "Push remote " .. remote .. " is missing; configure its URL." end
	local endpoint; endpoint, err = push_endpoint(remote)
	if not endpoint then return nil, err end
	local specs; specs, err = config_values("remote." .. remote .. ".push")
	if err then return nil, err end
	local ref = opts.ref
	if not ref and #specs > 0 then
		if #specs ~= 1 then return nil, "Ambiguous remote push refspecs; configure one current-branch mapping." end
		local source, destination = specs[1]:match("^([^:]+):([^:]+)$")
		local source_shorthand = source or specs[1]
		if source_shorthand == branch then
			local exists, output, code = system({ "show-ref", "--quiet", "--verify", "--", "refs/tags/" .. branch }, { silent = true })
			if exists then return nil, "Configured push source is ambiguous; use the full refs/heads/ source." end
			if code ~= 1 or #output > 0 then return nil, "Cannot inspect configured push source tag; use a full refs/heads/ source or retry." end
		end
		if not source and (specs[1] == "HEAD" or specs[1] == branch or specs[1] == "refs/heads/" .. branch) then
			source, destination = "refs/heads/" .. branch, "refs/heads/" .. branch
		end
		if not source or source:sub(1, 1) == "+" or (destination:match("^refs/") and not destination:match("^refs/heads/")) then
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

		ref, err = configured_branch_destination(ref, endpoint)
		if not ref then return nil, err end
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
			if not upstream then
				local remotes, reason = M.remotes()
				if reason then return nil, reason end
				local pull_remote = #remotes == 1 and remotes[1] or "origin"
				if remote == pull_remote then
					return nil, "push.default=simple requires a central upstream; use gPp for first publication."
				end
			end
			ref = "refs/heads/" .. branch
		elseif policy ~= nil then return nil, "Unsupported push.default=" .. policy .. "; configure a single branch destination."
		else ref = upstream and upstream.remote == remote and upstream.ref or ("refs/heads/" .. branch) end
	end
	if not ref:match("^refs/heads/.+") or not select(1, system({ "check-ref-format", ref }, { silent = true })) then
		return nil, "Push destination must be a valid full refs/heads/ branch."
	end
	local target = { remote = remote, ref = ref, branch = ref:sub(12), local_branch = branch, head = selected_head,
		set_upstream = not upstream, endpoint = endpoint, override = opts.remote ~= nil or opts.ref ~= nil }
	target.requires_confirmation = target.override or not upstream
	if opts.inspect_remote then
		local exists, output, code = system({ "ls-remote", "--exit-code", "--heads", "--", target.endpoint, target.ref }, { silent = true })
		if not exists and (code ~= 2 or #output > 0) then
			return nil, "Cannot inspect push destination; verify URL/authentication: " .. table.concat(output, "\n")
		end
		target.remote_exists = exists
		if not exists then target.requires_confirmation = true end
		for _, line in ipairs(exists and output or {}) do
			local oid, name = line:match("^(%x+)%s+(%S+)$")
			if name == ref then target.remote_head = oid end
		end
	end
	return target
end

-- Publication evidence is always relative to cached tracking history.
local function map_ref(source, destination, ref)
	local prefix, suffix = source:match("^([^*]*)%*([^*]*)$")
	if not prefix then return source == ref and destination or nil end
	local dp, ds = destination:match("^([^*]*)%*([^*]*)$")
	if not dp or ref:sub(1, #prefix) ~= prefix or (#suffix > 0 and ref:sub(-#suffix) ~= suffix)
		or #ref < #prefix + #suffix then return nil end
	return dp .. ref:sub(#prefix + 1, #ref - #suffix) .. ds
end

local function parse_fetch_mapping(spec)
	return spec:gsub("^+", ""):match("^([^:]+):([^:]+)$")
end

local function fetch_source(spec, tracking)
	local source, destination = parse_fetch_mapping(spec)
	return source and map_ref(destination, source, tracking)
end

local function excluded(specs, ref)
	for _, spec in ipairs(specs) do
		if spec:sub(1, 1) == "^" and map_ref(spec:sub(2), "*", ref) then return true end
	end
	return false
end

local function tracking_ref(target)
	local specs, err = config_values("remote." .. target.remote .. ".fetch")
	if err then return nil, err end
	if excluded(specs, target.ref) then return nil, "Selected target is excluded from fetch tracking" end
	local matches = {}
	for _, spec in ipairs(specs) do
		local source, destination = parse_fetch_mapping(spec)
		local ref = source and map_ref(source, destination, target.ref)
		if ref then matches[ref] = true end
	end
	local refs = vim.tbl_keys(matches)
	if #refs ~= 1 or not refs[1]:match("^refs/remotes/") then return nil, "No unique remote-tracking mapping for selected target" end
	local ok, remotes = system({ "remote" }, { silent = true })
	if not ok then return nil, "Cannot inspect tracking ref ownership" end
	for _, remote in ipairs(remotes) do
		local mappings; mappings, err = config_values("remote." .. remote .. ".fetch")
		if err then return nil, err end
		for _, spec in ipairs(mappings) do
			local remote_ref = fetch_source(spec, refs[1])
			if remote_ref and not excluded(mappings, remote_ref) and (remote ~= target.remote or remote_ref ~= target.ref) then
				return nil, "Tracking ref has ambiguous remote ownership"
			end
		end
	end
	return refs[1]
end

local function fetch_context(remote)
	local ok, urls = system({ "remote", "get-url", "--all", remote }, { silent = true })
	local common_ok, common = system({ "rev-parse", "--git-common-dir" }, { silent = true })
	if not ok or #urls ~= 1 or not common_ok or not common[1] then return nil end
	local specs, err = config_values("remote." .. remote .. ".fetch")
	if err then return nil end
	local directory = common[1]:sub(1, 1) == "/" and common[1] or cwd .. "/" .. common[1]
	return { key = (vim.uv or vim.loop).fs_realpath(directory) or directory, remote = remote, url = urls[1], specs = specs }
end

local function record_fetch(context, ok)
	if not context then return end
	local current = fetch_context(context.remote)
	if not vim.deep_equal(current, context) then return end
	fetch_records[context.key] = fetch_records[context.key] or {}
	local records = fetch_records[context.key]
	local previous = records[context.remote]
	if not ok then
		if not previous or not vim.deep_equal(previous.context, context) then previous = { context = context, refs = {} }; records[context.remote] = previous end
		previous.failed_at = os.time()
		return
	end
	local refs_ok, refs = system({ "for-each-ref", "--format=%(refname)%09%(objectname)", "refs/remotes/" }, { silent = true })
	if not refs_ok then records[context.remote] = nil; return end
	local path_ok, paths = system({ "rev-parse", "--git-path", "FETCH_HEAD" }, { silent = true })
	local fetched = {}
	local path = path_ok and paths[1]
	if path then
		if path:sub(1, 1) ~= "/" then path = cwd .. "/" .. path end
		local readable, lines = pcall(vim.fn.readfile, path)
		for _, line in ipairs(readable and lines or {}) do
			local oid, branch = line:match("^(%x+)\t[^\t]*\tbranch '(.*)' of ")
			if branch then fetched["refs/heads/" .. branch] = oid end
		end
	end
	local observation = { context = context, fetched_at = os.time(), refs = {} }
	for _, line in ipairs(refs) do
		local ref, oid = line:match("^(%S+)\t(%S+)$")
		for _, spec in ipairs(context.specs) do
			local remote_ref = fetch_source(spec, ref)
			if remote_ref and fetched[remote_ref] == oid and not excluded(context.specs, remote_ref) then observation.refs[ref] = { oid = oid, source = remote_ref } end
		end
	end
	records[context.remote] = observation
end

local function publication_freshness(target, ref, oid)
	local context = fetch_context(target.remote)
	local record = context and fetch_records[context.key] and fetch_records[context.key][target.remote]
	if not record or not vim.deep_equal(record.context, context) then return { state = "unobserved" } end
	local evidence = record.refs[ref]
	local fetched_at = evidence and evidence.oid == oid and evidence.source == target.ref and record.fetched_at or nil
	return { state = record.failed_at and "failed" or (fetched_at and "cached" or "unobserved"), fetched_at = fetched_at, failed_at = record.failed_at }
end

--- A shared classification for display and later history-rewrite decisions.
--- Unknown evidence must never authorize rewriting published history.
function M.publication_snapshot(target, limit)
	local reason
	if not target then target, reason = M.resolve_push_target() end
	local snapshot = { target = target, head = head_oid(), state = "unknown", reason = reason, commits = {}, freshness = { state = "unobserved" } }
	local log_ok, lines = system({ "log", "--max-count=" .. (limit or -1), "--pretty=format:%H%x01%h%x01%s", snapshot.head or "HEAD" }, { silent = true })
	for _, line in ipairs(log_ok and lines or {}) do
		local oid, hash, message = line:match("^([^\1]+)\1([^\1]+)\1(.*)$")
		if oid then table.insert(snapshot.commits, { oid = oid, hash = hash, message = message, publication = "unknown" }) end
	end
	if not snapshot.head then snapshot.reason = "Cannot inspect source HEAD; publication state is unknown"; return snapshot end
	if not log_ok then snapshot.reason = "Cannot inspect local commit history"; return snapshot end
	if not target then return snapshot end
	if target.head and target.head ~= snapshot.head then snapshot.reason = "Selected source commit changed; select the target again"; return snapshot end
	if target.endpoint and push_endpoint(target.remote) ~= target.endpoint then snapshot.reason = "Selected push endpoint changed; select the target again"; return snapshot end
	local url_ok, urls = system({ "remote", "get-url", "--all", target.remote }, { silent = true })
	if not url_ok or #urls ~= 1 or (target.endpoint and target.endpoint ~= urls[1]) then
		snapshot.reason = "Tracking history does not identify the selected push endpoint"; return snapshot
	end
	local ref; ref, reason = tracking_ref(target)
	snapshot.tracking_ref = ref
	if not ref then snapshot.reason = reason; return snapshot end
	local ok, output = system({ "rev-parse", "--verify", ref .. "^{commit}" }, { silent = true })
	if not ok then snapshot.reason = "Selected remote-tracking ref is missing or unreadable"; return snapshot end
	snapshot.tracking_oid = output[1]
	snapshot.freshness = publication_freshness(target, ref, snapshot.tracking_oid)
	ok, output = system({ "rev-parse", "--is-shallow-repository" }, { silent = true })
	if not ok or output[1] ~= "false" then snapshot.reason = "Incomplete or unreadable ancestry; publication is unknown"; return snapshot end
	ok, output = system({ "rev-list", snapshot.tracking_oid .. ".." .. snapshot.head }, { silent = true })
	if not ok then snapshot.reason = "Cannot inspect publication history"; return snapshot end
	local local_only = {}
	for _, hash in ipairs(output) do local_only[hash] = true end
	for _, entry in ipairs(snapshot.commits) do entry.publication = local_only[entry.oid] and "local-only" or "published" end
	snapshot.state = local_only[snapshot.head] and "local-only" or "published"
	return snapshot
end

local function revalidate_target(target, operation)
	if type(target) ~= "table" or M.current_branch() ~= target.local_branch then
		return nil, "Branch changed since target selection; retry the operation."
	end
	local resolved, err
	if operation == "push" then
		resolved, err = M.resolve_push_target(target.override and { remote = target.remote, ref = target.ref, inspect_remote = true } or { inspect_remote = true })
	else resolved, err = M.resolve_pull_target() end
	if not resolved then return nil, err end
	if target.head and resolved.head ~= target.head then return nil, "Source commit changed since target selection; retry the operation." end
	if resolved.remote ~= target.remote or resolved.ref ~= target.ref
		or (operation == "push" and (resolved.endpoint ~= target.endpoint or resolved.set_upstream ~= target.set_upstream)) then
		return nil, "Sync destination changed since selection; retry the operation."
	end
	return resolved
end

local function target_args(target, operation, rebase)
	local resolved, err = revalidate_target(target, operation)
	if not resolved then return nil, err end
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

-- Callers may add protected branches but can never unprotect main.
local always_protected_branch = "main"
local protected_refusal = "Protected branch %s cannot be rewritten; publish ordinary commits instead."

local function is_protected_branch(branch, protected)
	if branch == always_protected_branch then return true end
	for _, name in ipairs(protected or {}) do
		if name:gsub("^refs/heads/", "") == branch then return true end
	end
	return false
end

-- History rewrites publish only against the remote commit the user reviewed.
--- opts.protected lists branch names (or refs/heads/ refs) never rewritten, in addition to main.
function M.resolve_rewrite_target(opts)
	opts = opts or {}
	local target, err = M.resolve_push_target({ inspect_remote = true })
	if not target then return nil, err end
	target.protected = vim.deepcopy(opts.protected or {})
	if is_protected_branch(target.branch, target.protected) then
		return nil, protected_refusal:format(target.ref)
	end
	if not target.remote_head then
		return nil, "No remote history at " .. target.remote .. " " .. target.ref .. " to rewrite; use ordinary push for first publication."
	end
	target.expected = target.remote_head
	return target
end

--- Review exactly the commits an operation can replace, using shared publication evidence.
function M.resolve_cleanup_target(operation, opts)
	opts = opts or {}
	if not vim.tbl_contains({ "amend", "squash", "rebase" }, operation) then return nil, "Unsupported history cleanup operation" end
	local snapshot = M.publication_snapshot()
	if snapshot.state == "unknown" then return nil, "Publication is unknown; fetch or fix the push target before cleanup. " .. (snapshot.reason or "") end
	local target = { operation = operation, head = snapshot.head, local_branch = M.current_branch(),
		count = opts.count, onto = opts.onto, protected = vim.deepcopy(opts.protected or {}), expected = M.repository_state(), publication = "local-only" }
	if not target.local_branch then return nil, "Switch to a local branch before history cleanup" end
	local affected
	if operation == "amend" then affected = { snapshot.head }
	elseif operation == "squash" then
		if type(target.count) ~= "number" or target.count < 1 or target.count % 1 ~= 0 then return nil, "Select a positive commit count for squash" end
		local ok, output = system({ "rev-parse", "--verify", "HEAD~" .. target.count .. "^{commit}" }, { silent = true })
		if not ok then return nil, "Squash needs a parent before the selected commits; the root commit cannot be included" end
		target.base = output[1]
		ok, affected = system({ "rev-list", target.base .. "..HEAD" }, { silent = true })
		if not ok then return nil, "Cannot inspect squash history" end
	else
		if not target.onto or not M.has_local_branch(target.onto) then return nil, "Choose a local branch to rebase onto" end
		local ok, output = system({ "rev-parse", "--verify", "refs/heads/" .. target.onto .. "^{commit}" }, { silent = true })
		if not ok then return nil, "Cannot inspect rebase target" end
		target.base = output[1]
		ok, affected = system({ "rev-list", target.base .. "..HEAD" }, { silent = true })
		if not ok then return nil, "Cannot inspect rebase history" end
	end
	local classifications = {}
	for _, entry in ipairs(snapshot.commits) do classifications[entry.oid] = entry.publication end
	for _, oid in ipairs(affected) do
		if classifications[oid] == "unknown" or not classifications[oid] then return nil, "Publication of affected history is unknown" end
		if classifications[oid] == "published" then target.publication = "published" end
	end
	if target.publication == "published" then
		if is_protected_branch(target.local_branch, target.protected) then return nil, protected_refusal:format("refs/heads/" .. target.local_branch) end
		local err; target.rewrite, err = M.resolve_cleanup_publication({ protected = target.protected })
		if not target.rewrite and not err then target.rewrite, err = M.resolve_rewrite_target({ protected = target.protected }) end
		if not target.rewrite then return nil, err end
	else
		local err; target.rewrite, err = M.resolve_cleanup_publication({ protected = target.protected })
		if err then return nil, err end
	end
	return target
end

function M.cleanup_target(target, message)
	if type(target) ~= "table" or not target.expected then return false, { "Review history cleanup before executing it" } end
	return M.mutate("cleanup", function()
		-- Compatible entrypoints can already own a reservation; still validate their review.
		if not M.validate_state(target.expected) then return false, { "Cleanup repository intent changed since review; review again" } end
		if not target.confirmed or (target.publication == "published" and not target.rewrite_confirmed) then
			return false, { "Choose the cleanup operation explicitly; published history requires Rewrite confirmation." }
		end
		local current, err = M.resolve_cleanup_target(target.operation, { count = target.count, onto = target.onto, protected = target.protected })
		if not current then return false, { err } end
		if current.head ~= target.head or current.local_branch ~= target.local_branch or current.publication ~= target.publication or current.base ~= target.base then
			return false, { "Cleanup history changed since review; review again" }
		end
		local ok, output
		if target.rewrite then
			local resolved, reason = revalidate_target(target.rewrite, "push")
			if not resolved then return false, { reason } end
		end
		if target.operation == "amend" then
			ok, output = system(message and vim.trim(message) ~= "" and { "commit", "--amend", "-m", message } or { "commit", "--amend", "--no-edit" })
		elseif target.operation == "squash" then
			local uv = vim.uv or vim.loop
			local path_ok, paths = system({ "rev-parse", "--git-path", "index" }, { silent = true })
			if not path_ok or not paths[1] then return false, { "Cannot locate index for squash recovery" } end
			local index = paths[1]:sub(1, 1) == "/" and paths[1] or cwd .. "/" .. paths[1]
			local backup = index .. ".mylazygit-cleanup-" .. vim.fn.tempname():gsub("[^%w]", "_")
			-- Hooks may stage formatter output before failing; preserve the complete original index.
			local copied, copy_error = uv.fs_copyfile(index, backup)
			if not copied then return false, { "Cannot back up index before squash: " .. tostring(copy_error) } end
			ok, output = system({ "reset", "--soft", target.base })
			if ok then
				ok, output = system({ "commit", "-m", message or "Squashed commits" })
				if not ok then
					local restored, diagnostics = system({ "update-ref", "refs/heads/" .. target.local_branch, target.head, target.base })
					if not restored then vim.list_extend(output, diagnostics) end
					local index_restored, restore_error = uv.fs_rename(backup, index)
					if not index_restored then table.insert(output, "Cannot restore index: " .. tostring(restore_error) .. "; original index saved at " .. backup) end
				else uv.fs_unlink(backup) end
			else uv.fs_unlink(backup) end
		else ok, output = system({ "rebase", "--no-update-refs", "--no-autostash", "--", target.base }) end
		if target.rewrite and (head_oid() ~= target.head or M.repository_state().operation) then
			cleanup_reviews[cleanup_key] = cleanup_reviews[cleanup_key] or {}
			cleanup_reviews[cleanup_key][target.local_branch] = vim.deepcopy(target.rewrite)
		end
		return ok, output
	end, { expected = target.expected, target = target })
end

--- Return a cleanup's original reviewed lease, never a refreshed remote expectation.
function M.resolve_cleanup_publication(opts)
	local branch = M.current_branch()
	local review = cleanup_reviews[cleanup_key] and cleanup_reviews[cleanup_key][branch]
	if not review then return nil end
	local target = vim.deepcopy(review)
	target.head, target.confirmed = head_oid(), nil
	target.protected = vim.list_extend(target.protected or {}, (opts or {}).protected or {})
	local resolved, err = revalidate_target(target, "push")
	if not resolved then return nil, err end
	if is_protected_branch(branch, target.protected) or is_protected_branch(resolved.branch, target.protected) then
		return nil, protected_refusal:format(resolved.ref)
	end
	return target
end

local function rewrite_args(target)
	local resolved, err = revalidate_target(target, "push")
	if not resolved then return nil, err end
	if is_protected_branch(resolved.branch, target.protected) then
		return nil, protected_refusal:format(resolved.ref)
	end
	if not target.expected or not target.confirmed then
		return nil, "Review the destination and remote commit before rewriting " .. target.remote .. " " .. target.ref .. "."
	end
	-- The lease names the reviewed commit; it is never renewed from fetched tracking refs.
	return { "push", "--no-follow-tags", "--force-with-lease=" .. target.ref .. ":" .. target.expected,
		"--", target.remote, "refs/heads/" .. target.local_branch .. ":" .. target.ref }
end

local function complete_cleanup_publication(target)
	local reviews = cleanup_reviews[cleanup_key]
	local review = reviews and reviews[target.local_branch]
	if review and review.expected == target.expected and review.remote == target.remote and review.ref == target.ref then
		reviews[target.local_branch] = nil
	end
end

function M.push_rewrite_target(target)
	local args, err = rewrite_args(target)
	if not args then return false, { err } end
	local ok, output = system(args)
	if ok then complete_cleanup_publication(target) end
	return ok, output
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

function M.push_rewrite_target_async(target, callback)
	local args, err = rewrite_args(target)
	if not args then callback(false, { err }); return end
	system_async(args, { loading_msg = "Rewriting " .. target.remote .. " " .. target.ref .. "..." }, function(ok, output)
		if ok then complete_cleanup_publication(target) end
		callback(ok, output)
	end)
end

function M.fetch_async(remote, callback)
	remote = remote or "origin"
	local context = fetch_context(remote)
	system_async({ "fetch", remote }, {
		loading_msg = string.format("Fetching %s...", remote),
	}, function(ok, output) record_fetch(context, ok); callback(ok, output) end)
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

	if opts.repo and trim(opts.repo) ~= "" then
		table.insert(args, "--repo")
		table.insert(args, trim(opts.repo))
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

function M.rebase(branch, target)
	if not target or target.operation ~= "rebase" or target.onto ~= branch then
		return false, { "Review rebase with resolve_cleanup_target and confirm cleanup_target before changing history." }
	end
	return M.cleanup_target(target)
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

local function github_repository(url)
	local path = url:match("^https://github%.com/(.+)$") or url:match("^git@github%.com:(.+)$")
		or url:match("^ssh://git@github%.com/(.+)$")
	if not path then return nil end
	path = path:gsub("/$", ""):gsub("%.git$", "")
	local owner, name = path:match("^([%w_.-]+)/([%w_.-]+)$")
	if not owner then return nil end
	return { owner = owner, name = name, repo = owner .. "/" .. name }
end

-- An explicit --head disables gh's Git-config fork discovery. Preserve both
-- repository identities when deriving the head of an already resolved push.
function M.resolve_pr_target(target, base_remote)
	if M.current_branch() ~= target.local_branch then return nil, "Branch changed since PR target selection; retry." end
	local ok, urls = system({ "remote", "get-url", "--all", base_remote }, { silent = true })
	if not ok or #urls ~= 1 then return nil, "PR base remote requires one unambiguous repository URL." end
	local base, head = github_repository(urls[1]), github_repository(target.endpoint)
	if base and head then
		return { repo = base.repo, head = base.repo:lower() == head.repo:lower() and target.branch
			or (head.owner .. ":" .. target.branch) }
	end
	-- Retain same-repository operation, including local transport adapters.
	if urls[1] == target.endpoint then return { head = target.branch } end
	return nil, "Cannot determine base and published GitHub repository identities; configure unambiguous GitHub URLs or create the PR with gh --repo owner/repo --head user:branch."
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

--- History-preserving integration; progress describes only steps actually completed.
function M.merge_workflow(opts)
	opts = opts or {}
	local main, feature = opts.main_branch, opts.feature_branch
	local replay = opts.mode == "rebase"
	local integration_label = (replay and "rebase " or "merge main into ") .. tostring(feature)
	local progress = { completed = {}, remaining = {} }
	local function merge(ref, ff)
		-- Command flags override pull/merge/branch options; never autostash or squash.
		return system({ "merge", ff and "--ff-only" or "--ff", "--commit", "--no-edit", "--no-autostash", "--no-squash", "--", ref })
	end
	local function sync(branch, ff)
		local target, err = upstream_target(branch)
		if not target then return false, { err } end
		local fetched, diagnostics = system({ "fetch", "--no-tags", "--", target.remote, target.ref })
		if not fetched then return false, diagnostics end
		local inspected, refs = system({ "rev-parse", "--verify", "FETCH_HEAD^{commit}" }, { silent = true })
		if not inspected or not refs[1] then return false, { "Cannot inspect fetched synchronization target for " .. branch } end
		return merge(refs[1], ff)
	end
	local function integrate()
		if not replay then return merge("refs/heads/" .. main) end
		local protected = vim.list_extend({ main }, vim.deepcopy(opts.protected or {}))
		local target, err = M.resolve_cleanup_target("rebase", { onto = main, protected = protected })
		if not target then return false, { err } end
		if not opts.review_cleanup then return false, { "Explicit cleanup review required before rebasing feature history" } end
		local confirmed = M.without_mutation(opts.review_cleanup, target)
		if not confirmed then progress.cancelled = true; return false, { "Rebase review cancelled; no feature history replayed" } end
		local success, diagnostics = M.cleanup_target(target)
		if target.rewrite then progress.publication = "reviewed-rewrite" end
		return success, diagnostics
	end
	local steps = {
		{ label = "checkout " .. tostring(main), run = function() return M.switch(main) end },
		{ label = "fast-forward main " .. tostring(main), run = function() return sync(main, true) end },
		{ label = "checkout " .. tostring(feature), run = function() return M.switch(feature) end },
		{ label = "merge feature upstream " .. tostring(feature), run = function() return sync(feature, false) end },
		{ label = integration_label, run = integrate },
		{ label = "checkout " .. tostring(main), run = function() return M.switch(main) end },
		{ label = "merge feature into " .. tostring(main), run = function() return merge("refs/heads/" .. feature) end },
	}
	for _, step in ipairs(steps) do table.insert(progress.remaining, step.label) end
	local ok, output, result = M.mutate("merge_workflow", function()
		if not main or not feature or main == "" or feature == "" or main == feature then
			progress.failed = "validate branches"
			return false, { "Choose distinct local main and feature branches for the workflow" }
		end
		if not M.has_local_branch(main) or not M.has_local_branch(feature) then
			progress.failed = "validate branches"
			return false, { "Both workflow branches must exist locally" }
		end
		if opts.mode and opts.mode ~= "merge" and opts.mode ~= "rebase" then
			progress.failed = "validate integration choice"; return false, { "Choose merge or an explicit reviewed rebase" }
		end
		if opts.rebase_args and (type(opts.rebase_args) ~= "table" or next(opts.rebase_args)) then
			progress.failed = "validate integration choice"
			return false, { "merge_workflow.rebase_args is no longer supported; choose reviewed rebase explicitly (gbr or gbw)" }
		end
		-- Validate both synchronization mappings before any branch moves.
		for _, branch in ipairs({ main, feature }) do
			local target, err = upstream_target(branch)
			if not target then progress.failed = "validate synchronization targets"; return false, { err } end
			if not select(1, system({ "check-ref-format", target.ref }, { silent = true }))
				or (target.remote ~= "." and not M.remote_get_url(target.remote)) then
				progress.failed = "validate synchronization targets"
				return false, { "Invalid upstream for " .. branch .. "; configure a valid remote and full branch ref" }
			end
		end
		if #M.status() > 0 then
			progress.failed = "validate clean worktree"
			return false, { "Commit or stash worktree and index changes before merge workflow; automatic stashing is disabled" }
		end
		progress.publication = "ordinary"
		for _, step in ipairs(steps) do
			local launched, success, diagnostics = pcall(step.run)
			if not launched then success, diagnostics = false, { tostring(success) } end
			if success then
				local state = M.repository_state()
				if state.operation or #state.conflicts > 0 then success, diagnostics = false, { "Step left an unfinished operation or unresolved conflicts" } end
			end
			if not success then
				progress.failed = step.label
				table.remove(progress.remaining, 1)
				return false, vim.list_extend({ "Merge workflow stopped at: " .. step.label }, diagnostics or {})
			end
			table.insert(progress.completed, step.label)
			table.remove(progress.remaining, 1)
		end
		return true, { "Merge workflow completed for " .. feature .. " -> " .. main .. "; publish main with ordinary push. " ..
			(progress.publication == "reviewed-rewrite" and "Publish feature with gPF using its pre-cleanup reviewed lease." or "Publish feature with ordinary push.") }
	end, { expected = opts.expected, target = { main_branch = main, feature_branch = feature } })
	result.workflow = progress
	if progress.cancelled then result.status = "cancelled" end
	return ok, output, result
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
	if not ok then return {}, "Cannot inspect configured remotes: " .. table.concat(remotes, "\n") end
	return remotes
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
	remote = remote or "origin"
	local context = fetch_context(remote)
	local ok, output = system({ "fetch", remote })
	record_fetch(context, ok)
	return ok, output
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

	if opts.repo and trim(opts.repo) ~= "" then
		table.insert(args, "--repo")
		table.insert(args, trim(opts.repo))
	end

	if opts.draft then
		table.insert(args, "--draft")
	end

	return system_external("gh", args)
end

function M.worktree()
	return cwd
end

-- Reservations live at the physical worktree seam, including legacy cwd sessions.
local function reservation_key()
	local root = vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
	local path = vim.v.shell_error == 0 and root[1] or cwd
	return (vim.uv or vim.loop).fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
end
local key = reservation_key()
local function in_context(owner, fn, ...)
	local previous = token
	token = owner
	local result = pack(pcall(fn, ...))
	token = previous
	if not result[1] then error(result[2]) end
	return unpack(result, 2, result.n)
end

--- External UI providers cannot borrow the running operation's ownership.
function M.without_mutation(fn, ...)
	local owner, intent = token, expected_intent
	token, expected_intent = nil, nil
	local result = pack(pcall(fn, ...))
	token, expected_intent = owner, intent
	if not result[1] then error(result[2]) end
	return unpack(result, 2, result.n)
end
--- Only the explicitly supplied continuation can resume the reserved workflow.
function M.user_callback(callback)
	local owner = token
	return function(...)
		return M.without_mutation(function(...)
			return in_context(owner and reservations[key] == owner and owner or nil, callback, ...)
		end, ...)
	end
end

function M.on_mutation(callback)
	observers[key] = observers[key] or {}
	observers[key][#observers[key] + 1] = callback
end
local function changed_lifecycle()
	for _, callback in ipairs(observers[key] or {}) do
		vim.schedule(function() pcall(callback) end)
	end
end
function M.with_expected(expected, fn, ...)
	local previous = expected_intent
	expected_intent = expected
	local result = pack(pcall(fn, ...))
	expected_intent = previous
	if not result[1] then error(result[2]) end
	return unpack(result, 2, result.n)
end

local function operation_identity(path)
	local stat = (vim.uv or vim.loop).fs_stat(path)
	local parts = {}
	local files = stat and stat.type == "directory" and { "orig-head", "onto", "head-name", "stopped-sha", "original-commit", "next", "last", "done", "git-rebase-todo", "head", "abort-safety", "todo" } or { "" }
	for _, file in ipairs(files) do
		local candidate = file == "" and path or path .. "/" .. file
		if vim.fn.filereadable(candidate) == 1 then
			local ok, content = pcall(vim.fn.readfile, candidate)
			if ok then parts[#parts + 1] = file .. "=" .. table.concat(content, "\n") end
		end
	end
	return table.concat(parts, "\n")
end

function M.repository_state()
	local head_ok, head = system({ "rev-parse", "--verify", "HEAD" }, { silent = true })
	local branch_ok, branch = system({ "symbolic-ref", "--quiet", "HEAD" }, { silent = true })
	local _, index = system({ "diff", "--cached", "--binary" }, { silent = true })
	local _, unstaged = system({ "diff", "--binary" }, { silent = true })
	local _, status = system({ "status", "--porcelain" }, { silent = true })
	local _, refs = system({ "for-each-ref", "--format=%(refname) %(objectname)", "refs" }, { silent = true })
	local _, conflicts = system({ "diff", "--name-only", "--diff-filter=U" }, { silent = true })
	local operation, operation_id
	for _, entry in ipairs({ { "rebase-merge", "rebase" }, { "rebase-apply", "rebase" }, { "MERGE_HEAD", "merge" }, { "CHERRY_PICK_HEAD", "cherry-pick" }, { "REVERT_HEAD", "revert" }, { "sequencer", "sequencer" } }) do
		local ok, paths = system({ "rev-parse", "--git-path", entry[1] }, { silent = true })
		local path = ok and paths[1]
		if path and path:sub(1, 1) ~= "/" then path = cwd .. "/" .. path end
		if path and (vim.uv or vim.loop).fs_stat(path) then operation, operation_id = entry[2], operation_identity(path); break end
	end
	return { head = head_ok and head[1] or nil, branch = branch_ok and branch[1] or nil, index = table.concat(index, "\n"), status = status, unstaged = table.concat(unstaged, "\n"),
		refs = refs, conflicts = conflicts, operation = operation, operation_id = operation_id, running = reservations[key] and reservations[key].action or nil }
end

local function recovery(state)
	if state.operation == "merge" then return { "resolve conflicts and stage", "merge --continue", "merge --abort" } end
	if state.operation == "rebase" or state.operation == "cherry-pick" or state.operation == "revert" then
		return { "resolve conflicts and stage", state.operation .. " --continue", state.operation .. " --skip", state.operation .. " --abort" }
	end
	if state.operation == "sequencer" then return { "inspect sequencer; cherry-pick/revert --continue or --abort" } end
	if #state.conflicts > 0 then return { "resolve conflicts and stage" } end
	if state.running then return { "wait for " .. state.running .. " to finish" } end
	return { "inspect repository and retry" }
end
local function outcome(action, status, output, before, target)
	local current = M.repository_state()
	return { status = status, action = action, target = target or { worktree = cwd }, diagnostics = output or {},
		state = current, recovery = recovery(current), changed = before and (before.head ~= current.head or before.branch ~= current.branch or not vim.deep_equal(before.status, current.status) or before.index ~= current.index or before.unstaged ~= current.unstaged or not vim.deep_equal(before.refs, current.refs) or before.operation ~= current.operation or before.operation_id ~= current.operation_id) or false }
end
function M.cancel_mutation(action, target)
	local result = outcome(action, "cancelled", { "Action cancelled" }, M.repository_state(), target)
	return false, result.diagnostics, result
end

local function same_intent(expected, current)
	return expected.head == current.head and expected.branch == current.branch and expected.index == current.index
		and vim.deep_equal(expected.refs, current.refs) and expected.operation == current.operation and expected.operation_id == current.operation_id
end

function M.validate_state(expected)
	local current = M.repository_state()
	if not same_intent(expected, current) then
		vim.notify("Branch, HEAD, staged changes or selected refs changed since selection; retry the action.", vim.log.levels.WARN, { title = "MyLazyGit" })
		return false
	end
	return true
end
function M.can_mutate(action)
	local state = M.repository_state()
	if state.running or state.operation or #state.conflicts > 0 then
		vim.notify("Cannot " .. action .. ": " .. (state.running and ("another mutation is running: " .. state.running) or ("resolve or abort " .. (state.operation or "conflicts") .. " first")), vim.log.levels.WARN, { title = "MyLazyGit" })
		return false
	end
	return true
end

local resolution = { stage = true, unstage = true, resolve_conflict = true, recover = true }
local function reserve(action, opts)
	opts = opts or {}
	opts.expected = opts.expected or expected_intent
	local before = M.repository_state()
	local nested = token and reservations[key] == token
	local reason
	if reservations[key] and not nested then reason = "Another mutation is running: " .. reservations[key].action .. ". Wait and retry."
	elseif (before.operation or #before.conflicts > 0) and not resolution[action] then
		reason = "Repository has an unfinished " .. (before.operation or "conflict") .. "; resolve or abort it before " .. action .. "."
	elseif opts.expected_head and opts.expected_head ~= before.head then
		reason = "Source commit changed since target selection; retry the operation."
	elseif not nested and opts.expected and not same_intent(opts.expected, before) then
		reason = "Branch, HEAD or staged changes changed since selection; retry the action."
	end
	if reason then
		local result = outcome(action, "rejected", { reason }, before, opts.target)
		vim.notify(reason, vim.log.levels.WARN, { title = "MyLazyGit" })
		return nil, result
	end
	if nested then return token, before, false end
	local owner = { action = action }
	reservations[key] = owner
	changed_lifecycle()
	return owner, before, true
end

--- Run dependent synchronous mutations under one reservation. Returns legacy values plus outcome.
function M.mutate(action, fn, opts)
	local owner, before, acquired = reserve(action, opts)
	if not owner then return false, before.diagnostics, before end
	local success, ok, output = pcall(in_context, owner, fn)
	if acquired then reservations[key] = nil; changed_lifecycle() end
	if not success then ok, output = false, { tostring(ok) } end
	local result = outcome(action, ok and "success" or "failed", output, before, opts and opts.target)
	return ok, output, result
end

--- fn(done) may use session async methods; dependent callbacks retain ownership until done.
function M.mutate_async(action, fn, callback, opts)
	local owner, before, acquired = reserve(action, opts)
	if not owner then callback(false, before.diagnostics, before); return end
	local finished = false
	local function done(ok, output, status)
		if finished then return end
		finished = true
		if acquired then reservations[key] = nil; changed_lifecycle() end
		local delivered, err = pcall(callback, ok, output, outcome(action, status or (ok and "success" or "failed"), output, before, opts and opts.target))
		if not delivered then
			if reservations[key] == owner then reservations[key] = nil; changed_lifecycle() end
			vim.notify(tostring(err), vim.log.levels.ERROR, { title = "MyLazyGit" })
		end
	end
	local ok, err = pcall(in_context, owner, fn, function(...)
		return in_context(owner, done, ...)
	end)
	if not ok then done(false, { tostring(err) }) end
end

function M.resolve_conflict(file, lines, opts)
	opts = opts or {}
	opts.target = opts.target or { worktree = cwd, file = file }
	return M.mutate("resolve_conflict", function()
		local path = file:sub(1, 1) == "/" and file or cwd .. "/" .. file
		local physical = (vim.uv or vim.loop).fs_realpath(path)
		if not physical or physical:sub(1, #key + 1) ~= key .. "/" then return false, { "Conflict file must belong to this worktree" } end
		if opts.contents and not vim.deep_equal(vim.fn.readfile(path), opts.contents) then return false, { "Conflict file changed since opening; reopen it before saving" } end
		if vim.fn.writefile(lines, path) ~= 0 then return false, { "Could not save conflict resolution" } end
		return M.stage(path)
	end, opts)
end

function M.recover(operation, action, callback, opts)
	opts = opts or {}
	opts.target = opts.target or { worktree = cwd, operation = operation, recovery = action }
	M.mutate_async("recover", function(done)
		local current = M.repository_state()
		if current.operation ~= operation then done(false, { "Interrupted operation changed; inspect repository and retry" }); return end
		local allowed = action == "abort" or action == "continue" or ((operation == "rebase" or operation == "cherry-pick" or operation == "revert") and action == "skip")
		if not allowed or not vim.tbl_contains({ "merge", "rebase", "cherry-pick", "revert" }, operation) then done(false, { "Unsupported recovery action" }); return end
		system_async({ operation, "--" .. action }, { env = { GIT_EDITOR = "true" } }, done)
	end, callback, opts)
end

local function mutation_target(name, args)
	local target = { worktree = cwd, arguments = vim.deepcopy(args) }
	if type(args[1]) == "table" and name ~= "stage" and name ~= "unstage" and name ~= "restore" then target = vim.tbl_extend("force", target, args[1])
	elseif name:find("push", 1, true) or name:find("pull", 1, true) or name:find("fetch", 1, true) or name == "delete_remote_branch" then target.remote, target.ref = args[1], args[2]
	elseif name == "stage" or name == "unstage" or name == "restore" then target.paths = args[1]
	else target.selection = args[1] end
	return target
end

local synchronous = { "stage", "unstage", "restore", "commit", "reset_soft", "init", "commit_amend", "stash_push", "stash_pop", "stash_drop", "pull", "pull_rebase", "push", "pull_target", "push_target", "push_rewrite_target", "merge", "rebase", "switch", "checkout_detached", "checkout", "switch_create", "switch_remote", "fetch_and_switch_remote", "remote_add", "remote_set_url", "delete_local_branch", "delete_branch", "rename_branch", "delete_remote_branch", "fetch", "check_conflicts", "create_pull_request" }
for _, name in ipairs(synchronous) do
	local original = M[name]
	M[name] = function(...)
		local args = pack(...)
		return M.mutate(name, function() return original(unpack(args, 1, args.n)) end, { target = mutation_target(name, args), expected_head = name:find("target", 1, true) and type(args[1]) == "table" and args[1].head or nil })
	end
end
local asynchronous = { pull_target_async = 3, push_target_async = 2, pull_async = 3, pull_rebase_async = 3, push_async = 3, push_set_upstream_async = 3, push_rewrite_target_async = 2, fetch_async = 2, create_pull_request_async = 2, create_github_repo_async = 2 }
for name, callback_index in pairs(asynchronous) do
	local original = M[name]
	M[name] = function(...)
		local args = pack(...)
		local callback = args[callback_index]
		args[callback_index] = nil
		M.mutate_async(name, function(done)
			local owner = token
			args[callback_index] = function(...) return in_context(owner, done, ...) end
			original(unpack(args, 1, callback_index))
		end, callback, { target = mutation_target(name, args), expected_head = name:find("target", 1, true) and type(args[1]) == "table" and args[1].head or nil })
	end
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
