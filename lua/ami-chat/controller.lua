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
  }
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
    vim.list_extend(messages, history_messages())
    messages[#messages + 1] = { role = "user", content = message }

    -- Outgoing request; extensions may mutate it (persona, extra messages) via the
    -- chat_turn_pre event before it is sent.
    local req = { model = eff.model, messages = messages, stream = true }
    A.emit("chat_turn_pre", req)

    local reply = {}
    A.client.stream_chat(eff.endpoint, req, {
      on_token = function(c)
        r.set_status(nil)
        reply[#reply + 1] = c
        r.append(c)
      end,
      on_done = function()
        M.streaming = false
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
        M.streaming = false
        r.set_status(nil)
        r.append("\n_[error: " .. e .. "]_\n")
        A.emit("chat_turn_post",
          { session = M.session_id, root = M.project_root(), ok = false, user = message, error = e })
      end,
    })
  end)
end

--- Submit the current draft. Clears it; keeps the chat open.
function M.submit()
  local message = vim.trim(ui().read_input() or "")
  A.log.debug(("submit: invoked (%d chars)"):format(#message))
  if message == "" then
    return
  end
  ui().clear_input()
  send(message)
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
