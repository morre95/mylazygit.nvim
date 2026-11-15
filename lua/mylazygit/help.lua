-- Searchable keymap help: a search field above a grouped keymap list and its explanation pane.
local M = {}

local ns = vim.api.nvim_create_namespace("mylazygit_help")
local HAS_FOOTER = vim.fn.has("nvim-0.10") == 1
local UNGROUPED = "Other"
local SEARCH_HINT = "Press / to search keys, names and explanations"
local LIST_FOOTER = " / search · j/k move · q close "

local function define_highlights()
	local links = { MyLazyGitHelpGroup = "Title", MyLazyGitHelpKey = "Special", MyLazyGitHelpHint = "Comment" }
	for name, link in pairs(links) do
		vim.api.nvim_set_hl(0, name, { link = link, default = true })
	end
end

local function explain_lines(map)
	if type(map.explain) == "string" then
		return vim.split(map.explain, "\n", { plain = true })
	elseif type(map.explain) == "table" then
		return vim.list_extend({}, map.explain)
	end
	return { "No explanation available" }
end

local function build_entries(mappings)
	local entries, group_order, seen = {}, {}, {}
	for _, map in ipairs(mappings) do
		local group = map.group or UNGROUPED
		if not seen[group] then
			seen[group] = true
			table.insert(group_order, group)
		end
		local label = string.format("[%s]", map.lhs or "")
		local haystack = table.concat({ map.lhs or "", map.desc or "", group, table.concat(explain_lines(map), "\n") }, "\n")
		local name = (map.lhs or "") .. "\n" .. (map.desc or "")
		table.insert(entries, {
			map = map,
			group = group,
			label = label,
			name = { exact = name, lower = name:lower() },
			haystack = { exact = haystack, lower = haystack:lower() },
		})
	end
	return entries, group_order
end

-- Every whitespace-separated token must occur; a token with an uppercase letter is case-sensitive.
local function matches(text, tokens)
	for _, token in ipairs(tokens) do
		if not (token:find("%u") and text.exact or text.lower):find(token, 1, true) then
			return false
		end
	end
	return true
end

local function build_rows(entries, group_order, tokens, key_width)
	local by_group = {}
	for _, entry in ipairs(entries) do
		if matches(entry.haystack, tokens) then
			by_group[entry.group] = by_group[entry.group] or {}
			table.insert(by_group[entry.group], entry)
		end
	end
	local rows = {}
	for _, group in ipairs(group_order) do
		if by_group[group] then
			if #rows > 0 then
				table.insert(rows, { text = "" })
			end
			table.insert(rows, { text = group, is_group = true })
			for _, entry in ipairs(by_group[group]) do
				local text = string.format("  %-" .. key_width .. "s  %s", entry.label, entry.map.desc or "")
				table.insert(rows, { text = text, entry = entry })
			end
		end
	end
	return rows
end

local function set_lines(buf, lines)
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

local function open_float(buf, enter, opts)
	local config = vim.tbl_extend("force", { relative = "editor", border = "rounded", style = "minimal", zindex = 120 }, opts)
	if not HAS_FOOTER then
		config.footer = nil
	end
	return vim.api.nvim_open_win(buf, enter, config)
end

