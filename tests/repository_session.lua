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
test('publication snapshot distinguishes tracking history with a differently named destination', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic'))
  assert(alice.push('origin', 'refs/heads/topic:refs/heads/team-topic'))
  vim.fn.writefile({ 'local' }, a .. '/local.txt'); assert(alice.stage('local.txt')); assert(alice.commit('Local only'))
  local snapshot = alice.publication_snapshot()
  equal(snapshot.target.ref, 'refs/heads/team-topic', 'Uses selected push destination')
  equal(snapshot.tracking_ref, 'refs/remotes/origin/team-topic', 'Uses full tracking ref')
  equal(snapshot.commits[1].publication, 'local-only', 'New commit is local-only relative to tracking history')
  equal(snapshot.commits[2].publication, 'published', 'Initial commit is confirmed in tracking history')
end)
test('publication remains unknown when a target or tracking evidence is absent', function()
  local alice = git.session(a)
  command(a, { 'config', '--unset', 'branch.main.remote' })
  local snapshot = alice.publication_snapshot()
  equal(snapshot.state, 'unknown', 'Absent upstream is unknown')
  equal(snapshot.commits[1].publication, 'unknown', 'Absent upstream never confirms a commit')
  command(a, { 'config', 'branch.main.remote', 'origin' })
  command(a, { 'update-ref', '-d', 'refs/remotes/origin/main' })
  snapshot = alice.publication_snapshot()
  equal(snapshot.state, 'unknown', 'Missing tracking ref is unknown')
  assert(snapshot.reason:find('missing', 1, true), 'Missing evidence has a reason')
  command(a, { 'config', 'remote.origin.pushurl', b })
  command(a, { 'fetch', 'origin' })
  snapshot = alice.publication_snapshot()
  equal(snapshot.state, 'unknown', 'Fetch tracking cannot describe a different push endpoint')
end)
test('publication fails closed on incomplete ancestry or a failed graph inspection', function()
  local alice = git.session(a)
  local initial = alice.repository_state().head
  vim.fn.writefile({ initial }, a .. '/.git/shallow')
  equal(alice.publication_snapshot().state, 'unknown', 'Shallow history cannot authorize a rewrite')
  vim.fn.delete(a .. '/.git/shallow')
  local original = vim.fn.systemlist
  vim.fn.systemlist = function(cmd)
    if type(cmd) == 'table' and cmd[4] == 'rev-list' then error('graph inspection unavailable') end
    return original(cmd)
  end
  local snapshot = alice.publication_snapshot()
  vim.fn.systemlist = original
  equal(snapshot.state, 'unknown', 'Failed inspection remains unknown')
  equal(snapshot.commits[1].publication, 'unknown', 'Failed inspection never confirms a commit')
  assert(snapshot.reason:find('inspect', 1, true), 'Failure gives a diagnostic')
end)
test('publication follows custom tracking mappings and refuses excluded or shared evidence', function()
  local alice = git.session(a)
  command(a, { 'remote', 'rename', 'origin', 'team/upstream' })
  command(a, { 'config', 'remote.team/upstream.fetch', '+refs/heads/team-*:refs/remotes/custom/*' })
  assert(alice.switch_create('topic'))
  assert(alice.push('team/upstream', 'refs/heads/topic:refs/heads/team-topic'))
  assert(alice.fetch('team/upstream'))
  local snapshot = alice.publication_snapshot()
  equal(snapshot.tracking_ref, 'refs/remotes/custom/topic', 'Slash remote and custom mapping honored')
  equal(snapshot.state, 'published', 'Mapped history confirms publication')
  command(a, { 'config', '--add', 'remote.team/upstream.fetch', '^refs/heads/team-topic' })
  equal(alice.publication_snapshot().state, 'unknown', 'Excluded branch does not imply publication')
  command(a, { 'config', '--unset-all', 'remote.team/upstream.fetch' })
  command(a, { 'config', 'remote.team/upstream.fetch', '+refs/heads/team-*:refs/remotes/custom/*' })
  assert(alice.remote_add('fork', b))
  command(a, { 'config', 'remote.fork.fetch', '+refs/heads/*:refs/remotes/custom/*' })
  equal(alice.publication_snapshot().state, 'unknown', 'Another remote can overwrite shared tracking evidence')
end)
test('publication selects the fork destination independently from pull history', function()
  local alice = git.session(a)
  local fork = root .. '/fork.git'
  command(root, { 'init', '--bare', fork })
  assert(alice.remote_add('fork', fork))
  assert(alice.switch_create('topic'))
  assert(alice.push('origin', 'refs/heads/topic:refs/heads/team-topic'))
  command(a, { 'config', 'branch.topic.pushRemote', 'fork' })
  equal(alice.publication_snapshot().state, 'unknown', 'Pull history cannot confirm fork publication')
  local target = assert(alice.resolve_push_target({ inspect_remote = true })); target.confirmed = true
  assert(alice.push_target(target))
  equal(alice.publication_snapshot().state, 'published', 'Fork tracking confirms selected destination')
  equal(alice.publication_snapshot(assert(alice.resolve_pull_target())).state, 'published', 'Explicit pull target uses the shared classification')
end)
test('publication freshness records only observed target fetches and keeps cached history explicit', function()
  local alice, bob = git.session(a), git.session(b)
  equal(alice.publication_snapshot().freshness.state, 'unobserved', 'Pre-existing tracking has no plugin fetch evidence')
  assert(alice.remote_add('other', b)); assert(alice.fetch('other'))
  equal(alice.publication_snapshot().freshness.state, 'unobserved', 'Fetching another remote gives no target freshness')
  local completed
  alice.fetch_async('origin', function(ok) completed = ok end)
  assert(vim.wait(5000, function() return completed ~= nil end)); assert(completed)
  local snapshot = git.session(a).publication_snapshot()
  equal(snapshot.freshness.state, 'cached', 'Successful async target fetch is cached evidence')
  assert(snapshot.freshness.fetched_at, 'Fetch time is visible to callers')
  vim.fn.writefile({ 'teammate' }, b .. '/teammate.txt'); assert(bob.stage('teammate.txt')); assert(bob.commit('Teammate')); assert(bob.push('origin', 'main'))
  equal(alice.publication_snapshot().freshness.state, 'cached', 'Teammate advance cannot become live proof')
  command(a, { 'fetch', 'origin' })
  equal(alice.publication_snapshot().freshness.state, 'unobserved', 'External tracking change invalidates old evidence')
  assert(alice.fetch('origin'))
  local original = vim.fn.systemlist
  vim.fn.systemlist = function(cmd)
    if type(cmd) == 'table' and cmd[4] == 'fetch' then error('fetch unavailable') end
    return original(cmd)
  end
  equal(alice.fetch('origin'), false, 'Failed fetch remains a failure')
  vim.fn.systemlist = original
  snapshot = alice.publication_snapshot()
  equal(snapshot.freshness.state, 'failed', 'Latest fetch failure is explicit')
  assert(snapshot.freshness.fetched_at, 'Last successful target evidence remains available')
  equal(snapshot.state, 'published', 'Cached reachable history remains classification evidence')
end)
test('publication freshness does not assign a fetch time to a retained deleted target', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic'))
  assert(alice.push('origin', 'refs/heads/topic:refs/heads/topic'))
  assert(alice.fetch('origin'))
  equal(alice.publication_snapshot().freshness.state, 'cached', 'Fetched target is observed')
  command(b, { 'push', 'origin', '--delete', 'topic' })
  assert(alice.fetch('origin'))
  equal(alice.publication_snapshot().freshness.state, 'unobserved', 'Unpruned deleted ref was not freshly fetched')
  equal(alice.publication_snapshot().state, 'published', 'Retained tracking still describes cached publication evidence')
end)
test('publication HEAD classification is independent of display limit and rejects a stale selected target', function()
  local alice = git.session(a)
  local target = assert(alice.resolve_push_target())
  equal(alice.publication_snapshot(target, 0).state, 'published', 'HEAD classification does not depend on displayed commits')
  vim.fn.writefile({ 'later' }, a .. '/later.txt'); assert(alice.stage('later.txt')); assert(alice.commit('Later'))
  equal(alice.publication_snapshot(target).state, 'unknown', 'Stale explicit source does not authorize a rewrite')
  local current = assert(alice.resolve_push_target())
  command(a, { 'config', 'remote.origin.pushurl', b })
  equal(alice.publication_snapshot(current).state, 'unknown', 'Stale selected push endpoint is refused')
end)
test('publication cannot confirm history when HEAD inspection fails', function()
  local alice = git.session(a)
  vim.fn.writefile({ 'local' }, a .. '/local.txt'); assert(alice.stage('local.txt')); assert(alice.commit('Local only'))
  local original = vim.fn.systemlist
  vim.fn.systemlist = function(cmd)
    if type(cmd) == 'table' and cmd[4] == 'rev-parse' and cmd[5] == '--verify' and cmd[6] == 'HEAD' then error('HEAD inspection unavailable') end
    return original(cmd)
  end
  local snapshot = alice.publication_snapshot()
  vim.fn.systemlist = original
  equal(snapshot.state, 'unknown', 'Missing pinned source is unknown')
  equal(snapshot.commits[1].publication, 'unknown', 'Missing HEAD cannot render local commit as confirmed')
  equal(snapshot.commits[2].publication, 'unknown', 'Missing HEAD cannot render previous commit as confirmed')
  assert(snapshot.reason, 'Missing HEAD has a diagnostic')
end)
test('publication fails closed on ownership and target configuration query failures', function()
  local alice = git.session(a)
  assert(alice.remote_add('other', remote))
  command(a, { 'config', 'remote.other.fetch', '+refs/heads/*:refs/remotes/origin/*' })
  equal(alice.publication_snapshot().state, 'unknown', 'Overlapping owner is normally unknown')
  local original = vim.fn.systemlist
  local function inspect_with_failure(key, invalid_key)
    vim.fn.systemlist = function(cmd)
      if type(cmd) == 'table' and cmd[4] == 'config' and cmd[6] == key then
        if invalid_key then return original({ 'git', 'config', '--get', 'invalid' }) end
        error('configuration inspection unavailable')
      end
      return original(cmd)
    end
    local snapshot = alice.publication_snapshot()
    vim.fn.systemlist = original
    equal(snapshot.state, 'unknown', 'Failed ' .. key .. ' cannot confirm publication')
    equal(snapshot.commits[1].publication, 'unknown', 'Failed config query keeps commit neutral')
    assert(snapshot.reason, 'Failed config query has a diagnostic')
  end
  inspect_with_failure('remote.other.fetch', false)
  inspect_with_failure('remote.other.fetch', true)
  command(a, { 'config', '--unset-all', 'remote.other.fetch' })
  equal(alice.publication_snapshot().state, 'published', 'Genuinely absent mapping is distinguished from inspection failure')
  inspect_with_failure('branch.main.pushRemote', false)
  inspect_with_failure('remote.pushDefault', true)
  inspect_with_failure('push.default', false)
end)
test('publication distinguishes a missing shorthand source tag from failed tag inspection', function()
  local alice = git.session(a)
  command(a, { 'config', 'remote.origin.push', 'main:refs/heads/main' })
  command(a, { 'tag', 'main' })
  equal(alice.publication_snapshot().state, 'unknown', 'Branch/tag source collision is refused')
  local original = vim.fn.systemlist
  local function failed_tag_snapshot()
    vim.fn.systemlist = function(cmd)
      if type(cmd) == 'table' and cmd[4] == 'show-ref' and cmd[#cmd] == 'refs/tags/main' then error('tag inspection unavailable') end
      return original(cmd)
    end
    local snapshot = alice.publication_snapshot()
    vim.fn.systemlist = original
    equal(snapshot.state, 'unknown', 'Failed source tag inspection cannot confirm publication')
    equal(snapshot.commits[1].publication, 'unknown', 'Failed source tag inspection keeps neutral commits')
    assert(snapshot.reason, 'Failed source tag inspection has a diagnostic')
  end
  failed_tag_snapshot()
  command(a, { 'tag', '-d', 'main' })
  equal(alice.publication_snapshot().state, 'published', 'Verified absent tag permits unambiguous shorthand')
  failed_tag_snapshot()
  equal(alice.log(1)[1].message, 'Initial', 'Failed snapshot inspection leaves history intact')
end)
test('publication target inspection cannot inherit stale missing-remote exit status', function()
  local alice = git.session(a)
  local opts = { remote = 'origin', ref = 'refs/heads/first', inspect_remote = true }
  local target = assert(alice.resolve_push_target(opts))
  equal(target.remote_exists, false, 'Verified remote absence permits deliberate first publication')
  local original = vim.fn.systemlist
  vim.fn.systemlist = function(cmd)
    if type(cmd) == 'table' and cmd[4] == 'ls-remote' and cmd[5] == '--exit-code' then
      original(cmd) -- Real missing destination exits 2; the launch exception must not inherit it.
      error('remote inspection unavailable')
    end
    return original(cmd)
  end
  local selected, reason = alice.resolve_push_target(opts)
  vim.fn.systemlist = original
  equal(selected, nil, 'Launcher failure is not verified destination absence')
  assert(reason:find('inspect', 1, true), 'Remote inspection failure has a diagnostic')
end)
test('publication target selection refuses failed remote enumeration in first-publication simple policy', function()
  local alice = git.session(a)
  assert(alice.remote_add('fork', remote))
  command(a, { 'config', '--unset', 'branch.main.remote' })
  command(a, { 'config', '--unset', 'branch.main.merge' })
  command(a, { 'config', 'branch.main.pushRemote', 'fork' })
  command(a, { 'config', 'push.default', 'simple' })
  equal(assert(alice.resolve_push_target()).remote, 'fork', 'Verified triangular policy permits deliberate first publication')
  local original = vim.fn.systemlist
  vim.fn.systemlist = function(cmd)
    if type(cmd) == 'table' and cmd[4] == 'remote' and #cmd == 4 then error('remote enumeration unavailable') end
    return original(cmd)
  end
  local selected, reason = alice.resolve_push_target()
  vim.fn.systemlist = original
  equal(selected, nil, 'Failed enumeration cannot establish the selected push policy')
  assert(reason:find('inspect', 1, true), 'Failed enumeration has a diagnostic')
end)
test('a running mutation rejects overlap across sessions but permits an independent linked worktree', function()
  local alice, alias = git.session(a), git.session(a .. '/.')
  local linked = root .. '/linked'
  command(a, { 'worktree', 'add', '-b', 'other', linked })
  local hooks = remote .. '/hooks'
  vim.fn.writefile({ '#!/bin/sh', 'touch "' .. root .. '/entered"', 'while test ! -e "' .. root .. '/release"; do sleep 0.01; done' }, hooks .. '/pre-receive')
  vim.fn.setfperm(hooks .. '/pre-receive', 'rwx------')
  vim.fn.writefile({ 'publication' }, a .. '/new.txt'); assert(alice.stage('new.txt')); assert(alice.commit('Publication'))
  local result
  command(a, { 'branch', 'candidate' })
  alice.push_async('origin', 'main', function(ok, output, outcome) result = { ok, outcome } end)
  assert(vim.wait(5000, function() return vim.fn.filereadable(root .. '/entered') == 1 end))
  local ok, output, outcome = alias.switch_create('overlap')
  equal(ok, false, 'Overlapping branch mutation refused')
  equal(outcome.status, 'rejected', 'Refusal has structured status')
  equal(outcome.state.running, 'push_async', 'Refusal identifies running mutation')
  vim.api.nvim_set_current_dir(a)
  equal(git.delete_branch('candidate'), false, 'Legacy alias cannot bypass same-worktree reservation')
  equal(alias.resolve_conflict('file.txt', { 'must not write' }), false, 'Conflict writer refuses before touching file')
  equal(vim.fn.readfile(a .. '/file.txt'), { 'initial' }, 'Busy conflict action leaves file intact')
  local ai = require('mylazygit.ai')
  local original_system = vim.fn.system
  vim.fn.system = function(cmd) if type(cmd) == 'table' and cmd[1] == 'curl' then error('Busy AI must not call network') end; return original_system(cmd) end
  ai.generate_commit_message(alias)
  vim.fn.system = original_system
  equal(alias.log(1)[1].message, 'Publication', 'Busy AI cannot change history')
  assert(git.session(linked).switch_create('independent'), 'Linked worktree can mutate independently')
  vim.fn.writefile({}, root .. '/release')
  assert(vim.wait(5000, function() return result ~= nil end))
  equal(result[1], true, 'Original publication succeeds')
  equal(result[2].status, 'success', 'Completion has structured status')
  assert(alias.switch_create('after'), 'Reservation released after completion')
end)
test('failed merge exposes current conflicts and recovery while rejecting unrelated mutations', function()
  local alice = git.session(a)
  assert(alice.switch_create('feature'))
  vim.fn.writefile({ 'feature' }, a .. '/file.txt'); assert(alice.stage('file.txt')); assert(alice.commit('Feature'))
  assert(alice.switch('main'))
  vim.fn.writefile({ 'main' }, a .. '/file.txt'); assert(alice.stage('file.txt')); assert(alice.commit('Main'))
  local ok, output, result = alice.merge('feature')
  equal(ok, false, 'Conflicting merge fails')
  equal(result.state.operation, 'merge', 'Failed operation reports merge state')
  equal(result.changed, true, 'Failed operation records changed repository state')
  equal(result.recovery, { 'resolve conflicts and stage', 'merge --continue', 'merge --abort' }, 'Actual merge recovery available')
  equal(alice.switch_create('unrelated'), false, 'Unfinished merge rejects branch changes')
  assert(alice.resolve_conflict('file.txt', { 'resolved' }))
  local completed
  alice.recover('merge', 'continue', function(success, _, outcome) completed = { success, outcome } end)
  assert(vim.wait(5000, function() return completed end))
  equal(completed[1], true, 'Necessary recovery allowed')
  equal(completed[2].state.operation, nil, 'Completion clears interrupted operation')
  assert(alice.switch_create('usable'), 'Repository usable after recovery')
end)
test('dependent mutations reject stale HEAD or staged changes before applying their work', function()
  local alice = git.session(a)
  vim.fn.writefile({ 'pending' }, a .. '/pending.txt'); assert(alice.stage('pending.txt'))
  local expected = alice.repository_state()
  assert(alice.commit('External commit'))
  vim.fn.writefile({ 'later' }, a .. '/later.txt'); assert(alice.stage('later.txt'))
  local ok, _, result = alice.mutate('dependent commit', function() return alice.commit('Stale commit') end, { expected = expected })
  equal(ok, false, 'Stale dependent commit refused')
  equal(result.status, 'rejected', 'Stale intent reported as rejection')
  equal(alice.log(1)[1].message, 'External commit', 'New history not committed by old intent')
  equal(alice.diff({ '--cached', '--name-only' }), { 'later.txt' }, 'New staged work remains intact')
end)
test('asynchronous launch and callback exceptions release reservations and cancellation reports current state', function()
  local alice = git.session(a)
  local original = vim.system
  vim.system = function() error('launcher unavailable') end
  local result
  alice.fetch_async('origin', function(ok, _, outcome) result = { ok, outcome } end)
  vim.system = original
  equal(result[1], false, 'Launcher failure reported')
  equal(result[2].status, 'failed', 'Launcher failure has structured outcome')
  assert(alice.switch_create('after-launch'), 'Launch failure releases reservation')
  local cancelled = select(3, alice.cancel_mutation('publication'))
  equal(cancelled.status, 'cancelled', 'Cancellation has structured outcome')
  equal(cancelled.changed, false, 'Cancellation changes no repository state')
  local complete = false
  alice.mutate_async('dependent chain', function(done)
    alice.fetch_async('origin', function() complete = true; error('dependent callback failed') end)
  end, function() end)
  assert(vim.wait(5000, function() return complete end))
  assert(alice.switch_create('after-callback'), 'Callback failure releases outer reservation')
end)
test('synchronous process waits reject reentrant mutations on the same session', function()
  local alice = git.session(a)
  local bin = root .. '/bin'; vim.fn.mkdir(bin, 'p')
  vim.fn.writefile({ '#!/bin/sh', 'touch "' .. root .. '/entered"', 'while test ! -e "' .. root .. '/release"; do sleep 0.01; done' }, bin .. '/gh')
  vim.fn.setfperm(bin .. '/gh', 'rwx------')
  local old_path = vim.env.PATH; vim.env.PATH = bin .. ':' .. old_path
  local original_wait, overlap = vim.fn.jobwait
  vim.fn.jobwait = function(jobs, ...)
    assert(vim.wait(5000, function() return vim.fn.filereadable(root .. '/entered') == 1 end), 'External job entered deterministic barrier')
    overlap = alice.switch_create('reentrant')
    vim.fn.writefile({}, root .. '/release')
    return original_wait(jobs, ...)
  end
  local ok = alice.create_pull_request({ title = 'Local only', head = 'main' })
  vim.env.PATH, vim.fn.jobwait = old_path, original_wait
  equal(ok, true, 'Held external process completes')
  equal(overlap, false, 'Event loop callback cannot borrow synchronous operation ownership')
  equal(alice.current_branch(), 'main', 'Reentrant branch change never happens')
end)
test('confirmed synchronization refuses a changed source commit before publishing', function()
  local alice = git.session(a)
  local target = assert(alice.resolve_push_target())
  local remote_before = git.session(remote).log(1)[1].hash
  vim.fn.writefile({ 'later' }, a .. '/later.txt'); assert(alice.stage('later.txt')); assert(alice.commit('Later commit'))
  local ok, _, result = alice.push_target(target)
  equal(ok, false, 'Selected publication cannot silently include a later commit')
  equal(result.target.ref, 'refs/heads/main', 'Refusal retains concrete destination')
  equal(git.session(remote).log(1)[1].hash, remote_before, 'Remote commit unchanged')
end)
test('optional nil async arguments preserve callbacks and release their reservation', function()
  local alice = git.session(a)
  local completed
  alice.fetch_async(nil, function(ok, output, result) completed = { ok, result } end)
  assert(vim.wait(1000, function() return completed end), 'Nil remote callback completes')
  equal(completed[1], true, 'Nil remote retains origin default')
  equal(completed[2].state.running, nil, 'Completion releases reservation')
  assert(alice.switch_create('after-nil'), 'Repository usable after default fetch')
end)
test('pull and ordinary push follow a differently named upstream without publishing the local name', function()
  local alice, bob = git.session(a), git.session(b)
  command(a, { 'push', 'origin', 'main:team-topic' })
  command(a, { 'switch', '-c', 'topic', '--track', 'origin/team-topic' })
  command(b, { 'fetch', 'origin' })
  command(b, { 'switch', '-c', 'team-topic', '--track', 'origin/team-topic' })
  vim.fn.writefile({ 'upstream change' }, b .. '/upstream.txt')
  assert(bob.stage('upstream.txt')); assert(bob.commit('Upstream update'))
  assert(bob.push('origin', 'team-topic'))
  local target = assert(alice.resolve_pull_target())
  equal(target.remote, 'origin', 'Pull remote follows upstream')
  equal(target.ref, 'refs/heads/team-topic', 'Pull names the source remote ref')
  assert(alice.pull_target(target, true))
  equal(alice.log(1)[1].message, 'Upstream update', 'Pulled intended branch')
  vim.fn.writefile({ 'local change' }, a .. '/local.txt')
  assert(alice.stage('local.txt')); assert(alice.commit('Local update'))
  target = assert(alice.resolve_push_target())
  equal(target.ref, 'refs/heads/team-topic', 'Push follows selected tracking destination')
  assert(alice.push_target(target))
  equal(alice.remote_branch_exists('origin', 'topic'), false, 'No same-named remote topic created')
  assert(bob.pull('origin', 'team-topic'))
  equal(bob.log(1)[1].message, 'Local update', 'Published intended branch')
end)
test('implicit triangular push selects the local name and inspects the effective push URL', function()
  local alice = git.session(a)
  command(a, { 'push', 'origin', 'main:team-topic' })
  command(a, { 'switch', '-c', 'topic', '--track', 'origin/team-topic' })
  local fork = root .. '/fork.git'
  command(root, { 'init', '--bare', '--initial-branch=main', fork })
  assert(alice.remote_add('fork', remote))
  command(a, { 'config', 'remote.fork.pushurl', fork })
  command(a, { 'config', 'remote.pushDefault', 'fork' })
  local target = assert(alice.resolve_push_target({ inspect_remote = true }))
  equal(target.ref, 'refs/heads/topic', 'Fork uses local name with implicit triangular policy')
  equal(target.requires_confirmation, true, 'Empty push URL requires first publication review')
  local ok = alice.push_target(target)
  equal(ok, false, 'Unconfirmed first publication refused at session seam')
  target.confirmed = true; assert(alice.push_target(target))
  equal(git.session(fork).has_local_branch('topic'), true, 'Published at push URL')
  equal(alice.remote_branch_exists('origin', 'topic'), false, 'Fetch URL unchanged')
  equal(alice.branch_upstream('topic'), { remote = 'origin', branch = 'team-topic' }, 'Pull target retains different name')
end)
test('explicit current-branch push refspecs honor shorthand and suppress automatic tag publication', function()
  local alice = git.session(a)
  command(a, { 'config', 'push.default', 'matching' })
  command(a, { 'config', 'remote.origin.push', 'HEAD' })
  command(a, { 'config', 'push.followTags', 'true' })
  command(a, { 'tag', '-a', 'release', '-m', 'Release' })
  local target, err = alice.resolve_push_target()
  assert(target, err)
  equal(target.ref, 'refs/heads/main', 'HEAD shorthand maps to current branch')
  assert(alice.push_target(target))
  equal(command(remote, { 'tag', '--list' }), '', 'Ordinary branch publication does not add configured follow tags')
  command(a, { 'config', 'remote.origin.push', 'refs/heads/*:refs/heads/team-*' })
  target = assert(alice.resolve_push_target({ inspect_remote = true }))
  equal(target.ref, 'refs/heads/team-main', 'Single wildcard maps current source branch')
  equal(target.requires_confirmation, true, 'New mapped destination requires review')
  target.confirmed = true; assert(alice.push_target(target))
  equal(alice.remote_branch_exists('origin', 'team-main'), true, 'Published explicit configured destination')
end)
test('ordinary push entrypoints refuse forced refspecs and leave divergent remote history intact', function()
  local alice, bob = git.session(a), git.session(b)
  vim.fn.writefile({ 'bob history' }, b .. '/bob.txt')
  assert(bob.stage('bob.txt')); assert(bob.commit('Bob remote history')); assert(bob.push('origin', 'main'))
  vim.fn.writefile({ 'alice history' }, a .. '/alice.txt')
  assert(alice.stage('alice.txt')); assert(alice.commit('Alice divergent history'))
  local target = assert(alice.resolve_push_target())
  equal(alice.push_target(target), false, 'Resolved ordinary publication rejects remote divergence')
  equal(alice.push('origin', '+refs/heads/main:refs/heads/main'), false, 'Explicit ordinary publication refuses forcing')
  local callbacks = 0
  for _, method in ipairs({ alice.push_async, alice.push_set_upstream_async }) do
    method('origin', '+refs/heads/main:refs/heads/main', function(ok)
      equal(ok, false, 'Async ordinary publication refuses forcing'); callbacks = callbacks + 1
    end)
  end
  assert(vim.wait(5000, function() return callbacks == 2 end), 'Both async refusals complete')
  equal(git.session(remote).log(1)[1].message, 'Bob remote history', 'Teammate remote commit retained')
end)
test('ambiguous push policies and detached HEAD refuse synchronization with actionable results', function()
  local alice = git.session(a)
  local cases = {
    { 'push.default', { 'matching' } },
    { 'push.default', { 'nothing' } },
    { 'branch.main.merge', { 'refs/heads/main', 'refs/heads/other' } },
    { 'remote.origin.push', { 'refs/heads/main:refs/heads/one', 'refs/heads/main:refs/heads/two' } },
    { 'remote.origin.push', { '+refs/heads/main:refs/heads/main' } },
    { 'remote.origin.mirror', { 'true' } },
    { 'remote.origin.pushurl', { remote, root .. '/other.git' } },
  }
  for _, case in ipairs(cases) do
    command(a, { 'config', '--replace-all', case[1], case[2][1] })
    for index = 2, #case[2] do command(a, { 'config', '--add', case[1], case[2][index] }) end
    local target, reason = alice.resolve_push_target()
    equal(target, nil, 'Unsafe mapping has no destination: ' .. case[1])
    assert(reason and #reason > 0, 'Refusal explains configuration to repair')
    command(a, { 'config', '--unset-all', case[1] })
    if case[1] == 'branch.main.merge' then command(a, { 'config', case[1], 'refs/heads/main' }) end
  end
  command(a, { 'config', 'push.default', 'simple' })
  assert(alice.switch_create('topic'))
  command(a, { 'config', 'branch.topic.remote', 'origin' })
  command(a, { 'config', 'branch.topic.merge', 'refs/heads/main' })
  local target, reason = alice.resolve_push_target()
  equal(target, nil, 'Explicit simple policy refuses differently named upstream')
  assert(reason:find('simple', 1, true), 'Policy refusal explains simple')
  command(a, { 'config', '--unset', 'push.default' })
  local selected = assert(alice.resolve_push_target())
  assert(alice.checkout_detached('HEAD'))
  for _, resolve in ipairs({ alice.resolve_pull_target, alice.resolve_push_target }) do
    target, reason = resolve()
    equal(target, nil, 'Detached HEAD has no sync destination')
    assert(reason:find('detached HEAD', 1, true), 'Detached refusal is actionable')
  end
  equal(alice.push_target(selected), false, 'Delayed selection cannot publish after branch change')
  equal(git.session(remote).log(1)[1].message, 'Initial', 'Refusals preserve remote history')
end)
test('pull uses full source refs for slash remote names and custom fetch mappings', function()
  local alice, bob = git.session(a), git.session(b)
  command(a, { 'push', 'origin', 'main:team-topic' })
  assert(alice.remote_add('team/upstream', remote))
  command(a, { 'config', 'remote.team/upstream.fetch', '+refs/heads/team-*:refs/remotes/custom/*' })
  assert(alice.fetch('team/upstream'))
  assert(alice.switch_create('topic'))
  command(a, { 'config', 'branch.topic.remote', 'team/upstream' })
  command(a, { 'config', 'branch.topic.merge', 'refs/heads/team-topic' })
  command(b, { 'fetch', 'origin' })
  command(b, { 'switch', '-c', 'team-topic', '--track', 'origin/team-topic' })
  vim.fn.writefile({ 'mapped upstream change' }, b .. '/mapped.txt')
  assert(bob.stage('mapped.txt')); assert(bob.commit('Mapped upstream update')); assert(bob.push('origin', 'team-topic'))
  local target = assert(alice.resolve_pull_target())
  equal(target.remote, 'team/upstream', 'Remote is never split at its slash')
  equal(target.ref, 'refs/heads/team-topic', 'Source ref is independent of tracking namespace')
  local done
  alice.pull_target_async(target, true, function(ok, output)
    assert(ok, table.concat(output, '\n')); done = true
  end)
  assert(vim.wait(5000, function() return done end), 'Async mapped pull completes')
  equal(alice.log(1)[1].message, 'Mapped upstream update', 'Fetched and rebased actual source branch')
  command(a, { 'config', 'remote.pushDefault', 'origin' })
  command(a, { 'config', 'branch.topic.pushRemote', 'team/upstream' })
  target = assert(alice.resolve_push_target())
  equal(target.remote, 'team/upstream', 'Branch pushRemote takes priority over repository push default')
  equal(target.ref, 'refs/heads/team-topic', 'Selected upstream destination remains full source branch')
end)
test('repository scalar push configuration overrides global values using Git precedence', function()
  local alice = git.session(a)
  local original_global = vim.env.GIT_CONFIG_GLOBAL
  local global = root .. '/global.gitconfig'
  vim.fn.writefile({ '[push]', ' default = matching', '[remote]', ' pushDefault = missing',
    '[branch "main"]', ' pushRemote = missing', '[remote "origin"]', ' mirror = true' }, global)
  vim.env.GIT_CONFIG_GLOBAL = global
  command(a, { 'config', 'push.default', 'current' })
  command(a, { 'config', 'remote.pushDefault', 'origin' })
  command(a, { 'config', 'branch.main.pushRemote', 'origin' })
  command(a, { 'config', 'remote.origin.mirror', 'false' })
  local target, err = alice.resolve_push_target()
  assert(target, err)
  equal(target.remote, 'origin', 'Local scalar destination overrides global configuration')
  equal(target.ref, 'refs/heads/main', 'Local push policy overrides global matching')
  assert(alice.push_target(target))
  vim.env.GIT_CONFIG_GLOBAL = original_global
end)
test('simple policy allows confirmed triangular first publication while refusing unconfigured central upstream', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic'))
  command(a, { 'config', 'push.default', 'simple' })
  command(a, { 'config', 'remote.pushDefault', 'origin' })
  equal(alice.resolve_push_target(), nil, 'Central simple push still requires upstream')
  local fork = root .. '/fork.git'
  command(root, { 'init', '--bare', '--initial-branch=main', fork })
  assert(alice.remote_add('fork', fork))
  command(a, { 'config', 'remote.pushDefault', 'fork' })
  local target, err = alice.resolve_push_target({ inspect_remote = true })
  assert(target, err)
  equal(target.ref, 'refs/heads/topic', 'Triangular simple publishes local branch name')
  equal(target.requires_confirmation, true, 'Triangular first publication requires review')
  equal(alice.push_target(target), false, 'Unconfirmed first publication changes no refs')
  target.confirmed = true; assert(alice.push_target(target))
  equal(git.session(fork).has_local_branch('topic'), true, 'Accepted first publication creates fork branch')
  equal(alice.remote_branch_exists('origin', 'topic'), false, 'Central remote remains unchanged')
end)
test('configured branch destination shorthand publishes its full branch and refuses tag collisions', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic'))
  command(a, { 'config', 'branch.topic.pushRemote', 'origin' })
  command(a, { 'config', 'remote.origin.push', 'topic:team-topic' })
  local target, err = alice.resolve_push_target({ inspect_remote = true })
  assert(target, err)
  equal(target.ref, 'refs/heads/team-topic', 'Unqualified branch destination expands to heads')
  target.confirmed = true; assert(alice.push_target(target))
  equal(alice.remote_branch_exists('origin', 'team-topic'), true, 'Published intended branch shorthand')
  command(a, { 'tag', 'team-topic' })
  assert(alice.push('origin', 'refs/tags/team-topic:refs/tags/team-topic'))
  target, err = alice.resolve_push_target()
  equal(target, nil, 'Shorthand refuses remote branch/tag destination collision')
  assert(err:find('ambiguous', 1, true), 'Collision explains ambiguous destination')
  command(a, { 'config', 'remote.origin.push', 'refs/heads/topic:refs/heads/team-topic' })
  target = assert(alice.resolve_push_target())
  assert(alice.push_target(target))
  command(a, { 'config', 'remote.origin.push', 'topic:tag-only' })
  assert(alice.push('origin', 'refs/tags/team-topic:refs/tags/tag-only'))
  target, err = alice.resolve_push_target()
  equal(target, nil, 'Existing tag-only shorthand cannot be treated as a branch')
  assert(err:find('branch', 1, true), 'Tag destination refusal explains branch scope')
end)
test('all ordinary push interfaces normalize mirror booleans consistently and refuse invalid policy', function()
  local alice = git.session(a)
  for _, value in ipairs({ 'FALSE', 'OFF', '0' }) do
    command(a, { 'config', 'remote.origin.mirror', value })
    local target, err = alice.resolve_push_target()
    assert(target, err)
    assert(alice.push_target(target))
    assert(alice.push('origin', 'main'))
  end
  for _, value in ipairs({ 'TRUE', 'not-a-boolean' }) do
    command(a, { 'config', 'remote.origin.mirror', value })
    local target, reason = alice.resolve_push_target()
    equal(target, nil, 'Unsafe mirror policy has no resolved target')
    local ok, output = alice.push('origin', 'main')
    equal(ok, false, 'Legacy ordinary push has the same mirror refusal')
    equal(output[1], reason, 'Mirror policy reports the same actionable result at both interfaces')
  end
end)
test('single-token source shorthand refuses colliding local branch and tag without changing remote refs', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic'))
  command(a, { 'config', 'branch.topic.pushRemote', 'origin' })
  command(a, { 'config', 'remote.origin.push', 'topic' })
  command(a, { 'tag', 'topic' })
  local target, err = alice.resolve_push_target({ inspect_remote = true })
  equal(target, nil, 'Single-token branch/tag source collision refuses publication')
  assert(err:find('ambiguous', 1, true), 'Refusal explains source ambiguity')
  equal(alice.remote_branch_exists('origin', 'topic'), false, 'No remote topic created')
  equal(git.session(remote).log(1)[1].message, 'Initial', 'Existing remote history remains')
end)
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
test('UI publication colors and descriptions use the snapshot and keep freshness visible after resizing', function()
  local alice = git.session(a)
  vim.fn.writefile({ 'local' }, a .. '/local.txt'); assert(alice.stage('local.txt')); assert(alice.commit('Local only'))
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a); plugin.open()
  local function groups()
    local result = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == 'mylazygit-commits' then
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().mylazygit, 0, -1, { details = true })) do result[mark[2] + 1] = mark[4].hl_group end
      end
    end
    return result
  end
  equal(groups()[1], 'MyLazyGitUnpushed', 'Local-only commit uses local color')
  equal(groups()[2], 'MyLazyGitPushed', 'Cached published commit uses published color')
  assert(ui_text():find('[local-only]', 1, true), 'Local-only description visible')
  assert(ui_text():find('Fetch: unobserved', 1, true), 'Unknown fetch freshness visible')
  assert(ui_text():find('live remote unverified', 1, true), 'Cached evidence is not live proof')
  assert(alice.fetch('origin')); plugin.refresh()
  assert(ui_text():find('Fetch: cached ', 1, true), 'Successful target fetch displays its time')
  command(a, { 'config', '--unset', 'branch.main.remote' }); plugin.refresh()
  equal(groups()[1], 'MyLazyGitUnknown', 'No upstream uses unknown color')
  equal(groups()[2], 'MyLazyGitUnknown', 'No upstream cannot mark prior commits published')
  assert(ui_text():find('[unknown]', 1, true), 'Unknown publication description visible')
  ui.focus('commits'); action('gct')
  for _, resize in ipairs({ false, true }) do
    local headers = 0
    if resize then vim.api.nvim_exec_autocmds('VimResized', {}) end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      if (lines[1] or ''):find('Branch:', 1, true) or (lines[1] or ''):find('Detached HEAD', 1, true) then
        headers = headers + 1
        local count = #lines
        while count > 0 and lines[count] == '' do count = count - 1 end
        assert(vim.api.nvim_win_get_height(win) >= count, 'All header descriptions fit at creation and resize')
      end
    end
    equal(headers, 1, 'Header geometry was inspected')
  end
  ui.close()
