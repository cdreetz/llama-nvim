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
M.chat_buffer = nil

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

-- Fix focusing on stop_reason detection
local function call_llama_api_stream(messages, callback)
	local accumulated_text = ""

	local job_id = vim.fn.jobstart({
		"curl",
		"-sS",
		"-N",
		"--no-buffer",
		M.config.api_url,
		"-H",
		"Authorization: Bearer " .. M.config.api_key,
		"-H",
		"Content-Type: application/json",
		"-H",
		"Accept: text/event-stream",
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
						vim.fn.writefile({ "LINE: " .. line }, "/tmp/llama_nvim_debug.log", "a")

						-- Process SSE data format
						if line:sub(1, 6) == "data: " then
							local raw_data = line:sub(7)

							if raw_data == "[DONE]" then
								vim.fn.writefile({ "DONE marker received" }, "/tmp/llama_nvim_debug.log", "a")
							else
								local success, parsed_data = pcall(json.decode, raw_data)
								if success then
									-- Check for text content in any recognized format
									local text = nil
									local stop_reason = nil

									-- Handle Llama API specific format
									if
										parsed_data.event
										and parsed_data.event.delta
										and parsed_data.event.delta.text
									then
										text = parsed_data.event.delta.text
									end

									-- Check for stop reason - key indicator that generation is complete
									if
										parsed_data.event
										and parsed_data.event.completion
										and parsed_data.event.completion.stop_reason
									then
										stop_reason = parsed_data.event.completion.stop_reason
										vim.fn.writefile(
											{ "STOP REASON: " .. stop_reason },
											"/tmp/llama_nvim_debug.log",
											"a"
										)
									end

									-- Process the text if we got some
									if text then
										accumulated_text = accumulated_text .. text
										callback(text)
									end

									-- If we got a stop reason, ensure we've processed all the text
									if stop_reason then
										vim.fn.writefile(
											{ "Final accumulated text: " .. accumulated_text },
											"/tmp/llama_nvim_debug.log",
											"a"
										)
									end
								else
									vim.fn.writefile(
										{ "JSON PARSE ERROR: " .. raw_data },
										"/tmp/llama_nvim_debug.log",
										"a"
									)
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
						vim.fn.writefile({ "STDERR: " .. line }, "/tmp/llama_nvim_debug.log", "a")
					end
				end
			end
		end,
		on_exit = function(_, exit_code)
			vim.fn.writefile({ "JOB EXIT with code: " .. exit_code }, "/tmp/llama_nvim_debug.log", "a")

			-- Add a delay before signaling completion to ensure all data is processed
			vim.defer_fn(function()
				callback(nil) -- Signal end of stream
			end, 200)
		end,
	})

	return job_id
end

-- Function to generate code
function M.generate_code(opts)
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
			log("Received content chunk: " .. content)
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

function M.get_all_files_content(recursive)
	local codebase_content = ""
	local files = {}
	if recursive then
		for file in vim.fs.dir(".") do
			if vim.fn.isdirectory(file) == 1 then
				for _, f in ipairs(vim.fn.glob(file .. "/**/*", 1, 1)) do
					if vim.fn.isdirectory(f) == 0 then
						table.insert(files, f)
					end
				end
			else
				table.insert(files, file)
			end
		end
	else
		for file in vim.fs.dir(".") do
			if vim.fn.isdirectory(file) == 0 then
				table.insert(files, file)
			end
		end
	end

	for _, file in ipairs(files) do
		if vim.fn.filereadable(file) == 1 then
			local content = table.concat(vim.fn.readfile(file), "\n")
			codebase_content = codebase_content .. "File: " .. file .. "\n" .. content .. "\n\n"
		end
	end

	return codebase_content
end

function M.LlamaGenerateWithCodebase(opts)
	local prompt = opts.args
	log("LlamaGenerateWithCodebase prompt: " .. prompt)

	local recursive = opts.fargs[2] == "-r"
	local codebase_content = M.get_all_files_content(recursive)

	local messages = {
		{
			role = "system",
			content = "You are a helpful coding assistant. Based on the users prompt and the codebase context, write the code or response. If the user is asking you to write some code, only generate the code they need with no additional formatting or text. The code you generate is written directly to the current file so make sure it is valid code. DO NOT WRAP THE CODE IN BACKTICKS, ONLY WRITE THE REAL CODE.",
		},
		{ role = "user", content = prompt .. "\n\nCodebase context:\n" .. codebase_content },
	}

	local row, col = unpack(vim.api.nvim_win_get_cursor(0))

	-- Notify user that generation has started
	vim.api.nvim_echo({ { "Generating code with codebase context using Llama API...", "WarningMsg" } }, false, {})

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
			vim.api.nvim_echo({ { "Code generation with codebase context complete.", "Normal" } }, false, {})
			log("Code generation with codebase context complete")
		end
	end)
end

vim.api.nvim_create_user_command("LlamaGenerateWithCodebase", M.LlamaGenerateWithCodebase, {
	nargs = "*",
	complete = function()
		return { "-r" }
	end,
})

-- Setup chat autocmds for buffer behavior
function M.setup_chat_buffer_behavior()
	local chat_augroup = vim.api.nvim_create_augroup("LlamaChatBuffer", { clear = true })
	
	-- Make the main chat area read-only except the input area
	vim.api.nvim_create_autocmd("InsertEnter", {
		buffer = M.chat_buffer,
		group = chat_augroup,
		callback = function()
			local line = vim.api.nvim_win_get_cursor(0)[1]
			local input_line = vim.api.nvim_buf_line_count(M.chat_buffer) - 1
			
			-- If not in the input area, move to it
			if line < input_line then
				vim.api.nvim_win_set_cursor(0, {input_line + 1, 0})
			end
		end,
	})
	
	-- Setup key mapping to enter insert mode at input area
	vim.api.nvim_buf_set_keymap(
		M.chat_buffer, 
		"n", 
		"i", 
		"<cmd>lua vim.api.nvim_win_set_cursor(0, {vim.api.nvim_buf_line_count(require('llama-nvim').chat_buffer), 0}) | startinsert<CR>", 
		{ noremap = true, silent = true }
	)
end

-- Simple function to open a chat sidebar
function M.open_chat_sidebar()
	-- Create a buffer if it doesn't exist
	if not M.chat_buffer or not vim.api.nvim_buf_is_valid(M.chat_buffer) then
		M.chat_buffer = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(M.chat_buffer, "LlamaChat")
	end
	
	-- Open the buffer in a vertical split on the right
	vim.cmd("vsplit")
	vim.cmd("vertical resize 50")
	vim.cmd("wincmd L") -- Move to rightmost position
	vim.api.nvim_win_set_buf(0, M.chat_buffer)
	
	-- Calculate chat content area and input area
	local line_count = 20 -- Example content area size
	
	-- Create chat content with separator and input area at bottom
	local lines = {}
	for i = 1, line_count do
		table.insert(lines, "")
	end
	table.insert(lines, string.rep("-", 48))
	table.insert(lines, "--- Type your message below ---")
	table.insert(lines, "")
	
	-- Set the buffer content
	vim.api.nvim_buf_set_lines(M.chat_buffer, 0, -1, false, lines)
	
	-- Set cursor at input line (the last line)
	vim.api.nvim_win_set_cursor(0, {#lines, 0})
	
	-- Setup buffer behavior
	M.setup_chat_buffer_behavior()
	
	-- Enter insert mode
	vim.cmd("startinsert")
end

-- Register the chat command
vim.api.nvim_create_user_command("LlamaChat", M.open_chat_sidebar, {})

return M
