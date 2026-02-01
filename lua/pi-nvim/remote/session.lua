local Promise = require("pi-nvim.util.promise")
local config = require("pi-nvim.config")
local extension_ui = require("pi-nvim.remote.extension-ui")
local buffer = require("pi-nvim.remote.buffer")
local RpcClient = require("pi-nvim.remote.rpc-client")
local log = require('pi-nvim.util.log')

local RemoteSession = {}
RemoteSession.__index = RemoteSession

function RemoteSession.new()
  local self = setmetatable({
    mode = "remote",
    client = nil,
    bufnr = nil,
    winid = nil,
    messages = {},
    is_streaming = false,
    event_unsubscribe = nil,
    _connection_timer = nil,
    _streaming_message = nil,
    _streaming_text = "",
    _streaming_thinking = "",
    _tool_executions = {},
    _last_render_time = 0,
    _render_timer = nil,
  }, RemoteSession)
  return self
end

function RemoteSession:_reset_streaming()
  self._streaming_message = nil
  self._streaming_text = ""
  self._streaming_thinking = ""
end

function RemoteSession:_stop_connection_check()
  if self._connection_timer then
    self._connection_timer:stop()
    self._connection_timer:close()
    self._connection_timer = nil
  end
end

function RemoteSession:_start_connection_check()
  self:_stop_connection_check()

  local session = self
  self._connection_timer = vim.uv.new_timer()
  self._connection_timer:start(1000, 2000, function()
    vim.schedule(function()
      if session.client and not session.client:is_connected() then
        session:_stop_connection_check()
        vim.notify("Connection to Pi Agent lost", vim.log.levels.WARN)
        session:_handle_disconnect()
      end
    end)
  end)
end

function RemoteSession:_handle_disconnect()
  if self.event_unsubscribe then
    self.event_unsubscribe()
    self.event_unsubscribe = nil
  end

  extension_ui.clear()
  self:_reset_streaming()
  self._tool_executions = {}
  self.is_streaming = false

  if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
    self:_render({ disconnected = true })
  end
end

function RemoteSession:_cancel_render_timer()
  if self._render_timer then
    self._render_timer:stop()
    self._render_timer:close()
    self._render_timer = nil
  end
end

function RemoteSession:_do_render()
  self:_cancel_render_timer()
  self._last_render_time = vim.uv.now()
  self:_render({
    streaming_text = self._streaming_text,
    streaming_thinking = self._streaming_thinking,
    streaming_message = self._streaming_message,
    is_streaming = self.is_streaming,
  })
end

function RemoteSession:_trigger_render()
  if not self.bufnr then
    return
  end

  local cfg = config.get()
  if not cfg.streaming.enabled then
    return
  end

  local now = vim.uv.now()
  local elapsed = now - self._last_render_time
  local throttle = cfg.streaming.throttle_ms

  if elapsed >= throttle then
    self:_do_render()
  elseif not self._render_timer then
    local delay = throttle - elapsed
    self._render_timer = vim.uv.new_timer()
    local session = self
    self._render_timer:start(delay, 0, function()
      vim.schedule(function()
        if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
          session:_do_render()
        end
      end)
    end)
  end
end

function RemoteSession:_render(opts)
  buffer.render(self.bufnr, self.messages, opts, self)
end

---@param event AgentEvent
function RemoteSession:_handle_event(event)
  log.log("EVENT", event)
  if event.type == "extension_ui_request" then
    extension_ui.handle_request(self.client, event)
    return
  end

  if event.type == "agent_start" then
    self:_reset_streaming()
    self._tool_executions = {}
    self.is_streaming = true
    self:_trigger_render()
    return
  end

  if event.type == "agent_end" then
    self.is_streaming = false
    self.messages = event.messages or self.messages
    self:_reset_streaming()
    self._tool_executions = {}
    self:_trigger_render()
    return
  end

  if event.type == "message_start" then
    if event.message and event.message.role == "assistant" then
      self._streaming_message = event.message
      self._streaming_text = ""
      self._streaming_thinking = ""
    end
    return
  end

  if event.type == "message_update" then
    local assistant_event = event.assistantMessageEvent
    if not assistant_event then
      return
    end

    local event_type = assistant_event.type

    if event_type == "text_delta" then
      self._streaming_text = self._streaming_text .. (assistant_event.delta or "")
      self:_trigger_render()
    elseif event_type == "thinking_delta" then
      self._streaming_thinking = self._streaming_thinking .. (assistant_event.delta or "")
      self:_trigger_render()
    elseif event_type == "text_end" then
      self._streaming_text = assistant_event.content or self._streaming_text
    elseif event_type == "thinking_end" then
      self._streaming_thinking = assistant_event.content or self._streaming_thinking
    elseif event_type == "done" or event_type == "error" then
      self._streaming_message = assistant_event.message or event.message
    end
    return
  end

  if event.type == "tool_execution_start" then
    self._tool_executions[event.toolCallId] = {
      name = event.toolName,
      args = event.args,
      status = "running",
    }
    self:_trigger_render()
    return
  end

  if event.type == "tool_execution_update" then
    if self._tool_executions[event.toolCallId] then
      self._tool_executions[event.toolCallId].partial_result = event.partialResult
    end
    return
  end

  if event.type == "tool_execution_end" then
    if self._tool_executions[event.toolCallId] then
      self._tool_executions[event.toolCallId].status = "done"
      self._tool_executions[event.toolCallId].result = event.result
      self._tool_executions[event.toolCallId].is_error = event.isError
    end
    self:_trigger_render()
    return
  end