end)
test('UI reports a held publication and rejects a second mutation until completion', function()
  local alice = git.session(a)
  vim.fn.writefile({ 'publish' }, a .. '/publish.txt'); assert(alice.stage('publish.txt')); assert(alice.commit('Publish'))
  vim.fn.writefile({ '#!/bin/sh', 'touch "' .. root .. '/entered"', 'while test ! -e "' .. root .. '/release"; do sleep 0.01; done' }, remote .. '/hooks/pre-receive')
  vim.fn.setfperm(remote .. '/hooks/pre-receive', 'rwx------')
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a); plugin.open(); action('P')
  assert(vim.wait(5000, function() return vim.fn.filereadable(root .. '/entered') == 1 and ui_text():find('Running: push_target_async', 1, true) end), 'Visible header reports publication still running')
  vim.fn.writefile({ 'pending' }, a .. '/pending.txt'); action('gsa')
  equal(alice.diff({ '--cached', '--name-only' }), {}, 'UI stage is rejected during publication')
  vim.fn.writefile({}, root .. '/release')
  assert(vim.wait(5000, function() return alice.repository_state().running == nil and ui_text():find('Repository: ready', 1, true) end), 'Completion refresh shows ready')
  ui.close()
end)
test('apply rebase recovery works through synchronous fallback without leaking editor environment', function()
  local alice = git.session(a)
  assert(alice.switch_create('feature'))
  vim.fn.writefile({ 'feature' }, a .. '/file.txt'); assert(alice.stage('file.txt')); assert(alice.commit('Feature'))
  assert(alice.switch('main'))
  vim.fn.writefile({ 'main' }, a .. '/file.txt'); assert(alice.stage('file.txt')); assert(alice.commit('Main'))
  assert(alice.switch('feature'))
  local result = vim.system({ 'git', '-C', a, 'rebase', '--apply', 'main' }, { text = true }):wait()
  assert(result.code ~= 0, 'Real apply rebase conflicts')
  equal(alice.repository_state().operation, 'rebase', 'Apply directory detected')
  local original_system, original_editor = vim.system, vim.env.GIT_EDITOR
  vim.system = nil; vim.env.GIT_EDITOR = 'existing-editor'
  local completed
  alice.recover('rebase', 'abort', function(ok, _, outcome) completed = { ok, outcome } end)
  equal(completed[1], true, 'Abort allowed through old Neovim fallback')
  equal(completed[2].state.operation, nil, 'Abort clears apply rebase')
  equal(vim.env.GIT_EDITOR, 'existing-editor', 'Recovery restores editor environment')
  vim.system, vim.env.GIT_EDITOR = original_system, original_editor
end)
test('fork publication UI displays separate full targets and confirms the destination while preserving pull upstream', function()
  local alice = git.session(a)
  local fork = root .. '/fork.git'
  command(root, { 'init', '--bare', '--initial-branch=main', fork })
  assert(alice.remote_add('my/fork', fork))
  command(a, { 'config', 'branch.main.pushRemote', 'my/fork' })
  command(a, { 'config', 'push.default', 'current' })
  vim.fn.writefile({ 'fork change' }, a .. '/fork.txt')
  assert(alice.stage('fork.txt')); assert(alice.commit('Fork publication'))
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  plugin.setup(); vim.api.nvim_set_current_dir(a); plugin.open()
  assert(ui_text():find('Pull: origin refs/heads/main', 1, true), 'Pull destination displayed separately')
  assert(ui_text():find('Push: my/fork refs/heads/main', 1, true), 'Push destination displayed separately')
  -- Header labels must be above every child pane, not obscured by their windows.
  local child_top = math.huge
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
    if ft == 'mylazygit-worktree' then child_top = cfg.row end
  end
  assert(child_top >= 5, 'Target header has reserved visible rows')
  local original_confirm, accepted, prompts = vim.fn.confirm, false, 0
  vim.fn.confirm = function(message, _, default)
    prompts = prompts + 1
    equal(message, 'Publish main to remote my/fork, branch refs/heads/main?', 'Full first publication destination')
    equal(default, 2, 'Publication defaults to cancellation')
    return accepted and 1 or 2
  end
  action('P')
  equal(alice.remote_branch_exists('my/fork', 'main'), false, 'Cancel leaves fork untouched')
  accepted = true; action('P')
  assert(vim.wait(5000, function() return alice.remote_branch_exists('my/fork', 'main') end), 'Confirmed fork publication completes')
  equal(alice.branch_upstream('main'), { remote = 'origin', branch = 'main' }, 'Pull upstream preserved')
  equal(prompts, 2, 'Both attempts reviewed full destination')
  vim.fn.confirm = original_confirm; ui.close()
end)
test('explicit push selection supports first publication, cancellation and stale branch refusal', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic'))
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a); plugin.open()
  local original_select, original_input, original_confirm = vim.ui.select, vim.ui.input, vim.fn.confirm
  local stage, prompts, pending = 'picker', 0
  vim.ui.select = function(items, opts, submit)
    equal(opts.prompt, 'Choose explicit push remote', 'Override identifies selection')
    assert(vim.tbl_contains(items, 'origin'), 'Configured remote offered')
    if stage == 'picker' then submit(nil) else submit('origin') end
  end
  vim.ui.input = function(_, submit)
    if stage == 'input' then submit(nil)
    elseif stage == 'stale' then pending = submit
    else submit('team/topic') end
  end
  vim.fn.confirm = function(message, _, default)
    prompts = prompts + 1
    equal(message, 'Publish topic to remote origin, branch refs/heads/team/topic?', 'Override reviews full destination')
    equal(default, 2, 'Override defaults to cancellation')
    return stage == 'confirmed' and 1 or 2
  end
  action('P')
  assert(notifications[#notifications]:find('gPp', 1, true), 'Missing mapping gives actionable selection')
  action('gPp'); stage = 'input'; action('gPp')
  equal(prompts, 0, 'Cancelled selections have no publication confirmation')
  stage = 'confirm'; action('gPp')
  equal(alice.remote_branch_exists('origin', 'team/topic'), false, 'Confirmation cancellation changes no refs')
  stage = 'stale'; action('gPp'); assert(pending); assert(alice.switch('main')); pending('team/topic')
  equal(prompts, 1, 'Changed branch is refused before confirmation')
  assert(alice.switch('topic')); stage = 'confirmed'; action('gPp')
  assert(vim.wait(5000, function() return alice.remote_branch_exists('origin', 'team/topic') end), 'Accepted first publication completes')
  equal(alice.branch_upstream('topic'), { remote = 'origin', branch = 'team/topic' }, 'First publication deliberately configures upstream')
  equal(alice.remote_branch_exists('origin', 'topic'), false, 'Override does not publish fallback name')
  vim.ui.select, vim.ui.input, vim.fn.confirm = original_select, original_input, original_confirm; ui.close()
end)
test('stage commit pull workflow stops before publication when real upstream rebase conflicts', function()
  local alice, bob = git.session(a), git.session(b)
  vim.fn.writefile({ 'bob side' }, b .. '/file.txt')
  assert(bob.stage('file.txt')); assert(bob.commit('Bob upstream change')); assert(bob.push('origin', 'main'))
  vim.fn.writefile({ 'alice side' }, a .. '/file.txt')
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a); plugin.open()
  local original_callback, original_confirm, submit = vim.fn.prompt_setcallback, vim.fn.confirm
  vim.fn.prompt_setcallback = function(_, callback) submit = callback end
  vim.fn.confirm = function() error('Failed pull must stop before publication choice') end
  action('gsC'); assert(submit, 'Commit prompt opened'); submit('Alice conflicting change')
  assert(not vim.tbl_isempty(alice.diff({ '--name-only', '--diff-filter=U' })), 'Real upstream conflict remains for resolution')
  equal(git.session(remote).log(1)[1].message, 'Bob upstream change', 'Failed workflow preserves remote history')
  assert(ui_text():find('Recovery: rebase', 1, true), 'Partial failure refresh displays real recovery state')
  vim.fn.prompt_setcallback, vim.fn.confirm = original_callback, original_confirm; ui.close()
end)

