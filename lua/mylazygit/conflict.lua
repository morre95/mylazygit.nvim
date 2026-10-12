local git_module = require("mylazygit.git")
local resolver = {}
local active_resolver

local function conflicted_files(git)
  return git.diff({ "--name-only", "--diff-filter=U" })
end

local function create_resolver(git)
local M = {}
local cwd = git.worktree()

local function select(items, opts, callback)
  return git.without_mutation(vim.ui.select, items, opts, git.user_callback(callback))
end
local function confirm(...)
  return git.without_mutation(vim.fn.confirm, ...)
end

-- State for the conflict resolver
local state = {
  file_path = nil,
  conflicts = {},
  current_conflict_idx = 1,
  file_chunks = {},
  buffers = {},
  windows = {},
}

-- Parse a file and extract conflicts
local function parse_conflicts(file_path, marker_size)
  local uv = vim.uv or vim.loop
  local fd = uv.fs_open(file_path, "r", 438)
  if not fd then
    return nil, "Could not open file"
  end
  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, "Could not stat file"
  end
  local content = uv.fs_read(fd, stat.size, 0) or ""
  uv.fs_close(fd)
  if content:find("\0", 1, true) then
    return nil, "Binary conflict is unsupported; resolve externally and stage explicitly. File remains unresolved"
  end

  local lines = vim.split(content, "\n", { plain = true })
  local conflicts, chunks = {}, {}
  local current, section, marker_width
  local function marker(line)
    local text = line:gsub("\r$", "")
    local kind = text:sub(1, 1)
    if kind ~= "<" and kind ~= "|" and kind ~= "=" and kind ~= ">" then return end
    local run, label = text:match("^(" .. kind .. "+)(.*)$")
    if not run or #run < math.min(7, marker_size) then return end
    return kind, #run, vim.trim(label), label == "" or label:match("^%s") ~= nil
  end
  local function malformed(i)
    return nil, "Malformed conflict markers at line " .. i .. "; file remains unresolved"
  end
  for i, line in ipairs(lines) do
    local kind, width, label, valid_label = marker(line)
    if kind then
      if not valid_label then return malformed(i) end
      if not current then
        if kind ~= "<" or width ~= marker_size then return malformed(i) end
        current = { ours = {}, ancestor = {}, theirs = {}, raw = {}, resolved = false, ours_label = label }
        marker_width, section = width, "ours"
      else
        if width ~= marker_width then return malformed(i) end
        if kind == "|" and section == "ours" then
          section = "ancestor"
          current.ancestor_label = label
        elseif kind == "=" and (section == "ours" or section == "ancestor") and label == "" then
          section = "theirs"
        elseif kind == ">" and section == "theirs" then
          current.theirs_label = label
          table.insert(current.raw, line)
          table.insert(conflicts, current)
          table.insert(chunks, { type = "conflict", index = #conflicts })
          current, section = nil, nil
        else
          return malformed(i)
        end
      end
      if current then table.insert(current.raw, line) end
    elseif current then
      table.insert(current[section], line)
      table.insert(current.raw, line)
    elseif #chunks > 0 and chunks[#chunks].type == "text" then
      table.insert(chunks[#chunks].lines, line)
    else
      table.insert(chunks, { type = "text", lines = { line } })
    end
  end
  if current then return malformed(#lines) end

  return conflicts, chunks
end

-- Build the result with resolved conflicts
local function build_result()
  local result = {}

  local file_chunks = state.file_chunks
  if type(file_chunks) ~= "table" then
    return result
  end
  ---@cast file_chunks table

  for _, chunk in ipairs(file_chunks) do
    if chunk.type == "text" then
      -- Regular text, just add it
      if type(chunk.lines) == "table" then
        vim.list_extend(result, chunk.lines)
      end
    elseif chunk.type == "conflict" then
      -- Conflict - use resolution or keep markers
      local conflict = state.conflicts[chunk.index]
      if conflict.resolved then
        if conflict.resolution == "ours" then
          vim.list_extend(result, conflict.ours)
        elseif conflict.resolution == "theirs" then
          vim.list_extend(result, conflict.theirs)
        elseif type(conflict.resolution) == "table" then
          vim.list_extend(result, conflict.resolution)
        end
      else
        -- Preserve Git's labels and optional ancestor section until resolved.
        vim.list_extend(result, conflict.raw)
      end
    end
  end

  return result
end

-- Create the UI buffers and windows
local function side_title(side, conflict)
  local role = side == "ours" and "Local (ours)" or "Incoming (theirs)"
  if state.expected.operation == "rebase" then
    role = side == "ours" and "Rebased base (ours)" or "Replayed commit (theirs)"
  end
  local label = conflict[side .. "_label"]
  return " " .. role .. (label and label ~= "" and (": " .. label) or "") .. " "
end

local function create_ui()
  -- Create buffers
  state.buffers.ours = vim.api.nvim_create_buf(false, true)
  state.buffers.theirs = vim.api.nvim_create_buf(false, true)
  state.buffers.result = vim.api.nvim_create_buf(false, true)
  state.buffers.info = vim.api.nvim_create_buf(false, true)

  -- Set buffer options
  for _, buf in pairs(state.buffers) do
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  end

  -- Calculate window dimensions
  local width = vim.o.columns
  local height = vim.o.lines
  local pane_width = math.floor(width / 3)
  local info_height = 3
  local pane_height = height - info_height - 4

  -- Create windows in a 3-column layout
  -- Left: Theirs (incoming)
  state.windows.theirs = vim.api.nvim_open_win(state.buffers.theirs, false, {
    relative = "editor",
    width = pane_width,
    height = pane_height,
    row = 1,
    col = 0,
    style = "minimal",
    border = "rounded",
    title = side_title("theirs", state.conflicts[state.current_conflict_idx]),
    title_pos = "center",
    zindex = 200,
  })

  -- Middle: Result
  state.windows.result = vim.api.nvim_open_win(state.buffers.result, true, {
    relative = "editor",
    width = pane_width,
    height = pane_height,
    row = 1,
    col = pane_width + 2,
    style = "minimal",
    border = "rounded",
    title = " Result ",
    title_pos = "center",
    zindex = 200,
  })

  -- Right: Ours (local)
  state.windows.ours = vim.api.nvim_open_win(state.buffers.ours, false, {
    relative = "editor",
    width = pane_width,
    height = pane_height,
    row = 1,
    col = (pane_width + 2) * 2,
    style = "minimal",
    border = "rounded",
    title = side_title("ours", state.conflicts[state.current_conflict_idx]),
    title_pos = "center",
    zindex = 200,
  })

  -- Info panel at bottom
  state.windows.info = vim.api.nvim_open_win(state.buffers.info, false, {
    relative = "editor",
    width = width - 4,
    height = info_height,
    row = pane_height + 3,
    col = 2,
    style = "minimal",
    border = "rounded",
    zindex = 200,
  })

  -- Set filetype for syntax highlighting
  local ft = vim.filetype.match({ filename = state.file_path }) or "text"
  vim.api.nvim_set_option_value("filetype", ft, { buf = state.buffers.ours })
  vim.api.nvim_set_option_value("filetype", ft, { buf = state.buffers.theirs })
  vim.api.nvim_set_option_value("filetype", ft, { buf = state.buffers.result })

  -- Enable line numbers
  vim.api.nvim_set_option_value("number", true, { win = state.windows.ours })
  vim.api.nvim_set_option_value("number", true, { win = state.windows.theirs })
  vim.api.nvim_set_option_value("number", true, { win = state.windows.result })
end

-- Update the display
local function render()
  if vim.tbl_isempty(state.conflicts) then
    return
  end

  local current = state.conflicts[state.current_conflict_idx]
  if not current then
    return
  end
  for _, side in ipairs({ "ours", "theirs" }) do
    vim.api.nvim_win_set_config(state.windows[side], { title = side_title(side, current) })
  end

  -- Update "ours" (local) buffer - show current conflict only
  vim.api.nvim_set_option_value("modifiable", true, { buf = state.buffers.ours })
  vim.api.nvim_buf_set_lines(state.buffers.ours, 0, -1, false, current.ours)
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.buffers.ours })

  -- Update "theirs" (incoming) buffer - show current conflict only
  vim.api.nvim_set_option_value("modifiable", true, { buf = state.buffers.theirs })
  vim.api.nvim_buf_set_lines(state.buffers.theirs, 0, -1, false, current.theirs)
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.buffers.theirs })

  -- Update result buffer - show ENTIRE file with live preview
  local result_content = build_result()

  vim.api.nvim_set_option_value("modifiable", true, { buf = state.buffers.result })
  vim.api.nvim_buf_set_lines(state.buffers.result, 0, -1, false, result_content)
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.buffers.result })

  -- Calculate the line number where the current conflict appears in the result
  local current_line = 1
  local file_chunks = state.file_chunks
  if type(file_chunks) ~= "table" then
    return
  end
  ---@cast file_chunks table

  for _, chunk in ipairs(file_chunks) do
    if chunk.type == "conflict" and chunk.index == state.current_conflict_idx then
      -- Found the current conflict, scroll to it
      break
    elseif chunk.type == "text" and type(chunk.lines) == "table" then
      current_line = current_line + #chunk.lines
    elseif chunk.type == "conflict" then
      -- Add lines from previous conflicts
      local prev_conflict = state.conflicts[chunk.index]
      if prev_conflict.resolved then
        if prev_conflict.resolution == "ours" then
          current_line = current_line + #prev_conflict.ours
        elseif prev_conflict.resolution == "theirs" then
          current_line = current_line + #prev_conflict.theirs
        elseif type(prev_conflict.resolution) == "table" then
          current_line = current_line + #prev_conflict.resolution
        end
      else
        -- Unresolved: markers + ours + separator + theirs + end marker
        current_line = current_line + #prev_conflict.raw
      end
    end
  end

  -- Scroll the result window to show the current conflict
  if vim.api.nvim_win_is_valid(state.windows.result) then
    vim.api.nvim_win_set_cursor(state.windows.result, { current_line, 0 })
  end

  -- Update info panel
  local total = #state.conflicts
  local resolved_count = 0
  for _, c in ipairs(state.conflicts) do
    if c.resolved then
      resolved_count = resolved_count + 1
    end
  end

  local status = current.resolved and ("[" .. current.resolution .. "]") or "[unresolved]"
  local info_lines = {
    string.format("Conflict %d/%d %s � File: %s", state.current_conflict_idx, total, status, state.file_path),
    string.format(
      "Resolved: %d/%d � [l]ours [h]theirs [j/k]navigate [a]ll-ours [A]ll-theirs [f]iles [s]ave [q]uit",
      resolved_count,
      total
    ),
    "Operation: " .. (state.expected.operation or "conflict") .. " · " .. side_title("ours", current) .. " · " .. side_title("theirs", current),
  }

  vim.api.nvim_set_option_value("modifiable", true, { buf = state.buffers.info })
  vim.api.nvim_buf_set_lines(state.buffers.info, 0, -1, false, info_lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.buffers.info })
