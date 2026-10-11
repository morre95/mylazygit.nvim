local plugin_root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(plugin_root)
vim.o.columns = 160
vim.o.lines = 60
local notifications = {}
vim.notify = function(message) notifications[#notifications + 1] = message end
vim.env.GIT_CONFIG_GLOBAL = '/dev/null'
vim.env.GIT_CONFIG_NOSYSTEM = '1'
local root, remote, a, b
local function command(cwd, args)
  local cmd = { 'git', '-C', cwd }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
local function fixture()
root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
remote, a, b = root .. '/remote.git', root .. '/alice', root .. '/bob'
command(root, { 'init', '--bare', '--initial-branch=main', remote })
command(root, { 'clone', remote, a })
command(a, { 'config', 'user.name', 'Alice' })
command(a, { 'config', 'user.email', 'alice@example.test' })
vim.fn.writefile({ 'initial' }, a .. '/file.txt')
command(a, { 'add', '.' })
command(a, { 'commit', '-m', 'Initial' })
command(a, { 'push', '-u', 'origin', 'main' })
command(root, { 'clone', remote, b })
command(b, { 'config', 'user.name', 'Bob' })
command(b, { 'config', 'user.email', 'bob@example.test' })
end
local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message .. '\nexpected ' .. vim.inspect(expected) .. '\nactual ' .. vim.inspect(actual))
end
local tests = {}
local function test(name, fn) tests[#tests + 1] = { name, fn } end
local git = require('mylazygit.git')
test('explicit local deletion of team/task leaves the team remote task untouched', function()
  local alice = git.session(a)
  assert(alice.remote_add('team', remote))
  assert(alice.push('team', 'main:task'))
  assert(alice.switch_create('team/task'))
  equal(alice.current_branch(), 'team/task', 'Current local branch keeps its full name despite colliding tracking ref')
  equal(alice.delete_local_branch('team/task', true), false, 'Force deletion refuses the current branch')
  equal(alice.has_local_branch('team/task'), true, 'Current branch remains')
  assert(alice.switch('main'))
  assert(alice.delete_local_branch('team/task', false))
  equal(alice.has_local_branch('team/task'), false, 'Local branch deleted')
  equal(alice.remote_branch_exists('team', 'task'), true, 'Remote task remains')
end)
test('local force deletion still refuses a branch checked out in another worktree', function()
  local alice = git.session(a)
  command(a, { 'worktree', 'add', '-b', 'linked-topic', root .. '/linked' })
  equal(alice.delete_local_branch('linked-topic', true), false, 'Force deletion respects linked worktree checkout')
  equal(alice.has_local_branch('linked-topic'), true, 'Linked worktree branch remains')
  equal(git.session(root .. '/linked').current_branch(), 'linked-topic', 'Linked worktree checkout remains')
end)
test('remote destinations retain slash remote names and full branches without guessing overlapping remotes', function()
  local alice = git.session(a)
  local added, add_details = alice.remote_add('team/upstream', remote)
  assert(added, table.concat(add_details, '\n'))
  local pushed, details = alice.push('team/upstream', 'main:feature/deep/task')
  assert(pushed, table.concat(details, '\n'))
  local target = { remote = 'team/upstream', branch = 'feature/deep/task' }
  local found = false
  for _, destination in ipairs(alice.remote_branch_destinations()) do
    if vim.deep_equal(destination, target) then found = true end
  end
  assert(found, 'Destination separates configured remote from full branch')
  -- New Git rejects this via remote add; existing/manual config can still overlap.
  command(a, { 'config', 'remote.team.url', remote })
  command(a, { 'config', 'remote.team.fetch', '+refs/heads/*:refs/remotes/team/*' })
  for _, destination in ipairs(alice.remote_branch_destinations()) do
    assert(destination.remote ~= 'team' and destination.remote ~= 'team/upstream', 'Ambiguous tracking ref is excluded')
  end
end)
test('remote deletion removes the full branch while preserving its local branch and same-named remote tag', function()
  local alice = git.session(a)
  assert(alice.switch_create('feature/deep/task'))
  assert(alice.switch('main'))
  command(a, { 'tag', 'feature/deep/task' })
  assert(alice.push('origin', 'refs/heads/feature/deep/task:refs/heads/feature/deep/task'))
  assert(alice.push('origin', 'refs/tags/feature/deep/task:refs/tags/feature/deep/task'))
  local deleted, details = alice.delete_remote_branch('origin', 'feature/deep/task')
  assert(deleted, table.concat(details, '\n'))
  equal(alice.remote_branch_exists('origin', 'feature/deep/task'), false, 'Remote branch removed')
  equal(alice.has_local_branch('feature/deep/task'), true, 'Local branch remains')
  local tag_ok, tag_output = alice.push('origin', 'refs/tags/feature/deep/task:refs/tags/feature/deep/task')
  assert(tag_ok and table.concat(tag_output, '\n'):find('Everything up%-to%-date'), 'Remote tag remains unchanged')
end)
test('independent sessions stage and commit in their captured repository after cwd changes', function()
  local alice, bob = git.session(a), git.session(b)
  vim.fn.writefile({ 'alice change' }, a .. '/alice.txt')
  vim.fn.writefile({ 'bob change' }, b .. '/bob.txt')
  vim.api.nvim_set_current_dir(b)
  assert(alice.stage('alice.txt'))
  assert(alice.commit('Alice session commit'))
  equal(alice.log(1)[1].message, 'Alice session commit', 'Alice session commit')
  equal(bob.log(1)[1].message, 'Initial', 'Bob history unchanged')
  equal(bob.parse_status()[1].file, 'bob.txt', 'Bob worktree stays unstaged')
end)
local function action(lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, 'n')) do
    if map.lhs == lhs then assert(map.callback, lhs .. ' callback missing'); map.callback(); return end
  end
  error('Missing mapping ' .. lhs)
