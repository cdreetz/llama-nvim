-- llama-nvim.lua
local M = {}
local curl = require("plenary.curl")
local json = vim.json

-- Configuration
M.config = {
	api_url = "https://api.llama.com/v1/chat/completions", -- Correct API URL
}

M.original_text = nil
M.original_range = nil

-- Debugging function
local function log(message)
	vim.fn.writefile({ tostring(message) }, "/tmp/llama_nvim_debug.log", "a")
end

-- Set up the plugin
function M.setup(opts)
	M.config = vim.tbl_extend("force", M.config, opts or {})
	if not M.config.api_key then
		error("Llama API key not set. Please set it in the setup function.")
	end
	-- Set up commands
	vim.api.nvim_create_user_command("LlamaGenerate", M.generate_code, { nargs = 1 })
	vim.api.nvim_create_user_command(
		"LlamaGenerateWithContext",
		M.generate_code_with_context,
		{ nargs = "+", complete = "file" }
	)
	vim.api.nvim_create_user_command("LlamaEdit", M.edit_code, { range = true, nargs = "?" })
	--vim.api.nvim_create_user_command("LlamaApprove", M.approve_changes, {})

	-- Log setup completion
	log("Llama NVim plugin setup complete with model: " .. (M.config.model or "not set"))
end

-- Helper function to make API calls with streaming
local function call_llama_api_stream(messages, callback)
	local job_id = vim.fn.jobstart({
		"curl",
		"-sS", -- Silent but show errors
		"-N", -- No buffering
		"--no-buffer", -- Additional no buffering flag
		M.config.api_url,
		"-H",
		"Authorization: Bearer " .. M.config.api_key,
		"-H",
		"Content-Type: application/json",
		"-H",
		"Accept: text/event-stream", -- Request SSE format
		"-d",
		json.encode({
			model = M.config.model,
			messages = messages,
			stream = true,
		}),
	}, {
		on_stdout = function(_, data)
			if data then
				for _, line in ipairs(data) do
					if line and line ~= "" then
						-- Process Llama API streaming format specifically
						if line:sub(1, 6) == "data: " then
							local raw_data = line:sub(7)
							if raw_data ~= "[DONE]" then
								local success, parsed_data = pcall(json.decode, raw_data)
								if success then
									-- Check for the Llama-specific event format
									if
										parsed_data.event
										and parsed_data.event.event_type == "progress"
										and parsed_data.event.delta
										and parsed_data.event.delta.text
									then
										-- Extract just the text
										local text = parsed_data.event.delta.text
										callback(text)
									end
								end
							end
						end
					end
				end
			end
		end,
		on_stderr = function(_, data)
			if data and #data > 0 then
				for _, line in ipairs(data) do
					if line and line ~= "" then
						-- Log errors to help with debugging
						vim.fn.writefile({ "STDERR: " .. line }, "/tmp/llama_nvim_debug.log", "a")
					end
				end
			end
		end,
		on_exit = function()
			callback(nil) -- Signal end of stream
		end,
	})

	return job_id
end

