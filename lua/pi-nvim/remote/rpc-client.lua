---@brief [[
--- RPC Client for programmatic access to the pi coding agent from Neovim.
---
--- Connects to the agent via TCP socket and provides a typed API for all operations.
--- Uses the same JSON line protocol as the built-in RPC mode.
---
--- Usage:
---   local RpcClient = require('rpc-client')
---   local Promise = require('promise')
---
---   local client = RpcClient.new({ host = '127.0.0.1', port = 9999 })
---
---   -- Using promises
---   client:connect():and_then(function()
---     return client:prompt('Hello!')
---   end):and_then(function()
---     return client:wait_for_idle()
---   end):and_then(function()
---     return client:get_state()
---   end):and_then(function(state)
---     print('Model: ' .. (state.model and state.model.id or 'none'))
---   end)
---
---   -- Using async/await pattern
---   Promise.spawn(function()
---     client:connect():await()
---     client:prompt('Hello!'):await()
---     client:wait_for_idle():await()
---     local state = client:get_state():await()
---     print('Model: ' .. (state.model and state.model.id or 'none'))
---   end)
---@brief ]]

local Promise = require('pi-nvim.util.promise')

-- ============================================================================
-- Type Definitions
-- ============================================================================

---@alias ThinkingLevel 'off' | 'low' | 'medium' | 'high' | 'xhigh'
---@alias SteeringMode 'all' | 'one-at-a-time'
---@alias FollowUpMode 'all' | 'one-at-a-time'
---@alias StreamingBehavior 'steer' | 'followUp'

---@class TextContent
---@field type 'text'
---@field text string
---@field textSignature string|nil

---@class ThinkingContent
---@field type 'thinking'
---@field thinking string
---@field thinkingSignature string|nil

---@class ImageContent
---@field type 'image'
---@field data string
---@field mimeType string

---@class ToolCall
---@field type 'toolCall'
---@field id string
---@field name string
---@field arguments table<string, any>
---@field thoughtSignature string|nil

---@class Usage
---@field type 'toolCall'
---@field input number
---@field cacheRead number
---@field cacheWrite number
---@field totalTokens number
---@field cost {input: number, output: number, cacheRead: number, cacheWrite: number, total: number}

---@alias StopReason 'stop' | 'length' | 'toolUse' | 'error' | 'aborted'

---@class UserMessage
---@field role 'user'
---@field content string | (TextContent | ImageContent)[]
---@field timestamp integer

---@class AssistantMessage
---@field role 'assistant'
---@field content (TextContent | ThinkingContent | ToolCall)[]
---@field api string
---@field provider string
---@field model string
---@field usage Usage
---@field stopReason StopReason
---@field errorMessage string?
---@field timestamp integer

---@class ToolResultMessage
---@field role 'toolResult'
---@field toolCallId string
---@field toolName string
---@field content (TextContent | ImageContent)[]
---@field details any?
---@field isError boolean
---@field timestamp integer

---@alias Message UserMessage | AssistantMessage | ToolResultMessage
  
---@alias AssistantMessageEvent
---  { type: 'start', partial: AssistantMessage }
---| { type: 'text_start', contentIndex: number, partial: AssistantMessage }
---| { type: 'text_delta', contentIndex: number, delta: string, partial: AssistantMessage }
---| { type: 'text_end', contentIndex: number, content: string, partial: AssistantMessage }
---| { type: 'thinking_start', contentIndex: number, partial: AssistantMessage }
---| { type: 'thinking_delta', contentIndex: number, delta: string, partial: AssistantMessage }
---| { type: 'thinking_end', contentIndex: number, content: string, partial: AssistantMessage }
---| { type: 'toolcall_start', contentIndex: number, partial: AssistantMessage }
---| { type: 'toolcall_delta', contentIndex: number, delta: string, partial: AssistantMessage }
---| { type: 'toolcall_end', contentIndex: number, toolCall: ToolCall, partial: AssistantMessage }
---| { type: 'done', reason: StopReason, message: AssistantMessage }
---| { type: 'error', reason: StopReason, error: AssistantMessage },