end
local function ui_text()
  local lines = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype ~= 'prompt' then
      vim.list_extend(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end
  end
  return table.concat(lines, '\n')
end
test('dedicated remote deletion confirms the exact destination and cancellation changes no refs', function()
  local alice = git.session(a)
  assert(alice.remote_add('team/upstream', remote))
  assert(alice.push('team/upstream', 'main:feature/deep/task'))
  assert(alice.switch_create('feature/deep/task'))
  assert(alice.switch('main'))
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  plugin.setup()
  vim.api.nvim_set_current_dir(a)
  plugin.open()
  local original_select, original_confirm = vim.ui.select, vim.fn.confirm
  local cancel_picker, confirmation, confirmations = true, 2, 0
  vim.ui.select = function(items, opts, submit)
    equal(opts.prompt, 'Delete remote branch', 'Dedicated action picker')
    local target
    for _, destination in ipairs(items) do
      if type(destination) == 'table' and destination.remote == 'team/upstream' and destination.branch == 'feature/deep/task' then
        target = destination
      end
    end
    assert(target, 'Picker carries the separate remote and full branch')
    equal(opts.format_item(target), 'remote: team/upstream | branch: feature/deep/task', 'Picker disambiguates destination')
    if cancel_picker then submit(nil) else submit(target) end
  end
  vim.fn.confirm = function(message, _, default)
    confirmations = confirmations + 1
    equal(message, 'Delete remote branch feature/deep/task on remote team/upstream?', 'Exact destination confirmation')
    equal(default, 2, 'Confirmation defaults to cancellation')
    return confirmation
  end
  action('gbx')
  equal(confirmations, 0, 'Picker cancellation does not confirm')
  equal(alice.remote_branch_exists('team/upstream', 'feature/deep/task'), true, 'Picker cancellation leaves remote ref')
  cancel_picker = false
  action('gbx')
  equal(alice.remote_branch_exists('team/upstream', 'feature/deep/task'), true, 'Confirmation cancellation leaves remote ref')
  equal(alice.has_local_branch('feature/deep/task'), true, 'Cancellation leaves local ref')
  confirmation = 1
  action('gbx')
  equal(alice.remote_branch_exists('team/upstream', 'feature/deep/task'), false, 'Confirmed remote destination deleted')
  equal(alice.has_local_branch('feature/deep/task'), true, 'Remote action leaves local ref')
  vim.ui.select, vim.fn.confirm = original_select, original_confirm
  ui.close()
end)
test('local UI deletion keeps safety checks and identifies force deletion separately', function()
  local alice = git.session(a)
  assert(alice.remote_add('team', remote))
  assert(alice.push('team', 'main:task'))
  assert(alice.switch_create('team/task'))
  vim.fn.writefile({ 'unique commit' }, a .. '/topic.txt')
  assert(alice.stage('topic.txt'))
  assert(alice.commit('Unmerged topic'))
  assert(alice.switch('main'))
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a)
  plugin.open()
  local original_select, original_confirm = vim.ui.select, vim.fn.confirm
  local force, confirmation = false, 2
  vim.ui.select = function(items, opts, submit)
    equal(opts.prompt, force and 'Force delete local branch (-D)' or 'Delete local branch (-d)', 'Local deletion scope is explicit')
    assert(not vim.tbl_contains(items, 'main'), 'Current branch is excluded from deletion picker')
    assert(vim.tbl_contains(items, 'team/task'), 'Slash-named local branch is selectable')
    submit('team/task')
  end
  vim.fn.confirm = function(message, _, default)
    equal(message, force and 'Force delete local branch team/task?' or 'Delete local branch team/task?', 'Local confirmation identifies force separately')
    equal(default, 2, 'Local confirmation defaults to cancellation')
    return confirmation
  end
  action('gbd')
  equal(alice.has_local_branch('team/task'), true, 'Safe cancellation preserves local branch')
  confirmation = 1
  action('gbd')
  equal(alice.has_local_branch('team/task'), true, 'Safe deletion refuses unmerged branch')
  force, confirmation = true, 2
  action('gbD')
  equal(alice.has_local_branch('team/task'), true, 'Force cancellation preserves local branch')
  confirmation = 1
  action('gbD')
  equal(alice.has_local_branch('team/task'), false, 'Explicit force deletion removes unmerged local branch')
  equal(alice.remote_branch_exists('team', 'task'), true, 'Local deletion never touches remote task')
  vim.ui.select, vim.fn.confirm = original_select, original_confirm
  ui.close()
end)
test('delayed UI commit remains in its original repository after close and reopen', function()
  local plugin = require('mylazygit')
  local ui = require('mylazygit.ui')
  plugin.setup()
  vim.api.nvim_set_current_dir(a)
  vim.fn.writefile({ 'prompt change' }, a .. '/prompt.txt')
  plugin.open()
  action('gsa')
  local original = vim.fn.prompt_setcallback
  local submit
  vim.fn.prompt_setcallback = function(_, cb) submit = cb end
  action('c')
  vim.fn.prompt_setcallback = original
  assert(submit, 'commit prompt was shown')
  ui.close()
  vim.api.nvim_set_current_dir(b)
  plugin.open()
  local before = ui_text()
  submit('Delayed Alice commit')
  equal(git.session(a).log(1)[1].message, 'Delayed Alice commit', 'Delayed commit belongs to Alice')
  equal(git.session(b).log(1)[1].message, 'Initial', 'Bob history unchanged')
  equal(ui_text(), before, 'Old completion must not redraw Bob UI')
  ui.close()
end)
test('raw force push rejects through synchronous and asynchronous entry points', function()
  local alice = git.session(a)
  local before = command(remote, { 'rev-parse', 'refs/heads/main' })
  local ok, output = alice.push_force('origin', 'main')
  equal(ok, false, 'Synchronous raw force push is disabled')
  assert(table.concat(output, '\n'):match('unavailable'), 'Disabled reason returned')
  local done
  alice.push_force_async('origin', 'main', function(success, details)
    equal(success, false, 'Asynchronous raw force push is disabled')
    assert(table.concat(details, '\n'):match('unavailable'), 'Async disabled reason returned')
    done = true
  end)
  assert(vim.wait(5000, function() return done end), 'Async force callback completes')
  equal(command(remote, { 'rev-parse', 'refs/heads/main' }), before, 'Remote history unchanged')
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a)
  plugin.open()
  action('gPF')
  assert(notifications[#notifications]:match('unavailable'), 'UI explains disabled force action')
  action('?')
  assert(ui_text():match('Force push unavailable'), 'Help identifies unavailable force action')
  action('q')
  ui.close()
end)
test('AI commit and cancellation prompts retain the invocation repository', function()
  local ai = require('mylazygit.ai')
  ai.setup({ api_key = 'test-placeholder' })
  local original_system, original_input = vim.fn.system, vim.ui.input
  vim.fn.system = function(cmd)
    if type(cmd) == 'table' and cmd[1] == 'curl' then
      return vim.json.encode({ choices = { { message = { content = 'suggested message' } } } })
    end
    return original_system(cmd)
  end
  local submit
  vim.ui.input = function(_, cb) submit = cb end
  vim.fn.writefile({ 'AI change' }, a .. '/ai.txt')
  assert(git.session(a).stage('ai.txt'))
  vim.api.nvim_set_current_dir(a)
  ai.generate_commit_message()
  assert(submit, 'AI confirmation shown')
  vim.api.nvim_set_current_dir(b)
  submit('Alice AI commit')
  equal(git.session(a).log(1)[1].message, 'Alice AI commit', 'AI commit stays in Alice')
  equal(git.session(b).log(1)[1].message, 'Initial', 'Bob unchanged by AI confirmation')
  vim.fn.writefile({ 'cancel change' }, a .. '/ai.txt')
  assert(git.session(a).stage('ai.txt'))
  vim.api.nvim_set_current_dir(a)
  ai.generate_commit_message()
  vim.api.nvim_set_current_dir(b)
  submit(nil)
  equal(git.session(a).parse_status()[1].staged, ' ', 'AI cancellation unstages Alice')
  vim.fn.system, vim.ui.input = original_system, original_input
end)
test('conflict resolver reads writes and stages in the captured worktree', function()
  local alice = git.session(a)
  assert(alice.switch_create('conflicting'))
  vim.fn.writefile({ 'feature side' }, a .. '/file.txt')
  assert(alice.stage('file.txt'))
  assert(alice.commit('Feature change'))
  assert(alice.switch('main'))
  vim.fn.writefile({ 'main side' }, a .. '/file.txt')
  assert(alice.stage('file.txt'))
  assert(alice.commit('Main change'))
  equal(alice.merge('conflicting'), false, 'Real merge conflict created')
  local resolver = require('mylazygit.conflict')
  vim.api.nvim_set_current_dir(b)
  local original_select, submit = vim.ui.select
  vim.ui.select = function(_, _, cb) submit = cb end
  resolver.open('file.txt', alice)
  action('a')
  action('s')
  equal(vim.fn.readfile(a .. '/file.txt')[1], 'main side', 'Resolved Alice file')
  equal(vim.fn.readfile(b .. '/file.txt'), { 'initial' }, 'Bob file unchanged')
  equal(alice.diff({ '--name-only', '--diff-filter=U' }), {}, 'Alice file was staged')
  assert(vim.wait(5000, function() return submit ~= nil end), 'Merge commit prompt shown')
  submit('Commit')
  assert(vim.wait(5000, function() return alice.log(1)[1].message:match('Merge branch') end), 'Alice merge committed')
  equal(git.session(b).log(1)[1].message, 'Initial', 'Bob unchanged by merge continuation')
  vim.ui.select = original_select
end)
test('UI snapshots and actions stay in the original repository after repeated open', function()
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.fn.writefile({ 'alice change' }, a .. '/alice-only.txt')
  vim.fn.writefile({ 'bob change' }, b .. '/bob-only.txt')
  vim.api.nvim_set_current_dir(a)
  plugin.open()
  vim.api.nvim_set_current_dir(b)
  plugin.open()
  action('r')
  assert(ui_text():find(a, 1, true), 'Header identifies captured worktree')
  assert(ui_text():match('alice%-only.txt'), 'Snapshot remains Alice')
  assert(not ui_text():match('bob%-only.txt'), 'Bob file absent from Alice snapshot')
  action('gsa')
  equal(git.session(a).parse_status()[1].staged, 'A', 'UI stage targets Alice')
  equal(git.session(b).parse_status()[1].staged, '?', 'UI leaves Bob unstaged')
  ui.close()
end)

test('temporary checkout return is retained per worktree across cwd changes and reopen', function()
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  local alice, bob = git.session(a), git.session(b)
  assert(alice.switch_create('alice-topic'))
  vim.api.nvim_set_current_dir(a)
  plugin.open()
  ui.focus('commits')
  action('gct')
  equal(alice.current_branch(), nil, 'Alice checkout detaches')
  vim.api.nvim_set_current_dir(b)
  action('gcr')
  equal(alice.current_branch(), 'alice-topic', 'Return restores Alice branch after cwd change')
  equal(bob.current_branch(), 'main', 'Bob branch unchanged')
  ui.focus('commits')
  action('gct')
  ui.close()
  plugin.open()
  action('gcr')
  equal(bob.current_branch(), 'main', 'Alice return point cannot affect Bob')
  ui.close()
  vim.api.nvim_set_current_dir(a)
  plugin.open()
  action('gcr')
  equal(alice.current_branch(), 'alice-topic', 'Reopening Alice retains return point')
  ui.close()
end)

test('in-flight fetch remains bound after cwd changes and another UI session opens', function()
  local alice = git.session(a)
  local bob = git.session(b)
  assert(bob.switch_create('teammate-only'))
  vim.fn.writefile({ 'teammate change' }, b .. '/teammate.txt')
  assert(bob.stage('teammate.txt'))
  assert(bob.commit('Teammate commit'))
  assert(bob.push('origin', 'teammate-only'))
  assert(bob.switch('main'))
  local upload_pack = root .. '/upload-pack'
  local release = root .. '/release-fetch'
  vim.fn.writefile({ '#!/bin/sh', 'while [ ! -f "' .. release .. '" ]; do sleep 0.01; done', 'exec git-upload-pack "$@"' }, upload_pack)
  vim.fn.setfperm(upload_pack, 'rwx------')
  command(a, { 'config', 'remote.origin.uploadpack', upload_pack })
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a)
  plugin.open()
  action('f')
  ui.close()
  vim.api.nvim_set_current_dir(b)
  plugin.open()
  local before = ui_text()
  vim.fn.writefile({ 'release' }, release)
  assert(vim.wait(10000, function() return alice.has_remote_branch('origin', 'teammate-only') end), 'Alice fetch completes')
  -- Drain the scheduled completion so a stale redraw cannot hide behind the assertion.
  vim.wait(100, function() return false end)
  equal(ui_text(), before, 'Alice async completion does not redraw Bob UI')
  equal(bob.log(1)[1].message, 'Initial', 'Bob history unchanged')
  ui.close()
end)

