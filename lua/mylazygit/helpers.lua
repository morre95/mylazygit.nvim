local M = {}

function M.centered_input(opts, on_confirm)
	opts = opts or {}
	local prompt = (opts.prompt or "Input") .. ": "

	local width = math.min(math.max(#prompt + 80, 40), math.floor(vim.o.columns * 0.7))
	local height = 1
	local row = math.floor((vim.o.lines - height) / 2) - 1
	local col = math.floor((vim.o.columns - width) / 2)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "prompt", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = opts.title or prompt:gsub(":%s*$", ""),
		title_pos = "center",
		noautocmd = true,
		zindex = 100,
	})

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end

	vim.fn.prompt_setprompt(buf, prompt)
	vim.fn.prompt_setcallback(buf, function(input)
		close()
		vim.cmd.stopinsert()
		if on_confirm then
			on_confirm(input)
		end
	end)

	vim.keymap.set("i", "<Esc>", function()
		close()
		vim.cmd.stopinsert()
		if on_confirm then
			on_confirm(nil)
		end
	end, { buffer = buf, nowait = true })
	vim.keymap.set("i", "<C-c>", function()
		close()
		vim.cmd.stopinsert()
		if on_confirm then
			on_confirm(nil)
		end
	end, { buffer = buf, nowait = true })

	vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:FloatBorder", { win = win })
	vim.api.nvim_set_option_value("cursorline", false, { win = win })
	vim.api.nvim_set_option_value("number", false, { win = win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = win })

	vim.cmd.startinsert()
end

