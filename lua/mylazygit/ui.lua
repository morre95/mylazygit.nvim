local M = {}

local namespace = vim.api.nvim_create_namespace("mylazygit")

local state = {
	root = nil,
	sections = {},
	focus_order = { "worktree", "commits", "diff", "preview" },
	focus_index = 1,
	keymaps = {},
	handlers = {},
	worktree_map = {},
	current_file = nil,
	current_worktree_line = 1,
	autocmd_group = nil,
	dimensions = nil,
}

local function pad_lines(lines, total)
	local padded = vim.list_extend({}, lines or {})
	total = math.max(total or #padded, #padded)
	while #padded < total do
		table.insert(padded, "")
	end
	return padded
end

local function add_highlight(buf, hl)
	if not buf or not vim.api.nvim_buf_is_valid(buf) or not hl or not hl.group then
		return
	end

	local line = math.max(hl.line or 0, 0)
	local col_start = math.max(hl.col_start or 0, 0)
	local line_text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ""
	local line_len = #line_text
	col_start = math.min(col_start, line_len)

	local col_end = hl.col_end
	if not col_end or col_end < 0 then
		col_end = line_len
	end
	col_end = math.max(col_start, math.min(col_end, line_len))

	local opts = {
		priority = hl.priority,
	}

	if vim.hl and vim.hl.range then
		vim.hl.range(buf, namespace, hl.group, { line, col_start }, { line, col_end }, opts)
	else
		vim.api.nvim_buf_set_extmark(buf, namespace, line, col_start, vim.tbl_extend("force", opts, {
			hl_group = hl.group,
			end_row = line,
			end_col = col_end,
		}))
	end
end

local function set_buffer_lines(buf, lines, opts)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	opts = opts or {}
	local content = (lines and #lines > 0) and lines or { "" }

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
	if opts.filetype then
		vim.api.nvim_set_option_value("filetype", opts.filetype, { buf = buf })
	end
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

local function compute_dimensions()
	local columns = vim.o.columns
	local lines = vim.o.lines
	local width = math.min(math.floor(columns * 0.9), columns - 4)
	local height = math.min(math.floor(lines * 0.85), lines - 4)
	width = math.max(width, 80)
	height = math.max(height, 24)
	local row = math.max(math.floor((lines - height) / 2) - 1, 1)
	local col = math.max(math.floor((columns - width) / 2), 1)
	return { width = width, height = height, row = row, col = col }
end

local function get_dimensions()
	if not state.dimensions then
		state.dimensions = compute_dimensions()
	end
	return state.dimensions
end

local function ensure_autocmd_group()
	if state.autocmd_group and pcall(vim.api.nvim_get_autocmds, { group = state.autocmd_group }) then
		return state.autocmd_group
	end
	state.autocmd_group = vim.api.nvim_create_augroup("MyLazyGitUI", { clear = true })
	return state.autocmd_group
end

local function create_root()
	local dims = compute_dimensions()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("filetype", "mylazygit-root", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = dims.width,
		height = dims.height,
		row = dims.row,
		col = dims.col,
		border = "rounded",
		style = "minimal",
		zindex = 40,
	})

	state.root = { buf = buf, win = win }
	state.dimensions = dims
	ensure_autocmd_group()

	return state.root
end

local function apply_navigation(buf)
	if not buf then
		return
	end
	local function next_window()
		M.focus_next()
	end
	local function prev_window()
		M.focus_prev()
	end
	vim.keymap.set("n", "<Tab>", next_window, { buffer = buf, silent = true, nowait = true })
	vim.keymap.set("n", "<S-Tab>", prev_window, { buffer = buf, silent = true, nowait = true })
end

local function track_focus(name, win)
	if not win then
		return
	end
	local group = ensure_autocmd_group()
	vim.api.nvim_create_autocmd("WinEnter", {
		group = group,
		callback = function(args)
			local triggered_win = (args and args.win) or vim.api.nvim_get_current_win()
			if triggered_win ~= win then
				return
			end

			for idx, target in ipairs(state.focus_order) do
				if target == name then
					state.focus_index = idx
					break
				end
			end
		end,
	})
end

local function create_section(name, opts)
	opts = opts or {}
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", opts.filetype or "mylazygit", { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	local win = vim.api.nvim_open_win(buf, false, {
		relative = "win",
		win = state.root.win,
		width = opts.width,
		height = opts.height,
		row = opts.row,
		col = opts.col,
		border = opts.border or "rounded",
		style = "minimal",
		title = opts.title,
		title_pos = opts.title_pos or "left",
		noautocmd = true,
		zindex = 60,
	})

	vim.api.nvim_set_option_value("cursorline", opts.cursorline or false, { win = win })
	vim.api.nvim_set_option_value("wrap", opts.wrap or false, { win = win })
	vim.api.nvim_set_option_value("number", false, { win = win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = win })

	local section = { buf = buf, win = win, title = opts.title }
	state.sections[name] = section

	if opts.navigate then
		apply_navigation(buf)
		track_focus(name, win)
	end

	return section