---@alias RpcCommand
---| { id: string?, type: 'prompt', message: string, images: ImageContent[]?, streamingBehavior: ('steer' | 'followUp')? }
---| { id: string?, type: 'steer', message: string }
---| { id: string?, type: 'follow_up', message: string }
---| { id: string?, type: 'abort' }
---| { id: string?, type: 'new_session', parentSession?: string }
---| { id: string?, type: 'get_state' }
---| { id: string?, type: 'set_model', provider: string, modelId: string }
---| { id: string?, type: 'cycle_model' }
---| { id: string?, type: 'get_available_models' }
---| { id: string?, type: 'set_thinking_level', level: ThinkingLevel }
---| { id: string?, type: 'cycle_thinking_level' }
---| { id: string?, type: 'set_steering_mode', mode: 'all' | 'one-at-a-time' }
---| { id: string?, type: 'set_follow_up_mode', mode: 'all' | 'one-at-a-time' }
---| { id: string?, type: 'compact', customInstructions: string? }
---| { id: string?, type: 'set_auto_compaction', enabled: boolean }
---| { id: string?, type: 'set_auto_retry', enabled: boolean }
---| { id: string?, type: 'abort_retry' }
---| { id: string?, type: 'bash', command: string }
---| { id: string?, type: 'abort_bash' }
---| { id: string?, type: 'get_session_stats' }
---| { id: string?, type: 'export_html', outputPath: string? }
---| { id: string?, type: 'switch_session', sessionPath: string }
---| { id: string?, type: 'fork', entryId: string }
---| { id: string?, type: 'get_fork_messages' }
---| { id: string?, type: 'get_last_assistant_text' }
---| { id: string?, type: 'set_session_name', name: string }
---| { id: string?, type: 'get_messages' }
---| { id: string?, type: 'get_commands' },

---@class RpcSlashCommand
---@field name string
---@field description string?
---@field source 'extension' | 'template' | 'skill'
---@field location 'user' | 'project' | 'path' | nil
---@field path string?

---@class Model
---@field id string
---@field name string
---@field api string
---@field provider string
---@field baseUrl string
---@field reasoning boolean
---@field input ('text' | 'image')[]
---@field cost {input: number, output: number, cacheRead: number, cacheWrite: number }
---@field contextWindow number
---@field maxTokens number
---@field headers table<string, string>?

---@class RpcSessionState
---@field model Model?
---@field thinkingLevel ThinkingLevel
---@field isStreaming boolean
---@field isCompacting boolean
---@field steeringMode SteeringMode
---@field followUpMode FollowUpMode
---@field sessionFile string?
---@field sessionId string
---@field sessionName string?
---@field autoCompactionEnabled boolean
---@field messageCount number
---@field pendingMessageCount number

---@class CompactionResult
---@field summary string
---@field firstKeptEntryId string
---@field tokensBefore number
---# Extension-specific data (e.g., ArtifactIndex, version markers for structured compaction)
---@field details any?

---@class SessionStats
---@field sessionFile string | nil
---@field sessionId string
---@field userMessages number
---@field assistantMessages number
---@field toolCalls number
---@field toolResults number
---@field totalMessages number
---@field tokens { input: number, output: number, cacheRead: number, cacheWrite: number, total: number }
---@field cost number

---@alias RpcResponse
---# Prompting (async - events follow)
---| { id: string?, type: 'response', command: 'prompt', success: true }
---| { id: string?, type: 'response', command: 'steer', success: true }
---| { id: string?, type: 'response', command: 'follow_up', success: true }
---| { id: string?, type: 'response', command: 'abort', success: true }
---| { id: string?, type: 'response', command: 'new_session', success: true, data: { cancelled: boolean } }
---# State
---| { id: string?, type: 'response', command: 'get_state', success: true, data: RpcSessionState }
---# Model
---| { id: string?, type: 'response', command: 'set_model', success: true, data: Model }
---| { id: string?, type: 'response', command: 'cycle_model', success: true, data: { model: Model<any>, thinkingLevel: ThinkingLevel, isScoped: boolean } | nil }
---| { id: string?, type: 'response', command: 'get_available_models', success: true, data: { models: Model[] } }
---# Thinking
---| { id: string?, type: 'response', command: 'set_thinking_level', success: true }
---| { id: string?, type: 'response', command: 'cycle_thinking_level', success: true, data: { level: ThinkingLevel } | nil }
---# Queue modes
---| { id: string?, type: 'response', command: 'set_steering_mode', success: true }
---| { id: string?, type: 'response', command: 'set_follow_up_mode', success: true }
---# Compaction
---| { id: string?, type: 'response', command: 'compact', success: true, data: CompactionResult }
---| { id: string?, type: 'response', command: 'set_auto_compaction', success: true }
---# Retry
---| { id: string?, type: 'response', command: 'set_auto_retry', success: true }
---| { id: string?, type: 'response', command: 'abort_retry', success: true }
---# Bash
---| { id: string?, type: 'response', command: 'bash', success: true, data: BashResult }
---| { id: string?, type: 'response', command: 'abort_bash', success: true }
---# Session
---| { id: string?, type: 'response', command: 'get_session_stats', success: true, data: SessionStats }
---| { id: string?, type: 'response', command: 'export_html', success: true, data: { path: string } }
---| { id: string?, type: 'response', command: 'switch_session', success: true, data: { cancelled: boolean } }
---| { id: string?, type: 'response', command: 'fork', success: true, data: { text: string, cancelled: boolean } }
---| { id: string?, type: 'response', command: 'get_fork_messages', success: true, data: { messages: { entryId: string, text: string }[] } }
---| { id: string?, type: 'response', command: 'get_last_assistant_text', success: true, data: { text: string | nil } }
---| { id: string?, type: 'response', command: 'set_session_name', success: true }
---# Messages
---| { id: string?, type: 'response', command: 'get_messages', success: true, data: { messages: AgentMessage[] } }
---# Commands
---| { id: string?, type: 'response', command: 'get_commands', success: true, data: { commands: RpcSlashCommand[] } }
---# Error response (any command can fail)
---| { id: string?, type: 'response', command: string, success: false, error: string },