function M.open(mappings)
	if vim.tbl_isempty(mappings or {}) then
		return
	end
	define_highlights()

	local entries, group_order = build_entries(mappings)
	local key_width = 0
	for _, entry in ipairs(entries) do
		key_width = math.max(key_width, #entry.label)
	end
	local rows = build_rows(entries, group_order, {}, key_width)

	-- Layout: the search field spans the list and explanation panes below it.
	local list_width = 0
	for _, row in ipairs(rows) do
		list_width = math.max(list_width, vim.fn.strdisplaywidth(row.text))
	end
	list_width = math.min(math.max(list_width + 2, 32), math.floor(vim.o.columns * 0.45))
	local preview_width = math.max(20, math.min(math.max(48, math.floor(vim.o.columns * 0.45)), vim.o.columns - list_width - 8))
	local height = math.max(1, math.min(#rows, vim.o.lines - 9))
	local total_width = list_width + preview_width + 2
	local row = math.max(math.floor((vim.o.lines - height - 3) / 2) - 1, 0)
	local col = math.max(math.floor((vim.o.columns - total_width - 2) / 2), 0)

	local origin = vim.api.nvim_get_current_win()
	local buf_search = vim.api.nvim_create_buf(false, true)
	local buf_list = vim.api.nvim_create_buf(false, true)
	local buf_prev = vim.api.nvim_create_buf(false, true)
	for buf, filetype in pairs({ [buf_search] = "mylazygit-help-search", [buf_list] = "mylazygit-help", [buf_prev] = "mylazygit-explain" }) do
		vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
		vim.api.nvim_set_option_value("filetype", filetype, { buf = buf })
	end

	local win_search = open_float(buf_search, false, { width = total_width, height = 1, row = row, col = col, title = " Search " })
	local win_list = open_float(buf_list, true, {
		width = list_width,
		height = height,
		row = row + 3,
		col = col,
		title = " Keymaps ",
		footer = LIST_FOOTER,
	})
	local win_prev = open_float(buf_prev, false, {
		width = preview_width,
		height = height,
		row = row + 3,
		col = col + list_width + 2,
		focusable = false,
	})
	vim.api.nvim_set_option_value("cursorline", true, { win = win_list })
	vim.api.nvim_set_option_value("wrap", true, { win = win_prev })
	vim.api.nvim_set_option_value("linebreak", true, { win = win_prev })
	vim.api.nvim_set_option_value("breakindent", true, { win = win_prev })

	local last_line = 1

	local function query()
		return vim.trim(vim.api.nvim_buf_get_lines(buf_search, 0, 1, false)[1] or "")
	end

	local function render_preview(entry)
		local lines
		if entry then
			local title = string.format("%s %s", entry.label, entry.map.desc or "")
			lines = explain_lines(entry.map)
			table.insert(lines, 1, title)
			table.insert(lines, 2, string.rep("—", math.min(vim.fn.strdisplaywidth(title), preview_width - 2)))
		elseif #rows == 0 then
			lines = { "Nothing matches. Try a shorter or different word." }
		else
			lines = { "Move the cursor to a keymap to see its explanation." }
		end
		set_lines(buf_prev, lines)
		vim.api.nvim_win_set_cursor(win_prev, { 1, 0 })
	end

	-- Group headings and blank lines are not selectable: find the closest keymap row.
	local function nearest_entry_line(line, direction)
		for _, step in ipairs({ direction, -direction }) do
			local index = line
			while rows[index] and not rows[index].entry do
				index = index + step
			end
			if rows[index] then
				return index
			end
		end
	end

	local function select_line(line)
		vim.api.nvim_win_set_cursor(win_list, { line, 0 })
		last_line = line
		render_preview(rows[line] and rows[line].entry)
	end

	local function render_list()
		local selected_row = rows[vim.api.nvim_win_get_cursor(win_list)[1]]
		local selected = selected_row and selected_row.entry
		local text = query()
		local tokens = text == "" and {} or vim.split(text, "%s+")
		rows = build_rows(entries, group_order, tokens, key_width)

		local lines = {}
		for _, item in ipairs(rows) do
			table.insert(lines, item.text)
		end
		if #rows == 0 then
			lines = { string.format('No keymaps match "%s"', text) }
		end
		set_lines(buf_list, lines)

		vim.api.nvim_buf_clear_namespace(buf_list, ns, 0, -1)
		local shown, target = 0, nil
		for index, item in ipairs(rows) do
			if item.is_group then
				vim.api.nvim_buf_set_extmark(buf_list, ns, index - 1, 0, { end_col = #item.text, hl_group = "MyLazyGitHelpGroup" })
			elseif item.entry then
				shown = shown + 1
				vim.api.nvim_buf_set_extmark(buf_list, ns, index - 1, 2, { end_col = 2 + #item.entry.label, hl_group = "MyLazyGitHelpKey" })
				-- While searching, prefer a keymap whose key or name matches over explanation-only matches.
				if text == "" and item.entry == selected or text ~= "" and not target and matches(item.entry.name, tokens) then
					target = index
				end
			end
		end
		if #rows == 0 then
			vim.api.nvim_buf_set_extmark(buf_list, ns, 0, 0, { end_col = #lines[1], hl_group = "MyLazyGitHelpHint" })
		end

		vim.api.nvim_buf_clear_namespace(buf_search, ns, 0, -1)
		if text == "" then
			vim.api.nvim_buf_set_extmark(buf_search, ns, 0, 0, { virt_text = { { SEARCH_HINT, "MyLazyGitHelpHint" } }, virt_text_pos = "overlay" })
		end
		local config = { title = string.format(" Keymaps %d/%d ", shown, #entries) }
		if HAS_FOOTER then
			config.footer = LIST_FOOTER
		end
		vim.api.nvim_win_set_config(win_list, config)
		select_line(target or nearest_entry_line(1, 1) or 1)
	end

	local function move_selection(delta)
		local index = vim.api.nvim_win_get_cursor(win_list)[1] + delta
		while rows[index] and not rows[index].entry do
			index = index + delta
		end
		if rows[index] then
			select_line(index)
		end
	end

	local augroup = vim.api.nvim_create_augroup("MyLazyGitHelp", { clear = true })
	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		vim.api.nvim_del_augroup_by_id(augroup)
		vim.cmd("stopinsert")
		for _, win in ipairs({ win_search, win_list, win_prev }) do
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end
		if vim.api.nvim_win_is_valid(origin) then
			vim.api.nvim_set_current_win(origin)
		end
	end

	local function focus_list()
		vim.cmd("stopinsert")
		vim.api.nvim_set_current_win(win_list)
	end

	local function focus_search()
		vim.api.nvim_set_current_win(win_search)
		vim.cmd("startinsert!")
	end

	local function clear_search_or_close()
		if query() == "" then
			close()
		else
			vim.api.nvim_buf_set_lines(buf_search, 0, -1, false, { "" })
			render_list()
		end
	end

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, { group = augroup, buffer = buf_search, callback = render_list })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = augroup,
		buffer = buf_list,
		callback = function()
			local line = vim.api.nvim_win_get_cursor(win_list)[1]
			select_line(nearest_entry_line(line, line >= last_line and 1 or -1) or line)
		end,
	})
	-- Closing any pane another way (:q, <C-w>c) closes the whole help view.
	for _, win in ipairs({ win_search, win_list, win_prev }) do
		vim.api.nvim_create_autocmd("WinClosed", { group = augroup, pattern = tostring(win), callback = vim.schedule_wrap(close) })
	end

	local function map(buf, modes, lhs, rhs)
		vim.keymap.set(modes, lhs, rhs, { buffer = buf, silent = true, nowait = true })
	end
	map(buf_list, "n", "q", close)
	map(buf_list, "n", "<Esc>", clear_search_or_close)
	map(buf_list, "n", "/", focus_search)
	map(buf_search, { "n", "i" }, "<CR>", focus_list)
	map(buf_search, { "n", "i" }, "<Esc>", focus_list)
	for lhs, delta in pairs({ ["<Down>"] = 1, ["<C-n>"] = 1, ["<Up>"] = -1, ["<C-p>"] = -1 }) do
		map(buf_search, { "n", "i" }, lhs, function()
			move_selection(delta)
		end)
	end

	render_list()
end

return M