test('commit pull push confirmation rejects reentrant UI mutations and releases on cancellation', function()
  local alice = git.session(a)
  vim.fn.writefile({ 'chain' }, a .. '/chain.txt')
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a); plugin.open()
  local original_callback, original_confirm, submit = vim.fn.prompt_setcallback, vim.fn.confirm
  vim.fn.prompt_setcallback = function(_, cb) submit = cb end
  vim.fn.confirm = function()
    vim.fn.writefile({ 'independent action' }, a .. '/interleaved.txt')
    action('gsa')
    return 2
  end
  action('gsC'); assert(submit); submit('Chain commit')
  equal(alice.diff({ '--cached', '--name-only' }), {}, 'Confirmation cannot lend ownership to another UI action')
  equal(alice.repository_state().running, nil, 'Cancellation releases compound reservation')
  equal(alice.log(1)[1].message, 'Chain commit', 'Completed commit remains after push cancellation')
  vim.fn.prompt_setcallback, vim.fn.confirm = original_callback, original_confirm
  ui.close()
end)
test('PR first publication uses its resolved differently named destination and cancellation preserves refs', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic'))
  command(a, { 'config', 'branch.topic.pushRemote', 'origin' })
  command(a, { 'config', 'remote.origin.push', 'refs/heads/topic:refs/heads/review-topic' })
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a); plugin.open()
  local original_confirm, accepted = vim.fn.confirm, false
  vim.fn.confirm = function(message, _, default)
    equal(message, 'Publish topic to remote origin, branch refs/heads/review-topic?', 'PR pre-push reviews resolved destination')
    equal(default, 2, 'PR first publication defaults to cancellation')
    return accepted and 1 or 2
  end
  action('gpr')
  equal(alice.remote_branch_exists('origin', 'review-topic'), false, 'Cancelled PR publication preserves remote')
  accepted = true; action('gpr')
  assert(vim.wait(5000, function() return ui_text():find('Title: topic', 1, true) end), 'PR form follows successful publication')
  equal(alice.remote_branch_exists('origin', 'review-topic'), true, 'PR publication uses configured branch')
  equal(alice.remote_branch_exists('origin', 'topic'), false, 'PR publication creates no fallback branch')
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, 'i')) do
    if map.lhs == '<Esc>' then map.callback(); break end
  end
  vim.fn.confirm = original_confirm; ui.close()