test('sessions resolve subdirectories and linked worktrees independently', function()
  vim.fn.mkdir(a .. '/nested', 'p')
  local alice = git.session(a .. '/nested')
  equal(alice.worktree(), a, 'Subdirectory session resolves worktree root')
  local linked = root .. '/linked'
  command(a, { 'worktree', 'add', '-b', 'linked-topic', linked })
  local other = git.session(linked)
  vim.api.nvim_set_current_dir(b)
  vim.fn.writefile({ 'linked change' }, linked .. '/linked.txt')
  assert(other.stage('linked.txt'))
  assert(other.commit('Linked worktree commit'))
  equal(other.log(1)[1].message, 'Linked worktree commit', 'Linked worktree receives commit')
  equal(alice.log(1)[1].message, 'Initial', 'Original worktree branch unchanged')
end)

test('legacy calls and synchronous fallbacks retain compatible invocation context', function()
  local alice = git.session(a)
  vim.fn.writefile({ 'legacy change' }, a .. '/legacy.txt')
  vim.api.nvim_set_current_dir(a)
  assert(git.stage('legacy.txt'))
  assert(git.commit('Legacy commit'))
  local original_system = vim.system
  vim.system = nil
  vim.api.nvim_set_current_dir(b)
  local fetched
  alice.fetch_async('origin', function(ok) fetched = ok end)
  equal(fetched, true, 'Legacy synchronous async fallback fetches captured repository')
  equal(alice.log(1)[1].message, 'Legacy commit', 'Session synchronous reads stay captured')
  equal(git.log(1)[1].message, 'Initial', 'Legacy module calls retain invocation-time cwd semantics')
  vim.system = original_system
end)

