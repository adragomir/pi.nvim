local M = {}

local defaults = {
  host = "127.0.0.1",
  default_port = 9999,
  split_direction = "horizontal",
  pi_command = "pi",
  filetype = "pi",
  prompt_format = "In file `{file}` lines {start_line}-{end_line}:\n```{filetype}\n{selection}\n```\n\n{prompt}",
  keymaps = {
    visual_prompt = "<leader>pi",
  },
  formatters = {
    thinking = nil,
    tool_call = nil,
    tool_result = nil,
  },
  streaming = {
    enabled = true,
    throttle_ms = 50,
  },
}

local config = {}

function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})
end

function M.get()
  return config
end

return M
