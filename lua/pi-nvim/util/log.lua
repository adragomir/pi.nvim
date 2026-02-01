local M = {}

local log_path = vim.fn.stdpath("state") .. "/pi.log"

function M.log(...)
  local args = { ... }
  local parts = {}

  for _, arg in ipairs(args) do
    if type(arg) == "string" then
      table.insert(parts, arg)
    else
      table.insert(parts, vim.inspect(arg))
    end
  end

  local line = os.date("%Y-%m-%d %H:%M:%S") .. " " .. table.concat(parts, " ") .. "\n"
  local file = io.open(log_path, "a")
  if file then
    file:write(line)
    file:close()
  end
end

return M