end)
test('fork PR creation qualifies the actual published head owner and explicit base repository', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic'))
  command(a, { 'config', 'branch.topic.remote', 'origin' })
  command(a, { 'config', 'branch.topic.merge', 'refs/heads/main' })
  command(a, { 'push', 'origin', 'main:topic' })
  local fork = root .. '/fork.git'
  command(root, { 'init', '--bare', '--initial-branch=main', fork })
  assert(alice.remote_add('fork', 'git@github.com:fetch-owner/project.git'))
  command(a, { 'config', 'remote.fork.pushurl', 'git@github.com:contributor/project.git' })
  local ssh = root .. '/local-ssh'
  vim.fn.writefile({ '#!/bin/sh', 'for arg do', ' case "$arg" in',
    '  "git-upload-pack "*) exec git-upload-pack "' .. fork .. '" ;;',
    '  "git-receive-pack "*) exec git-receive-pack "' .. fork .. '" ;;',
    ' esac', 'done', 'exit 1' }, ssh)
  vim.fn.setfperm(ssh, 'rwx------')
  command(a, { 'config', 'core.sshCommand', ssh })
  command(a, { 'config', 'branch.topic.pushRemote', 'fork' })
  command(a, { 'push', 'fork', 'topic' })
  command(a, { 'remote', 'set-url', 'origin', 'https://github.com/upstream/project.git' })
  local bin, arguments = root .. '/bin', root .. '/gh-args'
  vim.fn.mkdir(bin, 'p')
  vim.fn.writefile({ '#!/bin/sh', 'printf "%s\\n" "$@" > "' .. arguments .. '"' }, bin .. '/gh')
  vim.fn.setfperm(bin .. '/gh', 'rwx------')
  local original_path, original_input = vim.env.PATH, vim.ui.input
  vim.env.PATH = bin .. ':' .. original_path
  local body_prompts = 0
  vim.ui.input = function(_, submit) body_prompts = body_prompts + 1; submit('') end
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a); plugin.open(); action('gpr')
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, 'i')) do if map.lhs == '<CR>' then map.callback(); break end end
  assert(vim.wait(5000, function() return vim.fn.filereadable(arguments) == 1 end), 'Local gh transport receives PR command')
  local args = vim.fn.readfile(arguments)
  local values = {}
  for index, arg in ipairs(args) do if arg:match('^%-%-') then values[arg] = args[index + 1] end end
  equal(values['--head'], 'contributor:topic', 'Fork PR head includes actual destination owner')
  equal(values['--repo'], 'upstream/project', 'PR targets explicit base repository')
  equal(alice.branch_upstream('topic'), { remote = 'origin', branch = 'main' }, 'PR creation preserves pull upstream')
  assert(vim.wait(5000, function() return alice.repository_state().running == nil end), 'First PR process completes before a second publication')
  vim.fn.delete(arguments)
  action('gpr')
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'Base: topic' })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, 'i')) do if map.lhs == '<CR>' then map.callback(); break end end
  equal(body_prompts, 2, 'Identical branch names across fork and base repositories are valid')
  assert(vim.wait(5000, function() return vim.fn.filereadable(arguments) == 1 end), 'Same-name fork PR reaches local gh transport')
  args = vim.fn.readfile(arguments)
  values = {}
  for index, arg in ipairs(args) do if arg:match('^%-%-') then values[arg] = args[index + 1] end end
  equal(values['--base'], 'topic', 'Base branch may share its name with fork head')
  equal(values['--head'], 'contributor:topic', 'Qualified fork identity remains intact')
  vim.env.PATH, vim.ui.input = original_path, original_input; ui.close()