end

-- Navigation
local function next_conflict()
  if state.current_conflict_idx < #state.conflicts then
    state.current_conflict_idx = state.current_conflict_idx + 1
    render()
  end
end

local function prev_conflict()
  if state.current_conflict_idx > 1 then
    state.current_conflict_idx = state.current_conflict_idx - 1
    render()
  end
end

-- Resolution functions
local function accept_ours()
  local current = state.conflicts[state.current_conflict_idx]
  if current then
    current.resolved = true
    current.resolution = "ours"
    render()
  end
end

local function accept_theirs()
  local current = state.conflicts[state.current_conflict_idx]
  if current then
    current.resolved = true
    current.resolution = "theirs"
    render()
  end
end

local function accept_all_ours()
  for _, conflict in ipairs(state.conflicts) do
    conflict.resolved = true
    conflict.resolution = "ours"
  end
  render()
  vim.notify("Accepted all ours changes", vim.log.levels.INFO)
end

local function accept_all_theirs()
  for _, conflict in ipairs(state.conflicts) do
    conflict.resolved = true
    conflict.resolution = "theirs"
  end
  render()
  vim.notify("Accepted all theirs changes", vim.log.levels.INFO)
end

-- Check if we're in a rebase state
local function is_in_rebase()
  return git.repository_state().operation == "rebase"