---@class BashResult
---@field output string
---@field exitCode number?
---@field cancelled boolean
---@field truncated boolean
---@field fullOutputPath string?

---@class SessionStats
---@field messageCount number
---@field tokenCount number
---@field contextUsage number

---@class ForkMessage
---@field entryId string
---@field text string

---@alias AgentMessage Message

---@alias AgentEvent
--- # Agent lifecycle
--- | { type: "agent_start" }
--- | { type: "agent_end", messages: AgentMessage[] }
--- # Turn lifecycle - a turn is one assistant response + any tool calls/results
--- | { type: "turn_start" }
--- | { type: "turn_end", message: AgentMessage, toolResults: ToolResultMessage[] }
--- # Message lifecycle - emitted for user, assistant, and toolResult messages
--- | { type: "message_start", message: AgentMessage }
--- # Only emitted for assistant messages during streaming
--- | { type: "message_update", message: AgentMessage, assistantMessageEvent: AssistantMessageEvent }
--- | { type: "message_end", message: AgentMessage }
--- # Tool execution lifecycle
--- | { type: "tool_execution_start", toolCallId: string, toolName: string, args: any }
--- | { type: "tool_execution_update", toolCallId: string, toolName: string, args: any, partialResult: any }
--- | { type: "tool_execution_end", toolCallId: string, toolName: string, result: any, isError: boolean },

---@alias AgentEventWire
--- # Agent lifecycle
--- | { type: "agent_start" }
--- | { type: "agent_end", messages: AgentMessage[] }
--- # Turn lifecycle - a turn is one assistant response + any tool calls/results
--- | { type: "turn_start", turnIndex: integer, timestamp: integer }
--- | { type: "turn_end", turnIndex: integer, message: AgentMessage, toolResults: ToolResultMessage[] }
--- # Message lifecycle - emitted for user, assistant, and toolResult messages
--- | { type: "message_start", turnIndex: integer, timestamp: integer, message: AgentMessage }
--- # Only emitted for assistant messages during streaming
--- | { type: "message_update", turnIndex: integer, message: AgentMessage, assistantMessageEvent: AssistantMessageEvent }
--- | { type: "message_end", turnIndex: integer, message: AgentMessage }
--- # Tool execution lifecycle
--- | { type: "tool_execution_start", turnIndex: integer, timestamp: integer, toolCallId: string, toolName: string, args: any }
--- | { type: "tool_execution_update", turnIndex: integer, toolCallId: string, toolName: string, args: any, partialResult: any }
--- | { type: "tool_execution_end", turnIndex: integer, toolCallId: string, toolName: string, result: any, isError: boolean },

---@class ResourcesDiscoverEvent
---@field type 'resource_discover'
---@field cwd string
---@field reason 'startup' | 'reload'

---@class SessionStartEvent
---@field type 'session_start'
---
---@class SessionBeforeSwitchEvent
---@field type 'session_before_switch'
---@field reason 'new' | 'resume'
---@field targetSessionFile string?

---@class SessionSwitchEvent
---@field type 'session_switch'
---@field reason 'new' | 'resume'
---@field previousSessionFile string?

---@class SessionBeforeForkEvent
---@field type 'session_before_fork'
---@field entryId string

---@class SessionForkEvent
---@field type 'session_fork'
---@field previousSessionFile string?

---@class FileOperations
---@field read string[]
---@field written string[]
---@field edited string[]

---@class CompactionSettings
---@field enabled boolean
---@field reserveTokens integer
---@field keepRecentTokens integer

---@class CompactionPreparation
---@field firstKeptEntryId string
---@field messagesToSummarize Message[]
---@field turnPrefixMessages Message[]
---@field isSplitTurn boolean
---@field tokensBefore integer
---@field previousSummary string?
---@field fileOps FileOperations[]
---@field settings CompactionSettings

---@class SessionMessageEntry
---@field type 'message'
---@field message Message

---@class ThinkingLevelChangeEntry
---@field type 'thinking_level_change'
---@field thinkingLevel integer

---@class ModelChangeEntry
---@field type 'model_change'
---@field provider string
---@field modelId string

---@class BranchSummaryEntry
---@field type 'branch_summary'
---@field summary string
---@field firstKeptEntryId string
---@field tokensBefore integer
---@field details any?
---@field fromHook boolean?

---@class CustomEntry
---@field type 'custom'
---@field customType string
---@field data any?