end)
test('fork PR validates its base on the selected upstream remote when configured remote is the fork', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic'))
  command(a, { 'config', 'branch.topic.remote', 'origin' })
  command(a, { 'config', 'branch.topic.merge', 'refs/heads/main' })
  local fork = root .. '/fork.git'
  command(root, { 'init', '--bare', '--initial-branch=main', fork })
  assert(alice.remote_add('fork', 'git@github.com:fetch-owner/project.git'))
  command(a, { 'config', 'remote.fork.pushurl', 'git@github.com:contributor/project.git' })
  local ssh = root .. '/local-ssh'
  vim.fn.writefile({ '#!/bin/sh', 'for arg do', ' case "$arg" in',
    '  "git-upload-pack "*) exec git-upload-pack "' .. fork .. '" ;;',
    '  "git-receive-pack "*) exec git-receive-pack "' .. fork .. '" ;;',
    ' esac', 'done', 'exit 1' }, ssh)
  vim.fn.setfperm(ssh, 'rwx------')
  command(a, { 'config', 'core.sshCommand', ssh })
  command(a, { 'config', 'branch.topic.pushRemote', 'fork' })
  command(a, { 'push', 'fork', 'topic' })
  command(a, { 'remote', 'set-url', 'origin', 'https://github.com/upstream/project.git' })
  local bin, arguments = root .. '/bin', root .. '/gh-args'
  vim.fn.mkdir(bin, 'p')
  vim.fn.writefile({ '#!/bin/sh', 'printf "%s\\n" "$@" > "' .. arguments .. '"' }, bin .. '/gh')
  vim.fn.setfperm(bin .. '/gh', 'rwx------')
  local original_path, original_input = vim.env.PATH, vim.ui.input
  vim.env.PATH = bin .. ':' .. original_path
  local body_prompted = false
  vim.ui.input = function(_, submit) body_prompted = true; submit('') end
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  command(a, { 'branch', '-d', 'main' })
  plugin.setup({ remote = 'fork' })
  vim.api.nvim_set_current_dir(a); plugin.open(); action('gpr')
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, 'i')) do if map.lhs == '<CR>' then map.callback(); break end end
  assert(body_prompted, 'Valid upstream main proceeds despite missing local/fork main')
  assert(vim.wait(5000, function() return vim.fn.filereadable(arguments) == 1 end), 'Local gh transport receives PR command')
  local args = vim.fn.readfile(arguments)
  local values = {}
  for index, arg in ipairs(args) do if arg:match('^%-%-') then values[arg] = args[index + 1] end end
  equal(values['--head'], 'contributor:topic', 'Fork PR head includes actual destination owner')
  equal(values['--repo'], 'upstream/project', 'PR targets explicit base repository')
  equal(alice.branch_upstream('topic'), { remote = 'origin', branch = 'main' }, 'PR creation preserves pull upstream')
  vim.env.PATH, vim.ui.input = original_path, original_input; ui.close(); plugin.setup({ remote = 'origin' })
