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
		if on_confirm then
			on_confirm(input)
		end
	end)

	vim.keymap.set("i", "<Esc>", function()
		close()
		if on_confirm then
			on_confirm(nil)
		end
	end, { buffer = buf, nowait = true })
	vim.keymap.set("i", "<C-c>", function()
		close()
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

return M
