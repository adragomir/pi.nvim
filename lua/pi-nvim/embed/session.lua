local config = require("pi-nvim.config")
local state = require("pi-nvim.state")

local EmbedSession = {}
EmbedSession.__index = EmbedSession

local function setup_buffer_cleanup(bufnr, session)
  local group = vim.api.nvim_create_augroup("PiNvimEmbedCleanup" .. bufnr, { clear = true })

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

function EmbedSession.new()
  local self = setmetatable({
    mode = "embed",
    bufnr = nil,
    winid = nil,
    job_id = nil,
  }, EmbedSession)
  return self
end

function EmbedSession:open(opts)
  opts = opts or {}
  local cfg = config.get()

  local vertical = opts.vertical
  if vertical == nil then
    vertical = cfg.split_direction == "vertical"
  end

  if vertical then
    vim.cmd("vsplit")
  else
    vim.cmd("split")
  end

  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "hide")
  vim.api.nvim_win_set_buf(winid, bufnr)

  local session = self
  local job_id = vim.fn.termopen(cfg.pi_command, {
    on_exit = function(_, exit_code, _)
      vim.schedule(function()
        session.job_id = nil
      end)
    end,
  })

  if job_id <= 0 then
    vim.api.nvim_win_close(winid, true)
    return false, "Failed to start terminal: " .. cfg.pi_command
  end

  self.bufnr = bufnr
  self.winid = winid
  self.job_id = job_id

  setup_buffer_cleanup(bufnr, self)

  vim.cmd("startinsert")
  return true
end

function EmbedSession:send(text)
  if not self:is_active() then
    return false, "Terminal is not running"
  end

  vim.fn.chansend(self.job_id, text)
  return true
end

function EmbedSession:close()
  if self.job_id then
    pcall(vim.fn.jobstop, self.job_id)
    self.job_id = nil
  end

  self.winid = nil
  self.bufnr = nil
end

function EmbedSession:is_active()
  if not self.job_id then
    return false
  end

  local ok, running = pcall(vim.fn.jobwait, { self.job_id }, 0)
  if not ok then
    return false
  end

  return running[1] == -1
end

function EmbedSession:focus()
  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_set_current_win(self.winid)
    vim.cmd("startinsert")
    return true
  end
  return false
end

function EmbedSession:abort()
  vim.notify("Abort only works in RPC mode", vim.log.levels.WARN)
end

return EmbedSession