end)
test('fork PR creation refuses unknown repository identities before publication or form entry', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic'))
  command(a, { 'config', 'branch.topic.remote', 'origin' })
  command(a, { 'config', 'branch.topic.merge', 'refs/heads/main' })
  local fork = root .. '/fork.git'
  command(root, { 'init', '--bare', '--initial-branch=main', fork })
  assert(alice.remote_add('fork', fork))
  command(a, { 'config', 'branch.topic.pushRemote', 'fork' })
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  local original_confirm = vim.fn.confirm
  vim.fn.confirm = function() error('Unknown fork identity stops before publication choice') end
  vim.api.nvim_set_current_dir(a); plugin.open(); action('gpr')
  assert(notifications[#notifications]:find('GitHub repository identities', 1, true), 'Unknown identity explains needed GitHub URLs or explicit CLI choice')
  assert(not ui_text():find('Title: topic', 1, true), 'Unknown fork identity has no PR form')
  equal(alice.remote_branch_exists('fork', 'topic'), false, 'Unknown fork identity leaves remote untouched')
  equal(alice.branch_upstream('topic'), { remote = 'origin', branch = 'main' }, 'Unknown identity preserves existing upstream')
  vim.fn.confirm = original_confirm; ui.close()
end)
test('revisiting explicit push help retains one explanation heading', function()
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a); plugin.open()
  local first
  for visit = 1, 2 do
    action('?')
    local help_buf = vim.api.nvim_get_current_buf()
    local selected
    for index, line in ipairs(vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)) do
      if line:find('[gPp]', 1, true) then selected = index end
    end
    assert(selected, 'Explicit destination action appears in help')
    vim.api.nvim_win_set_cursor(0, { selected, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = help_buf })
    local explanation
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == 'mylazygit-explain' then explanation = vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
    end
    assert(explanation, 'Help explanation is visible')
    local headings = 0
    for _, line in ipairs(explanation) do if line:match('^Explanation:') then headings = headings + 1 end end
    equal(headings, 1, 'Help does not accumulate titles on visit ' .. visit)
    if first then equal(explanation, first, 'Repeated help selection has stable content') else first = explanation end
    action('q')
  end
  ui.close()
end)
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
test('remote deletion omits unsupported fetch mappings instead of guessing a remote branch', function()
  local alice = git.session(a)
  assert(alice.push('origin', 'main:topic'))
  assert(alice.push('origin', 'main:release/topic'))
  command(a, { 'update-ref', '-d', 'refs/remotes/origin/topic' })
  command(a, { 'config', 'remote.origin.fetch', '+refs/heads/release/*:refs/remotes/origin/*' })
  assert(alice.fetch('origin'))
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a)
  plugin.open()
  local original_select, original_confirm = vim.ui.select, vim.fn.confirm
  vim.ui.select = function() error('Unsupported mapping must not offer a guessed destination') end
  vim.fn.confirm = function() error('Unsupported mapping must not offer a deletion confirmation') end
  local mappings = {
    { '+refs/heads/release/*:refs/remotes/origin/*' },
    { '+refs/heads/*:refs/remotes/origin/*', '+refs/heads/release/*:refs/remotes/origin/*' },
    { '+refs/heads/topic:refs/remotes/origin/topic', '+refs/heads/release/topic:refs/remotes/origin/topic' },
  }
  for _, specs in ipairs(mappings) do
    command(a, { 'config', '--unset-all', 'remote.origin.fetch' })
    for _, spec in ipairs(specs) do command(a, { 'config', '--add', 'remote.origin.fetch', spec }) end
    equal(alice.remote_branch_destinations(), {}, 'Custom or additional fetch mappings have no deletion destination')
    action('gbx')
    assert(notifications[#notifications]:find('standard fetch mappings', 1, true), 'Empty picker explains unsupported mappings')
    equal(alice.remote_branch_exists('origin', 'topic'), true, 'Unrelated topic remains')
    equal(alice.remote_branch_exists('origin', 'release/topic'), true, 'Actual mapped release/topic remains')
  end
  -- A custom mapping may write another configured remote's tracking namespace.
  assert(alice.remote_add('team', remote))
  command(a, { 'config', '--unset-all', 'remote.origin.fetch' })
  command(a, { 'config', 'remote.origin.fetch', '+refs/heads/release/*:refs/remotes/team/*' })
  assert(alice.fetch('origin'))
  equal(alice.remote_branch_destinations(), {}, 'Cross-remote namespace mapping has no guessed destination')
  action('gbx')
  equal(alice.remote_branch_exists('team', 'topic'), true, 'Unrelated branch on canonical remote remains')
  equal(alice.remote_branch_exists('origin', 'release/topic'), true, 'Cross-mapped source branch remains')
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
test('delayed UI commit refuses changed history and leaves the current index visible', function()
  local alice = git.session(a)
  vim.fn.writefile({ 'pending' }, a .. '/pending.txt'); assert(alice.stage('pending.txt'))
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a); plugin.open()
  local original, submit = vim.fn.prompt_setcallback
  vim.fn.prompt_setcallback = function(_, cb) submit = cb end
  action('c'); vim.fn.prompt_setcallback = original
  command(a, { 'commit', '-m', 'External commit' })
  vim.fn.writefile({ 'new work' }, a .. '/new.txt'); assert(alice.stage('new.txt'))
  submit('Stale commit')
  equal(alice.log(1)[1].message, 'External commit', 'Old prompt cannot commit changed repository')
  equal(alice.diff({ '--cached', '--name-only' }), { 'new.txt' }, 'New staged work preserved')
  ui.close()
end)
local function published_topic(alice)
  assert(alice.switch_create('topic'))
  vim.fn.writefile({ 'draft' }, a .. '/topic.txt'); assert(alice.stage('topic.txt')); assert(alice.commit('Draft topic'))
  command(a, { 'push', '-u', 'origin', 'topic' })
  local reviewed = command(remote, { 'rev-parse', 'refs/heads/topic' })
  vim.fn.writefile({ 'rewritten' }, a .. '/topic.txt'); assert(alice.stage('topic.txt')); command(a, { 'commit', '--amend', '-m', 'Rewritten topic' })
  return reviewed
end
local function teammate_push(bob)
  command(b, { 'fetch', 'origin' }); command(b, { 'switch', 'topic' })
  vim.fn.writefile({ 'teammate' }, b .. '/teammate.txt'); assert(bob.stage('teammate.txt')); assert(bob.commit('Teammate work'))
  assert(bob.push('origin', 'topic'))
  return command(b, { 'rev-parse', 'HEAD' })
end
test('reviewed rewrite publishes only after confirming the full destination and reviewed remote commit', function()
  local alice = git.session(a)
  local reviewed = published_topic(alice)
  local target, err = alice.resolve_rewrite_target()
  assert(target, err)
  equal({ target.remote, target.ref, target.expected }, { 'origin', 'refs/heads/topic', reviewed }, 'Review identifies full destination and remote commit')
  local ok, output = alice.push_rewrite_target(target)
  equal(ok, false, 'Unreviewed rewrite refused')
  assert(table.concat(output, '\n'):find('Review', 1, true), 'Refusal asks for review')
  equal(command(remote, { 'rev-parse', 'refs/heads/topic' }), reviewed, 'Unreviewed rewrite changes no remote ref')
  target.confirmed = true
  assert(alice.push_rewrite_target(target))
  equal(command(remote, { 'rev-parse', 'refs/heads/topic' }), command(a, { 'rev-parse', 'HEAD' }), 'Reviewed rewrite published')
end)
test('rewrite without remote history is refused before review', function()
  local alice = git.session(a)
  assert(alice.switch_create('unpublished'))
  command(a, { 'config', 'remote.pushDefault', 'origin' }); command(a, { 'config', 'push.default', 'current' })
  local target, reason = alice.resolve_rewrite_target()
  equal(target, nil, 'Unpublished destination has nothing to rewrite')
  assert(reason:find('No remote history at origin refs/heads/unpublished', 1, true), 'Refusal names the missing destination')
end)
test('teammate advance after review rejects the rewrite even after a fetch and keeps the teammate commit', function()
  local alice, bob = git.session(a), git.session(b)
  local reviewed = published_topic(alice)
  local target = assert(alice.resolve_rewrite_target())
  target.confirmed = true
  local teammate = teammate_push(bob)
  assert(alice.fetch('origin'))
  equal(command(a, { 'rev-parse', 'refs/remotes/origin/topic' }), teammate, 'Fetch observed the teammate advance')
  local completed
  alice.push_rewrite_target_async(target, function(ok, output, outcome) completed = { ok, output, outcome } end)
  assert(vim.wait(5000, function() return completed end), 'Async rewrite completes')
  equal(completed[1], false, 'Stale reviewed lease rejected')
  equal(completed[3].status, 'failed', 'Rejection reported as failed publication')
  equal(target.expected, reviewed, 'Reviewed expectation is not renewed')
  equal(alice.push_rewrite_target(target), false, 'Retrying the same review stays rejected')
  equal(alice.push_target(alice.resolve_push_target()), false, 'Ordinary publication does not overwrite the teammate either')
  command(remote, { 'merge-base', '--is-ancestor', teammate, 'refs/heads/topic' })
end)
test('rewrite is rejected when the reviewed remote branch was deleted', function()
  local alice = git.session(a)
  published_topic(alice)
  local target = assert(alice.resolve_rewrite_target())
  target.confirmed = true
  command(b, { 'push', 'origin', '--delete', 'topic' })
  equal(alice.push_rewrite_target(target), false, 'Lease on a deleted branch rejected')
  equal(vim.system({ 'git', '-C', remote, 'show-ref', '--verify', '--quiet', 'refs/heads/topic' }):wait().code, 1, 'Deleted branch is not recreated by the rewrite')
end)
test('rewrite is rejected when the reviewed remote branch was deleted and recreated', function()
  local alice, bob = git.session(a), git.session(b)
  published_topic(alice)
  local target = assert(alice.resolve_rewrite_target())
  target.confirmed = true
  command(b, { 'push', 'origin', '--delete', 'topic' })
  command(b, { 'switch', '-c', 'topic' })
  vim.fn.writefile({ 'recreated' }, b .. '/recreated.txt'); assert(bob.stage('recreated.txt')); assert(bob.commit('Recreated topic'))
  command(b, { 'push', 'origin', 'topic' })
  local recreated = command(b, { 'rev-parse', 'HEAD' })
  equal(alice.push_rewrite_target(target), false, 'Lease on a recreated branch rejected')
  equal(command(remote, { 'rev-parse', 'refs/heads/topic' }), recreated, 'Recreated branch unchanged')
end)
test('main is protected from rewriting during review by default', function()
  local alice = git.session(a)
  command(a, { 'commit', '--amend', '-m', 'Rewritten initial' })
  local target, reason = alice.resolve_rewrite_target()
  equal(target, nil, 'Main is protected by default')
  assert(reason:find('Protected branch refs/heads/main', 1, true), 'Refusal names the protected destination')
end)
test('an empty protected list cannot unprotect main during review', function()
  local alice = git.session(a)
  command(a, { 'commit', '--amend', '-m', 'Rewritten initial' })
  local target, reason = alice.resolve_rewrite_target({ protected = {} })
  equal(target, nil, 'Main stays protected with an empty list')
  assert(reason:find('Protected branch refs/heads/main', 1, true), 'Refusal names main')
end)
test('execution refuses main even when the target protection list was emptied', function()
  local alice = git.session(a)
  local main_before = command(remote, { 'rev-parse', 'refs/heads/main' })
  command(a, { 'commit', '--amend', '-m', 'Rewritten initial' })
  local forged = assert(alice.resolve_push_target({ inspect_remote = true }))
  forged.expected, forged.confirmed, forged.protected = main_before, true, {}
  local ok, output = alice.push_rewrite_target(forged)
  equal(ok, false, 'Execution refuses main despite the emptied protection list')
  assert(table.concat(output, '\n'):find('Protected branch refs/heads/main', 1, true), 'Refusal names main')
  equal(command(remote, { 'rev-parse', 'refs/heads/main' }), main_before, 'Protected remote history unchanged')
end)
test('additional protected branches are refused during review', function()
  local alice = git.session(a)
  published_topic(alice)
  local target, reason = alice.resolve_rewrite_target({ protected = { 'refs/heads/topic' } })
  equal(target, nil, 'Additional configured branch is protected')
  assert(reason:find('Protected branch refs/heads/topic', 1, true), 'Refusal names destination')
end)
local function open_rewrite_ui(opts, respond)
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  plugin.setup(opts); vim.api.nvim_set_current_dir(a); plugin.open()
  local original_confirm = vim.fn.confirm
  vim.fn.confirm = respond
  return function()
    vim.fn.confirm = original_confirm; ui.close()
    plugin.setup({ merge_workflow = { main_branch = 'main' }, protected_branches = {} })
  end
end
test('rewrite UI review shows destination, endpoint and both commits and cancels by default', function()
  local alice = git.session(a)
  local reviewed = published_topic(alice)
  local review
  local close = open_rewrite_ui({}, function(message, choices, default) review = { message, choices, default }; return 2 end)
  action('gPF')
  equal(review, { 'Rewrite remote origin (' .. remote .. '), branch refs/heads/topic?\nReviewed remote commit: ' .. reviewed
    .. '\nLocal topic commit ' .. command(a, { 'rev-parse', 'HEAD' }) .. ' replaces it only while the remote still has that commit.',
    '&Rewrite\n&Cancel', 2 }, 'Review shows endpoint, destination and both commits, defaulting to cancel')
  equal(notifications[#notifications], 'Rewrite cancelled', 'Cancellation reported')
  equal(command(remote, { 'rev-parse', 'refs/heads/topic' }), reviewed, 'Cancellation changes no remote ref')
  close()
end)
test('rewrite UI publishes the reviewed rewrite after confirmation', function()
  local alice = git.session(a)
  published_topic(alice)
  local close = open_rewrite_ui({}, function() return 1 end)
  action('gPF')
  assert(vim.wait(5000, function() return command(remote, { 'rev-parse', 'refs/heads/topic' }) == command(a, { 'rev-parse', 'HEAD' }) end), 'Reviewed rewrite completes')
  close()
end)
test('rewrite UI refuses configured main before review', function()
  local alice = git.session(a)
  published_topic(alice)
  local prompts = 0
  local close = open_rewrite_ui({ merge_workflow = { main_branch = 'topic' } }, function() prompts = prompts + 1; return 1 end)
  action('gPF')
  assert(notifications[#notifications]:find('Protected branch refs/heads/topic', 1, true), 'Configured main is protected')
  equal(prompts, 0, 'Refused before review')
  close()
end)
test('rewrite UI refuses configured protected branches before review', function()
  local alice = git.session(a)
  published_topic(alice)
  local prompts = 0
  local close = open_rewrite_ui({ protected_branches = { 'topic' } }, function() prompts = prompts + 1; return 1 end)
  action('gPF')
  assert(notifications[#notifications]:find('Protected branch refs/heads/topic', 1, true), 'Additional configured branch is protected')
  equal(prompts, 0, 'Refused before review')
  close()
end)
test('rewrite UI reports a lease rejected by Git', function()
  local alice, bob = git.session(a), git.session(b)
  published_topic(alice)
  local teammate
  local close = open_rewrite_ui({}, function() teammate = teammate_push(bob); return 1 end)
  action('gPF')
  assert(vim.wait(5000, function() return notifications[#notifications]:find('Rewrite rejected; the remote kept its history. Fetch and review again.', 1, true) end), 'Lease rejection advises fetch and review')
  equal(command(remote, { 'rev-parse', 'refs/heads/topic' }), teammate, 'Teammate commit kept')
  close()
end)
test('rewrite UI reports a pre-push refusal with its own reason', function()
  local alice = git.session(a)
  local reviewed = published_topic(alice)
  local close = open_rewrite_ui({}, function() command(a, { 'switch', 'main' }); return 1 end)
  local count = #notifications
  action('gPF')
  assert(vim.wait(5000, function() return #notifications > count and notifications[#notifications]:find('changed since target selection', 1, true) end), 'Refusal reason shown')
  for i = count + 1, #notifications do
    assert(not notifications[i]:find('Rewrite rejected', 1, true), 'Pre-push refusal does not claim a lease rejection')
  end
  equal(command(remote, { 'rev-parse', 'refs/heads/topic' }), reviewed, 'Refusal changes no remote ref')
  close()
end)
test('rewrite help names the reviewed-lease action', function()
  local close = open_rewrite_ui({}, function() return 2 end)
  action('?')
  assert(ui_text():find('Rewrite with reviewed lease', 1, true), 'Help names the rewrite action')
  action('q')
  close()
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
test('AI confirmation refuses changed staged content and cancellation preserves another action’s index', function()
  local alice, ai = git.session(a), require('mylazygit.ai')
  ai.setup({ api_key = 'test-placeholder' })
  local original_system, original_input = vim.fn.system, vim.ui.input
  vim.fn.system = function(cmd)
    if type(cmd) == 'table' and cmd[1] == 'curl' then return vim.json.encode({ choices = { { message = { content = 'suggested' } } } }) end
    return original_system(cmd)
  end
  local submit
  vim.ui.input = function(_, cb) submit = cb end
  vim.fn.writefile({ 'old' }, a .. '/ai.txt'); assert(alice.stage('ai.txt'))
  ai.generate_commit_message(alice)
  vim.fn.writefile({ 'changed' }, a .. '/ai.txt'); assert(alice.stage('ai.txt'))
  submit('Stale AI message')
  equal(alice.log(1)[1].message, 'Initial', 'AI cannot commit a changed index')
  submit(nil)
  equal(alice.diff({ '--cached', '--name-only' }), { 'ai.txt' }, 'Stale cancellation cannot unstage changed work')
  vim.fn.system, vim.ui.input = original_system, original_input
end)
test('a stale conflict recovery confirmation cannot commit a replacement merge', function()
  local alice = git.session(a)
  for _, branch in ipairs({ 'feature1', 'feature2' }) do
    assert(alice.switch_create(branch))
    vim.fn.writefile({ branch }, a .. '/file.txt'); assert(alice.stage('file.txt')); assert(alice.commit(branch))
    assert(alice.switch('main'))
  end
  vim.fn.writefile({ 'main' }, a .. '/file.txt'); assert(alice.stage('file.txt')); assert(alice.commit('Main'))
  assert(not alice.merge('feature1'))
  local resolver = require('mylazygit.conflict')
  local original_select, pending = vim.ui.select
  vim.ui.select = function(_, _, cb) pending = cb end
  resolver.open('file.txt', alice); action('a'); action('s')
  assert(vim.wait(5000, function() return pending end), 'First merge commit confirmation opened')
  local original_head = alice.repository_state().head
  command(a, { 'merge', '--abort' })
  assert(not alice.merge('feature2'))
  vim.fn.writefile({ 'main' }, a .. '/file.txt'); command(a, { 'add', 'file.txt' })
  pending('Commit')
  assert(vim.wait(1000, function() return alice.repository_state().running == nil end))
  equal(alice.repository_state().operation, 'merge', 'Replacement merge remains available for its own review')
  equal(alice.repository_state().head, original_head, 'Old confirmation cannot commit a different merge')
  vim.ui.select = original_select; resolver.close()
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
test('cleanup amend distinguishes private choice and includes existing staged work', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic')); command(a, { 'push', '-u', 'origin', 'topic' })
  vim.fn.writefile({ 'draft' }, a .. '/draft.txt'); assert(alice.stage('draft.txt')); assert(alice.commit('Private draft'))
  vim.fn.writefile({ 'staged' }, a .. '/staged.txt'); assert(alice.stage('staged.txt'))
  local before = alice.repository_state()
  local target = assert(alice.resolve_cleanup_target('amend'))
  equal(target.publication, 'local-only', 'Only amended commit participates in classification')
  equal(alice.cleanup_target(target, 'Private amended'), false, 'Explicit operation choice required')
  equal(alice.repository_state().head, before.head, 'Unconfirmed cleanup preserves HEAD')
  equal(alice.diff({ '--cached', '--name-only' }), { 'staged.txt' }, 'Unconfirmed cleanup preserves index')
  target.confirmed = true
  assert(alice.cleanup_target(target, 'Private amended'))
  equal(command(a, { 'show', 'HEAD:staged.txt' }), 'staged', 'Amend includes existing staged work')
  equal(alice.diff({ '--cached', '--name-only' }), {}, 'Successful amend consumes staged work')
end)
test('cleanup published amend retains review expectation through fetch and later publication', function()
  local alice, bob = git.session(a), git.session(b)
  assert(alice.switch_create('topic'))
  vim.fn.writefile({ 'draft' }, a .. '/topic.txt'); assert(alice.stage('topic.txt')); assert(alice.commit('Published draft'))
  command(a, { 'push', '-u', 'origin', 'topic' })
  local reviewed = command(remote, { 'rev-parse', 'refs/heads/topic' })
  local target = assert(alice.resolve_cleanup_target('amend'))
  equal(target.publication, 'published', 'Published commit requires rewrite')
  target.confirmed = true
  equal(alice.cleanup_target(target, 'New message'), false, 'Operation choice alone cannot rewrite published history')
  equal(alice.repository_state().head, reviewed, 'Refusal preserves published HEAD')
  target.rewrite_confirmed = true; assert(alice.cleanup_target(target, 'New message'))
  local teammate = teammate_push(bob); assert(alice.fetch('origin'))
  local publication = assert(git.session(a).resolve_cleanup_publication())
  equal(publication.expected, reviewed, 'A new session retains pre-cleanup remote expectation after fetch')
  publication.confirmed = true
  equal(alice.push_rewrite_target(publication), false, 'Teammate advance rejects stale cleanup lease')
  equal(command(remote, { 'rev-parse', 'refs/heads/topic' }), teammate, 'Teammate history preserved')
end)
test('cleanup refuses unknown evidence and protected published branches across operations', function()
  local alice = git.session(a)
  vim.fn.writefile({ 'second' }, a .. '/second.txt'); assert(alice.stage('second.txt')); assert(alice.commit('Second'))
  command(a, { 'push', 'origin', 'main' }); command(a, { 'branch', 'base', 'HEAD~1' })
  local head, index = alice.repository_state().head, command(a, { 'write-tree' })
  for _, spec in ipairs({ { 'amend', {} }, { 'squash', { count = 1 } }, { 'rebase', { onto = 'base' } } }) do
    local target, reason = alice.resolve_cleanup_target(spec[1], spec[2])
    equal(target, nil, 'Protected published ' .. spec[1] .. ' refused')
    assert(reason:find('Protected branch', 1, true), reason)
  end
  command(a, { 'update-ref', '-d', 'refs/remotes/origin/main' })
  for _, spec in ipairs({ { 'amend', {} }, { 'squash', { count = 1 } }, { 'rebase', { onto = 'base' } } }) do
    local target, reason = alice.resolve_cleanup_target(spec[1], spec[2])
    equal(target, nil, 'Unknown ' .. spec[1] .. ' refused')
    assert(reason:find('unknown', 1, true), reason)
  end
  equal(alice.commit_amend('Unsafe bypass'), false, 'Legacy amend cannot bypass review')
  equal(alice.rebase('base'), false, 'Legacy rebase cannot bypass review')
  equal(alice.repository_state().head, head, 'Refusals preserve HEAD')
  equal(command(a, { 'write-tree' }), index, 'Refusals preserve index')
end)
test('cleanup UI cancels amend squash and rebase without changing refs or staged work', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic')); command(a, { 'push', '-u', 'origin', 'topic' })
  vim.fn.writefile({ 'private' }, a .. '/private.txt'); assert(alice.stage('private.txt')); assert(alice.commit('Private'))
  vim.fn.writefile({ 'staged' }, a .. '/staged.txt'); assert(alice.stage('staged.txt'))
  local head, index = alice.repository_state().head, command(a, { 'write-tree' })
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a); plugin.open()
  local old_confirm, old_select, old_input, old_prompt = vim.fn.confirm, vim.ui.select, vim.ui.input, vim.fn.prompt_setcallback
  local choices = 0
  vim.fn.confirm = function(message, buttons, default)
    choices = choices + 1
    assert(message:find('unpublished', 1, true), 'Private operation is identified')
    equal(default, 2, 'Cleanup defaults to cancel'); return 2
  end
  vim.ui.select = function(items, opts, cb) cb(items[1]) end
  vim.ui.input = function() error('Cancellation must happen before message input') end
  vim.fn.prompt_setcallback = function() error('Cancellation must happen before amend input') end
  action('A'); action('gss'); action('gbr')
  equal(choices, 3, 'Every cleanup requires an explicit choice')
  equal(alice.repository_state().head, head, 'Cancelled cleanups preserve refs')
  equal(command(a, { 'write-tree' }), index, 'Cancelled cleanups preserve staged content')
  vim.fn.confirm, vim.ui.select, vim.ui.input, vim.fn.prompt_setcallback = old_confirm, old_select, old_input, old_prompt
  ui.close()
end)
test('cleanup squash commit failure restores original refs and preserves staged work', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic')); command(a, { 'push', '-u', 'origin', 'topic' })
  for _, name in ipairs({ 'one', 'two' }) do
    vim.fn.writefile({ name }, a .. '/' .. name); assert(alice.stage(name)); assert(alice.commit(name))
  end
  vim.fn.writefile({ 'staged' }, a .. '/staged'); assert(alice.stage('staged'))
  local before, tree = alice.repository_state().head, command(a, { 'write-tree' })
  vim.fn.writefile({ '#!/bin/sh', 'exit 1' }, a .. '/.git/hooks/pre-commit'); vim.fn.setfperm(a .. '/.git/hooks/pre-commit', 'rwxr-xr-x')
  local target = assert(alice.resolve_cleanup_target('squash', { count = 2 })); target.confirmed = true
  equal(target.publication, 'local-only', 'Only selected private commits participate')
  equal(alice.cleanup_target(target, 'Combined'), false, 'Real commit hook rejects squash')
  equal(alice.repository_state().head, before, 'Failed squash restores original branch tip')
  equal(command(a, { 'write-tree' }), tree, 'Failed squash preserves original staged content')
  vim.fn.delete(a .. '/.git/hooks/pre-commit')
  target = assert(alice.resolve_cleanup_target('squash', { count = 2 })); target.confirmed = true
  assert(alice.cleanup_target(target, 'Combined'))
  equal(alice.log(2)[1].message, 'Combined', 'Retry creates one combined commit')
  equal(command(a, { 'show', 'HEAD:staged' }), 'staged', 'Squash includes existing staged work')
  equal(command(a, { 'rev-list', '--count', 'origin/topic..HEAD' }), '1', 'Exactly one private commit remains')
end)
test('cleanup published rebase failure exposes recovery and retains original publication lease', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic'))
  vim.fn.writefile({ 'topic side' }, a .. '/file.txt'); assert(alice.stage('file.txt')); assert(alice.commit('Topic side'))
  command(a, { 'push', '-u', 'origin', 'topic' })
  local reviewed = alice.repository_state().head
  assert(alice.switch('main'))
  vim.fn.writefile({ 'main side' }, a .. '/file.txt'); assert(alice.stage('file.txt')); assert(alice.commit('Main side'))
  assert(alice.switch('topic'))
  local target = assert(alice.resolve_cleanup_target('rebase', { onto = 'main' }))
  equal(target.publication, 'published', 'Replayed published commits require rewrite')
  target.confirmed, target.rewrite_confirmed = true, true
  local ok, _, result = alice.cleanup_target(target)
  equal(ok, false, 'Real rebase conflict reported')
  equal(result.state.operation, 'rebase', 'Conflict exposes existing recovery flow')
  vim.fn.writefile({ 'resolved' }, a .. '/file.txt'); assert(alice.stage('file.txt'))
  local done
  alice.recover('rebase', 'continue', function(success) done = success end)
  assert(vim.wait(5000, function() return done ~= nil end)); assert(done)
  local publication = assert(alice.resolve_cleanup_publication())
  equal(publication.expected, reviewed, 'Continue retains pre-rebase reviewed expectation')
  publication.confirmed = true; assert(alice.push_rewrite_target(publication))
  equal(command(remote, { 'show', 'topic:file.txt' }), 'resolved', 'Recovered rewrite published with reviewed lease')
end)
test('cleanup squash classifies published ancestors even when HEAD is private', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic'))
  vim.fn.writefile({ 'published' }, a .. '/published'); assert(alice.stage('published')); assert(alice.commit('Published'))
  command(a, { 'push', '-u', 'origin', 'topic' })
  vim.fn.writefile({ 'private' }, a .. '/private'); assert(alice.stage('private')); assert(alice.commit('Private'))
  local target = assert(alice.resolve_cleanup_target('squash', { count = 2 }))
  equal(target.publication, 'published', 'Any selected published commit requires explicit rewrite')
  target.confirmed = true
  equal(alice.cleanup_target(target, 'Combined'), false, 'Private HEAD cannot bypass published ancestor review')
  target.rewrite_confirmed = true; assert(alice.cleanup_target(target, 'Combined'))
  equal(command(a, { 'rev-list', '--count', 'HEAD' }), '2', 'Selected published and private commits combined')
end)
test('cleanup private rebase explicitly confirms replay and preserves staged work on refusal', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic')); command(a, { 'push', '-u', 'origin', 'topic' })
  vim.fn.writefile({ 'private' }, a .. '/private'); assert(alice.stage('private')); assert(alice.commit('Private'))
  assert(alice.switch('main'))
  vim.fn.writefile({ 'base' }, a .. '/base'); assert(alice.stage('base')); assert(alice.commit('New base'))
  assert(alice.switch('topic'))
  local before = alice.repository_state().head
  local target = assert(alice.resolve_cleanup_target('rebase', { onto = 'main' }))
  equal(target.publication, 'local-only', 'Published common base is not replayed')
  equal(alice.cleanup_target(target), false, 'Private rebase requires explicit choice')
  equal(alice.repository_state().head, before, 'Cancellation preserves ref')
  vim.fn.writefile({ 'staged' }, a .. '/staged'); assert(alice.stage('staged'))
  local tree = command(a, { 'write-tree' })
  target = assert(alice.resolve_cleanup_target('rebase', { onto = 'main' })); target.confirmed = true
  equal(alice.cleanup_target(target), false, 'Git refuses rebase with staged work')
  equal(alice.repository_state().head, before, 'Refusal preserves ref')
  equal(command(a, { 'write-tree' }), tree, 'Refusal preserves staged content')
  assert(alice.unstage('staged')); vim.fn.delete(a .. '/staged')
  target = assert(alice.resolve_cleanup_target('rebase', { onto = 'main' })); target.confirmed = true
  assert(alice.cleanup_target(target))
  equal(command(a, { 'show', 'HEAD:base' }), 'base', 'Private commit replayed over new base')
  equal(alice.resolve_cleanup_publication(), nil, 'Private replay uses ordinary publication')
end)
test('cleanup UI published amend and later gPF retain original expectation after teammate fetch', function()
  local alice, bob = git.session(a), git.session(b)
  assert(alice.switch_create('topic'))
  vim.fn.writefile({ 'draft' }, a .. '/topic.txt'); assert(alice.stage('topic.txt')); assert(alice.commit('Published topic'))
  command(a, { 'push', '-u', 'origin', 'topic' })
  local reviewed = alice.repository_state().head
  local plugin, ui = require('mylazygit'), require('mylazygit.ui')
  vim.api.nvim_set_current_dir(a); plugin.open()
  local old_confirm, old_prompt, submit = vim.fn.confirm, vim.fn.prompt_setcallback
  local reviews = {}
  vim.fn.confirm = function(message, buttons, default)
    reviews[#reviews + 1] = message
    equal(default, 2, 'Both rewrite choices default to cancel')
    equal(buttons, '&Rewrite\n&Cancel', 'Published operation explicitly chooses Rewrite')
    assert(message:find(reviewed, 1, true), 'Both choices retain original reviewed commit')
    return 1
  end
  vim.fn.prompt_setcallback = function(_, cb) submit = cb end
  action('A'); assert(submit); submit('Rewritten topic')
  assert(notifications[#notifications]:find('pre-cleanup reviewed lease', 1, true), 'Cleanup reports intentional publication path')
  local teammate = teammate_push(bob); assert(alice.fetch('origin'))
  plugin.refresh(); action('gPF')
  assert(vim.wait(5000, function() return notifications[#notifications]:find('Rewrite rejected', 1, true) end), 'Later publication uses stale original lease')
  equal(#reviews, 2, 'Cleanup and publication each require explicit Rewrite choice')
  equal(command(remote, { 'rev-parse', 'refs/heads/topic' }), teammate, 'Later rewrite keeps teammate history')
  vim.fn.confirm, vim.fn.prompt_setcallback = old_confirm, old_prompt; ui.close()
end)
test('cleanup private follow-up keeps an earlier published rewrite publication path', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic'))
  vim.fn.writefile({ 'draft' }, a .. '/draft'); assert(alice.stage('draft')); assert(alice.commit('Draft'))
  command(a, { 'push', '-u', 'origin', 'topic' })
  local reviewed = alice.repository_state().head
  local target = assert(alice.resolve_cleanup_target('amend')); target.confirmed, target.rewrite_confirmed = true, true
  assert(alice.cleanup_target(target, 'Rewrite draft'))
  vim.fn.writefile({ 'private' }, a .. '/private'); assert(alice.stage('private')); assert(alice.commit('Private follow-up'))
  target = assert(alice.resolve_cleanup_target('amend'))
  equal(target.publication, 'local-only', 'Follow-up commit itself remains private')
  assert(target.rewrite, 'Publication still requires earlier intentional rewrite')
  equal(target.rewrite.expected, reviewed, 'Follow-up retains original remote expectation')
  target.confirmed = true; assert(alice.cleanup_target(target, 'Private amended'))
  local publication = assert(alice.resolve_cleanup_publication()); publication.confirmed = true
  assert(alice.push_rewrite_target(publication))
  equal(alice.resolve_cleanup_publication(), nil, 'Successful publication clears pending cleanup lease')
end)
test('cleanup legacy reviewed entrypoints refuse stale staged intent', function()
  local alice = git.session(a)
  assert(alice.switch_create('topic')); command(a, { 'push', '-u', 'origin', 'topic' })
  vim.fn.writefile({ 'private' }, a .. '/private'); assert(alice.stage('private')); assert(alice.commit('Private'))
  local target = assert(alice.resolve_cleanup_target('amend')); target.confirmed = true
  local before = alice.repository_state().head
  vim.fn.writefile({ 'later staged' }, a .. '/later'); assert(alice.stage('later'))
  equal(alice.commit_amend('Stale amend', target), false, 'Legacy reviewed amend revalidates captured index')
  equal(alice.repository_state().head, before, 'Stale reviewed entrypoint preserves HEAD')
  equal(alice.diff({ '--cached', '--name-only' }), { 'later' }, 'Stale reviewed entrypoint preserves newer staged work')
end)
local ok, err = xpcall(function()
  for _, entry in ipairs(tests) do
    if not vim.env.MYLAZYGIT_TEST_FILTER or entry[1]:find(vim.env.MYLAZYGIT_TEST_FILTER, 1, true) then
    fixture()
    entry[2]()
    vim.api.nvim_set_current_dir(plugin_root)
    vim.fn.delete(root, 'rf')
    print('PASS ' .. entry[1])
    end
  end
end, debug.traceback)
vim.api.nvim_set_current_dir(plugin_root)
vim.fn.delete(root, 'rf')
if not ok then print(err); vim.cmd('cquit 1') else vim.cmd('qa!') end
