-- ami-chat.controller: the advisor chat controller. Owns the session, assembles
-- each request (system prompt + context + prior turns + the new message), streams
-- it straight to the model, and emits lifecycle events — but draws nothing itself.
-- All UI goes through a "chat_ui" renderer: the bundled floating panel
-- (ami-chat.ui) by default, or one another extension registers with
-- api.provide("chat_ui", impl).
--
-- Prior turns come from a registered "history" provider (e.g. ami-history.nvim);
-- with none installed, a built-in in-memory history keeps the current session
-- multi-turn (not persisted). This table is registered as the "chat" capability,
-- so other extensions reach it through api.chat.*.
local M = {
  session_id = "default",
  source_buf = nil,
  source_win = nil,
  streaming = false,
}

local STATUS = "⏳ waiting for the model… (the first reply can be slow while it loads)"

-- The advisor identity: a pair programmer that advises but never acts.
local ADVISOR_SYSTEM = [[You are a senior engineer acting as a pair programmer embedded in the user's editor.
Your role is to ADVISE, never to ACT.

Hard rules:
- Never claim to have edited, created, run, or changed any file or command. You cannot; you only advise.
- Do not emit full-file rewrites or large code dumps. Prefer reasoning, trade-offs, and small, pointed snippets (a few lines) that illustrate an idea.
- When the user is thinking out loud, help them think: ask clarifying questions, name the trade-offs, and point out risks or edge cases they may have missed.
- Be concise and direct. The user is an experienced developer; skip boilerplate explanations and get to the substance.
- When you suggest an approach, say briefly why, and mention the main alternative if there is a meaningful one.
- Ground your advice in the provided context (open file, selection, README/PLAN). If context is missing, say what you'd need rather than guessing.

You are a colleague at the whiteboard, not an autonomous agent.]]

local A = nil -- the ami extension API, set in M.init()

-- Built-in in-memory history, used only when no "history" provider is registered.
-- Keyed by session id; each entry is a list of { role, content } turns.
local mem = {}

-- Recallable history of messages sent from the input box (oldest → newest),
-- shared across sessions for this editor session. Drives the input's up/down
-- recall in the renderer; separate from conversation history, and not persisted.
local input_history = {}
local INPUT_HISTORY_MAX = 200

--- Capture the ami extension API. Call once from the extension's setup().
function M.init(api)
  A = api
end

-- The registered history provider, if any.
local function history()
  local h = A.resolve("history")
  if h and h.messages then
    return h
  end
  return nil
end

-- Prior-turn messages for the next request: from the history provider, else the
-- built-in in-memory history.
local function history_messages()
  local h = history()
  if h then
    return h.messages(M.session_id) or {}
  end
  return mem[M.session_id] or {}
end

-- The system message content: advisor identity + the assembled context block.
local function system_content(block)
  if not block or vim.trim(block) == "" then
    return ADVISOR_SYSTEM
  end
  return ADVISOR_SYSTEM .. "\n\n# Current Context\n\n" .. block
end

-- The active renderer: an extension-provided "chat_ui", else the bundled panel.
local function ui()
  return A.resolve("chat_ui") or require("ami-chat.ui")
end

local function ctl()
  return {
    submit = M.submit,
    new_session = function() M.new_session() end,
    close = M.close,
    stop = M.cancel,
    input_history = M.input_history,
    commands = M.command_list,
  }
end

