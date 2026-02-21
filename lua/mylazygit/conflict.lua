local M = {}

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
local function parse_conflicts(file_path)
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

  local lines = vim.split(content, "\n", { plain = true })
  local conflicts = {}
  local chunks = {} -- Maintains file structure: {type="text", lines={...}} or {type="conflict", index=N}
  local i = 1

  while i <= #lines do
    local line = lines[i]

    -- Check for conflict marker
    if line:match("^<<<<<<<") then
      local conflict = {
        start_line = i,
        ours_start = i + 1,
        separator_line = nil,
        theirs_start = nil,
        end_line = nil,
        ours = {},
        theirs = {},
        resolved = false,
        resolution = nil, -- "ours", "theirs", or custom lines
      }

      -- Read "ours" section
      i = i + 1
      while i <= #lines and not lines[i]:match("^=======") do
        table.insert(conflict.ours, lines[i])
        i = i + 1
      end

      conflict.separator_line = i

      -- Read "theirs" section
      i = i + 1
      conflict.theirs_start = i
      while i <= #lines and not lines[i]:match("^>>>>>>>") do
        table.insert(conflict.theirs, lines[i])
        i = i + 1
      end

      conflict.end_line = i

      table.insert(conflicts, conflict)
      -- Add conflict reference to chunks
      table.insert(chunks, { type = "conflict", index = #conflicts })
      i = i + 1
    else
      -- Non-conflict line - accumulate text
      if #chunks > 0 and chunks[#chunks].type == "text" then
        -- Add to existing text chunk
        table.insert(chunks[#chunks].lines, line)
      else
        -- Create new text chunk
        table.insert(chunks, { type = "text", lines = { line } })
      end
      i = i + 1
    end
  end

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
        -- Unresolved conflict - keep markers
        table.insert(result, "<<<<<<< HEAD")
        vim.list_extend(result, conflict.ours)
        table.insert(result, "=======")
        vim.list_extend(result, conflict.theirs)
        table.insert(result, ">>>>>>> MERGE_HEAD")
      end
    end
  end

  return result
end

-- Create the UI buffers and windows
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
    title = " Incoming (Theirs) ",
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
    title = " Local (Ours) ",
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
        current_line = current_line + 1 + #prev_conflict.ours + 1 + #prev_conflict.theirs + 1
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
      "Resolved: %d/%d � [l]ours [h]theirs [j/k]navigate [a]ll-ours [A]ll-theirs [s]ave [q]uit",
      resolved_count,
      total
    ),
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
  vim.notify("Accepted all local changes", vim.log.levels.INFO)
end

local function accept_all_theirs()
  for _, conflict in ipairs(state.conflicts) do
    conflict.resolved = true
    conflict.resolution = "theirs"
  end
  render()
  vim.notify("Accepted all incoming changes", vim.log.levels.INFO)
end

-- Check if we're in a rebase state
local function is_in_rebase()
  local ok, output = pcall(vim.fn.systemlist, { "git", "rev-parse", "--git-path", "rebase-merge" })
  if not ok or vim.v.shell_error ~= 0 then
    return false
  end
  local rebase_dir = output[1]
  return vim.fn.isdirectory(rebase_dir) == 1
end

-- Check if we're in a merge state
local function is_in_merge()
  local ok, output = pcall(vim.fn.systemlist, { "git", "rev-parse", "--git-path", "MERGE_HEAD" })
  if not ok or vim.v.shell_error ~= 0 then
    return false
  end
  return vim.fn.filereadable(output[1]) == 1
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

local function run_git(args, opts, on_success, on_failure)
  opts = opts or {}

  if vim.system then
    vim.system(vim.list_extend({ "git" }, args), { text = true, env = opts.env }, function(res)
      vim.schedule(function()
        if res.code == 0 then
          if on_success then
            on_success()
          end
        elseif on_failure then
          local output = {}
          if res.stdout and res.stdout ~= "" then
            vim.list_extend(output, vim.split(res.stdout, "\n", { trimempty = true }))
          end
          if res.stderr and res.stderr ~= "" then
            vim.list_extend(output, vim.split(res.stderr, "\n", { trimempty = true }))
          end
          on_failure(output)
        end
      end)
    end)
    return
  end

  local old_env = {}
  if opts.env then
    for key, value in pairs(opts.env) do
      old_env[key] = vim.env[key]
      vim.env[key] = value
    end
  end

  local ok, output = pcall(vim.fn.systemlist, vim.list_extend({ "git" }, args))

  if opts.env then
    for key, value in pairs(old_env) do
      vim.env[key] = value
    end
  end

  if ok and vim.v.shell_error == 0 then
    if on_success then
      on_success()
    end
  elseif on_failure then
    on_failure(output or {})
  end
end

local function prompt_post_resolve(in_rebase, in_merge)
  if in_rebase then
    vim.ui.select({ "Continue", "Stop here" }, {
      prompt = "File resolved and staged. Continue rebase?",
    }, function(choice)
      if not is_selected(choice, "Continue") then
        return
      end
      vim.notify("Continuing rebase...", vim.log.levels.INFO)
      run_git({ "rebase", "--continue" }, { env = { GIT_EDITOR = "true" } }, function()
        vim.notify("Rebase continued successfully", vim.log.levels.INFO)
      end, function(output)
        vim.notify("Rebase continue failed:\n" .. table.concat(output, "\n"), vim.log.levels.ERROR)
      end)
    end)
  elseif in_merge then
    vim.ui.select({ "Commit", "Stop here" }, {
      prompt = "File resolved and staged. Commit the merge?",
    }, function(choice)
      if not is_selected(choice, "Commit") then
        return
      end
      vim.notify("Committing merge...", vim.log.levels.INFO)
      run_git({ "commit", "--no-edit" }, nil, function()
        vim.notify("Merge committed successfully", vim.log.levels.INFO)
      end, function(output)
        vim.notify("Merge commit failed:\n" .. table.concat(output, "\n"), vim.log.levels.ERROR)
      end)
    end)
  end
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
        vim.fn.confirm(string.format("%d conflict(s) unresolved. Save anyway?", unresolved), "&Yes\n&No", 2)
    if choice ~= 1 then
      return
    end
  end

  -- Build final content
  local final_lines = build_result()

  -- Write to file
  local uv = vim.uv or vim.loop
  local fd = uv.fs_open(state.file_path, "w", 438)
  if not fd then
    vim.notify("Failed to write to file: " .. state.file_path, vim.log.levels.ERROR)
    return
  end
  uv.fs_write(fd, table.concat(final_lines, "\n") .. "\n")
  uv.fs_close(fd)

  vim.notify(string.format("Saved %s", state.file_path), vim.log.levels.INFO)

  -- Stage the file
  local stage_ok = pcall(vim.fn.system, { "git", "add", state.file_path })
  if stage_ok and vim.v.shell_error == 0 then
    vim.notify(string.format("Staged %s", state.file_path), vim.log.levels.INFO)
  else
    vim.notify("Failed to stage file", vim.log.levels.WARN)
  end

  -- Check if in rebase or merge and offer to continue
  local in_rebase = is_in_rebase()
  local in_merge = is_in_merge()

  M.close()
  vim.schedule(function()
    prompt_post_resolve(in_rebase, in_merge)
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
    vim.keymap.set("n", "l", accept_ours, { buffer = buf, silent = true, desc = "Accept local (ours)" })
    vim.keymap.set("n", "h", accept_theirs, { buffer = buf, silent = true, desc = "Accept incoming (theirs)" })
    vim.keymap.set("n", "a", accept_all_ours, { buffer = buf, silent = true, desc = "Accept all local" })
    vim.keymap.set("n", "A", accept_all_theirs, { buffer = buf, silent = true, desc = "Accept all incoming" })
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

  -- Check if file exists
  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(file_path)
  if not stat then
    vim.notify("File not found: " .. file_path, vim.log.levels.ERROR)
    return
  end

  -- Parse conflicts
  local conflicts, file_chunks = parse_conflicts(file_path)
  if not conflicts then
    vim.notify("Error parsing conflicts: " .. (file_chunks or "unknown error"), vim.log.levels.ERROR)
    return
  end

  if #conflicts == 0 then
    vim.notify("No conflicts found in " .. file_path, vim.log.levels.INFO)
    return
  end

  -- Set up state
  state.file_path = file_path
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
  local ok, output = pcall(vim.fn.systemlist, { "git", "diff", "--name-only", "--diff-filter=U" })
  if not ok or vim.v.shell_error ~= 0 then
    return {}
  end
  return output
end

return M