---@class CustomMessageEntry
---@field type 'custom_message'
---@field customType string
---@field content string | (TextContent | ImageContent)[]
---@field details any?
---@field display boolean

---@class LabelEntry
---@field type 'label'
---@field targetId string
---@field label string?

---@class SessionInfoEntry
---@field type 'session_info'
---@field name string?

---@alias SessionEntry
---SessionMessageEntry
---| ThinkingLevelChangeEntry
---| ModelChangeEntry
---| CompactionEntry
---| BranchSummaryEntry
---| CustomEntry
---| CustomMessageEntry
---| LabelEntry
---| SessionInfoEntry

---@class CompactionEntry
---@field type 'compaction'
---@field summary string
---@field firstKeptEntryId string
---@field tokensBefore integer
---@field details any?
---@field fromHook boolean?

---@class SessionBeforeCompactEvent
---@field type 'session_before_compact'
---@field previousSessionFile string?

---@class SessionCompactEvent
---@field type 'session_compact'
---@field compactionEntry CompactionEntry
---@field fromExtension boolean

---@class SessionShutdownEvent
---@field type 'session_shutdown'

---@class TreePreparation
---@field targetId string
---@field oldLeafId string?
---@field commonAncestorId string?
---@field entriesToSummarize SessionEntry[]
---@field userWantsSummary boolean
---@field customInstructions string?
---@field replaceInstructions boolean?
---@field label string?

---@class SessionBeforeTreeEvent
---@field type 'session_before_tree'
---@field preparation TreePreparation
---@field signal any

---@class SessionTreeEvent
---@field newLeafId string | nil
---@field oldLeafId string | nil
---@field summaryEntry BranchSummaryEntry?
---@field fromExtension boolean?

---@alias SessionEvent
--- SessionStartEvent
---| SessionBeforeSwitchEvent
---| SessionSwitchEvent
---| SessionBeforeForkEvent
---| SessionForkEvent
---| SessionBeforeCompactEvent
---| SessionCompactEvent
---| SessionShutdownEvent
---| SessionBeforeTreeEvent
---| SessionTreeEvent

---@class ContextEvent
---@field type 'context'
---@field messages Message[]


---@class BeforeAgentStartEvent
---@field type 'before_agent_start'
---@field prompt string
---@field images ImageContent[]?
---@field systemPrompt string

---@class AgentStartEvent
---@field type 'agent_start'



---@class AgentEndEvent
---@field type 'agent_end'
---@field messages Message[]

---@class TurnStartEvent
---@field type "turn_start"
---@field turnIndex integer
---@field timestamp integer

---@class TurnEndEvent
---@field type "turn_end"
---@field turnIndex integer
---@field message Message
---@field toolResults ToolResultMessage[]

---@class MessageStartEvent
---@field type "message_start"
---@field turnIndex integer
---@field timestamp integer
---@field message Message

---@class MessageUpdateEvent
---@field type "message_update"
---@field turnIndex integer
---@field message Message
---@field assistantMessageEvent AssistantMessageEvent

---@class MessageEndEvent
---@field type "message_end"
---@field turnIndex integer
---@field message Message

---@class ToolExecutionStartEvent
---@field type "tool_execution_start"
---@field turnIndex integer
---@field timestamp integer
---@field toolCallId string
---@field toolName string
---@field args any

---@class ToolExecutionUpdateEvent
---@field type "tool_execution_update"
---@field turnIndex integer
---@field toolCallId string
---@field toolName string
---@field args any
---@field partialResult any

---@class ToolExecutionEndEvent
---@field type "tool_execution_end"
---@field turnIndex integer
---@field toolCallId string
---@field toolName string
---@field result any
---@field isError boolean

---@alias ModelSelectSource "set" | "cycle" | "restore"

---@class ModelSelectEvent
---@field type "model_select"
---@field model Model
---@field previousModel Model
---@field source ModelSelectSource

---@class UserBashEvent
---@field type "user_bash"
---@field command string
---@field excludeFromContext boolean
---@field cwd string

---@alias InputSource "interactive" | "rpc" | "extension"

---@class InputEvent
---@field type "input"
---@field text string
---@field images ImageContent[]
---@field source InputSource

---@class ToolCallEventBase
---@field type 'tool_call'
---@field toolCallId string

---@class BashToolInput
---@field command string
---@field timeout number?

---@class BashToolCallEvent: ToolCallEventBase
---@field toolName 'bash'
---@field input BashToolInput

---@class ReadToolInput
---@field path string
---@field offset number?
---@field limit number?

---@class ReadToolCallEvent: ToolCallEventBase
---@field toolName 'read'
---@field input ReadToolInput

---@class EditToolInput
---@field path string
---@field oldText string
---@field newText string

---@class EditToolCallEvent: ToolCallEventBase
---@field toolName 'edit'
---@field input EditToolInput

---@class WriteToolInput
---@field path string
---@field content string

