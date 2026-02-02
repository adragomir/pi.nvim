local Promise = require("pi-nvim.util.promise")
local config = require("pi-nvim.config")
local state = require("pi-nvim.state")

local M = {}

function M.build_prompt(selection_info, user_input)
  local cfg = config.get()
  local format = cfg.prompt_format

  local result = format
  result = result:gsub("{file}", selection_info.file or "unknown")
  result = result:gsub("{start_line}", tostring(selection_info.start_line or 0))
  result = result:gsub("{end_line}", tostring(selection_info.end_line or 0))
  result = result:gsub("{filetype}", selection_info.filetype or "")
  result = result:gsub("{selection}", selection_info.text or "")
  result = result:gsub("{prompt}", user_input or "")

  return result
end

function M.open_prompt_popup(selection_info)
  local promise = Promise.new()

  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)

  local file_display = selection_info.file or "unknown"
  if #file_display > 40 then
    file_display = "..." .. file_display:sub(-37)
  end

  local header_lines = {
    "┌─ Pi Agent Prompt ─────────────────────────────────────┐",
    "│ File: " .. file_display .. string.rep(" ", math.max(0, 52 - 7 - #file_display)) .. "│",
    "│ Lines: " .. selection_info.start_line .. "-" .. selection_info.end_line .. string.rep(" ", math.max(0, 52 - 8 - #tostring(selection_info.start_line) - 1 - #tostring(selection_info.end_line))) .. "│",
    "├───────────────────────────────────────────────────────┤",
    "│ Enter your prompt below, then:                        │",
    "│   <CR> to submit  |  <Esc> or <C-c> to cancel         │",
    "└───────────────────────────────────────────────────────┘",
    "",
  }

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, header_lines)
  vim.api.nvim_buf_set_lines(buf, #header_lines, -1, false, { "" })

  local width = 60
  local height = 15
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Pi Agent ",
    title_pos = "center",
  })

  vim.api.nvim_win_set_option(win, "wrap", true)
  vim.api.nvim_win_set_option(win, "cursorline", false)

  local input_start_line = #header_lines + 1
  vim.api.nvim_win_set_cursor(win, { input_start_line, 0 })
  vim.cmd("startinsert")

  local submitted = false

  local function cleanup()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function submit()
    if submitted then
      return
    end
    submitted = true

    local lines = vim.api.nvim_buf_get_lines(buf, #header_lines, -1, false)
    local input_text = vim.trim(table.concat(lines, "\n"))

    cleanup()

    if input_text == "" then
      promise:resolve(nil)
    else
      promise:resolve(input_text)
    end
  end

  local function cancel()
    if submitted then
      return
    end
    submitted = true
    cleanup()
    promise:resolve(nil)
  end

  vim.keymap.set("n", "<CR>", submit, { buffer = buf, nowait = true })
  vim.keymap.set("i", "<C-CR>", submit, { buffer = buf, nowait = true })
  vim.keymap.set({ "n", "i" }, "<Esc>", cancel, { buffer = buf, nowait = true })
  vim.keymap.set({ "n", "i" }, "<C-c>", cancel, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, nowait = true })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        cancel()
      end)
    end,
  })

  return promise
end

function M.get_visual_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  local start_line = start_pos[2]
  local end_line = end_pos[2]

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

  local mode = vim.fn.visualmode()
  if mode == "v" then
    local start_col = start_pos[3]
    local end_col = end_pos[3]

    if #lines == 1 then
      lines[1] = lines[1]:sub(start_col, end_col)
    else
      lines[1] = lines[1]:sub(start_col)
      lines[#lines] = lines[#lines]:sub(1, end_col)
    end
  end

  local text = table.concat(lines, "\n")

  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then
    file = "[No Name]"
  else
    file = vim.fn.fnamemodify(file, ":.")
  end

  local filetype = vim.api.nvim_buf_get_option(bufnr, "filetype")

  return {
    file = file,
    start_line = start_line,
    end_line = end_line,
    filetype = filetype,
    text = text,
    bufnr = bufnr,
  }
end

function M.handle_visual_selection()
  local selection_info = M.get_visual_selection()

  M.open_prompt_popup(selection_info):and_then(function(user_input)
    if not user_input then
      return
    end

    local prompt = M.build_prompt(selection_info, user_input)
    local session, err = state.get_visible_session()
    if not session then
      local level = err == "Multiple visible Pi Agent sessions" and vim.log.levels.ERROR or vim.log.levels.WARN
      vim.notify(err, level)
      return
    end

    if not session:is_active() then
        vim.notify("Terminal is not running", vim.log.levels.WARN)
    end
    session:send(prompt .. "\n")
    session:focus()
  end)
end

return M
