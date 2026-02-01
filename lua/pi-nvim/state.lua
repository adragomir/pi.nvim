local M = {}

local tab_states = {}

function M.get_state(tabnr)
  tabnr = tabnr or vim.api.nvim_get_current_tabpage()
  if not tab_states[tabnr] then
    tab_states[tabnr] = {session = nil}
  end
  return tab_states[tabnr]
end

function M.set_session(session, tabnr)
  tabnr = tabnr or vim.api.nvim_get_current_tabpage()
  if not tab_states[tabnr] then
    tab_states[tabnr] = {session = nil}
  end
  tab_states[tabnr].session = session
end

function M.get_session(tabnr)
  local state = M.get_state(tabnr)
  return state.session
end

function M.clear_state(tabnr)
  tabnr = tabnr or vim.api.nvim_get_current_tabpage()
  local state = tab_states[tabnr]

  if state and state.session then
    state.session:close()
    state.session = nil
  end

  tab_states[tabnr] = nil
end

function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("PiNvimState", { clear = true })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function(ev)
      local tabnr = tonumber(ev.file)
      if tabnr and tab_states[tabnr] then
        M.clear_state(tabnr)
      end
    end,
  })
end

return M