end
local function is_in_merge()
  return git.repository_state().operation == "merge"
end

local function is_selected(choice, label)
  if choice == label or choice == 1 then
    return true
  end
  if type(choice) == "table" then
    if choice[1] == label or choice.label == label or choice.text == label then
      return true
    end
  end
  return false
end

local function continue_operation(operation, expected, on_success, on_failure)
  git.recover(operation, "continue", function(ok, output)
    if ok then if on_success then on_success() end
    elseif on_failure then on_failure(output) end
  end, { expected = expected })
end

local function prompt_post_resolve(in_rebase, in_merge)
  local expected = git.repository_state()
  if in_rebase then
    select({ "Continue", "Stop here" }, {
      prompt = "File resolved and staged. Continue rebase?",
    }, function(choice)
      if not is_selected(choice, "Continue") then
        return
      end
      vim.notify("Continuing rebase...", vim.log.levels.INFO)
      continue_operation("rebase", expected, function()
        vim.notify("Rebase continued successfully", vim.log.levels.INFO)
      end, function(output)
        vim.notify("Rebase continue failed:\n" .. table.concat(output, "\n"), vim.log.levels.ERROR)
      end)
    end)
  elseif in_merge then
    select({ "Commit", "Stop here" }, {
      prompt = "File resolved and staged. Commit the merge?",
    }, function(choice)
      if not is_selected(choice, "Commit") then
        return
      end
      vim.notify("Committing merge...", vim.log.levels.INFO)
      continue_operation("merge", expected, function()
        vim.notify("Merge committed successfully", vim.log.levels.INFO)
      end, function(output)
        vim.notify("Merge commit failed:\n" .. table.concat(output, "\n"), vim.log.levels.ERROR)
      end)
    end)
  end