end

function RemoteSession:connect(port)
  local promise = Promise.new()
  local cfg = config.get()

  port = port or cfg.default_port
  local client = RpcClient.new({
    host = cfg.host,
    port = port,
  })

  local session = self
  client:connect():and_then(function()
    session.client = client
    session.event_unsubscribe = client:on_event(function(event)
      session:_handle_event(event)
    end)

    return client:get_messages()
  end):and_then(function(messages)
    session.messages = messages or {}
    session:_start_connection_check()
    promise:resolve(session)
  end):catch(function(err)
    session.client = nil
    session.event_unsubscribe = nil
    promise:reject(err)
  end)

  return promise
end

function RemoteSession:open_window(opts)
  opts = opts or {}
  local cfg = config.get()

  self.bufnr = buffer.create(self)

  local vertical = opts.vertical
  if vertical == nil then
    vertical = cfg.split_direction == "vertical"
  end

  if vertical then
    vim.cmd("vsplit")
  else
    vim.cmd("split")
  end

  self.winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.winid, self.bufnr)

  vim.api.nvim_win_set_option(self.winid, "wrap", true)
  vim.api.nvim_win_set_option(self.winid, "linebreak", true)
  vim.api.nvim_win_set_option(self.winid, "signcolumn", "no")
  vim.api.nvim_win_set_option(self.winid, "number", false)
  vim.api.nvim_win_set_option(self.winid, "relativenumber", false)
  vim.api.nvim_win_set_option(self.winid, "cursorline", true)

  buffer.move_cursor_to_input(self.bufnr, self.winid)

  self:_render({ is_streaming = self.is_streaming })

  return self.winid
end

function RemoteSession:send(text)
  local promise = Promise.new()

  if not self:is_active() then
    promise:reject("Not connected to RPC server")
    return promise
  end

  local user_message = {
    role = "user",
    content = text,
    timestamp = os.time() * 1000,
  }
  table.insert(self.messages, user_message)
  self:_trigger_render()

  if self.is_streaming then
    return self.client:steer(text)
  end

  return self.client:prompt(text)
end

function RemoteSession:close()
  self:_stop_connection_check()
  self:_cancel_render_timer()

  if self.event_unsubscribe then
    self.event_unsubscribe()
    self.event_unsubscribe = nil
  end

  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_win_close(self.winid, true)
  end
  self.winid = nil

  if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_delete(self.bufnr, { force = true })
  end
  self.bufnr = nil

  extension_ui.clear()

  if self.client then
    self.client:disconnect()
    self.client = nil
  end

  self.messages = {}
  self.is_streaming = false
  self:_reset_streaming()
  self._tool_executions = {}
end

function RemoteSession:is_active()
  return self.client ~= nil and self.client:is_connected()
end

function RemoteSession:focus()
  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_set_current_win(self.winid)
    return true
  end
  return false
end

function RemoteSession:get_rpc_state()
  if not self:is_active() then
    return nil
  end
  return self.client:get_state()
end

function RemoteSession:get_port()
  if self.client and self.client._options then
    return self.client._options.port
  end
  return nil
end

function RemoteSession:get_bufnr()
  return self.bufnr
end

function RemoteSession:get_winid()
  return self.winid
end

function RemoteSession:get_messages()
  return self.messages
end

function RemoteSession:get_tool_executions()
  return self._tool_executions
end

function RemoteSession:abort()
  if self.client then
    self.client:abort()
  end
end

return RemoteSession
