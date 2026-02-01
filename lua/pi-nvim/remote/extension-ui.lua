local M = {}

local function send_response(client, id, response)
  client:send_extension_ui_response(id, response)
end

local function send_cancelled(client, id)
  send_response(client, id, { cancelled = true })
end

local function with_timeout(client, id, timeout_ms, fn)
  local timer = nil
  local completed = false

  if timeout_ms and timeout_ms > 0 then
    timer = vim.uv.new_timer()
    timer:start(timeout_ms, 0, function()
      if not completed then
        completed = true
        timer:stop()
        timer:close()
        vim.schedule(function()
          send_cancelled(client, id)
        end)
      end
    end)
  end

  local function done(response)
    if completed then
      return
    end
    completed = true
    if timer then
      timer:stop()
      timer:close()
    end
    send_response(client, id, response)
  end

  local function cancel()
    if completed then
      return
    end
    completed = true
    if timer then
      timer:stop()
      timer:close()
    end
    send_cancelled(client, id)
  end

  fn(done, cancel)
end

local function handle_select(client, request)
  with_timeout(client, request.id, request.timeout, function(done, cancel)
    vim.ui.select(request.options, {
      prompt = request.title,
    }, function(choice)
      if choice then
        done({ value = choice })
      else
        cancel()
      end
    end)
  end)
end

local function handle_confirm(client, request)
  with_timeout(client, request.id, request.timeout, function(done, cancel)
    vim.ui.select({ "Yes", "No" }, {
      prompt = request.title .. (request.message and ("\n" .. request.message) or ""),
    }, function(choice)
      if choice then
        done({ confirmed = choice == "Yes" })
      else
        cancel()
      end
    end)
  end)
end

local function handle_input(client, request)
  with_timeout(client, request.id, request.timeout, function(done, cancel)
    vim.ui.input({
      prompt = request.title .. ": ",
      default = request.placeholder or "",
    }, function(input)
      if input then
        done({ value = input })
      else
        cancel()
      end
    end)
  end)
end

local function handle_editor(client, request)
  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "swapfile", false)

  if request.prefill then
    local lines = vim.split(request.prefill, "\n")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end

  vim.cmd("split")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.api.nvim_buf_set_name(bufnr, "[Pi] " .. (request.title or "Editor"))

  local submitted = false

  local function submit()
    if submitted then
      return
    end
    submitted = true
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local text = table.concat(lines, "\n")
    send_response(client, request.id, { value = text })
    vim.api.nvim_win_close(winid, true)
  end

  local function cancel()
    if submitted then
      return
    end
    submitted = true
    send_cancelled(client, request.id)
    vim.api.nvim_win_close(winid, true)
  end

  vim.keymap.set("n", "<C-s>", submit, { buffer = bufnr, desc = "Submit editor content" })
  vim.keymap.set("n", "<C-c>", cancel, { buffer = bufnr, desc = "Cancel editor" })
  vim.keymap.set("n", "q", cancel, { buffer = bufnr, desc = "Cancel editor" })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      if not submitted then
        send_cancelled(client, request.id)
      end
    end,
  })
end

local function handle_notify(client, request)
  local level = vim.log.levels.INFO
  if request.notifyType == "warning" then
    level = vim.log.levels.WARN
  elseif request.notifyType == "error" then
    level = vim.log.levels.ERROR
  end

  vim.notify(request.message, level, { title = "Pi Agent" })
  send_response(client, request.id, {})
end

local extension_status = {}

local function handle_set_status(client, request)
  extension_status[request.statusKey] = request.statusText
  send_response(client, request.id, {})
end

function M.get_status()
  return extension_status
end

local extension_widgets = {}

local function handle_set_widget(client, request)
  if request.widgetLines then
    extension_widgets[request.widgetKey] = {
      lines = request.widgetLines,
      placement = request.widgetPlacement or "belowEditor",
    }
  else
    extension_widgets[request.widgetKey] = nil
  end
  send_response(client, request.id, {})
end

function M.get_widgets()
  return extension_widgets
end

local function handle_set_title(client, request)
  vim.o.titlestring = request.title
  send_response(client, request.id, {})
end

local function handle_set_editor_text(client, request)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.split(request.text, "\n")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  send_response(client, request.id, {})
end

function M.handle_request(client, request)
  if request.type ~= "extension_ui_request" then
    return false
  end

  local method = request.method

  if method == "select" then
    handle_select(client, request)
  elseif method == "confirm" then
    handle_confirm(client, request)
  elseif method == "input" then
    handle_input(client, request)
  elseif method == "editor" then
    handle_editor(client, request)
  elseif method == "notify" then
    handle_notify(client, request)
  elseif method == "setStatus" then
    handle_set_status(client, request)
  elseif method == "setWidget" then
    handle_set_widget(client, request)
  elseif method == "setTitle" then
    handle_set_title(client, request)
  elseif method == "set_editor_text" then
    handle_set_editor_text(client, request)
  else
    vim.notify("Unknown extension UI method: " .. tostring(method), vim.log.levels.WARN)
    send_cancelled(client, request.id)
  end

  return true
end

function M.clear()
  extension_status = {}
  extension_widgets = {}
end

return M
