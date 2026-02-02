local config = require("pi-nvim.config")
local state = require("pi-nvim.state")
local log = require("pi-nvim.util.log")

local INPUT_SEPARATOR = "─────────────────── <CR> send │ <C-CR> insert │ <C-c> abort ───────────────────"
local INPUT_SEPARATOR_PREFIX = "───────────────────"
local INPUT_PROMPT = "> "

local M = {}

local function split(s)
  local t={}
  for line in s:gmatch("([^\r\n]+)") do
    t[#t+1]=line
  end
  return t
end

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
    local s = session or state.get_session(bufnr)
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
    local s = session or state.get_session(bufnr)
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

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      session:close()
      state.clear_session(bufnr)
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

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, {
    "",
    INPUT_SEPARATOR,
    INPUT_PROMPT,
  })
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)

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

---@param content string | (TextContent | ImageContent)[]
function render_message_content(content)
  log.log("render_message_content", content)
  if type(content) == "string" then
    return split(content)
  end

  local lines = {}
  for _, block in ipairs(content) do
    if block.type == "text" then
      if #lines > 0 then
        table.insert(lines, "Response:")
      end
      local pieces = split(block.text)
      for _, line in ipairs(pieces) do
        table.insert(lines, line)
      end
    elseif block.type == "image" then
      table.insert(lines, "[Image]")
    elseif block.type == "thinking" then
      table.insert(lines, "Thinking...")
      local pieces = split(block.thinking)
      for _, line in ipairs(pieces) do
        table.insert(lines, line)
      end
    elseif block.type == "toolCall" or block.name then
      table.insert(lines, "[Tool Call: " .. (block.name or "unknown") .. "]")
      for k, v in ipairs(block.arguments) do
        table.insert(lines, string.format("  %s = %s", tostring(k), tostring(v)))
      end
    else
      table.insert(lines, "[Unknown content type]")
    end
  end
  return lines
end

---@param bufnr integer
---@param message Message?
function M.render(bufnr, message, opts, session)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  opts = opts or {}

  local winid = session and session:get_winid()
  local win_valid = vim.api.nvim_win_is_valid(winid)

  local old_cursor = nil
  local was_at_bottom = false
  local was_in_input = false

  if winid and win_valid then
    old_cursor = vim.api.nvim_win_get_cursor(winid)
    local old_separator = find_separator_line(bufnr)
    was_in_input = old_cursor[1] >= old_separator
    was_at_bottom = old_cursor[1] >= old_separator - 3
  end

  local separator_line = find_separator_line(bufnr)
  local input_area_lines = {}
  if separator_line then
    input_area_lines = vim.api.nvim_buf_get_lines(bufnr, separator_line - 1, -1, false)
  end

  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  if opts.disconnected then
    vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, {"_⚠️ Disconnected from Pi Agent_"})
  elseif opts.is_working then
    vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, {"_⚠️ Disconnected from Pi Agent_"})
  end

  if message then
    local content_lines = {}
    if message.role == "user" then
      table.insert(content_lines, "## User: ")
      tmp = render_message_content(message.content)
      for _, line in ipairs(tmp) do
        table.insert(content_lines, line)
      end
      table.insert(content_lines, "")
    elseif message.role == "assistant" then
      table.insert(content_lines, "## Assistant: ")
      tmp = render_message_content(message.content)
      for _, line in ipairs(tmp) do
        table.insert(content_lines, line)
      end
      table.insert(content_lines, "")
    elseif message.role == "toolResult" then
      table.insert(content_lines, "## Tool Result: ")
      table.insert(content_lines, "")
      tmp = render_message_content(message.content)
      for _, line in ipairs(tmp) do
        table.insert(content_lines, line)
      end
      table.insert(content_lines, "")
    end
    vim.api.nvim_buf_set_lines(bufnr, separator_line - 1, separator_line - 1, false, content_lines)
  end

  if winid and win_valid then
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
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)


  if opts.is_working then
    vim.cmd('redraw')
  end
end

return M