---@class WriteToolCallEvent: ToolCallEventBase
---@field toolName 'write'
---@field input WriteToolInput

---@class GrepToolInput
---@field pattern string
---@field path string?
---@field glob string?
---@field ignoreCase boolean?
---@field literal boolean?
---@field context number?
---@field limit number?

---@class GrepToolCallEvent: ToolCallEventBase
---@field toolName 'grep'
---@field input GrepToolInput

---@class FindToolInput
---@field pattern string
---@field path string?
---@field limit number?

---@class FindToolCallEvent: ToolCallEventBase
---@field toolName 'find'
---@field input FindToolInput

---@class LsToolInput
---@field path string?
---@field limit number?

---@class LsToolCallEvent: ToolCallEventBase
---@field toolName 'ls'
---@field input LsToolInput

---@class CustomToolCallEvent: ToolCallEventBase
---@field toolName string
---@field input table<string, string>

---@alias ToolCallEvent
--- BashToolCallEvent
--- | ReadToolCallEvent
--- | EditToolCallEvent
--- | WriteToolCallEvent
--- | GrepToolCallEvent
--- | FindToolCallEvent
--- | LsToolCallEvent
--- | CustomToolCallEvent

---@class ToolResultEventBase
---@field type "tool_result"
---@field toolCallId string
---@field input table<string, any>
---@field content (TextContent | ImageContent)[]
---@field isError boolean

---@class TruncationResult
---@field content string
---@field truncated boolean
---@field truncatedBy "lines" | "bytes" | nil
---@field totalLines number
---@field totalBytes number
---@field outputLines number
---@field outputBytes number
---@field lastLinePartial boolean
---@field firstLineExceedsLimit boolean
---@field maxLines number
---@field maxBytes number

---@class BashToolDetails
---@field truncation TruncationResult?
---@field fullOutputPath string?

---@class BashToolResultEvent: ToolResultEventBase
---@field toolName "bash"
---@field details BashToolDetails?

---@class ReadToolDetails
---@field truncation TruncationResult?

---@class ReadToolResultEvent: ToolResultEventBase
---@field toolName "read"
---@field details ReadToolDetails?

---@class EditToolDetails
---@field diff string
---@field firstChangedLine number?

---@class EditToolResultEvent: ToolResultEventBase
---@field toolName "edit"
---@field details EditToolDetails?

---@class WriteToolResultEvent: ToolResultEventBase
---@field toolName "write"
---@field details nil

---@class GrepToolDetails
---@field truncation TruncationResult?
---@field matchLimitReached number?
---@field linesTruncated boolean?

---@class GrepToolResultEvent: ToolResultEventBase
---@field toolName "grep"
---@field details GrepToolDetails?

---@class FindToolDetails
---@field truncation TruncationResult?
---@field resultLimitReached number?

---@class FindToolResultEvent: ToolResultEventBase
---@field toolName "find"
---@field details FindToolDetails?

---@class LsToolDetails
---@field truncation TruncationResult?
---@field entryLimitReached number?

---@class LsToolResultEvent: ToolResultEventBase
---@field toolName "ls"
---@field details LsToolDetails?

---@class CustomToolResultEvent: ToolResultEventBase
---@field toolName string
---@field details any

---@alias ToolResultEvent
--- BashToolResultEvent
---| ReadToolResultEvent
---| EditToolResultEvent
---| WriteToolResultEvent
---| GrepToolResultEvent
---| FindToolResultEvent
---| LsToolResultEvent
---| CustomToolResultEvent


---@alias ExtensionEvent
--- ResourcesDiscoverEvent
---| SessionEvent
---| ContextEvent
---| BeforeAgentStartEvent
---| AgentStartEvent
---| AgentEndEvent
---| TurnStartEvent
---| TurnEndEvent
---| MessageStartEvent
---| MessageUpdateEvent
---| MessageEndEvent
---| ToolExecutionStartEvent
---| ToolExecutionUpdateEvent
---| ToolExecutionEndEvent
---| ModelSelectEvent
---| UserBashEvent
---| InputEvent
---| ToolCallEvent
---| ToolResultEvent

---@alias RpcEventListener fun(event: ExtensionEvent): nil

---@class RpcClientOptions
---@field host string|nil Host to connect to (default: '127.0.0.1')
---@field port number|nil Port to connect to (default: 9999)
---@field timeout number|nil Request timeout in ms (default: 30000)

---@class PendingRequest
---@field promise Promise
---@field timer any

-- ============================================================================
-- RPC Client
-- ============================================================================

---@class RpcClient
---@field private _options RpcClientOptions
---@field private _socket any
---@field private _connected boolean
---@field private _event_listeners RpcEventListener[]
---@field private _pending_requests table<string, PendingRequest>
---@field private _request_id number
---@field private _line_buffer string
local RpcClient = {}
RpcClient.__index = RpcClient

