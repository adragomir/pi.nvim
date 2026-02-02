local state = require("pi-nvim.state")

local M = {}

local INPUT_SEPARATOR = "─────────────────── <CR> send │ <C-CR> insert │ <C-c> abort ───────────────────"
local INPUT_SEPARATOR_PREFIX = "───────────────────"
local INPUT_PROMPT = "> "

function M.get_separator()
  return INPUT_SEPARATOR
end

function M.get_prompt_marker()
  return INPUT_PROMPT
end

function M.find_separator_line(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if vim.startswith(lines[i], INPUT_SEPARATOR_PREFIX) and lines[i]:find("send") then
      return i
    end
  end
  return nil
end

function M.setup_input_area(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)

  vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, {
    "",
    INPUT_SEPARATOR,
    INPUT_PROMPT,
  })

  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
end

function M.get_input_region(bufnr)
  local separator_line = M.find_separator_line(bufnr)
  if not separator_line then
    return nil
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  return {
    start_line = separator_line + 1,
    end_line = line_count,
  }
end

function M.get_input_text(bufnr)
  local region = M.get_input_region(bufnr)
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

function M.clear_input(bufnr)
  local separator_line = M.find_separator_line(bufnr)
  if not separator_line then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, separator_line, line_count, false, {
    INPUT_PROMPT,
  })
end

function M.is_cursor_in_input(bufnr, winid)
  local region = M.get_input_region(bufnr)
  if not region then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  local row = cursor[1]

  return row >= region.start_line
end

function M.setup_keymaps(bufnr, session)
  local function submit_input()
    local s = session or state.get_session(bufnr)
    if not s or s.mode ~= "remote" then
      return
    end

    local text = M.get_input_text(bufnr)
    if text == "" then
      return
    end

    M.clear_input(bufnr)

    s:send(text):catch(function(err)
      vim.notify("Failed to send prompt: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end

  -- local function abort_operation()
  --   local s = session or state.get_session()
  --   if s and s.mode == "remote" then
  --     s:abort()
  --   end
  -- end

  vim.keymap.set("n", "<CR>", function()
    local winid = vim.api.nvim_get_current_win()
    if M.is_cursor_in_input(bufnr, winid) then
      submit_input()
    end
  end, { buffer = bufnr, desc = "Submit prompt" })

  vim.keymap.set("i", "<C-CR>", function()
    submit_input()
  end, { buffer = bufnr, desc = "Submit prompt" })

  -- vim.keymap.set({ "n", "i" }, "<C-c>", function()
  --   abort_operation()
  -- end, { buffer = bufnr, desc = "Abort operation" })
end

return M
