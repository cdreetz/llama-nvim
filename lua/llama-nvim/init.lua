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
	vim.api.nvim_create_user_command("LlamaVoice", M.record_and_transcribe_local, { range = true })

	vim.api.nvim_create_user_command("LlamaEditFile", M.edit_file, { nargs = "?" })

	vim.api.nvim_set_keymap("n", "<leader>lef", ":LlamaEditFile ", { noremap = true })

	-- Create keymappings
	vim.api.nvim_set_keymap("n", "<leader>lv", ":LlamaVoice<CR>", { noremap = true, silent = true })
	vim.api.nvim_set_keymap("v", "<leader>lv", ":LlamaVoice<CR>", { noremap = true, silent = true })

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
-- Function to edit code with proper expansion handling
-- Function to edit code with proper expansion handling
function M.edit_code(opts)
	local start_line = opts.line1 - 1
	local end_line = opts.line2
	local selected_text = table.concat(vim.api.nvim_buf_get_lines(0, start_line, end_line, false), "\n")
	local prompt = opts.args or ""

	-- Log for debugging
	log("Edit code range: " .. start_line .. "-" .. end_line)

	-- Store original cursor position
	local window = vim.api.nvim_get_current_win()
	local cursor_pos = vim.api.nvim_win_get_cursor(window)

	local messages = {
		{
			role = "system",
			content = "You are a code editing assistant. Edit the provided code according to instructions. Return only the edited code.",
		},
		{
			role = "user",
			content = "Edit this code: " .. prompt .. "\n\nCode:\n" .. selected_text,
		},
	}

	-- 1. Delete the highlighted section
	vim.api.nvim_buf_set_lines(0, start_line, end_line, false, {})

	-- Notify user
	vim.api.nvim_echo({ { "Editing code with Llama API...", "WarningMsg" } }, false, {})

	-- Current insertion point
	local current_line = start_line

	call_llama_api_stream(messages, function(content)
		if content then
			-- Remove code blocks if present
			content = content:gsub("```[%w%s]*\n", ""):gsub("```", "")

			-- 3. For each new line, insert at the current position
			local new_lines = vim.split(content, "\n", true)

			for _, line in ipairs(new_lines) do
				-- Insert the new line at the current position
				vim.api.nvim_buf_set_lines(0, current_line, current_line, false, { line })
				-- Move insertion point down
				current_line = current_line + 1
			end
		else
			-- End of stream, restore cursor to reasonable position
			local new_cursor_line = math.min(cursor_pos[1], current_line)
			pcall(vim.api.nvim_win_set_cursor, window, { new_cursor_line, cursor_pos[2] })

			-- Notify completion
			vim.api.nvim_echo({ { "Code editing complete.", "Normal" } }, false, {})
			log("Code editing complete")
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

-- speech stuff
function M.record_and_transcribe_local(opts)
	local temp_audio_file = os.tmpname() .. ".wav"
	local temp_output_file = os.tmpname() .. ".txt"
	local should_continue = true

	-- Save visual selection information if provided
	local has_range = false
	local start_line, end_line
	if opts and opts.range == 2 then
		has_range = true
		start_line = opts.line1
		end_line = opts.line2
		-- Exit visual mode if we're in it
		if vim.api.nvim_get_mode().mode:match("[vV]") then
			vim.cmd("normal! <Esc>")
		end
	end

	-- Show recording indicator immediately
	vim.api.nvim_echo({ { "Recording 🎤", "WarningMsg" } }, false, {})

	-- Set up a repeating timer to update the recording indicator
	local dots = 0
	local timer_id = vim.fn.timer_start(500, function()
		dots = (dots % 3) + 1
		local dot_str = string.rep(".", dots)
		vim.api.nvim_echo({ { "Recording 🎤" .. dot_str, "WarningMsg" } }, false, {})
	end, { ["repeat"] = -1 })

	-- Create a flag file to indicate recording is in progress
	local flag_file = os.tmpname() .. ".flag"
	local file = io.open(flag_file, "w")
	file:write("recording")
	file:close()

	-- Set up key mapping to stop recording when Enter is pressed
	vim.api.nvim_set_keymap("n", "<CR>", "", {
		noremap = true,
		callback = function()
			if should_continue then
				should_continue = false
				os.remove(flag_file)
				vim.api.nvim_echo({ { "Stopping recording...", "WarningMsg" } }, false, {})
			end
			return true -- Allow the keypress to continue processing
		end,
	})

	-- Prepare sox command with longer timeout and a method to stop early
	local cmd = "sox"
	local args = {
		"-d",
		"-r",
		"16000",
		"-c",
		"1",
		"-b",
		"16",
		temp_audio_file,
		"trim",
		"0",
		"10", -- Changed from 5 to 10 seconds
		"silence",
		"1",
		"0.1",
		"1%", -- Stop on silence
	}

	-- Use killable recording command
	local stop_recording_cmd = string.format(
		'bash -c \'for i in {1..100}; do if [ ! -f "%s" ]; then pkill -f "sox.*%s"; exit 0; fi; sleep 0.1; done\'',
		flag_file,
		temp_audio_file
	)

	-- Start the stop command in background
	vim.fn.jobstart(stop_recording_cmd)

	-- Use Neovim's job API for non-blocking execution
	local job_id = vim.fn.jobstart({ cmd, unpack(args) }, {
		on_exit = function(_, exit_code)
			-- Restore normal Enter behavior
			vim.api.nvim_del_keymap("n", "<CR>")

			-- Stop the indicator timer
			vim.fn.timer_stop(timer_id)

			if exit_code ~= 0 and should_continue then
				vim.api.nvim_echo({ { "Error recording audio", "ErrorMsg" } }, false, {})
				os.remove(temp_audio_file)
				os.remove(flag_file)
				return
			end

			-- Show processing message
			vim.api.nvim_echo({ { "Processing speech...", "WarningMsg" } }, false, {})

			-- Transcribe the audio using whisper.cpp
			local whisper_path = vim.fn.expand("~/dev/whisper.cpp/build/bin/whisper-cli")
			local whisper_model = vim.fn.expand("~/dev/whisper.cpp/models/ggml-base.en.bin")

			-- Use jobstart again for the transcription
			local transcribe_job_id = vim.fn.jobstart({
				whisper_path,
				"-m",
				whisper_model,
				temp_audio_file,
			}, {
				on_stdout = function(_, data)
					if not data or #data == 0 then
						return
					end
					-- Append stdout data to output file
					local file = io.open(temp_output_file, "a")
					if file then
						for _, line in ipairs(data) do
							if line and line ~= "" then
								file:write(line .. "\n")
							end
						end
						file:close()
					end
				end,
				on_exit = function(_, _)
					-- Process the transcription output
					local file = io.open(temp_output_file, "r")
					local output = ""
					if file then
						output = file:read("*a")
						file:close()
					end

					-- Clean up temporary files
					os.remove(temp_audio_file)
					os.remove(temp_output_file)
					os.remove(flag_file)

					-- Extract the transcription text
					local text = nil
					-- Try to match the timestamp pattern first
					for line in output:gmatch("[^\r\n]+") do
						local transcript = line:match("%[%d+:%d+:%d+%.%d+ %-%-> %d+:%d+:%d+%.%d+%]%s*(.+)")
						if transcript then
							text = transcript
							break
						end
					end

					-- Fallback to any line that looks like transcription
					if not text then
						for line in output:gmatch("[^\r\n]+") do
							if
								not line:match("^%s*$")
								and not line:match("^whisper_")
								and not line:match("^main:")
								and not line:match("^%[%d+:%d+:%d+")
								and not line:match("Done%.")
							then
								text = line
								break
							end
						end
					end

					if not text or text == "" or text:match("%[BLANK_AUDIO%]") then
						vim.api.nvim_echo({ { "No speech detected", "WarningMsg" } }, false, {})
						return
					end

					-- Clean up text
					text = text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
					vim.api.nvim_echo({ { "Recognized: " .. text, "Normal" } }, false, {})

					-- Process the voice command with the range if we have it
					if has_range then
						M.process_voice_command_with_range(text, start_line, end_line)
					else
						M.process_voice_command(text)
					end
				end,
			})

			if transcribe_job_id <= 0 then
				vim.api.nvim_echo({ { "Error starting transcription", "ErrorMsg" } }, false, {})
				os.remove(temp_audio_file)
			end
		end,
	})

	if job_id <= 0 then
		vim.fn.timer_stop(timer_id)
		vim.api.nvim_echo({ { "Error starting recording", "ErrorMsg" } }, false, {})
		vim.api.nvim_del_keymap("n", "<CR>")
		os.remove(flag_file)
	end

	return job_id
end

-- Add a new function to process voice commands with a range
function M.process_voice_command_with_range(text, start_line, end_line)
	if text:match("^edit") or text:match("^change") or text:match("^modify") then
		vim.cmd(start_line .. "," .. end_line .. "LlamaEdit " .. text:gsub("^edit%s*", ""))
	else
		-- If not an edit command, handle the text selection as context
		local selected_text = table.concat(vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false), "\n")
		vim.cmd("LlamaGenerate " .. text .. " [CONTEXT: " .. selected_text .. "]")
	end

	log("Voice command processed with range: " .. text)
