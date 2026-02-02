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
    is_working = false,
    event_unsubscribe = nil,
    _connection_timer = nil,
    _last_render_time = 0,
    _render_timer = nil,
  }, RemoteSession)
  return self
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
  self.is_working = false

  if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
    self:_render(nil, { disconnected = true })
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
  self:_render(nil)
end

function RemoteSession:_trigger_render()
  if not self.bufnr then
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

---@param message Message?
function RemoteSession:_render(message, opts)
  buffer.render(self.bufnr, message, opts, self)
end

---@param event ExtensionEvent
function RemoteSession:_handle_event(event)
  -- ignored events
  if event.type == 'tool_call' or event.type == 'tool_result' then
    return
  end

  if event.type == "extension_ui_request" then
    extension_ui.handle_request(self.client, event)
    return
  end

  if event.type == "agent_start" then
    self.is_working = true
    -- self:_trigger_render()
    return
  end

  if event.type == "agent_end" then
    self.is_working = false
    self.messages = event.messages or self.messages
    -- self:_trigger_render()
    return
  end

  if event.type == "message_end" then
    log.log("EVENT: ", event)
    if event.message.role == "user" then
      -- render the message
      self:_render(event.message)
    elseif event.message.role == "assistant" then
      self:_render(event.message)
    elseif event.message.role == 'toolResult' then
      self:_render(event.message)
    end
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

  self:_render(nil, { is_working = self.is_working })

  return self.winid
end

function RemoteSession:send(text)
  local promise = Promise.new()

  if not self:is_active() then
    promise:reject("Not connected to RPC server")
    return promise
  end

  if self.is_working then
    return self.client:steer(text)
  end

  return self.client:prompt(text)
end

function RemoteSession:close(opts)
  opts = opts or {}
  local skip_buf_delete = opts.skip_buf_delete

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

  if not skip_buf_delete and self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_delete(self.bufnr, { force = true })
  end
  self.bufnr = nil

  extension_ui.clear()

  if self.client then
    self.client:disconnect()
    self.client = nil
  end

  self.messages = {}
  self.is_working = false
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

function RemoteSession:get_winid()
  return self.winid
end

function RemoteSession:abort()
  if self.client then
    self.client:abort()
  end
end

return RemoteSession