end

local function create_sections()
	local dims = get_dimensions()
	if not dims then
		return
	end
	local inner_width = math.max((dims.width or 0) - 4, 40)
	local inner_height = math.max((dims.height or 0) - 4, 20)
	local left_col = 2
	local right_padding = 2
	local left_width = math.floor(inner_width * 0.35)
	local right_width = inner_width - left_width - right_padding
	local right_col = left_col + left_width + right_padding

	local info_height = 2
	local keymap_height = 3
	local content_row = info_height + 1
	local gap = 1
	local available_height = inner_height - content_row - keymap_height - gap

	local worktree_height = math.max(6, math.floor(available_height * 0.45))
	local commits_height = math.max(5, math.floor(available_height * 0.25))
	local diff_height = math.max(5, available_height - worktree_height - commits_height - gap * 2)
	local preview_height = worktree_height + commits_height + diff_height + gap * 2

	create_section("worktree", {
		width = left_width,
		height = worktree_height,
		row = content_row,
		col = left_col,
		title = " Worktree ",
		cursorline = true,
		filetype = "mylazygit-worktree",
		navigate = true,
	})

	create_section("commits", {
		width = left_width,
		height = commits_height,
		row = content_row + worktree_height + gap,
		col = left_col,
		title = " Commits ",
		filetype = "mylazygit-commits",
		navigate = true,
	})

	create_section("diff", {
		width = left_width,
		height = diff_height,
		row = content_row + worktree_height + commits_height + gap * 2,
		col = left_col,
		title = " Diff preview ",
		filetype = "mylazygit-diffsummary",
		navigate = true,
	})

	create_section("preview", {
		width = right_width,
		height = preview_height,
		row = content_row,
		col = right_col,
		title = " Preview ",
		filetype = "diff",
		wrap = false,
		navigate = true,
	})

	create_section("keymap", {
		width = inner_width,
		height = keymap_height,
		row = content_row + preview_height + gap,
		col = left_col,
		title = " Keymap ",
		filetype = "mylazygit-keymap",
		title_pos = "center",
		wrap = true,
	})
end

local function set_section_title(name, title)
	local section = state.sections[name]
	if not section or not title then
		return
	end
	if not section.win or not vim.api.nvim_win_is_valid(section.win) then
		return
	end
	local cfg = vim.api.nvim_win_get_config(section.win)
	cfg.title = title
	cfg.title_pos = cfg.title_pos or "left"
	vim.api.nvim_win_set_config(section.win, cfg)
	section.title = title
end

local function apply_highlights(buf, highlights)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	for _, hl in ipairs(highlights or {}) do
		add_highlight(buf, hl)
	end
end