--- Record a message sent from the input box for up/down recall. De-dupes the
--- immediately previous entry (pressing send twice on the same text) and caps the
--- list. Exposed to the renderer via ctl().input_history.
function M.record_input(message)
  if message == nil or message == "" then
    return
  end
  if input_history[#input_history] == message then
    return
  end
  input_history[#input_history + 1] = message
  if #input_history > INPUT_HISTORY_MAX then
    table.remove(input_history, 1)
  end
end

--- The recallable input history (oldest → newest). The renderer reads this to
--- cycle previously sent messages in the prompt.
---@return string[]
function M.input_history()
  return input_history
end

local function capture_source()
  local cur_buf = vim.api.nvim_get_current_buf()
  if not ui().owns_buf(cur_buf) then
    M.source_buf = cur_buf
    M.source_win = vim.api.nvim_get_current_win()
  end
end

local function do_open()
  capture_source()
  ui().open(ctl())
end

-- Chat service (also the "chat" capability surface) ---------------------------

function M.close()
  M.cancel() -- don't leave a request streaming into a hidden panel
  ui().close()
end

function M.toggle()
  if ui().is_open() then
    ui().close()
  else
    do_open()
  end
end

function M.open()
  if ui().is_open() then
    return
  end
  do_open()
end

function M.append(text)
  ui().append(text)
end

function M.session()
  return M.session_id
end

function M.source()
  return M.source_buf, M.source_win
end

function M.set_source(buf, win)
  M.source_buf, M.source_win = buf, win
end

function M.is_streaming()
  return M.streaming == true
end

-- Assemble a turn (system + context + prior turns + message) and stream it
-- straight to the model, rendering tokens into the transcript.
local function send(message, selection, range)
  if M.streaming then
    vim.notify("ami: still streaming the previous reply", vim.log.levels.WARN)
    return
  end
  M.streaming = true
  local r = ui()
  r.show()
  r.append("\n\n### You\n\n" .. message .. "\n\n### Advisor\n\n")
  r.set_status(STATUS)

  A.context.gather_async(M.source_buf, M.source_win, selection, range, function(ctx)
    local budget = (require("ami.config").options.context or {}).token_budget or 8000
    local block = A.context.assemble(ctx, budget)
    local eff = A.models.effective("chat")
    A.log.debug(("chat: turn (session=%s, model=%s, ctx=%d chars, deps=%d)"):format(
      M.session_id, tostring(eff.model), #block, #(ctx.dep_paths or {})))

    local messages = { { role = "system", content = system_content(block) } }
    -- System-message contributions (persona, house style, …) via the chat.system
    -- collector; chat composes them, right after the advisor prompt.
    for _, s in ipairs(A.emit_collect("chat.system", { session = M.session_id, ctx = ctx })) do
      if type(s) == "string" and vim.trim(s) ~= "" then
        messages[#messages + 1] = { role = "system", content = s }
      end
    end
    vim.list_extend(messages, history_messages())
    messages[#messages + 1] = { role = "user", content = message }

    -- Outgoing request; extensions may mutate it (persona, extra messages) via the
    -- chat_turn_pre event before it is sent.
    local req = { model = eff.model, messages = messages, stream = true }
    A.emit("chat_turn_pre", req)

    local timeout = (require("ami.config").options.chat or {}).timeout_ms
    local reply = {}
    M._inflight = A.client.stream_chat(eff.endpoint, req, {
      on_token = function(c)
        r.set_status(nil)
        reply[#reply + 1] = c
        r.append(c)
      end,
      on_done = function()
        M.streaming, M._inflight = false, nil
        r.set_status(nil)
        r.append("\n")
        local assistant = table.concat(reply)
        -- A history provider records via the chat_turn_post event; with none, keep
        -- the built-in in-memory history going.
        if not history() then
          mem[M.session_id] = mem[M.session_id] or {}
          table.insert(mem[M.session_id], { role = "user", content = message })
          table.insert(mem[M.session_id], { role = "assistant", content = assistant })
        end
        A.emit("chat_turn_post",
          { session = M.session_id, root = M.project_root(), ok = true, user = message, assistant = assistant })
      end,
      on_error = function(e)
        M.streaming, M._inflight = false, nil
        r.set_status(nil)
        if M._cancelled then
          M._cancelled = false
          r.append("\n_[stopped]_\n")
        else
          r.append("\n_[error: " .. e .. "]_\n")
        end
        A.emit("chat_turn_post",
          { session = M.session_id, root = M.project_root(), ok = false, user = message, error = e })
      end,
    }, { timeout_ms = timeout })
  end)
end

--- Stop the in-flight reply, if any (api.chat/:AmiStop/panel key). The killed
--- request surfaces through on_error, which renders "[stopped]" not an error.
function M.cancel()
  if not (M.streaming and M._inflight) then
    return
  end
  M._cancelled = true
  pcall(function() M._inflight:kill("sigterm") end)
end

-- Slash commands ------------------------------------------------------------
-- A message beginning with "/" is a command, not a prompt to the model. ami-chat
-- ships a couple of built-ins; extensions contribute more by returning a
-- { name = { desc, fn } } table from the "chat.commands" collector (e.g.
-- ami-history adds /compact). A handler receives ctx = { args, session, append,
-- controller }. Escape a literal leading slash by doubling it ("//ask …").

local builtins

-- All commands: built-ins plus any contributed via the chat.commands collector
-- (later contributors win). Collected fresh each dispatch so newly loaded
-- extensions appear without a restart.
local function all_commands()
  local cmds = {}
  for name, spec in pairs(builtins) do
    cmds[name] = spec
  end
  for _, tbl in ipairs(A.emit_collect("chat.commands")) do
    if type(tbl) == "table" then
      for name, spec in pairs(tbl) do
        if type(spec) == "table" and type(spec.fn) == "function" then
          cmds[name:lower()] = spec
        end
      end
    end
  end
  return cmds
end

builtins = {
  help = {
    desc = "List the available chat commands",
    fn = function(ctx)
      local cmds = all_commands()
      local names = vim.tbl_keys(cmds)
      table.sort(names)
      local lines = { "", "**Chat commands**", "" }
      for _, n in ipairs(names) do
        lines[#lines + 1] = ("- `/%s` — %s"):format(n, cmds[n].desc or "")
      end
      lines[#lines + 1] = ""
      lines[#lines + 1] = "_(prefix a real message with `//` to send text that starts with a slash)_"
      ctx.append("\n" .. table.concat(lines, "\n") .. "\n")
    end,
  },
  new = {
    desc = "Start a fresh session (/new [name])",
    fn = function(ctx)
      M.new_session(ctx.args ~= "" and ctx.args or nil)
    end,
  },
}

--- The available slash commands as a sorted list of { name, desc }. The renderer
--- reads this to offer a completion popup when the input starts with "/".
---@return { name: string, desc: string }[]
function M.command_list()
  local out = {}
  for name, spec in pairs(all_commands()) do
    out[#out + 1] = { name = name, desc = spec.desc or "" }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- Parse "/name rest of the args" → name, args.
local function parse_command(message)
  local name, args = message:match("^/(%S+)%s*(.-)%s*$")
  return name, args or ""
end

--- Run a slash command typed into the input.
function M.run_command(message)
  local name, args = parse_command(message)
  local r = ui()
  r.show()
  r.append("\n\n### You\n\n" .. message .. "\n")
  if not name then
    r.append("\n_Type a command after the slash, e.g. `/help`._\n")
    return
  end
  local cmd = all_commands()[name:lower()]
  if not cmd then
    r.append(("\n_Unknown command `/%s`. Try `/help`._\n"):format(name))
    return
  end
  local ctx = { args = args, session = M.session_id, append = M.append, controller = M }
  local ok, err = pcall(cmd.fn, ctx)
  if not ok then
    A.log.error(("chat: command /%s failed — %s"):format(name, tostring(err)))
    r.append(("\n_Command `/%s` errored: %s_\n"):format(name, tostring(err)))
  end
end

--- Submit the current draft. Clears it; keeps the chat open. A leading "/" routes
--- to a slash command instead of the model ("//" escapes it to a literal message).
function M.submit()
  local message = vim.trim(ui().read_input() or "")
  A.log.debug(("submit: invoked (%d chars)"):format(#message))
  if message == "" then
    return
  end
  M.record_input(message)
  ui().clear_input()
  if message:sub(1, 2) == "//" then
    send(message:sub(2)) -- escaped: send text that really does start with a slash
  elseif message:sub(1, 1) == "/" then
    M.run_command(message)
  else
    send(message)
  end
end

--- One-shot ask (e.g. from :AmiAsk), optionally with a selection/range.
function M.ask(message, selection, range)
  message = vim.trim(message or "")
  if message == "" then
    return
  end
  capture_source()
  send(message, selection, range)
end

--- Project root for the code buffer the chat is attached to.
function M.project_root()
  return A.context.project_root(M.source_buf or 0)
end

--- Rebuild the transcript from a list of conversation nodes (branch switch).
function M.render_nodes(nodes)
  local r = ui()
  r.clear()
  for _, n in ipairs(nodes or {}) do
    local header = (n.role == "assistant") and "### Advisor" or "### You"
    r.append("\n\n" .. header .. "\n\n" .. (n.content or ""))
    if n.collapsed and n.summary and n.summary ~= "" then
      r.append("\n\n> _summary:_ " .. n.summary)
    end
  end
  r.show()
end

--- Append an unsolicited proactive suggestion (does not steal focus / force open).
function M.add_proactive(text)
  ui().append("\n\n### 💡 Suggestion\n\n" .. text .. "\n")
end

--- Start a fresh session (new history), keeping the panel open.
function M.new_session(name)
  M.session_id = (name and vim.trim(name) ~= "") and vim.trim(name)
    or ("session-" .. os.date("%Y%m%d-%H%M%S"))
  A.emit("chat_session", { session = M.session_id, root = M.project_root() })
  local r = ui()
  r.show()
  r.append("\n\n---\n\n_New session: `" .. M.session_id .. "`_\n")
  A.log.info("chat: new session '" .. M.session_id .. "'")
end

return M
