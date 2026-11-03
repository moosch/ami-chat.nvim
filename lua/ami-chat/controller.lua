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

-- Directory names never offered as @file completions nor walked into.
local FILE_IGNORE = {
  [".git"] = true, ["node_modules"] = true, [".venv"] = true, ["venv"] = true,
  ["__pycache__"] = true, [".mypy_cache"] = true, [".pytest_cache"] = true,
  ["target"] = true, ["dist"] = true, ["build"] = true, [".next"] = true,
  [".cache"] = true, [".idea"] = true, [".DS_Store"] = true,
}
local FILE_LIST_CAP = 3000 -- stop walking after this many files (keeps the popup snappy)
-- Short-lived cache of the project's file list, so repeatedly opening the @ popup
-- doesn't re-walk the tree on every keystroke.
local file_cache = { root = nil, at = 0, list = nil }

-- Cancellers for anything currently streaming into the panel. The chat reply is
-- cancelled directly (it needs the _cancelled flag for its "[stopped]" line); other
-- producers that stream into the transcript — e.g. ami-doc's /doc — register a
-- canceller here so the same <C-c> / :AmiStop / panel close stops them too. Keyed by
-- an opaque token; each fn is run at most once.
local cancellers = {}

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
    files = M.file_list,
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

--- Mark the transcript end; returns a handle (or nil if the renderer can't).
--- Pair with M.collapse to stream content in and then fold it to a summary line.
function M.mark()
  local r = ui()
  return r.mark and r.mark() or nil
end

--- Remove everything appended since `handle`, then append `text`. If the renderer
--- doesn't support collapsing (no mark/collapse), just append `text`.
function M.collapse(handle, text)
  local r = ui()
  if r.collapse then
    r.collapse(handle, text)
  elseif text and text ~= "" then
    r.append(text)
  end
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

-- @file references ------------------------------------------------------------
-- A message may name project files with "@path/to/file"; each one that resolves to
-- a real file under the project root is read and included in the request context
-- (as a "Referenced file" section, ranked above auto-resolved deps). "@" in ordinary
-- prose (emails, @param, …) is ignored because it only counts when it points at a
-- file that exists.

-- Parse @path tokens from `message` and resolve them to files under the project
-- root. Returns parallel lists: absolute paths (for the context) and project-
-- relative paths (for the "attached …" note). Exposed (underscore) for unit tests.
---@param message string
---@return string[] abs, string[] rel
function M._resolve_refs(message)
  local root = vim.fs.normalize(M.project_root())
  local uv = vim.uv or vim.loop
  local abs, rel, seen = {}, {}, {}
  for tok in (message or ""):gmatch("@([%w._/%-]+)") do
    tok = tok:gsub("[%.,]+$", "") -- drop trailing sentence punctuation
    if tok ~= "" and not seen[tok] then
      seen[tok] = true
      local full = vim.fs.normalize(tok:sub(1, 1) == "/" and tok or (root .. "/" .. tok))
      local under = full == root or full:sub(1, #root + 1) == root .. "/"
      local st = uv.fs_stat(full)
      if under and st and st.type == "file" then
        abs[#abs + 1] = full
        rel[#rel + 1] = full:sub(#root + 2)
      end
    end
  end
  return abs, rel
end

--- The project's files as project-relative paths (sorted), for the @ completion
--- popup. Cached briefly and capped so a large tree stays responsive. Exposed to
--- the renderer via ctl().files.
---@return string[]
function M.file_list()
  local root = M.project_root()
  local uv = vim.uv or vim.loop
  local now = uv.now()
  if file_cache.root == root and file_cache.list and (now - file_cache.at) < 5000 then
    return file_cache.list
  end
  local out = {}
  -- Prune ignored directories during traversal where supported; fall back to a
  -- plain walk (with a per-file segment filter below) on older Neovim.
  local ok, iter = pcall(vim.fs.dir, root, {
    depth = 20,
    skip = function(name) return not FILE_IGNORE[name] end,
  })
  if not ok then
    ok, iter = pcall(vim.fs.dir, root, { depth = 20 })
  end
  if ok and iter then
    for name, typ in iter do
      if typ == "file" then
        local skip = false
        for seg in name:gmatch("[^/]+") do
          if FILE_IGNORE[seg] then
            skip = true
            break
          end
        end
        if not skip then
          out[#out + 1] = name
        end
      end
      if #out >= FILE_LIST_CAP then
        break
      end
    end
  end
  table.sort(out)
  file_cache = { root = root, at = now, list = out }
  return out
end

-- "~3.2k" for ≥1000, "~850" otherwise. For the header + /tokens breakdown.
local function fmt_tokens(n)
  n = n or 0
  if n >= 1000 then
    return ("~%.1fk"):format(n / 1000)
  end
  return ("~%d"):format(n)
end

-- Estimate the outgoing request's size, broken into the parts the user can reason
-- about: fixed instructions, per-turn file context, conversation history (what
-- /compact reduces), and the new message. `total` sums the whole request (so it also
-- captures anything chat_turn_pre added).
local function estimate_request(req, block, hist, message, budget)
  local est = A.context.estimate_tokens
  local total = 0
  for _, m in ipairs(req.messages or {}) do
    total = total + est(m.content or "")
  end
  local history_tok = 0
  for _, m in ipairs(hist or {}) do
    history_tok = history_tok + est(m.content or "")
  end
  local block_tok, user_tok = est(block or ""), est(message or "")
  local instr = total - block_tok - history_tok - user_tok
  return {
    total = total,
    instructions = instr > 0 and instr or 0,
    context = block_tok,
    history = history_tok,
    message = user_tok,
    budget = budget,
  }
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
  -- Resolve any @file references up front, so the "attached" note sits in the user
  -- turn (before "### Advisor") and the files can be added to the gathered context.
  local ref_abs, ref_rel = M._resolve_refs(message)
  local note = ""
  if #ref_rel > 0 then
    note = ("\n_(attached %d file%s: %s)_\n"):format(
      #ref_rel, #ref_rel > 1 and "s" or "", table.concat(ref_rel, ", "))
  end
  r.append("\n\n### You\n\n" .. message .. note .. "\n\n### Advisor\n\n")
  r.set_status(STATUS)

  A.context.gather_async(M.source_buf, M.source_win, selection, range, function(ctx)
    ctx.explicit_paths = ref_abs
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
    local hist = history_messages()
    vim.list_extend(messages, hist)
    messages[#messages + 1] = { role = "user", content = message }

    -- Outgoing request; extensions may mutate it (persona, extra messages) via the
    -- chat_turn_pre event before it is sent.
    local req = { model = eff.model, messages = messages, stream = true }
    A.emit("chat_turn_pre", req)

    -- Context-budget indicator: estimate the whole outgoing request and break it down
    -- (so the header shows the total, and /tokens shows how much is history — the part
    -- /compact reduces). Computed after chat_turn_pre so persona/extra messages count.
    M._last_tokens = estimate_request(req, block, hist, message, budget)
    if r.set_tokens then
      r.set_tokens(M._last_tokens.total, (require("ami.config").options.chat or {}).context_window)
    end

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

--- Register a canceller for something streaming into the panel (e.g. ami-doc).
--- Returns an opaque token; call unregister_cancel(token) when the stream settles.
--- M.cancel() runs every registered canceller (and the chat reply) at once.
---@param fn fun() stops the producer's in-flight request
---@return table token
function M.register_cancel(fn)
  local token = {}
  cancellers[token] = fn
  return token
end

--- Drop a canceller registered with register_cancel (on normal completion/error).
function M.unregister_cancel(token)
  if token then
    cancellers[token] = nil
  end
end

--- Stop whatever is streaming into the panel, if anything (api.chat/:AmiStop/panel
--- key/panel close): the chat reply and any registered producer (ami-doc, …). The
--- killed chat request surfaces through on_error, which renders "[stopped]" not an
--- error. Returns true if it stopped something.
---@return boolean stopped
function M.cancel()
  local stopped = false
  if M.streaming and M._inflight then
    M._cancelled = true
    pcall(function() M._inflight:kill("sigterm") end)
    stopped = true
  end
  for token, fn in pairs(cancellers) do
    cancellers[token] = nil -- clear first so a re-entrant cancel can't double-run it
    pcall(fn)
    stopped = true
  end
  return stopped
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
  yank = {
    desc = "Copy a transcript code block to the clipboard (/yank [N]; default last)",
    fn = function(ctx)
      M.yank_block(ctx.args)
    end,
  },
  apply = {
    desc = "Diff a code block against a file to review & apply it (/apply [N] [path])",
    fn = function(ctx)
      M.apply_block(ctx.args)
    end,
  },
  tokens = {
    desc = "Show the estimated context size of the last turn (what /compact reduces)",
    fn = function(ctx)
      local t = M._last_tokens
      if not t then
        ctx.append("\n_No turns yet — the token estimate appears after your first message._\n")
        return
      end
      local lines = {
        "",
        "**Context estimate** (last turn, ~4 chars/token)",
        "",
        ("- instructions (advisor + persona): %s"):format(fmt_tokens(t.instructions)),
        ("- file / project context: %s (budget %s)"):format(fmt_tokens(t.context), fmt_tokens(t.budget)),
        ("- conversation history: %s  ← `/compact` shrinks this"):format(fmt_tokens(t.history)),
        ("- your message: %s"):format(fmt_tokens(t.message)),
        ("- **total sent: %s**"):format(fmt_tokens(t.total)),
        "",
      }
      ctx.append("\n" .. table.concat(lines, "\n") .. "\n")
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

-- Code blocks → yank / apply -------------------------------------------------
-- Bridge the advisor (which only ADVISES) to action, but always user-initiated:
-- /yank copies a fenced code block from the transcript to the clipboard, and /apply
-- opens a block in a diff against a file so you review and save it yourself. ami
-- never writes a file here — it stages the change; you commit it.

-- Parse fenced ``` code blocks out of transcript lines, in order. Each block is
-- { lang, lines }. Unclosed blocks (a reply still streaming) are ignored.
---@param lines string[]
---@return { lang: string, lines: string[] }[]
local function code_blocks(lines)
  local blocks, cur = {}, nil
  for _, line in ipairs(lines or {}) do
    if cur then
      if line:match("^```+%s*$") then -- closing fence
        blocks[#blocks + 1] = cur
        cur = nil
      else
        cur.lines[#cur.lines + 1] = line
      end
    else
      local fence, lang = line:match("^(```+)(.*)$")
      if fence then
        cur = { lang = vim.trim(lang or ""), lines = {} }
      end
    end
  end
  return blocks
end

-- A path shown relative to the project root (falls back to a ~/cwd-relative form
-- when it isn't under the root).
local function rel_to_root(abs)
  local root = vim.fs.normalize(M.project_root())
  local full = vim.fs.normalize(abs)
  if full == root then
    return vim.fs.basename(full)
  end
  if full:sub(1, #root + 1) == root .. "/" then
    return full:sub(#root + 2)
  end
  return vim.fn.fnamemodify(abs, ":~:.")
end

-- Resolve `rel` to an absolute path confined to the project root (nil, err on an
-- escape). The file need not exist — /apply diffs against an empty buffer for a new
-- file. Shares the sandbox idea with @file references and ami-doc.
local function path_under_root(rel)
  local root = vim.fs.normalize(M.project_root())
  local full = vim.fs.normalize(rel:sub(1, 1) == "/" and rel or (root .. "/" .. rel))
  if full ~= root and full:sub(1, #root + 1) ~= root .. "/" then
    return nil, "refusing a path outside the project root"
  end
  return full
end

-- Pick block index from an arg ("" → last; N → Nth; -1 → last). Returns block, n,
-- count, err.
local function pick_block(blocks, raw)
  local count = #blocks
  if count == 0 then
    return nil, nil, 0, "there are no code blocks in the transcript yet"
  end
  local n = tonumber(vim.trim(raw or "")) or count
  if n < 0 then
    n = count + 1 + n
  end
  local b = blocks[n]
  if not b then
    return nil, n, count, ("no code block %d (there %s %d)"):format(n, count == 1 and "is" or "are", count)
  end
  return b, n, count
end

--- Copy a transcript code block to the clipboard (default: the last one).
---@param arg string|nil  the block number (N, or -1 for last); empty = last
function M.yank_block(arg)
  local r = ui()
  r.show()
  if not r.transcript_lines then
    r.append("\n_This chat UI can't read the transcript, so `/yank` isn't available._\n")
    return
  end
  local blocks = code_blocks(r.transcript_lines())
  local b, n, count, err = pick_block(blocks, arg)
  if not b then
    r.append("\n_" .. err .. "._\n")
    return
  end
  local text = table.concat(b.lines, "\n")
  vim.fn.setreg('"', text) -- unnamed: paste with p
  vim.fn.setreg("0", text) -- yank register
  pcall(vim.fn.setreg, "+", text) -- system clipboard, if a provider is present
  r.append(("\n_✓ yanked code block %d of %d (%s%d line%s) — paste with `p`, or ⌘/Ctrl-V if a clipboard provider is set._\n")
    :format(n, count, b.lang ~= "" and (b.lang .. ", ") or "", #b.lines, #b.lines == 1 and "" or "s"))
end

-- Open `block` in a diff against the file at `abs`, in a fresh tab: the file on the
-- left, the suggestion on the right. The user transfers hunks (do/dp, ]c/[c) and
-- :w the file — nothing is written by ami.
local function open_diff(abs, block, n)
  vim.schedule(function()
    local _, win = M.source()
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_set_current_win, win) -- step out of the chat float first
    end
    local ok = pcall(vim.cmd, "tabnew " .. vim.fn.fnameescape(abs))
    if not ok then
      vim.notify("ami apply: could not open " .. abs, vim.log.levels.ERROR)
      return
    end
    local ft = vim.bo.filetype
    vim.cmd("diffthis")
    vim.cmd("vnew")
    local sb = vim.api.nvim_get_current_buf()
    vim.bo[sb].buftype = "nofile"
    vim.bo[sb].bufhidden = "wipe"
    vim.bo[sb].swapfile = false
    pcall(vim.api.nvim_buf_set_name, sb, ("ami://suggestion-%d"):format(n))
    vim.api.nvim_buf_set_lines(sb, 0, -1, false, block.lines)
    vim.bo[sb].filetype = (block.lang ~= "" and block.lang) or ft
    vim.cmd("diffthis")
    vim.notify(
      ("ami: block %d vs %s — move hunks with do/dp (]c/[c to navigate), then :w the file. Nothing is written until you save.")
        :format(n, rel_to_root(abs)),
      vim.log.levels.INFO)
  end)
end

--- Diff a transcript code block against a file so it can be reviewed and applied.
--- `/apply [N] [path]` — N defaults to the last block; path defaults to the file the
--- chat is attached to. ami stages the diff; the user saves.
---@param arg string|nil
function M.apply_block(arg)
  local r = ui()
  r.show()
  if not r.transcript_lines then
    r.append("\n_This chat UI can't read the transcript, so `/apply` isn't available._\n")
    return
  end
  local blocks = code_blocks(r.transcript_lines())
  -- "[N] [path]": a leading integer is the block number; the rest (or the whole arg)
  -- is the target path.
  local a = vim.trim(arg or "")
  local num, path
  local first, rest = a:match("^(%S+)%s*(.-)%s*$")
  if first and first:match("^%-?%d+$") then
    num, path = first, (rest ~= "" and rest or nil)
  elseif a ~= "" then
    path = a
  end

  local b, n, _, err = pick_block(blocks, num)
  if not b then
    r.append("\n_" .. err .. "._\n")
    return
  end

  local abs
  if path then
    local full, perr = path_under_root(path)
    if not full then
      r.append("\n_apply: " .. perr .. "._\n")
      return
    end
    abs = full
  else
    local buf = M.source_buf
    local name = (buf and vim.api.nvim_buf_is_valid(buf)) and vim.api.nvim_buf_get_name(buf) or ""
    if name == "" then
      r.append(("\n_apply: no target file — give a path, e.g. `/apply %d path/to/file`._\n"):format(n))
      return
    end
    abs = name
  end
  r.append(("\n_Opening code block %d in a diff against `%s` — review and `:w` to apply._\n")
    :format(n, rel_to_root(abs)))
  open_diff(abs, b, n)
end

-- Shell passthrough ----------------------------------------------------------
-- A message beginning with "!" runs the rest as a shell command (like :! or
-- Claude's bash mode) instead of calling the model: it runs in the project root,
-- in the background, and its output is echoed into the transcript. Nothing is sent
-- to the LLM and the turn is not recorded in history. Gated by chat.shell.enabled.

--- Run `cmd` in a background shell and append its output to the transcript.
function M.run_shell(cmd)
  cmd = vim.trim(cmd or "")
  local r = ui()
  r.show()
  if cmd == "" then
    r.append("\n\n_Usage: `!<shell command>` — e.g. `!pwd`_\n")
    return
  end
  if M.streaming then
    vim.notify("ami: finish the current reply before running a shell command", vim.log.levels.WARN)
    return
  end

  local scfg = (require("ami.config").options.chat or {}).shell or {}
  local cwd = M.project_root()
  r.append(("\n\n### You\n\n!%s\n\n### Shell\n\n"):format(cmd))
  r.set_status("⏳ running…")

  local shell = (vim.o.shell ~= "" and vim.o.shell) or "sh"
  local flag = (vim.o.shellcmdflag ~= "" and vim.o.shellcmdflag) or "-c"
  A.log.debug(("shell: %s %s %q (cwd=%s)"):format(shell, flag, cmd, cwd))

  local ok, err = pcall(vim.system, { shell, flag, cmd }, {
    cwd = cwd,
    text = true,
    timeout = scfg.timeout_ms or 30000,
  }, function(res)
    vim.schedule(function()
      r.set_status(nil)
      local out = res.stdout or ""
      if res.stderr and res.stderr ~= "" then
        out = (out ~= "" and (out .. "\n") or "") .. res.stderr
      end
      out = vim.trim(out)
      local cap = scfg.max_output_bytes or 100000
      if #out > cap then
        out = out:sub(1, cap) .. "\n…(output truncated)…"
      end
      if out == "" then
        out = "(no output)"
      end
      r.append("```\n" .. out .. "\n```\n")
      if res.code ~= 0 then
        r.append(("_(exit %d)_\n"):format(res.code))
      end
    end)
  end)

  if not ok then
    r.set_status(nil)
    r.append("```\n(failed to launch shell: " .. tostring(err) .. ")\n```\n")
  end
end

--- Submit the current draft. Clears it; keeps the chat open. A leading "/" routes
--- to a slash command and a leading "!" to a shell command, instead of the model;
--- "//" escapes a literal leading slash.
function M.submit()
  local message = vim.trim(ui().read_input() or "")
  A.log.debug(("submit: invoked (%d chars)"):format(#message))
  if message == "" then
    return
  end
  M.record_input(message)
  ui().clear_input()
  local scfg = (require("ami.config").options.chat or {}).shell or {}
  if message:sub(1, 2) == "//" then
    send(message:sub(2)) -- escaped: send text that really does start with a slash
  elseif message:sub(1, 1) == "/" then
    M.run_command(message)
  elseif message:sub(1, 1) == "!" and scfg.enabled ~= false then
    M.run_shell(message:sub(2))
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