end

function M.process_voice_command(text)
	if text:match("^edit") or text:match("^change") or text:match("^modify") then
		local mode = vim.api.nvim_get_mode().mode
		if mode:match("[vV]") then
			local start_line = vim.fn.line("'<")
			local end_line = vim.fn.line("'>")

			vim.cmd("normal! <Esc>") -- Exit visual mode
			vim.cmd(start_line .. "," .. end_line .. "LlamaEdit " .. text:gsub("^edit%s*", ""))
		else
			vim.api.nvim_echo({ { "Please select text to edit first", "WarningMsg" } }, false, {})
		end
	else
		vim.cmd("LlamaGenerate " .. text)
	end

	log("Voice command processed: " .. text)
end

-- edit whole file
function M.edit_file(opts)
	local prompt = opts.args or ""
	local file_content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")

	-- Store original content for diff calculation
	M.original_content = file_content
	M.original_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

	local messages = {
		{
			role = "system",
			content = "You are a helpful coding assistant. Based on the user's prompt, edit the provided file. Return the entire file content with the changes applied. The code you generate will replace the current file, so ensure it's complete and valid. DO NOT add any explanations or markdown formatting.",
		},
		{
			role = "user",
			content = "Make the following changes to this file: " .. prompt .. "\n\nFILE CONTENT:\n" .. file_content,
		},
	}

	-- Notify user that editing has started
	vim.api.nvim_echo({ { "Editing file with Llama API...", "WarningMsg" } }, false, {})

	-- Get current window/buffer info for updates
	M.current_buf = vim.api.nvim_get_current_buf()
	M.current_win = vim.api.nvim_get_current_win()

	-- Clear existing diff highlights if any
	M.clear_diff_highlights()

	-- Variables to collect and process the new text
	local collected_text = ""

	call_llama_api_stream(messages, function(content)
		if content then
			-- Append to our collected text
			collected_text = collected_text .. content

			-- Process and visualize diffs as content arrives
			M.process_streaming_diff(collected_text)
		else
			-- Finalize changes
			M.finalize_file_edit(collected_text)

			-- Notify completion
			vim.api.nvim_echo({ { "File editing complete.", "Normal" } }, false, {})
		end
	end)
