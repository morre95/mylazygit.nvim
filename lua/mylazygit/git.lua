local M = {}

local function trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function normalize(args)
  local cleaned = {}
  for _, value in ipairs(args) do
    if value and value ~= '' then
      table.insert(cleaned, value)
    end
  end
  return cleaned
end

local function system(args, opts)
  opts = opts or {}
  local cmd = { 'git' }
  vim.list_extend(cmd, normalize(args))

  local output = vim.fn.systemlist(cmd)
  local ok = vim.v.shell_error == 0
  if not ok and not opts.silent then
    vim.notify(table.concat(output, '\n'), vim.log.levels.ERROR, { title = 'MyLazyGit' })
  end

  return ok, output
end

function M.is_repo()
  local ok = select(1, system({ 'rev-parse', '--is-inside-work-tree' }, { silent = true }))
  return ok
end

function M.status()
  local ok, output = system({ 'status', '--short' }, { silent = true })
  if not ok then
    return {}
  end
  return output
end

function M.stage(paths)
  paths = type(paths) == 'table' and paths or { paths }
  return system(vim.list_extend({ 'add' }, paths))
end

function M.unstage(paths)
  paths = type(paths) == 'table' and paths or { paths }
  return system(vim.list_extend({ 'restore', '--staged' }, paths))
end

function M.commit(message)
  return system({ 'commit', '-m', message })
end

function M.init()
  return system({ 'init' })
end

function M.pull(remote, branch)
  return system({ 'pull', remote, branch })
end

function M.push(remote, branch)
  return system({ 'push', remote, branch })
end

function M.switch(branch)
  return system({ 'switch', branch })
end

function M.switch_create(branch)
  return system({ 'switch', '-c', branch })
end

function M.branches()
  local ok, output = system({ 'branch', '--format', '%(refname:short)' }, { silent = true })
  if not ok then
    return {}
  end
  local branches = {}
  for _, line in ipairs(output) do
    local name = trim(line)
    if name ~= '' then
      table.insert(branches, name)
    end
  end
  table.sort(branches)
  return branches
end

function M.remote_add(name, url)
  return system({ 'remote', 'add', name, url })
end

function M.remote_set_url(name, url)
  return system({ 'remote', 'set-url', name, url })
end

local function upstream_ref(remote, branch)
  local ok, output = system({ 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}' }, { silent = true })
  if ok and output[1] and output[1] ~= '' then
    return trim(output[1])
  end
  if remote and branch then
    return string.format('%s/%s', remote, branch)
  end
end

function M.fetch(remote)
  return system({ 'fetch', remote or 'origin' })
end

function M.log(limit)
  limit = limit or 5
  local ok, output = system({
    'log',
    string.format('-n%d', limit),
    '--pretty=format:%h%x01%s',
  }, { silent = true })
  if not ok then
    return {}
  end

  local entries = {}
  for _, line in ipairs(output) do
    local sep = line:find('\1', 1, true)
    if sep then
      table.insert(entries, {
        hash = line:sub(1, sep - 1),
        message = line:sub(sep + 1),
      })
    else
      table.insert(entries, { hash = line, message = '' })
    end
  end
  return entries
end

function M.unpushed(remote, branch)
  local upstream = upstream_ref(remote, branch)
  if not upstream then
    return {}
  end

  local ok, output = system({
    'log',
    '--pretty=format:%h',
    string.format('%s..HEAD', upstream),
  }, { silent = true })

  if not ok then
    return {}
  end

  return output
end

function M.diff(args)
  local cmd = { 'diff' }
  if args then
    vim.list_extend(cmd, args)
  end
  local ok, output = system(cmd, { silent = true })
  if not ok then
    return {}
  end
  return output
end

function M.current_branch()
  local ok, output = system({ 'rev-parse', '--abbrev-ref', 'HEAD' }, { silent = true })
  if not ok or #output == 0 then
    return nil
  end
  local branch = trim(output[1])
  if branch == 'HEAD' then
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

return M