end

local function select_conflicted_file()
  local conflicted_files = M.get_conflicted_files()
  if vim.tbl_isempty(conflicted_files) then
    vim.notify("No conflicted files found", vim.log.levels.INFO)
    return
  end

  select(conflicted_files, {
    prompt = string.format("Select conflicted file (%d files)", #conflicted_files),
  }, function(choice)
    if not choice then
      return
    end
    if choice == state.file_path then
      return
    end

    M.close()
    vim.schedule(function()
      M.open(choice)
    end)
  end)
end

local function prompt_next_conflicted_file(in_rebase, in_merge)
  local conflicted_files = M.get_conflicted_files()
  if vim.tbl_isempty(conflicted_files) then
    prompt_post_resolve(in_rebase, in_merge)
    return
  end

  local options = { "Stop here" }
  vim.list_extend(options, conflicted_files)

  select(options, {
    prompt = string.format("Select next conflicted file (%d remaining)", #conflicted_files),
  }, function(choice)
    if not choice or choice == "Stop here" then
      vim.notify("You can resume conflict resolution with [X]", vim.log.levels.INFO)
      return
    end
    M.open(choice)
  end)
end

-- Save the resolved file
local function save_and_close()
  -- Check if all conflicts are resolved
  local unresolved = 0
  for _, conflict in ipairs(state.conflicts) do
    if not conflict.resolved then
      unresolved = unresolved + 1
    end
  end

  if unresolved > 0 then
    local choice =
        confirm(string.format("%d conflict(s) unresolved. Save anyway?", unresolved), "&Yes\n&No", 2)
    if choice ~= 1 then
      return
    end
  end

  -- Build final content
  local final_lines = build_result()

  local stage_ok, output = git.resolve_conflict(state.file_path, final_lines, { contents = state.original_contents, expected = state.expected })
  if not stage_ok then
    vim.notify(table.concat(output, "\n"), vim.log.levels.WARN)
    return
  end
  vim.notify(string.format("Saved and staged %s", state.file_path), vim.log.levels.INFO)

  -- Check if in rebase or merge and offer to continue
  local in_rebase = is_in_rebase()
  local in_merge = is_in_merge()

  M.close()
  vim.schedule(function()
    prompt_next_conflicted_file(in_rebase, in_merge)
  end)
end

-- Close the conflict resolver
function M.close()
  for _, win in pairs(state.windows) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  for _, buf in pairs(state.buffers) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  state = {
    file_path = nil,
    conflicts = {},
    current_conflict_idx = 1,
    file_chunks = {},
    buffers = {},
    windows = {},
  }
end

-- Set up keybindings
local function setup_keymaps()
  local bufs = { state.buffers.ours, state.buffers.theirs, state.buffers.result, state.buffers.info }

  for _, buf in ipairs(bufs) do
    vim.keymap.set("n", "j", next_conflict, { buffer = buf, silent = true, desc = "Next conflict" })
    vim.keymap.set("n", "k", prev_conflict, { buffer = buf, silent = true, desc = "Previous conflict" })
    vim.keymap.set("n", "l", accept_ours, { buffer = buf, silent = true, desc = "Accept ours (see pane label)" })
    vim.keymap.set("n", "h", accept_theirs, { buffer = buf, silent = true, desc = "Accept theirs (see pane label)" })
    vim.keymap.set("n", "a", accept_all_ours, { buffer = buf, silent = true, desc = "Accept all ours" })
    vim.keymap.set("n", "A", accept_all_theirs, { buffer = buf, silent = true, desc = "Accept all theirs" })
    vim.keymap.set("n", "f", select_conflicted_file, { buffer = buf, silent = true, desc = "Select conflicted file" })
    vim.keymap.set("n", "s", save_and_close, { buffer = buf, silent = true, desc = "Save and close" })
    vim.keymap.set("n", "q", M.close, { buffer = buf, silent = true, desc = "Quit without saving" })
    vim.keymap.set("n", "<Esc>", M.close, { buffer = buf, silent = true, desc = "Quit without saving" })
  end
end

-- Open the conflict resolver for a specific file
function M.open(file_path)
  if not file_path or file_path == "" then
    vim.notify("No file path provided", vim.log.levels.ERROR)
    return
  end

  if file_path:sub(1, 1) ~= "/" then file_path = cwd .. "/" .. file_path end

  local info, info_error = git.conflict_file_info(file_path)
  if not info then
    vim.notify(info_error, vim.log.levels.ERROR)
    return
  end
  if info.delete_modify then
    vim.notify("Delete/modify conflict is unsupported; resolve externally and stage explicitly. File remains unresolved", vim.log.levels.WARN)
    return
  end
  if info.binary then
    vim.notify("Binary conflict is unsupported; resolve externally and stage explicitly. File remains unresolved", vim.log.levels.WARN)
    return
  end

  -- Check if file exists
  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(file_path)
  if not stat then
    vim.notify("File not found: " .. file_path, vim.log.levels.ERROR)
    return
  end

  -- Parse conflicts
  local conflicts, file_chunks = parse_conflicts(file_path, info.marker_size)
  if not conflicts then
    vim.notify("Error parsing conflicts: " .. (file_chunks or "unknown error"), vim.log.levels.ERROR)
    return
  end

  if #conflicts == 0 then
    vim.notify(info.unmerged and ("Unmerged file has no supported conflict markers; resolve externally and stage explicitly. File remains unresolved: " .. file_path)
      or ("No conflicts found in " .. file_path), info.unmerged and vim.log.levels.WARN or vim.log.levels.INFO)
    return
  end

  -- Set up state
  state.file_path = file_path
  state.original_contents = vim.fn.readfile(file_path)
  state.expected = git.repository_state()
  state.conflicts = conflicts
  state.file_chunks = file_chunks
  state.current_conflict_idx = 1

  -- Create UI
  create_ui()
  setup_keymaps()
  render()

  vim.notify(string.format("Found %d conflict(s) in %s", #conflicts, file_path), vim.log.levels.INFO)
end

-- Get all files with conflicts in the repository
function M.get_conflicted_files()
  return conflicted_files(git)
end

return M
end

function resolver.open(file_path, session)
  if active_resolver then active_resolver.close() end
  active_resolver = create_resolver(session or git_module.session())
  active_resolver.open(file_path)
end

function resolver.close()
  if active_resolver then active_resolver.close() end
end

function resolver.get_conflicted_files(session)
  return conflicted_files(session or git_module.session())
end

return resolver
