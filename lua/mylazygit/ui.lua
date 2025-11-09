local M = {}

local state = {
  buf = nil,
  win = nil,
}

local namespace = vim.api.nvim_create_namespace('mylazygit')

local function add_highlight(hl)
  if not hl.group then
    return
  end

  local line = hl.line or 0
  local col_start = hl.col_start or 0
  local line_text = vim.api.nvim_buf_get_lines(state.buf, line, line + 1, false)[1] or ''
  local line_len = #line_text

  col_start = math.min(math.max(col_start, 0), line_len)

  local col_end = hl.col_end
  if not col_end or col_end < 0 then
    col_end = line_len
  end
  col_end = math.max(col_start, math.min(col_end, line_len))

  vim.api.nvim_buf_set_extmark(state.buf, namespace, line, col_start, {
    hl_group = hl.group,
    priority = hl.priority,
    end_row = line,
    end_col = col_end,
  })
end

local function create_window()
  local columns = vim.o.columns
  local lines = vim.o.lines
  local width = math.floor(columns * 0.6)
  local height = math.floor(lines * 0.6)
  local row = math.floor((lines - height) / 2) - 1
  local col = math.floor((columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(row, 1),
    col = math.max(col, 1),
    border = 'rounded',
    style = 'minimal',
  })

  vim.api.nvim_set_option_value('filetype', 'mylazygit', { buf = buf })
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = buf })

  state.buf = buf
  state.win = win

  return buf, win
end

function M.open()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return state.buf, state.win
  end

  return create_window()
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
end

function M.is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

function M.render(lines, highlights)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = state.buf })
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = state.buf })

  vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
  if highlights then
    for _, hl in ipairs(highlights) do
      add_highlight(hl)
    end
  end
end

function M.set_keymaps(mappings)
  if not state.buf then
    return
  end

  for _, map in ipairs(mappings) do
    vim.keymap.set('n', map.lhs, map.rhs, {
      buffer = state.buf,
      silent = true,
      nowait = true,
      desc = map.desc,
    })
  end
end

return M