-- Function to generate code
function M.generate_code(opts)
	local buffer = ""
	local prompt = opts.args
	log("LlamaGenerate prompt: " .. prompt)

	local messages = {
		{
			role = "system",
			content = "You are a helpful coding assistant. Based on the users prompt, write the code or response. If the user is asking you to write some code, only generate the code they need with no additional formatting or text. The code you generate is written directly to the current file so make sure it is valid code. DO NOT WRAP THE CODE IN BACKTICKS, ONLY WRITE THE REAL CODE.",
		},
		{ role = "user", content = prompt },
	}

	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	log("Starting cursor position: row=" .. row .. ", col=" .. col)

	-- Notify user that generation has started
	vim.api.nvim_echo({ { "Generating code with Llama API...", "WarningMsg" } }, false, {})

	call_llama_api_stream(messages, function(content)
		if content then
			buffer = buffer .. content
			log("Received content chunk: " .. content)
			local new_lines = vim.split(buffer, "\n", true)

			-- Process complete lines, keep last line in buffer if incomplete
			if #new_lines > 1 then
				-- Process all lines except the last one (which might be incomplete)
				for i = 1, #new_lines - 1 do
					if i == 1 then
						-- Append to the current line
						local current_line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
						vim.api.nvim_buf_set_lines(0, row - 1, row, false, { current_line .. new_lines[i] })
					else
						-- Insert new lines
						vim.api.nvim_buf_set_lines(0, row, row, false, { new_lines[i] })
						row = row + 1
					end
				end
				-- Keep the last line in buffer
				buffer = new_lines[#new_lines]
			end
			vim.api.nvim_win_set_cursor(0, { row, col })
		else
			-- End of stream - write any remaining buffer content
			if buffer ~= "" then
				local current_line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
				vim.api.nvim_buf_set_lines(0, row - 1, row, false, { current_line .. buffer })
			end
			vim.api.nvim_echo({ { "Code generation complete.", "Normal" } }, false, {})
			log("Code generation complete")
		end
	end)
end

-- Function to edit code
function M.edit_code(opts)
	local start_line = opts.line1 - 1
	local end_line = opts.line2
	local selected_text = table.concat(vim.api.nvim_buf_get_lines(0, start_line, end_line, false), "\n")
	local prompt = opts.args or ""

	-- Log for debugging
	vim.fn.writefile({ "Edit code range: " .. start_line .. "-" .. end_line }, "/tmp/llama_nvim_debug.log", "a")
	vim.fn.writefile({ "Selected text: " .. selected_text }, "/tmp/llama_nvim_debug.log", "a")

	local messages = {
		{
			role = "system",
			content = "You are a helpful coding assistant. Based on the users prompt, and the selected code, rewrite the selection with any necessary edits based on the users prompt. All of the selected code will be deleted so make sure you rewrite it by incorporating both the old code and the new changes. The user is asking you to write some code, only generate the code they need with no additional formatting or text. The code you generate is written directly to the current file so make sure it is valid code. DO NOT WRAP THE CODE IN BACKTICKS, ONLY WRITE THE REAL CODE.",
		},
		{
			role = "user",
			content = "Make the following changes to this code: " .. prompt .. "\n\nCODE TO EDIT:\n" .. selected_text,
		},
	}

	-- Store original cursor position
	local window = vim.api.nvim_get_current_win()
	local cursor_pos = vim.api.nvim_win_get_cursor(window)

	-- Clear the selected lines but keep a backup
	local original_lines = vim.api.nvim_buf_get_lines(0, start_line, end_line, false)
	vim.api.nvim_buf_set_lines(0, start_line, end_line, false, {})

	-- Notify user that editing has started
	vim.api.nvim_echo({ { "Editing code with Llama API...", "WarningMsg" } }, false, {})

	-- Variables to collect the new text
	local collected_text = ""
	local is_first_chunk = true

	call_llama_api_stream(messages, function(content)
		if content then
			-- Remove markdown code blocks if present
			content = content:gsub("```%w*\n", ""):gsub("```", "")

			-- Append to our collected text
			collected_text = collected_text .. content

			-- Split the current collected text into lines
			local new_lines = vim.split(collected_text, "\n", true)

			-- Replace the entire range with the current state of collected text
			vim.api.nvim_buf_set_lines(0, start_line, start_line + #new_lines, false, new_lines)

			-- Update is_first_chunk flag
			if is_first_chunk then
				is_first_chunk = false
			end
		else
			-- End of stream, finalize changes
			local final_lines = vim.split(collected_text, "\n", true)
			vim.api.nvim_buf_set_lines(0, start_line, start_line + #final_lines, false, final_lines)

			-- Calculate new cursor position
			local new_cursor_pos = {
				start_line + math.min(cursor_pos[1] - start_line - 1, #final_lines),
				math.min(cursor_pos[2], #(final_lines[math.min(cursor_pos[1] - start_line, #final_lines)] or "")),
			}

			-- Set cursor to appropriate position
			pcall(vim.api.nvim_win_set_cursor, window, new_cursor_pos)

			-- Notify completion
			vim.api.nvim_echo({ { "Code editing complete.", "Normal" } }, false, {})
			vim.fn.writefile({ "Code editing complete" }, "/tmp/llama_nvim_debug.log", "a")
		end
	end)
end

function M.get_file_content(file_path)
	local file = io.open(file_path, "rb")
	if not file then
		print("Error: Unable to open file " .. file_path)
		return nil
	end
	local content = file:read("*a")
	file:close()
	return content
end

function M.generate_code_with_context(opts)
	--local prompt = opts.args
	local prompt = table.concat(opts.fargs, " ", 1, #opts.fargs - 1)
	local context = opts.fargs[#opts.fargs]
	log("LlamaGenerateWithContext prompt: " .. prompt)
	log("Context file: " .. context)

	local file_content = M.get_file_content(context)

	if not file_content then
		print("Error: Unable to read context file")
		return
	end

	local messages = {
		{
			role = "system",
			content = "You are a helpful coding assistant. Based on the users prompt and context, write the code or response. If the user is asking you to write some code, only generate the code they need with no additional formatting or text. The code you generate is written directly to the current file so make sure it is valid code. DO NOT WRAP THE CODE IN BACKTICKS, ONLY WRITE THE REAL CODE.",
		},
		{ role = "user", content = prompt .. "\n\nContext file:\n" .. file_content },
	}

	local row, col = unpack(vim.api.nvim_win_get_cursor(0))

	-- Notify user that generation has started
	vim.api.nvim_echo({ { "Generating code with context using Llama API...", "WarningMsg" } }, false, {})

	call_llama_api_stream(messages, function(content)
		if content then
			local new_lines = vim.split(content, "\n", true)
			for i, line in ipairs(new_lines) do
				if i == 1 then
					-- Append to the current line
					local current_line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
					vim.api.nvim_buf_set_lines(0, row - 1, row, false, { current_line .. line })
				else
					-- Insert new lines
					vim.api.nvim_buf_set_lines(0, row, row, false, { line })
					row = row + 1
				end
			end
			vim.api.nvim_win_set_cursor(0, { row, col })
		else
			-- End of stream
			vim.api.nvim_echo({ { "Code generation with context complete.", "Normal" } }, false, {})
			log("Code generation with context complete")
		end
	end)
end

return M
