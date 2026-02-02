local M = {}

local sessions = {}

function M.set_session(session, bufnr)
  if not session or not bufnr then
    return
  end
  sessions[bufnr] = session
end

function M.get_session(bufnr)
  if not bufnr then
    return nil
  end
  return sessions[bufnr]
end

function M.clear_session(bufnr)
  if not bufnr then
    return
  end
  sessions[bufnr] = nil
end

function M.get_visible_session()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local list = {}
  local unique = {}

  for _, win in ipairs(wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    local session = sessions[buf]
    if session and not unique[session] then
      unique[session] = true
      table.insert(list, session)
    end
  end

  if #list == 1 then
    return list[1]
  end
  if #list == 0 then
    return nil, "No visible Pi Agent session"
  end
  return nil, "Multiple visible Pi Agent sessions"
end

return M