local function handle_worktree_cursor(line, opts)
	if not state.worktree_map[line] then
		if opts and opts.force then
			state.current_file = nil
			if state.handlers.on_worktree_select then
				state.handlers.on_worktree_select(nil)
			else
				M.reset_preview()
			end
		end
		return
	end
	local file = state.worktree_map[line].file
	if not file then
		return
	end
	if file == state.current_file and not (opts and opts.force) then
		return
	end
	state.current_file = file
	state.current_worktree_line = line
	if state.handlers.on_worktree_select then
		state.handlers.on_worktree_select(file)
	end
end

local function attach_worktree_listener(buf, win)
	local group = ensure_autocmd_group()
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = buf,
		callback = function()
			if not vim.api.nvim_win_is_valid(win) then
				return
			end
			local line = vim.api.nvim_win_get_cursor(win)[1]
			handle_worktree_cursor(line, { force = false })
		end,
	})
end

local function render_info(info)
	if not state.root or not vim.api.nvim_buf_is_valid(state.root.buf) then
		return
	end
	local lines = {}
	if info and info.branch then
		table.insert(lines, info.branch)
	else
		table.insert(lines, "Branch: -")
	end
	if info and info.details then
		for _, detail in ipairs(info.details) do
			table.insert(lines, detail)
		end
	else
		table.insert(lines, "")
	end
	lines = pad_lines(lines, state.dimensions.height)
	set_buffer_lines(state.root.buf, lines, { filetype = "mylazygit-root" })
end

