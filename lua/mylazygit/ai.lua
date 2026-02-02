local git = require("mylazygit.git")

local M = {}

local default_config = {
	model = "google/gemini-2.5-flash-lite",
	base_url = "https://openrouter.ai/api/v1/chat/completions",
	headers = {
		["HTTP-Referer"] = "https://github.com/morre95/mylazygit.nvim",
		["X-Title"] = "MyLazyGit",
	},
	temperature = 0.2,
	max_tokens = 200,
	diff_max_lines = 400,
	request_timeout = 30,
}

local config = vim.deepcopy(default_config)

local state = {
	model = config.model,
	commands_registered = false,
}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "MyLazyGit AI" })
end

local function ensure_model()
	if state.model and state.model ~= "" then
		return state.model
	end
	state.model = config.model
	return state.model
end

local function limit_lines(lines, max_lines)
	if not max_lines or #lines <= max_lines then
		return lines
	end
	local trimmed = {}
	for i = 1, max_lines - 1 do
		trimmed[i] = lines[i]
	end
	trimmed[max_lines] = string.format("... truncated %d additional staged diff lines ...", #lines - (max_lines - 1))
	return trimmed
end

local function staged_diff()
	local diff_lines = git.diff({ "--cached" })
	if vim.tbl_isempty(diff_lines) then
		return nil
	end
	return limit_lines(diff_lines, config.diff_max_lines or #diff_lines)
end

local function get_api_key()
	local key = config.api_key or vim.env.OPENROUTER_API_KEY
	if not key or key == "" then
		return nil
	end
	return key
end

local function encode_messages(diff_text)
	local payload = {
		model = ensure_model(),
		temperature = config.temperature,
		max_tokens = config.max_tokens,
		messages = {
			{
				role = "system",
				content = table.concat({
					"You are an expert release engineer who writes conventional git commit messages.",
					"Limit the subject line to 72 characters, prefer active voice, and keep it lowercase except for proper nouns.",
					"If multiple themes exist, add a short body with bullet points.",
				}, " "),
			},
			{
				role = "user",
				content = string.format(
					"Generate a commit message describing these staged changes:\n\n%s\n\nOnly answer with the commit message.",
					diff_text
				),
			},
		},
	}

	local ok, encoded = pcall(vim.json.encode, payload)
	if not ok then
		return nil, encoded
	end
	return encoded, nil
end

local function decode_message(body)
	if not body then
		return nil, "Empty response from OpenRouter"
	end

	local ok, decoded = pcall(vim.json.decode, body)
	if not ok then
		return nil, "Failed to decode OpenRouter response: " .. decoded
	end

	if decoded.error then
		local details = type(decoded.error) == "table" and decoded.error.message or decoded.error
		return nil, details or "OpenRouter returned an error"
	end

	local choice = decoded.choices and decoded.choices[1]
	if not choice or not choice.message then
		return nil, "OpenRouter response did not include a completion"
	end

	local content = choice.message.content
	if type(content) == "string" then
		return vim.trim(content)
	end

	if type(content) == "table" then
		local parts = {}
		for _, chunk in ipairs(content) do
			if type(chunk) == "table" and chunk.type == "text" and chunk.text then
				table.insert(parts, chunk.text)
			elseif type(chunk) == "string" then
				table.insert(parts, chunk)
			end
		end
		if #parts > 0 then
			return vim.trim(table.concat(parts, "\n"))
		end
	end

	return nil, "OpenRouter response contained no text"
end

local function call_openrouter(diff_text)
	local api_key = get_api_key()
	if not api_key then
		return nil, "Set OPENROUTER_API_KEY or configure mylazygit.ai.api_key"
	end

	local payload, encode_err = encode_messages(diff_text)
	if not payload then
		return nil, encode_err
	end

	local cmd = {
		"curl",
		"-sS",
		"-X",
		"POST",
		config.base_url,
		"-H",
		"Authorization: Bearer " .. api_key,
		"-H",
		"Content-Type: application/json",
	}

	for header, value in pairs(config.headers or {}) do
		if value and value ~= "" then
			table.insert(cmd, "-H")
			table.insert(cmd, string.format("%s: %s", header, value))
		end
	end

	if config.request_timeout and config.request_timeout > 0 then
		table.insert(cmd, "--max-time")
		table.insert(cmd, tostring(config.request_timeout))
	end

	table.insert(cmd, "--data-raw")
	table.insert(cmd, payload)

	local response = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		local err = vim.trim(response or "")
		if err == "" then
			err = string.format("curl exited with code %d", vim.v.shell_error)
		end
		return nil, err
	end

	return decode_message(response)
end

local function split_subject_body(message)
	local trimmed = vim.trim(message or "")
	if trimmed == "" then
		return trimmed, nil
	end

	local subject, body = trimmed:match("([^\n]+)%s*\n+(.+)")
	if subject then
		return vim.trim(subject), vim.trim(body)
	else
		return trimmed, nil
	end
end

function M.generate_commit_message()
	if not git.is_repo() then
		notify("MyLazyGit AI requires a git repository", vim.log.levels.WARN)
		return
	end

	local diff_lines = staged_diff()
	if not diff_lines then
		local status_items = git.status() or {}
		if not vim.tbl_isempty(status_items) then
			-- Offer to stage everything so the user can immediately retry.
			vim.ui.select({ "Yes", "No" }, {
				prompt = "No staged changes detected. Stage all changes and continue?",
			}, function(choice)
				if choice ~= "Yes" then
					notify(
						"No staged changes detected. Stage files before asking for a commit message.",
						vim.log.levels.INFO
					)
					return
				end

				local ok = select(1, git.stage({ "." }))
				if not ok then
					notify("Failed to stage changes", vim.log.levels.ERROR)
					return
				end

				notify("Changes staged. Retrying commit message generation …")
				vim.schedule(function()
					M.generate_commit_message()
				end)
			end)
		else
			notify("No staged changes detected. Stage files before asking for a commit message.", vim.log.levels.INFO)
		end
		return
	end

	local diff_text = table.concat(diff_lines, "\n")
	notify(string.format("Generating commit message with %s …", ensure_model()))
	local message, err = call_openrouter(diff_text)
	if not message then
		notify("OpenRouter request failed: " .. err, vim.log.levels.ERROR)
		return
	end

	local subject, body = split_subject_body(message)
	if subject == "" then
		notify("OpenRouter returned an empty commit suggestion", vim.log.levels.WARN)
		return
	end

	vim.ui.input({
		prompt = "AI commit message:",
		default = subject,
	}, function(input)
		local final_subject = input and vim.trim(input) or ""
		if final_subject == "" then
			notify("Commit cancelled", vim.log.levels.INFO)
			return
		end

		local final_message = final_subject
		if body and body ~= "" then
			final_message = string.format("%s\n\n%s", final_subject, body)
		end

		local ok = select(1, git.commit(final_message))
		if ok then
			notify("Commit created with AI generated message")
		end
	end)
end

function M.switch_model(model)
	if not model or vim.trim(model) == "" then
		notify("Provide a non-empty model id", vim.log.levels.WARN)
		return false
	end
	state.model = vim.trim(model)
	notify(string.format("MyLazyGit AI model set to %s", state.model))
	return true
end

local function prompt_model_switch()
	vim.ui.input({
		prompt = "OpenRouter model id:",
		default = ensure_model(),
	}, function(input)
		if not input or vim.trim(input) == "" then
			return
		end
		M.switch_model(input)
	end)
end

local function register_commands()
	if state.commands_registered then
		return
	end

	vim.api.nvim_create_user_command("MyLazyGitAICommit", function()
		M.generate_commit_message()
	end, { desc = "Generate a commit message from staged changes using OpenRouter" })

	vim.api.nvim_create_user_command("MyLazyGitAISwitchModel", function()
		prompt_model_switch()
	end, { desc = "Switch the OpenRouter model used for AI commit messages" })

	state.commands_registered = true
end

function M.setup(opts)
	opts = opts or {}
	config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), opts)
	state.model = config.model or default_config.model
	register_commands()
end

return M