---Create a new RPC client
---@param options RpcClientOptions|nil
---@return RpcClient
function RpcClient.new(options)
  options = options or {}
  local self = setmetatable({
    _options = {
      host = options.host or '127.0.0.1',
      port = options.port or 9999,
      timeout = options.timeout or 30000,
    },
    _socket = nil,
    _connected = false,
    _event_listeners = {},
    _pending_requests = {},
    _request_id = 0,
    _line_buffer = '',
  }, RpcClient)
  return self
end

---Connect to the RPC server
---@return Promise<nil>
function RpcClient:connect()
  local promise = Promise.new()

  if self._connected then
    promise:resolve(nil)
    return promise
  end

  local socket = vim.uv.new_tcp()
  self._socket = socket

  socket:connect(self._options.host, self._options.port, function(err)
    if err then
      promise:reject('Failed to connect: ' .. err)
      return
    end

    self._connected = true

    socket:read_start(function(read_err, data)
      if read_err then
        self:_handle_disconnect()
        return
      end
      if data then
        self:_handle_data(data)
      else
        self:_handle_disconnect()
      end
    end)

    promise:resolve(nil)
  end)

  return promise
end

---Disconnect from the RPC server
---@return Promise<nil>
function RpcClient:disconnect()
  local promise = Promise.new()

  if not self._connected then
    promise:resolve(nil)
    return promise
  end

  self:_handle_disconnect()
  promise:resolve(nil)
  return promise
end

---Check if connected
---@return boolean
function RpcClient:is_connected()
  return self._connected
end

---Subscribe to agent events
---@param listener RpcEventListener
---@return fun(): nil Unsubscribe function
function RpcClient:on_event(listener)
  table.insert(self._event_listeners, listener)
  return function()
    for i, l in ipairs(self._event_listeners) do
      if l == listener then
        table.remove(self._event_listeners, i)
        break
      end
    end
  end
end

-- =========================================================================
-- Command Methods
-- =========================================================================

---Send a prompt to the agent
---@param message string
---@param images ImageContent[]|nil
---@return Promise<nil>
function RpcClient:prompt(message, images)
  return self:_send({ type = 'prompt', message = message, images = images }):and_then(function()
    return nil
  end)
end

---Queue a steering message to interrupt the agent mid-run
---@param message string
---@return Promise<nil>
function RpcClient:steer(message)
  return self:_send({ type = 'steer', message = message }):and_then(function()
    return nil
  end)
end

---Queue a follow-up message to be processed after the agent finishes
---@param message string
---@return Promise<nil>
function RpcClient:follow_up(message)
  return self:_send({ type = 'follow_up', message = message }):and_then(function()
    return nil
  end)
end

---Abort current operation
---@return Promise<nil>
function RpcClient:abort()
  return self:_send({ type = 'abort' }):and_then(function()
    return nil
  end)
end

---Start a new session
---@param parent_session string|nil Optional parent session path
---@return Promise<{ cancelled: boolean }>
function RpcClient:new_session(parent_session)
  return self:_send({ type = 'new_session', parentSession = parent_session }):and_then(function(response)
    return self:_get_data(response)
  end)
end

---Get current session state
---@return Promise<RpcSessionState>
function RpcClient:get_state()
  return self:_send({ type = 'get_state' }):and_then(function(response)
    return self:_get_data(response)
  end)
end

---Set model by provider and ID
---@param provider string
---@param model_id string
---@return Promise<Model>
function RpcClient:set_model(provider, model_id)
  return self:_send({ type = 'set_model', provider = provider, modelId = model_id }):and_then(function(response)
    return self:_get_data(response)
  end)
end

---Cycle to next model
---@return Promise<{ model: Model, thinkingLevel: ThinkingLevel, isScoped: boolean }|nil>
function RpcClient:cycle_model()
  return self:_send({ type = 'cycle_model' }):and_then(function(response)
    return self:_get_data(response)
  end)
end

---Get list of available models
---@return Promise<Model[]>
function RpcClient:get_available_models()
  return self:_send({ type = 'get_available_models' }):and_then(function(response)
    local data = self:_get_data(response)
    return data.models
  end)
end

---Set thinking level
---@param level ThinkingLevel
---@return Promise<nil>
function RpcClient:set_thinking_level(level)
  return self:_send({ type = 'set_thinking_level', level = level }):and_then(function()
    return nil
  end)
end

---Cycle thinking level
---@return Promise<{ level: ThinkingLevel }|nil>
function RpcClient:cycle_thinking_level()
  return self:_send({ type = 'cycle_thinking_level' }):and_then(function(response)
    return self:_get_data(response)
  end)
end

---Set steering mode
---@param mode SteeringMode
---@return Promise<nil>
function RpcClient:set_steering_mode(mode)
  return self:_send({ type = 'set_steering_mode', mode = mode }):and_then(function()
    return nil
  end)
end

