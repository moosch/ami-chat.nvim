-- ami-chat.controller: the advisor chat controller. Owns the session, streams
-- turns to the daemon, assembles context, and emits lifecycle events — but draws
-- nothing itself. All UI goes through a "chat_ui" renderer: the bundled floating
-- panel (ami-chat.ui) by default, or one another extension registers with
-- api.provide("chat_ui", impl).
--
-- This table is registered as the "chat" capability, so other extensions reach it
-- through api.chat.* and ami-chat's own commands/tree drive it directly.
local M = {
  session_id = "default",
  source_buf = nil,
  source_win = nil,
  streaming = false,
}

local STATUS = "⏳ waiting for the model… (the first reply can be slow while it loads)"

local A = nil -- the ami extension API, set in M.init()

--- Capture the ami extension API. Call once from the extension's setup().
function M.init(api)
  A = api
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

-- Stream one turn to the daemon and render it into the transcript.
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
    A.log.debug(("chat: sending turn (session=%s, project=%s, active=%s, deps=%d, %d chars)"):format(
      M.session_id, ctx.project_root, ctx.active_path ~= "" and ctx.active_path or "(none)",
      #(ctx.dep_paths or {}), #message))

    -- The outgoing request. Extensions may mutate it (persona, extra context) via
    -- the chat_turn_pre event before it is sent.
    local req = {
      session_id = M.session_id,
      message = message,
      model = A.models.effective("chat").model,
      context = ctx,
    }
    A.emit("chat_turn_pre", req)

    A.client.stream("/chat", req, {
      on_token = function(c)
        r.set_status(nil)
        r.append(c)
      end,
      on_done = function()
        M.streaming = false
        r.set_status(nil)
        r.append("\n")
        A.emit("chat_turn_post", { ok = true, session_id = req.session_id })
      end,
      on_error = function(e)
        M.streaming = false
        r.set_status(nil)
        r.append("\n_[error: " .. e .. "]_\n")
        A.emit("chat_turn_post", { ok = false, session_id = req.session_id, error = e })
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
  local r = ui()
  r.show()
  r.append("\n\n---\n\n_New session: `" .. M.session_id .. "`_\n")
  A.log.info("chat: new session '" .. M.session_id .. "'")
end

return M
