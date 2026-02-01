local M = {}

local config = require("pi-nvim.config")
local state = require("pi-nvim.state")

local function register_commands()
  state.setup_autocmds()
  vim.api.nvim_create_user_command("PiAgent", function(opts)
    local args = opts.fargs
    local vertical = opts.smods and opts.smods.vertical or false

    if #args == 0 then
      vim.notify("Usage: :PiAgent new | <port> | disconnect | status", vim.log.levels.INFO)
      return
    end

    local subcmd = args[1]

    if subcmd == "new" then
      local session = require('pi-nvim.embed.session').new()
      state.set_session(session)
      session.open({vertical = vertical})
      return
    end

    if string.match(subcmd, "^%d+$") then
      local port = tonumber(subcmd)
      if port then
        local session = state.get_session()
        if session then
          vim.notify("Session already active. Disconnect first.", vim.log.levels.WARN)
          return
        end
        session = require('pi-nvim.remote.session').new()
        state.set_session(session)
        session:connect(port):and_then(function(_val)
          session:open_window({vertical = vertical})
        end):catch(function(err)
          state.set_session(nil)
          vim.notify("Failed to connect: " .. tostring(err), vim.log.levels.ERROR)
        end)
        return
      end
    end

    -- rest commands need session
    local session = state.get_session()
    if not session then
      vim.notify("No active Pi Agent session", vim.log.levels.WARN)
      return
    end
    if subcmd == "disconnect" then
      session:close()
      state.set_session(nil)
      return
    end

    if subcmd == "status" then
      local running = session:is_active() and "running" or "stopped"
      vim.notify("Mode: " .. session.mode .. "(" .. running .. ")", vim.log.levels.INFO)
      return
    end

    if subcmd == "focus" then
      session:focus()
      return
    end

    if subcmd == "abort" then
      session:abort()
      return
    end
    vim.notify("Unknown subcommand: " .. subcmd, vim.log.levels.ERROR)
  end, {
    nargs = "*",
    complete = function(arglead, cmdline, cursorpos)
      local completions = { "new", "disconnect", "status", "focus", "abort" }

      if arglead == "" then
        return completions
      end

      local matches = {}
      for _, c in ipairs(completions) do
        if vim.startswith(c, arglead) then
          table.insert(matches, c)
        end
      end
      return matches
    end,
    desc = "Pi Agent commands",
  })
end

local function register_keymaps()
  local cfg = config.get()
  local keymap = cfg.keymaps.visual_prompt

  if keymap then
    vim.keymap.set("v", keymap, function()
      local session = state.get_session()
      if not session then
        vim.notify("No active Pi Agent session", vim.log.levels.WARN)
        return
      end

      local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
      vim.api.nvim_feedkeys(esc, "x", false)

      vim.schedule(function()
        local popup = require("pi-nvim.ui.popup")
        popup.handle_visual_selection()
      end)
    end, { desc = "Send selection to Pi Agent" })
  end
end

function M.setup(opts)
  config.setup(opts)
  register_commands()
  register_keymaps()
end

return M