test('external commands use the session process directory including synchronous fallback', function()
  local alice = git.session(a)
  local bin = root .. '/bin'
  vim.fn.mkdir(bin, 'p')
  -- Deliver the empty stderr EOF before stdout, as real job callbacks may do.
  vim.fn.writefile({ '#!/bin/sh', 'exec 2>&-', 'sleep 0.05', 'pwd' }, bin .. '/gh')
  vim.fn.setfperm(bin .. '/gh', 'rwx------')
  local original_path, original_system = vim.env.PATH, vim.system
  vim.env.PATH = bin .. ':' .. original_path
  vim.api.nvim_set_current_dir(b)
  local ok, output = alice.create_pull_request({ title = 'Local test' })
  assert(ok)
  equal(output, { a }, 'Synchronous external command runs in Alice')
  local done
  alice.create_pull_request_async({ title = 'Local test' }, function(success, lines)
    assert(success)
    equal(lines, { a }, 'Async external command runs in Alice')
    done = true
  end)
  assert(vim.wait(5000, function() return done end), 'External callback completes')
  vim.system = nil
  alice.create_github_repo_async({}, function(success, lines)
    assert(success)
    equal(lines, { a }, 'External fallback runs in Alice')
  end)
  vim.system, vim.env.PATH = original_system, original_path
  equal(vim.fn.getcwd(), b, 'Execution never changes Neovim cwd')
end)
test('legacy relative paths and dot actions retain invocation subdirectory scope', function()
  local alice = git.session(a)
  vim.fn.mkdir(a .. '/nested', 'p')
  vim.fn.writefile({ 'nested initial' }, a .. '/nested/file.txt')
  assert(alice.stage('nested/file.txt'))
  assert(alice.commit('Nested file'))
  vim.fn.writefile({ 'root change' }, a .. '/file.txt')
  vim.fn.writefile({ 'nested change' }, a .. '/nested/file.txt')
  vim.api.nvim_set_current_dir(a .. '/nested')
  assert(git.stage('file.txt'))
  equal(alice.diff({ '--cached', '--name-only' }), { 'nested/file.txt' }, 'Legacy filename resolves from subdirectory')
  vim.fn.writefile({ 'nested new file' }, a .. '/nested/new.txt')
  assert(git.stage('.'))
  equal(alice.diff({ '--cached', '--name-only' }), { 'nested/file.txt', 'nested/new.txt' }, 'Legacy dot stage excludes root changes')
  assert(alice.stage('file.txt'))
  assert(git.unstage('.'))
  equal(alice.diff({ '--cached', '--name-only' }), { 'file.txt' }, 'Legacy dot unstage leaves root index intact')
  assert(git.restore('.'))
  equal(vim.fn.readfile(a .. '/nested/file.txt'), { 'nested initial' }, 'Legacy dot restore restores nested tracked content')
  equal(vim.fn.readfile(a .. '/file.txt'), { 'root change' }, 'Legacy dot restore leaves root content intact')
  equal(git.session().worktree(), a, 'Explicit session still resolves worktree root')
end)
local ok, err = xpcall(function()
  for _, entry in ipairs(tests) do
    fixture()
    entry[2]()
    vim.api.nvim_set_current_dir(plugin_root)
    vim.fn.delete(root, 'rf')
    print('PASS ' .. entry[1])
  end
end, debug.traceback)
vim.api.nvim_set_current_dir(plugin_root)
vim.fn.delete(root, 'rf')
if not ok then print(err); vim.cmd('cquit 1') else vim.cmd('qa!') end
