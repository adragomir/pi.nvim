local config = require("pi-nvim.config")

local M = {}

local function split_lines(text)
  if not text or text == "" then
    return {}
  end
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  return lines
end

local function append_lines(target, source)
  for _, line in ipairs(source) do
    table.insert(target, line)
  end
end

function M.format_thinking(thinking_content)
  local cfg = config.get()
  if cfg.formatters.thinking then
    return cfg.formatters.thinking(thinking_content)
  end

  local text = thinking_content.thinking or ""
  local lines = {
    "<details>",
    "<summary>💭 Thinking...</summary>",
    "",
  }
  append_lines(lines, split_lines(text))
  table.insert(lines, "")
  table.insert(lines, "</details>")
  table.insert(lines, "")
  return lines
end

function M.format_tool_call(tool_call)
  local cfg = config.get()
  if cfg.formatters.tool_call then
    return cfg.formatters.tool_call(tool_call)
  end

  local args_json = vim.json.encode(tool_call.args or {})
  local ok, pretty = pcall(function()
    return vim.fn.json_encode(vim.fn.json_decode(args_json))
  end)
  if not ok then
    pretty = args_json
  end

  local lines = {
    "**🔧 Tool: " .. tool_call.name .. "**",
    "",
    "```json",
  }
  for line in pretty:gmatch("[^\n]+") do
    table.insert(lines, line)
  end
  table.insert(lines, "```")
  table.insert(lines, "")
  return lines
end

function M.format_tool_result(tool_name, content, is_error)
  local cfg = config.get()
  if cfg.formatters.tool_result then
    return cfg.formatters.tool_result(tool_name, content, is_error)
  end

  local prefix = is_error and "❌ " or "✅ "
  local lines = {
    "### " .. prefix .. (tool_name or "Tool Result"),
    "",
  }

  local text_content = M.format_content(content)
  append_lines(lines, split_lines(text_content))

  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")
  return lines
end

function M.format_content(content)
  if type(content) == "string" then
    return content
  end

  if type(content) ~= "table" then
    return tostring(content or "")
  end

  local parts = {}
  for _, block in ipairs(content) do
    if block.type == "text" then
      table.insert(parts, block.text or "")
    elseif block.type == "image" then
      table.insert(parts, "[Image]")
    elseif block.type == "thinking" then
      table.insert(parts, "[Thinking: " .. string.sub(block.thinking or "", 1, 50) .. "...]")
    elseif block.type == "tool_use" or block.name then
      table.insert(parts, "[Tool Call: " .. (block.name or "unknown") .. "]")
    else
      table.insert(parts, "[Unknown content type]")
    end
  end

  return table.concat(parts, "\n")
end

function M.render_user_message(msg)
  local lines = {
    "## 👤 User",
    "",
  }

  local content = msg.content
  if type(content) == "string" then
    append_lines(lines, split_lines(content))
  elseif type(content) == "table" then
    append_lines(lines, split_lines(M.format_content(content)))
  end

  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")
  return lines
end

function M.render_assistant_message(msg, streaming_opts)
  local lines = {
    "## 🤖 Assistant",
    "",
  }

  streaming_opts = streaming_opts or {}

  if streaming_opts.streaming_thinking and streaming_opts.streaming_thinking ~= "" then
    local thinking_lines = M.format_thinking({ thinking = streaming_opts.streaming_thinking })
    append_lines(lines, thinking_lines)
  end

  local content = msg.content
  if type(content) == "table" then
    for _, block in ipairs(content) do
      if block.type == "text" then
        append_lines(lines, split_lines(block.text or ""))
      elseif block.type == "thinking" then
        local thinking_lines = M.format_thinking(block)
        append_lines(lines, thinking_lines)
      elseif block.type == "tool_use" or block.name then
        local tool_lines = M.format_tool_call(block)
        append_lines(lines, tool_lines)
      end
    end
  elseif type(content) == "string" then
    append_lines(lines, split_lines(content))
  end

  if streaming_opts.streaming_text and streaming_opts.streaming_text ~= "" then
    append_lines(lines, split_lines(streaming_opts.streaming_text))
  end

  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")
  return lines
end

function M.render_tool_result_message(msg)
  return M.format_tool_result(msg.toolName, msg.content, msg.isError)
end

function M.render_message(msg, streaming_opts)
  local role = msg.role

  if role == "user" then
    return M.render_user_message(msg)
  elseif role == "assistant" then
    return M.render_assistant_message(msg, streaming_opts)
  elseif role == "toolResult" then
    return M.render_tool_result_message(msg)
  else
    return { "<!-- Unknown message role: " .. tostring(role) .. " -->", "" }
  end
end

function M.render_messages(messages, streaming_opts)
  local lines = {}
  streaming_opts = streaming_opts or {}

  for i, msg in ipairs(messages or {}) do
    local is_last = i == #messages
    local msg_streaming_opts = nil

    if is_last and msg.role == "assistant" and streaming_opts.is_streaming then
      msg_streaming_opts = streaming_opts
    end

    local msg_lines = M.render_message(msg, msg_streaming_opts)
    append_lines(lines, msg_lines)
  end

  if streaming_opts.is_streaming and streaming_opts.streaming_message then
    local dominated_by_existing = false
    if #messages > 0 then
      local last = messages[#messages]
      if last.role == "assistant" then
        dominated_by_existing = true
      end
    end

    if not dominated_by_existing then
      local msg_lines = M.render_assistant_message(streaming_opts.streaming_message, streaming_opts)
      append_lines(lines, msg_lines)
    end
  elseif streaming_opts.is_streaming and (streaming_opts.streaming_text or streaming_opts.streaming_thinking) then
    local has_assistant = false
    if #messages > 0 and messages[#messages].role == "assistant" then
      has_assistant = true
    end

    if not has_assistant then
      local lines_new = {
        "## 🤖 Assistant",
        "",
      }
      if streaming_opts.streaming_thinking and streaming_opts.streaming_thinking ~= "" then
        local thinking_lines = M.format_thinking({ thinking = streaming_opts.streaming_thinking })
        append_lines(lines_new, thinking_lines)
      end
      if streaming_opts.streaming_text and streaming_opts.streaming_text ~= "" then
        append_lines(lines_new, split_lines(streaming_opts.streaming_text))
      end
      table.insert(lines_new, "")
      table.insert(lines_new, "---")
      table.insert(lines_new, "")
      append_lines(lines, lines_new)
    end
  end

  return lines
end

return M