---Set follow-up mode
---@param mode FollowUpMode
---@return Promise<nil>
function RpcClient:set_follow_up_mode(mode)
  return self:_send({ type = 'set_follow_up_mode', mode = mode }):and_then(function()
    return nil
  end)
end

---Compact session context
---@param custom_instructions string|nil
---@return Promise<CompactionResult>
function RpcClient:compact(custom_instructions)
  return self:_send({ type = 'compact', customInstructions = custom_instructions }):and_then(function(response)
    return self:_get_data(response)
  end)
end

---Set auto-compaction enabled/disabled
---@param enabled boolean
---@return Promise<nil>
function RpcClient:set_auto_compaction(enabled)
  return self:_send({ type = 'set_auto_compaction', enabled = enabled }):and_then(function()
    return nil
  end)
end

---Set auto-retry enabled/disabled
---@param enabled boolean
---@return Promise<nil>
function RpcClient:set_auto_retry(enabled)
  return self:_send({ type = 'set_auto_retry', enabled = enabled }):and_then(function()
    return nil
  end)
end

---Abort in-progress retry
---@return Promise<nil>
function RpcClient:abort_retry()
  return self:_send({ type = 'abort_retry' }):and_then(function()
    return nil
  end)
end

---Execute a bash command
---@param command string
---@return Promise<BashResult>
function RpcClient:bash(command)
  return self:_send({ type = 'bash', command = command }):and_then(function(response)
    return self:_get_data(response)
  end)
end

---Abort running bash command
---@return Promise<nil>
function RpcClient:abort_bash()
  return self:_send({ type = 'abort_bash' }):and_then(function()
    return nil
  end)
end

---Get session statistics
---@return Promise<SessionStats>
function RpcClient:get_session_stats()
  return self:_send({ type = 'get_session_stats' }):and_then(function(response)
    return self:_get_data(response)
  end)
end

---Export session to HTML
---@param output_path string|nil
---@return Promise<{ path: string }>
function RpcClient:export_html(output_path)
  return self:_send({ type = 'export_html', outputPath = output_path }):and_then(function(response)
    return self:_get_data(response)
  end)
end

---Switch to a different session file
---@param session_path string
---@return Promise<{ cancelled: boolean }>
function RpcClient:switch_session(session_path)
  return self:_send({ type = 'switch_session', sessionPath = session_path }):and_then(function(response)
    return self:_get_data(response)
  end)
end

---Fork from a specific message
---@param entry_id string
---@return Promise<{ text: string, cancelled: boolean }>
function RpcClient:fork(entry_id)
  return self:_send({ type = 'fork', entryId = entry_id }):and_then(function(response)
    return self:_get_data(response)
  end)
end

---Get messages available for forking
---@return Promise<ForkMessage[]>
function RpcClient:get_fork_messages()
  return self:_send({ type = 'get_fork_messages' }):and_then(function(response)
    local data = self:_get_data(response)
    return data.messages
  end)
end

---Get text of last assistant message
---@return Promise<string|nil>
function RpcClient:get_last_assistant_text()
  return self:_send({ type = 'get_last_assistant_text' }):and_then(function(response)
    local data = self:_get_data(response)
    return data.text
  end)
end

---Set the session display name
---@param name string
---@return Promise<nil>
function RpcClient:set_session_name(name)
  return self:_send({ type = 'set_session_name', name = name }):and_then(function()
    return nil
  end)
end

---Get all messages in the session
---@return Promise<AgentMessage[]>
function RpcClient:get_messages()
  return self:_send({ type = 'get_messages' }):and_then(function(response)
    local data = self:_get_data(response)
    return data.messages
  end)
end

---Get available commands (extension commands, prompt templates, skills)
---@return Promise<RpcSlashCommand[]>
function RpcClient:get_commands()
  return self:_send({ type = 'get_commands' }):and_then(function(response)
    local data = self:_get_data(response)
    return data.commands
  end)
end

-- =========================================================================
-- Helper Methods
-- =========================================================================

---Wait for agent to become idle (no streaming)
---@param timeout number|nil Timeout in ms (default: 60000)
---@return Promise<nil>
function RpcClient:wait_for_idle(timeout)
  timeout = timeout or 60000
  local promise = Promise.new()

  local timer = vim.uv.new_timer()
  local unsubscribe

  local cleanup = function()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    if unsubscribe then
      unsubscribe()
      unsubscribe = nil
    end
  end

  timer:start(timeout, 0, function()
    cleanup()
    vim.schedule(function()
      promise:reject('Timeout waiting for agent to become idle')
    end)
  end)

  unsubscribe = self:on_event(function(event)
    if event.type == 'agent_end' then
      cleanup()
      promise:resolve(nil)
    end
  end)

  return promise
end

