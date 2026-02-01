local config = require("pi-nvim.config")
local render = require("pi-nvim.remote.render")
local state = require("pi-nvim.state")

local INPUT_SEPARATOR = "─────────────────── <CR> send │ <C-CR> insert │ <C-c> abort ───────────────────"
local INPUT_SEPARATOR_PREFIX = "───────────────────"
local INPUT_PROMPT = "> "

local M = {}

local function find_separator_line(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if vim.startswith(lines[i], INPUT_SEPARATOR_PREFIX) and lines[i]:find("send") then
      return i
    end
  end
  return nil
end

local function setup_input_area(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)

  vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, {
    "",
    INPUT_SEPARATOR,
    INPUT_PROMPT,
  })

  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
end

local function get_input_region(bufnr)
  local separator_line = find_separator_line(bufnr)
  if not separator_line then
    return nil
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  return {
    start_line = separator_line + 1,
    end_line = line_count,
  }
end

local function get_input_text(bufnr)
  local region = get_input_region(bufnr)
  if not region then
    return ""
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, region.start_line - 1, region.end_line, false)

  for i, line in ipairs(lines) do
    if i == 1 and vim.startswith(line, INPUT_PROMPT) then
      lines[i] = line:sub(#INPUT_PROMPT + 1)
    end
  end

  local text = table.concat(lines, "\n")
  return vim.trim(text)
end

local function clear_input(bufnr)
  local separator_line = find_separator_line(bufnr)
  if not separator_line then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, separator_line, line_count, false, {
    INPUT_PROMPT,
  })
end

local function is_cursor_in_input(bufnr, winid)
  local region = get_input_region(bufnr)
  if not region then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  local row = cursor[1]

  return row >= region.start_line
end

local function setup_keymaps(bufnr, session)
  local function submit_input()
    local s = session or state.get_session()
    if not s or s.mode ~= "remote" then
      return
    end

    local text = get_input_text(bufnr)
    if text == "" then
      return
    end

    clear_input(bufnr)

    s:send(text):catch(function(err)
      vim.notify("Failed to send prompt: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end

  local function abort_operation()
    local s = session or state.get_session()
    if s and s.mode == "remote" then
      s:abort()
    end
  end

  vim.keymap.set("n", "<CR>", function()
    local winid = vim.api.nvim_get_current_win()
    if is_cursor_in_input(bufnr, winid) then
      submit_input()
    end
  end, { buffer = bufnr, desc = "Submit prompt" })

  vim.keymap.set("i", "<C-CR>", function()
    submit_input()
  end, { buffer = bufnr, desc = "Submit prompt" })

  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    abort_operation()
  end, { buffer = bufnr, desc = "Abort operation" })
end


local function setup_buffer_protection(bufnr, session)
  local group = vim.api.nvim_create_augroup("PiNvimBufferProtect" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      local winid = vim.api.nvim_get_current_win()
      if not is_cursor_in_input(bufnr, winid) then
        local region = get_input_region(bufnr)
        if region then
          vim.api.nvim_win_set_cursor(winid, { region.start_line, 2 })
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      vim.api.nvim_del_augroup_by_id(group)
      if state.get_session() == session then
        session:close()
        state.set_session(nil)
      end
    end,
  })
end

function M.create(session)
  local cfg = config.get()

  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
  vim.api.nvim_buf_set_option(bufnr, "filetype", "pi")

  vim.api.nvim_buf_set_name(bufnr, "pi://chat")

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "# Pi Agent",
    "",
    "_Connecting..._",
    "",
  })

  setup_input_area(bufnr)
  setup_keymaps(bufnr, session)
  setup_buffer_protection(bufnr, session)

  return bufnr
end

function M.move_cursor_to_input(bufnr, winid)
  local region = get_input_region(bufnr)
  if not region then
    return
  end

  local line = region.start_line
  local lines = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)
  local col = 0
  if lines[1] then
    col = #lines[1]
  end

  if vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_set_cursor(winid, { line, col })
  end
end

function M.render(bufnr, messages, streaming_opts, session)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  streaming_opts = streaming_opts or {}

  local winid = session and session:get_winid()

  local old_cursor = nil
  local was_at_bottom = false
  local was_in_input = false

  if winid and vim.api.nvim_win_is_valid(winid) then
    old_cursor = vim.api.nvim_win_get_cursor(winid)
    local old_separator = find_separator_line(bufnr)

    if old_separator then
      was_in_input = old_cursor[1] >= old_separator
      was_at_bottom = old_cursor[1] >= old_separator - 3
    else
      local old_line_count = vim.api.nvim_buf_line_count(bufnr)
      was_at_bottom = old_cursor[1] >= old_line_count - 3
    end
  end

  local separator_line = find_separator_line(bufnr)
  local input_lines = {}
  if separator_line then
    input_lines = vim.api.nvim_buf_get_lines(bufnr, separator_line - 1, -1, false)
  end

  local content_lines = render.render_messages(messages, streaming_opts)

  if #content_lines == 0 then
    content_lines = {
      "# Pi Agent",
      "",
      "_No messages yet. Type below to start._",
      "",
    }
  else
    table.insert(content_lines, 1, "# Pi Agent")
    table.insert(content_lines, 2, "")
  end

  if streaming_opts.disconnected then
    table.insert(content_lines, "")
    table.insert(content_lines, "_⚠️ Disconnected from Pi Agent_")
    table.insert(content_lines, "")
  elseif streaming_opts.is_streaming then
    table.insert(content_lines, "")
    table.insert(content_lines, "_⏳ Agent is working..._")
    table.insert(content_lines, "")
  end

  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)

  local all_lines = {}
  for _, line in ipairs(content_lines) do
    table.insert(all_lines, line)
  end
  for _, line in ipairs(input_lines) do
    table.insert(all_lines, line)
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, all_lines)

  if winid and vim.api.nvim_win_is_valid(winid) then
    local new_separator = find_separator_line(bufnr)

    if old_cursor and was_in_input and new_separator then
      local input_offset = old_cursor[1] - (separator_line or old_cursor[1])
      local new_row = new_separator + input_offset
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      new_row = math.max(new_separator, math.min(new_row, line_count))
      vim.api.nvim_win_set_cursor(winid, { new_row, old_cursor[2] })
    elseif was_at_bottom and new_separator then
      vim.api.nvim_win_set_cursor(winid, { new_separator - 1, 0 })
    elseif old_cursor then
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local new_row = math.min(old_cursor[1], line_count)
      pcall(vim.api.nvim_win_set_cursor, winid, { new_row, old_cursor[2] })
    end
  end

  if streaming_opts.is_streaming then
    vim.cmd('redraw')
  end
end

function M.focus(session)
  if not session then
    return false
  end

  local winid = session:get_winid()
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end

  vim.api.nvim_set_current_win(winid)
  return true
end

return M