local function render_worktree(data)
	local section = state.sections.worktree
	if not section then
		return
	end
	local items = data.items or {}
	state.worktree_map = {}
	for idx, item in ipairs(items) do
		state.worktree_map[idx] = item
	end

	local previous_line = state.current_worktree_line or 1
	local lines = data.lines or {}
	if vim.tbl_isempty(lines) then
		lines = { "Working tree clean" }
	end

	set_section_title("worktree", data.title or section.title or " Worktree ")
	set_buffer_lines(section.buf, lines, { filetype = "mylazygit-worktree" })
	apply_highlights(section.buf, data.highlights)

	if data.cursorline_disabled then
		vim.api.nvim_set_option_value("cursorline", false, { win = section.win })
	else
		vim.api.nvim_set_option_value("cursorline", true, { win = section.win })
	end

	local total_items = math.max(#items, 1)
	local target_line = math.min(previous_line, total_items)
	state.current_worktree_line = target_line
	vim.api.nvim_win_set_cursor(section.win, { target_line, 0 })
	if section.buf and not section.listener_attached then
		attach_worktree_listener(section.buf, section.win)
		section.listener_attached = true
	end
	if #items > 0 then
		handle_worktree_cursor(target_line, { force = true })
	else
		state.current_file = nil
	end
end

local function render_commits(data)
	local section = state.sections.commits
	if not section then
		return
	end
	local lines = data.lines or {}
	if vim.tbl_isempty(lines) then
		lines = { "No commits found" }
	end
	set_section_title("commits", data.title or section.title or " Commits ")
	set_buffer_lines(section.buf, lines, { filetype = "mylazygit-commits" })
	apply_highlights(section.buf, data.highlights)
end

local function render_diff(data)
	local section = state.sections.diff
	if not section then
		return
	end
	local lines = data.lines or {}
	if vim.tbl_isempty(lines) then
		lines = { "Working tree clean" }
	end
	set_section_title("diff", data.title or section.title or " Diff preview ")
	set_buffer_lines(section.buf, lines, { filetype = "mylazygit-diffsummary" })
end

local function render_keymap(data)
	local section = state.sections.keymap
	if not section then
		return
	end
	local lines = data.lines or {}
	if vim.tbl_isempty(lines) then
		lines = { "No keymaps registered" }
	end
	set_buffer_lines(section.buf, lines, { filetype = "mylazygit-keymap" })
end

local function render_preview(data)
	if not data then
		return
	end
	M.show_preview(data.lines, { title = data.title, filetype = data.filetype })
end

local function apply_keymaps()
	if vim.tbl_isempty(state.keymaps) then
		return
	end
	local targets = {}
	if state.root and vim.api.nvim_buf_is_valid(state.root.buf) then
		table.insert(targets, state.root.buf)
	end
	for _, section in pairs(state.sections) do
		if section.buf and vim.api.nvim_buf_is_valid(section.buf) then
			table.insert(targets, section.buf)
		end
	end

	for _, buf in ipairs(targets) do
		for _, map in ipairs(state.keymaps) do
			if map.lhs and map.rhs then
				vim.keymap.set("n", map.lhs, map.rhs, {
					buffer = buf,
					silent = true,
					nowait = true,
					desc = map.desc,
				})
			end
		end
	end
end

function M.is_open()
	return state.root and state.root.win and vim.api.nvim_win_is_valid(state.root.win)
end

local function focus_by_index(index)
	local name = state.focus_order[index]
	if not name then
		return
	end
	local section = state.sections[name]
	if not section or not section.win or not vim.api.nvim_win_is_valid(section.win) then
		return
	end
	state.focus_index = index
	vim.api.nvim_set_current_win(section.win)
end

function M.focus_next()
	if vim.tbl_isempty(state.focus_order) then
		return
	end
	local next_index = (state.focus_index % #state.focus_order) + 1
	focus_by_index(next_index)
end

function M.focus_prev()
	if vim.tbl_isempty(state.focus_order) then
		return
	end
	local prev_index = state.focus_index - 1
	if prev_index < 1 then
		prev_index = #state.focus_order
	end
	focus_by_index(prev_index)
end

function M.focus(name)
	for idx, target in ipairs(state.focus_order) do
		if target == name then
			focus_by_index(idx)
			break
		end
	end
end

function M.show_preview(lines, opts)
	local section = state.sections.preview
	if not section then
		return
	end
	local content = (lines and #lines > 0) and lines or { "Select a file from the worktree list to preview changes." }
	opts = opts or {}
	local preview_opts = { filetype = opts.filetype or "diff" }
	set_buffer_lines(section.buf, content, preview_opts)
	set_section_title("preview", opts.title or section.title or " Preview ")
end

function M.reset_preview()
	M.show_preview({
		"Select a file from Worktree to see the live diff preview.",
	}, { title = " Preview " })
end

function M.render(payload)
	if not M.is_open() then
		return
	end
	render_info(payload.info)
	render_worktree(payload.worktree or {})
	render_commits(payload.commits or {})
	render_diff(payload.diff or {})
	render_preview(payload.preview or {})
	render_keymap(payload.keymap or {})
end

function M.open()
	if M.is_open() then
		M.focus("worktree")
		return state.root.buf, state.root.win
	end
	create_root()
	create_sections()
	apply_keymaps()
	M.reset_preview()
	M.focus("worktree")
	return state.root.buf, state.root.win
end

function M.close()
	for _, section in pairs(state.sections) do
		if section.win and vim.api.nvim_win_is_valid(section.win) then
			vim.api.nvim_win_close(section.win, true)
		end
		if section.buf and vim.api.nvim_buf_is_valid(section.buf) then
			vim.api.nvim_buf_delete(section.buf, { force = true })
		end
	end
	state.sections = {}
	state.worktree_map = {}
	state.current_file = nil
	state.current_worktree_line = 1
	state.focus_index = 1

	if state.root then
		if state.root.win and vim.api.nvim_win_is_valid(state.root.win) then
			vim.api.nvim_win_close(state.root.win, true)
		end
		if state.root.buf and vim.api.nvim_buf_is_valid(state.root.buf) then
			vim.api.nvim_buf_delete(state.root.buf, { force = true })
		end
	end
	state.root = nil

	if state.autocmd_group then
		pcall(vim.api.nvim_del_augroup_by_id, state.autocmd_group)
		state.autocmd_group = nil
	end
end

function M.set_keymaps(mappings)
	state.keymaps = mappings or {}
	if M.is_open() then
		apply_keymaps()
	end
end

function M.set_handlers(handlers)
	state.handlers = handlers or {}
end

return M