function M.centered_dual_input(opts, on_confirm)
	opts = opts or {}

	local prompt1 = (opts.prompt1 or "First") .. ": "
	local prompt2 = (opts.prompt2 or "Second") .. ": "
	local default1 = opts.default1 or ""
	local default2 = opts.default2 or ""

	local title = opts.title or "Input"

	-- Compute sizing
	local content_w = math.max(#(prompt1 .. default1), #(prompt2 .. default2))
	local width = math.min(math.max(content_w + 40, 80), math.floor(vim.o.columns * 0.7))
	local height = 2

	local row = math.floor((vim.o.lines - height) / 2) - 1
	local col = math.floor((vim.o.columns - width) / 2)

	-- Buffer and window
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = title,
		title_pos = "center",
		noautocmd = true,
		zindex = 100,
	})

	-- Style adjustments
	vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:FloatBorder", { win = win })
	vim.api.nvim_set_option_value("cursorline", false, { win = win })
	vim.api.nvim_set_option_value("number", false, { win = win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = win })

	-- Close helper
	local function close()
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end

	-- Handle cancel
	local function cancel()
		close()
		vim.cmd.stopinsert()
		if on_confirm then
			on_confirm(nil, nil)
		end
	end

	vim.keymap.set("i", "<Esc>", cancel, { buffer = buf, nowait = true })
	vim.keymap.set("i", "<C-c>", cancel, { buffer = buf, nowait = true })

	-- Two-line prompt
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		prompt1 .. default1,
		prompt2 .. default2,
	})

	-- Extract user input from a line, even if the prompt was partially deleted.
	local function strip_prompt(line, prompt)
		if line:sub(1, #prompt) == prompt then
			return line:sub(#prompt + 1)
		end

		for i = #prompt - 1, 1, -1 do
			local prefix = prompt:sub(1, i)
			if line:sub(1, i) == prefix then
				return line:sub(i + 1)
			end
		end

		for i = 2, #prompt do
			local suffix = prompt:sub(i)
			if suffix ~= "" and line:sub(1, #suffix) == suffix then
				return line:sub(#suffix + 1)
			end
		end

		return line
	end

	local function get_lines()
		if not vim.api.nvim_buf_is_valid(buf) then
			return nil
		end
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		if not lines or #lines < 2 then
			return nil
		end
		return lines
	end

	local function submit()
		local lines = get_lines()
		if not lines then
			cancel()
			return
		end

		local v1 = strip_prompt(lines[1], prompt1)
		local v2 = strip_prompt(lines[2], prompt2)

		close()
		vim.cmd.stopinsert()

		if on_confirm then
			on_confirm(v1, v2)
		end
	end

	-- Put cursor after default1 on line 1
	local function focus_line(idx)
		if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf)) then
			return
		end
		local line = vim.api.nvim_buf_get_lines(buf, idx - 1, idx, false)[1] or ""
		pcall(vim.api.nvim_win_set_cursor, win, { idx, math.max(#line, 0) })
	end

	local function toggle_focus()
		if not vim.api.nvim_win_is_valid(win) then
			return
		end
		local cursor = vim.api.nvim_win_get_cursor(win)
		if cursor[1] == 1 then
			focus_line(2)
		else
			focus_line(1)
		end
	end

	local function ensure_prompt(line_idx, prompt)
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
		if line:sub(1, #prompt) ~= prompt then
			local value = strip_prompt(line, prompt)
			vim.api.nvim_buf_set_lines(buf, line_idx - 1, line_idx, false, { prompt .. value })
		end
	end

	local function enforce_prompts()
		ensure_prompt(1, prompt1)
		ensure_prompt(2, prompt2)
	end

	local function clamp_cursor()
		if not vim.api.nvim_win_is_valid(win) then
			return
		end
		local cursor = vim.api.nvim_win_get_cursor(win)
		local prompt = cursor[1] == 1 and prompt1 or prompt2
		local min_col = #prompt
		if cursor[2] < min_col then
			vim.api.nvim_win_set_cursor(win, { cursor[1], min_col })
		end
	end

	local augroup = vim.api.nvim_create_augroup("CenteredDualInput" .. buf, { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = buf,
		group = augroup,
		callback = function()
			enforce_prompts()
			clamp_cursor()
		end,
	})
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		buffer = buf,
		group = augroup,
		callback = clamp_cursor,
	})

	vim.defer_fn(function()
		focus_line(1)
	end, 1)

	vim.keymap.set("i", "<CR>", function()
		local cursor = vim.api.nvim_win_get_cursor(win)
		if cursor[1] == 1 then
			focus_line(2)
		else
			submit()
		end
	end, { buffer = buf, nowait = true })

	vim.keymap.set("i", "<Tab>", toggle_focus, { buffer = buf, nowait = true })
	vim.keymap.set("i", "<S-Tab>", toggle_focus, { buffer = buf, nowait = true })

	vim.cmd.startinsert()
end

function M.centered_dual_input2(opts, on_confirm)
	local defaults = {
		prompt1 = "Input 1",
		prompt2 = "Input 2",
		title = "Input",
		default1 = "",
		default2 = "",
	}
	opts = vim.tbl_deep_extend("force", defaults, opts or {})

	local prompt1 = opts.prompt1
	local prompt2 = opts.prompt2
	local width = math.min(math.max(math.max(#prompt1, #prompt2) + 80, 40), math.floor(vim.o.columns * 0.7))
	local height = 4 -- 2 rader för prompts + 2 rader för input
	local row = math.floor((vim.o.lines - height) / 2) - 1
	local col = math.floor((vim.o.columns - width) / 2)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = opts.title or "Input",
		title_pos = "center",
		noautocmd = true,
		zindex = 100,
	})

	-- Sätt upp innehållet
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		prompt1 .. ": " .. (opts.default1 or ""),
		"",
		prompt2 .. ": " .. (opts.default2 or ""),
		"",
	})

	-- Placera cursor på första input-raden
	vim.api.nvim_win_set_cursor(win, { 1, #prompt1 + 2 })

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end

	local function get_values()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local value1 = lines[1]:sub(#prompt1 + 3)
		local value2 = lines[3]:sub(#prompt2 + 3)
		return value1, value2
	end

	local function submit()
		local value1, value2 = get_values()
		close()
		vim.cmd.stopinsert()
		if on_confirm then
			on_confirm(value1, value2)
		end
	end

	local function cancel()
		close()
		vim.cmd.stopinsert()
		if on_confirm then
			on_confirm(nil, nil)
		end
	end

	-- Keymaps
	vim.keymap.set("i", "<CR>", function()
		local cursor = vim.api.nvim_win_get_cursor(win)
		if cursor[1] == 1 then
			-- På första raden, gå till andra
			vim.api.nvim_win_set_cursor(win, { 3, #prompt2 + 2 })
		else
			-- På andra raden, submit
			submit()
		end
	end, { buffer = buf, nowait = true })

	vim.keymap.set("i", "<Tab>", function()
		local cursor = vim.api.nvim_win_get_cursor(win)
		if cursor[1] == 1 then
			vim.api.nvim_win_set_cursor(win, { 3, #prompt2 + 2 })
		else
			vim.api.nvim_win_set_cursor(win, { 1, #prompt1 + 2 })
		end
	end, { buffer = buf, nowait = true })

	vim.keymap.set("i", "<S-Tab>", function()
		local cursor = vim.api.nvim_win_get_cursor(win)
		if cursor[1] == 3 then
			vim.api.nvim_win_set_cursor(win, { 1, #prompt1 + 2 })
		else
			vim.api.nvim_win_set_cursor(win, { 3, #prompt2 + 2 })
		end
	end, { buffer = buf, nowait = true })

	vim.keymap.set("i", "<Esc>", cancel, { buffer = buf, nowait = true })
	vim.keymap.set("i", "<C-c>", cancel, { buffer = buf, nowait = true })

	-- Styling
	vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:FloatBorder", { win = win })
	vim.api.nvim_set_option_value("cursorline", false, { win = win })
	vim.api.nvim_set_option_value("number", false, { win = win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = win })

	vim.cmd.startinsert()
end

return M