---Collect events until agent becomes idle
---@param timeout number|nil Timeout in ms (default: 60000)
---@return Promise<AgentEvent[]>
function RpcClient:collect_events(timeout)
  timeout = timeout or 60000
  local promise = Promise.new()
  local events = {}

  local timer = vim.uv.new_timer()
  local unsubscribe

  local cleanup = function()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    if unsubscribe then
      unsubscribe()
      unsubscribe = nil
    end
  end

  timer:start(timeout, 0, function()
    cleanup()
    vim.schedule(function()
      promise:reject('Timeout collecting events')
    end)
  end)

  unsubscribe = self:on_event(function(event)
    table.insert(events, event)
    if event.type == 'agent_end' then
      cleanup()
      promise:resolve(events)
    end
  end)

  return promise
end

---Send prompt and wait for completion, returning all events
---@param message string
---@param images ImageContent[]|nil
---@param timeout number|nil Timeout in ms (default: 60000)
---@return Promise<AgentEvent[]>
function RpcClient:prompt_and_wait(message, images, timeout)
  local events_promise = self:collect_events(timeout)
  return self:prompt(message, images):and_then(function()
    return events_promise
  end)
end

---Send extension UI response (fire-and-forget, no response expected)
---@param id string Request ID from extension_ui_request
---@param response table Response data ({ value = ... } or { confirmed = ... } or { cancelled = true })
---@return boolean success
function RpcClient:send_extension_ui_response(id, response)
  if not self._connected or not self._socket then
    return false
  end

  local msg = vim.tbl_extend('force', {
    type = 'extension_ui_response',
    id = id,
  }, response)

  local json = vim.json.encode(msg) .. '\n'
  self._socket:write(json, function(err)
    if err then
      vim.notify('Failed to send extension UI response: ' .. err, vim.log.levels.WARN)
    end
  end)

  return true
end

-- =========================================================================
-- Internal Methods
-- =========================================================================

---Handle incoming data from socket
---@private
---@param data string
function RpcClient:_handle_data(data)
  self._line_buffer = self._line_buffer .. data

  while true do
    local newline_pos = self._line_buffer:find('\n')
    if not newline_pos then
      break
    end

    local line = self._line_buffer:sub(1, newline_pos - 1)
    self._line_buffer = self._line_buffer:sub(newline_pos + 1)

    if line ~= '' then
      self:_handle_line(line)
    end
  end
end

---Handle a single JSON line
---@private
---@param line string
function RpcClient:_handle_line(line)
  local ok, data = pcall(vim.json.decode, line)
  if not ok then
    return
  end

  -- response type
  if data.type == 'response' and data.id and self._pending_requests[data.id] then
    local pending = self._pending_requests[data.id]
    self._pending_requests[data.id] = nil

    if pending.timer then
      pending.timer:stop()
      pending.timer:close()
    end

    vim.schedule(function()
      pending.promise:resolve(data)
    end)
    return
  end

  -- event type
  vim.schedule(function()
    for _, listener in ipairs(self._event_listeners) do
      local listener_ok, err = pcall(listener, data)
      if not listener_ok then
        vim.notify('RPC event listener error: ' .. tostring(err), vim.log.levels.WARN)
      end
    end
  end)
end

---Handle socket disconnect
---@private
function RpcClient:_handle_disconnect()
  self._connected = false

  if self._socket then
    self._socket:read_stop()
    self._socket:close()
    self._socket = nil
  end

  for id, pending in pairs(self._pending_requests) do
    if pending.timer then
      pending.timer:stop()
      pending.timer:close()
    end
    vim.schedule(function()
      pending.promise:reject('Connection closed')
    end)
    self._pending_requests[id] = nil
  end
end

---Send a command and return a promise for the response
---@private
---@param command RpcCommand
---@return Promise<table>
function RpcClient:_send(command)
  local promise = Promise.new()

  if not self._connected or not self._socket then
    vim.schedule(function()
      promise:reject('Client not connected')
    end)
    return promise
  end

  self._request_id = self._request_id + 1
  local id = 'req_' .. self._request_id
  command.id = id

  local timer = vim.uv.new_timer()
  timer:start(self._options.timeout, 0, function()
    if self._pending_requests[id] then
      self._pending_requests[id] = nil
      timer:stop()
      timer:close()
      vim.schedule(function()
        promise:reject('Timeout waiting for response to ' .. command.type)
      end)
    end
  end)

  self._pending_requests[id] = {
    promise = promise,
    timer = timer,
  }

  local json = vim.json.encode(command) .. '\n'
  self._socket:write(json, function(err)
    if err then
      if self._pending_requests[id] then
        self._pending_requests[id] = nil
        timer:stop()
        timer:close()
      end
      vim.schedule(function()
        promise:reject('Failed to send command: ' .. err)
      end)
    end
  end)

  return promise
end

---Extract data from response, throwing on error
---@private
---@param response RpcResponse
---@return any
function RpcClient:_get_data(response)
  if not response.success then
    error(response.error or 'Unknown error')
  end
  return response.data
end

return RpcClient