end

-- Initialize namespace for diff highlights
M.diff_ns = vim.api.nvim_create_namespace("llama_diff_highlights")

function M.clear_diff_highlights()
	vim.api.nvim_buf_clear_namespace(M.current_buf, M.diff_ns, 0, -1)
end

function M.process_streaming_diff(current_text)
	-- Split the streamed text into lines
	local new_lines = vim.split(current_text, "\n", true)

	-- Calculate how many complete lines we have
	-- (the last line might be incomplete in streaming)
	local complete_line_count = #new_lines

	-- Compare each line with the original
	for i = 1, math.min(complete_line_count, #M.original_lines) do
		if new_lines[i] ~= M.original_lines[i] then
			-- Line changed - highlight it
			vim.api.nvim_buf_set_lines(M.current_buf, i - 1, i, false, { new_lines[i] })
			vim.api.nvim_buf_add_highlight(M.current_buf, M.diff_ns, "DiffText", i - 1, 0, -1)
		end
	end

	-- Handle additional lines (if any)
	if complete_line_count > #M.original_lines then
		vim.api.nvim_buf_set_lines(
			M.current_buf,
			#M.original_lines,
			#M.original_lines,
			false,
			vim.list_slice(new_lines, #M.original_lines + 1, complete_line_count)
		)

		-- Highlight new lines
		for i = #M.original_lines + 1, complete_line_count do
			vim.api.nvim_buf_add_highlight(M.current_buf, M.diff_ns, "DiffAdd", i - 1, 0, -1)
		end
	end

	-- Handle deleted lines
	if complete_line_count < #M.original_lines then
		-- Instead of removing lines immediately, mark them as deleted
		for i = complete_line_count + 1, #M.original_lines do
			vim.api.nvim_buf_add_highlight(M.current_buf, M.diff_ns, "DiffDelete", i - 1, 0, -1)
		end
	end
end

function M.finalize_file_edit(final_text)
	-- Replace the entire buffer with the final text
	local final_lines = vim.split(final_text, "\n", true)
	vim.api.nvim_buf_set_lines(M.current_buf, 0, -1, false, final_lines)

	-- Calculate final diff for highlighting
	local added = {}
	local changed = {}
	local deleted = {}

	-- Find changed and added lines
	for i = 1, math.max(#final_lines, #M.original_lines) do
		if i <= #final_lines and i <= #M.original_lines then
			if final_lines[i] ~= M.original_lines[i] then
				changed[i] = true
			end
		elseif i <= #final_lines then
			added[i] = true
		else
			deleted[i] = true
		end
	end

	-- Apply final highlights
	for i, _ in pairs(changed) do
		vim.api.nvim_buf_add_highlight(M.current_buf, M.diff_ns, "DiffText", i - 1, 0, -1)
	end

	for i, _ in pairs(added) do
		vim.api.nvim_buf_add_highlight(M.current_buf, M.diff_ns, "DiffAdd", i - 1, 0, -1)
	end

	-- Create temporary marks for deleted lines (optional)
	-- This could show deleted content in a virtual text

	-- Schedule highlight removal after a delay
	vim.defer_fn(function()
		M.clear_diff_highlights()
	end, 5000) -- Remove highlights after 5 seconds
end

return M
