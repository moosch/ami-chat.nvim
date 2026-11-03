-- ami-chat.ui: the default chat renderer — two stacked floating windows, a
-- transcript "stream" on top and an input prompt below it. The prompt reuses its
-- buffer, so an unsent draft survives being hidden.
--
-- This is the default provider for the "chat_ui" capability. Another extension can
-- replace the whole panel (e.g. ami-chat-split.nvim) by implementing this same
-- interface and registering it with api.provide("chat_ui", impl). Contract:
--   open(ctl) / show() / close() / is_open() / owns_buf(b) /
--   append(text) / clear() / set_status(text|nil) / read_input() / clear_input()
local M = {
  transcript_buf = nil,
  transcript_win = nil,
  prompt_buf = nil,
  prompt_win = nil,
  _status_text = nil,
  -- Up/down recall state for the input: idx = nil means editing the live draft;
  -- otherwise it counts steps back from the newest sent message (1 = newest).
  -- draft holds the unsent text stashed when recall begins, restored on the way back.
  _hist = { idx = nil, draft = nil },
}

-- Chat UI options live under `chat` (this extension's config namespace).
local function ui_opts()
  return (require("ami.config").options.chat or {}).ui or {}
end

local function resolve_dim(v, total, default_frac)
  if not v or v <= 0 then
    return math.floor(total * default_frac)
  end
  if v <= 1 then
    return math.floor(total * v)
  end
  return math.floor(v)
end

local function layout()
  local cols, rows = vim.o.columns, vim.o.lines
  local ui = ui_opts()
  local position = ui.position or "right"
  local margin = ui.margin or 2

  local width = resolve_dim(ui.width, cols, 0.4)
  width = math.max(40, math.min(width, cols - 2))

  local prompt_h = 6
  local total_h = resolve_dim(ui.height, rows, 0.9)
  total_h = math.max(prompt_h + 8, math.min(total_h, rows - 2))
  local trans_h = total_h - prompt_h - 1

  local col
  if position == "left" then
    col = margin
  elseif position == "center" then
    col = math.floor((cols - width) / 2)
  else -- "right" (default)
    col = cols - width - margin
  end
  col = math.max(0, col)

  local top = math.max(1, math.floor((rows - total_h) / 2) - 1)
  return {
    width = width,
    col = col,
    transcript = { row = top, height = trans_h },
    prompt = { row = top + trans_h + 2, height = prompt_h },
  }
end

local function apply_blend(win)
  local opacity = ui_opts().opacity
  if opacity == nil then
    opacity = 1
  end
  local blend = math.floor((1 - opacity) * 100 + 0.5)
  vim.wo[win].winblend = math.max(0, math.min(100, blend))
end

-- Highlight the transcript like telescope's previewer: prefer treesitter (its
-- markdown parser highlights fenced code blocks per language via injections),
-- falling back to the filetype's regex syntax when no parser is available.
local function start_highlight(buf)
  local ts = vim.treesitter
  if ts and ts.highlighter and ts.highlighter.active[buf] then
    return -- already highlighting
  end
  if not (ts and ts.start and pcall(ts.start, buf, "markdown")) then
    pcall(function() vim.bo[buf].syntax = "markdown" end)
  end
end

-- Role styling --------------------------------------------------------------
-- On top of the markdown highlighting, colour each turn's header line so the
-- conversation is easy to scan: You / Advisor / Shell / 💡 Suggestion each get a
-- distinct, theme-derived accent, plus muted/error tints for status lines. Applied
-- as extmarks (priority over treesitter); colours are copied from the colorscheme's
-- semantic groups and refreshed on :colorscheme, so they adapt to light/dark.
M.style_ns = vim.api.nvim_create_namespace("ami_chat_style")
-- Tracks collapse marks (a position in the transcript that survives later appends).
M.mark_ns = vim.api.nvim_create_namespace("ami_chat_mark")

-- group -> { config key, source groups to borrow fg from (first with a real fg
-- wins), attrs }. The Diagnostic family is used because themes colour it distinctly
-- and reliably: You = teal/hint, Advisor = blue/info, Shell = green, Suggestion =
-- yellow, error = red. Each falls back to a syntax group for minimal themes that skip
-- Diagnostic*. The user can override any role via chat.highlights[key] (see below).
local HL_GROUPS = {
  AmiChatRoleUser = { key = "user", src = { "DiagnosticHint", "Identifier" }, bold = true },
  AmiChatRoleAdvisor = { key = "advisor", src = { "DiagnosticInfo", "Function" }, bold = true },
  AmiChatRoleShell = { key = "shell", src = { "DiagnosticOk", "String" }, bold = true },
  AmiChatRoleSuggestion = { key = "suggestion", src = { "DiagnosticWarn", "WarningMsg" }, bold = true },
  AmiChatError = { key = "error", src = { "DiagnosticError", "ErrorMsg" } },
  AmiChatMuted = { key = "muted", src = { "Comment" }, italic = true },
}

-- line pattern -> highlight group (first match wins).
local LINE_HL = {
  { pat = "^### You%s*$", hl = "AmiChatRoleUser" },
  { pat = "^### Advisor%s*$", hl = "AmiChatRoleAdvisor" },
  { pat = "^### Shell%s*$", hl = "AmiChatRoleShell" },
  { pat = "Suggestion%s*$", hl = "AmiChatRoleSuggestion" }, -- "### 💡 Suggestion"
  { pat = "^_%[error.*_%s*$", hl = "AmiChatError" },
  { pat = "^_%[stopped%]_%s*$", hl = "AmiChatMuted" },
  { pat = "^⏳", hl = "AmiChatMuted" },
  { pat = "^_New session:.*_%s*$", hl = "AmiChatMuted" },
}

-- First fg found among the candidate source groups (resolving links), or nil.
local function first_fg(srcs)
  for _, name in ipairs(srcs) do
    local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and type(h) == "table" and h.fg then
      return h.fg
    end
  end
  return nil
end

--- (Re)define the ami-chat highlight groups. By default each role's colour is
--- borrowed from the current colourscheme (bold); the user can override any role via
--- chat.highlights[key], where the value is:
---   a string  → link the role to that highlight group  ("AmiChatRoleUser" ← "Keyword")
---   a table   → an nvim_set_hl spec                     ({ fg = "#7aa2f7", bold = true })
---   false     → turn the tint off for that role (keeps the plain markdown header)
--- Re-run on every :colorscheme, so config overrides survive theme changes.
function M.define_highlights()
  local hl = (require("ami.config").options.chat or {}).highlights or {}
  M._style_disabled = {}
  for name, d in pairs(HL_GROUPS) do
    local override = hl[d.key]
    if override == false then
      M._style_disabled[name] = true -- style_range will skip this role entirely
    elseif type(override) == "string" then
      vim.api.nvim_set_hl(0, name, { link = override })
    elseif type(override) == "table" then
      vim.api.nvim_set_hl(0, name, override)
    else
      local fg = first_fg(d.src) -- theme-derived default
      if fg then
        vim.api.nvim_set_hl(0, name, { fg = fg, bold = d.bold, italic = d.italic })
      else
        vim.api.nvim_set_hl(0, name, { link = d.src[#d.src] })
      end
    end
  end
end

-- Highlight the role-header lines in [from, to] (0-indexed, inclusive).
local function style_range(buf, from, to)
  from = math.max(0, from)
  local lines = vim.api.nvim_buf_get_lines(buf, from, to + 1, false)
  vim.api.nvim_buf_clear_namespace(buf, M.style_ns, from, to + 1)
  local disabled = M._style_disabled or {}
  for i, line in ipairs(lines) do
    for _, rule in ipairs(LINE_HL) do
      if line:match(rule.pat) and not disabled[rule.hl] then
        local lnum = from + i - 1
        pcall(vim.api.nvim_buf_set_extmark, buf, M.style_ns, lnum, 0, {
          end_row = lnum,
          end_col = #line,
          hl_group = rule.hl,
          priority = 200,
        })
        break
      end
    end
  end
end

local function ensure_transcript_buf()
  if M.transcript_buf and vim.api.nvim_buf_is_valid(M.transcript_buf) then
    return
  end
  M.transcript_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.transcript_buf].bufhidden = "hide"
  vim.bo[M.transcript_buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(M.transcript_buf, "ami://chat")
  start_highlight(M.transcript_buf)
  if not M._hl_installed then
    M._hl_installed = true
    M.define_highlights()
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("AmiChatHighlights", { clear = true }),
      callback = M.define_highlights,
    })
  end
end

local function transcript_visible()
  return M.transcript_win and vim.api.nvim_win_is_valid(M.transcript_win)
end

local function ensure_prompt_buf()
  if M.prompt_buf and vim.api.nvim_buf_is_valid(M.prompt_buf) then
    return
  end
  M.prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.prompt_buf].bufhidden = "hide"
  vim.bo[M.prompt_buf].filetype = "markdown"
end

--- Ensure the transcript window is visible (does not steal focus).
function M.show()
  ensure_transcript_buf()
  if transcript_visible() then
    return
  end
  local l = layout()
  M.transcript_win = vim.api.nvim_open_win(M.transcript_buf, false, {
    relative = "editor",
    width = l.width,
    height = l.transcript.height,
    row = l.transcript.row,
    col = l.col,
    style = "minimal",
    border = "rounded",
    title = " ami · advisor ",
    title_pos = "center",
  })
  vim.wo[M.transcript_win].wrap = true
  vim.wo[M.transcript_win].linebreak = true
  apply_blend(M.transcript_win)
end

function M.append(text)
  ensure_transcript_buf()
  local buf = M.transcript_buf
  local last = vim.api.nvim_buf_line_count(buf) - 1
  local last_line = vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or ""
  local parts = vim.split(last_line .. text, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, last, last + 1, false, parts)
  style_range(buf, last, vim.api.nvim_buf_line_count(buf) - 1)
  if transcript_visible() then
    vim.api.nvim_win_set_cursor(M.transcript_win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

--- The transcript as a list of lines (optional renderer method). Lets the
--- controller read back the conversation — e.g. to pull a fenced code block out of
--- it for /yank and /apply. Returns {} when there's no transcript yet.
---@return string[]
function M.transcript_lines()
  if not (M.transcript_buf and vim.api.nvim_buf_is_valid(M.transcript_buf)) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(M.transcript_buf, 0, -1, false)
end

function M.clear()
  ensure_transcript_buf()
  vim.api.nvim_buf_set_lines(M.transcript_buf, 0, -1, false, {})
  vim.api.nvim_buf_clear_namespace(M.transcript_buf, M.style_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(M.transcript_buf, M.mark_ns, 0, -1)
end

--- Mark the current end of the transcript and return an opaque handle. A later
--- `collapse(handle, …)` removes everything appended after this point — used to
--- stream content in live and then fold it away. The handle tracks its position
--- across the appends in between (it's an extmark).
function M.mark()
  ensure_transcript_buf()
  local row = math.max(0, vim.api.nvim_buf_line_count(M.transcript_buf) - 1)
  -- Left gravity: appends at this position must NOT drag the mark along, or it would
  -- ride to the end of the stream and collapse would remove nothing.
  return vim.api.nvim_buf_set_extmark(M.transcript_buf, M.mark_ns, row, 0, { right_gravity = false })
end

--- Remove everything appended since `handle` (from mark()), then optionally append
--- `text`. Leaves the transcript as it was at the mark, plus `text`.
function M.collapse(handle, text)
  ensure_transcript_buf()
  local buf = M.transcript_buf
  if handle then
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.mark_ns, handle, {})
    if pos and pos[1] then
      local from, last = pos[1], vim.api.nvim_buf_line_count(buf)
      if from < last then
        vim.api.nvim_buf_set_lines(buf, from, last, false, {})
        vim.api.nvim_buf_clear_namespace(buf, M.style_ns, from, -1)
      end
    end
    pcall(vim.api.nvim_buf_del_extmark, buf, M.mark_ns, handle)
  end
  if text and text ~= "" then
    M.append(text)
  end
end

function M.set_status(text)
  if text then
    M.append(text)
    M._status_text = text
    return
  end
  if not M._status_text then
    return
  end
  local want = M._status_text
  M._status_text = nil
  ensure_transcript_buf()
  local buf = M.transcript_buf
  local last = vim.api.nvim_buf_line_count(buf) - 1
  local line = vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or ""
  if line == want then
    vim.api.nvim_buf_set_lines(buf, last, last + 1, false, { "" })
  end
end

function M.is_open()
  return transcript_visible() or (M.prompt_win and vim.api.nvim_win_is_valid(M.prompt_win)) or false
end

function M.owns_buf(bufnr)
  return bufnr == M.transcript_buf or bufnr == M.prompt_buf
end

function M.read_input()
  if not (M.prompt_buf and vim.api.nvim_buf_is_valid(M.prompt_buf)) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(M.prompt_buf, 0, -1, false), "\n")
end

function M.clear_input()
  if M.prompt_buf and vim.api.nvim_buf_is_valid(M.prompt_buf) then
    vim.api.nvim_buf_set_lines(M.prompt_buf, 0, -1, false, {})
  end
  -- A fresh draft starts: next Up begins recall from the newest message again.
  M._hist = { idx = nil, draft = nil }
end

-- Pure up/down recall logic, factored out so it can be unit-tested without
-- windows. `dir` is "prev" (older) or "next" (newer); `list` is the sent messages
-- oldest→newest; `state` = { idx, draft } (see the M table). Returns:
--   handled  — true if we consumed the key (false ⇒ let the real arrow move)
--   text     — the input to show, or nil to leave it unchanged
--   state    — the updated recall state
---@return boolean handled, string|nil text, table state
function M._recall(dir, list, state, current)
  state = state or { idx = nil, draft = nil }
  local n = #list
  if dir == "prev" then
    if n == 0 then
      return false, nil, state
    end
    if state.idx == nil then
      state.draft = current or "" -- remember the half-typed draft
      state.idx = 1
    elseif state.idx < n then
      state.idx = state.idx + 1
    else
      return true, nil, state -- already at the oldest; swallow the key
    end
    return true, list[n - state.idx + 1], state
  else -- "next"
    if state.idx == nil then
      return false, nil, state -- editing the live draft; nothing newer to show
    elseif state.idx > 1 then
      state.idx = state.idx - 1
      return true, list[n - state.idx + 1], state
    else
      state.idx = nil -- past the newest: restore the stashed draft
      return true, state.draft or "", state
    end
  end
end

function M.close()
  if M._saved_completeopt then
    vim.o.completeopt = M._saved_completeopt
    M._saved_completeopt = nil
  end
  if M.prompt_win and vim.api.nvim_win_is_valid(M.prompt_win) then
    vim.api.nvim_win_close(M.prompt_win, true)
  end
  M.prompt_win = nil
  if M.transcript_win and vim.api.nvim_win_is_valid(M.transcript_win) then
    vim.api.nvim_win_close(M.transcript_win, true)
  end
  M.transcript_win = nil
end

-- Completion source (the prompt buffer's 'completefunc'), serving two popups like
-- Claude/OpenCode:
--   * a leading "/" offers the available slash commands (name + description);
--   * an "@token" anywhere offers project files to reference in the message.
-- M._commands / M._files are captured in open().
---@param findstart integer
---@param base string
function M._complete(findstart, base)
  local line = vim.api.nvim_get_current_line()
  if findstart == 1 then
    -- Command completion: a leading "/" owns the whole line.
    if line:sub(1, 1) == "/" then
      return 0
    end
    -- File completion: an "@token" ending at the cursor and starting a word.
    local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-based byte col of the cursor
    local before = line:sub(1, col)
    local start = before:match("()@[%w._/%-]*$") -- 1-based index of the @, if any
    if start then
      local prev = before:sub(start - 1, start - 1)
      if start == 1 or prev:match("%s") then
        return start - 1 -- 0-based byte col of the @
      end
    end
    return -3 -- nothing to complete here
  end

  base = base or ""
  local items = {}
  if base:sub(1, 1) == "/" then
    local typed = base:sub(2)
    for _, c in ipairs((M._commands and M._commands()) or {}) do
      if typed == "" or c.name:sub(1, #typed):lower() == typed:lower() then
        items[#items + 1] = { word = "/" .. c.name, abbr = "/" .. c.name, menu = c.desc or "", icase = 1 }
      end
    end
  elseif base:sub(1, 1) == "@" then
    local typed = base:sub(2)
    for _, rel in ipairs((M._files and M._files()) or {}) do
      if typed == "" or rel:sub(1, #typed):lower() == typed:lower() then
        items[#items + 1] = { word = "@" .. rel, abbr = "@" .. rel, menu = "file", icase = 1 }
      end
    end
  end
  return items
end

-- A stable global name for 'completefunc' to call into the module.
_G.__ami_chat_completefunc = _G.__ami_chat_completefunc
  or function(findstart, base) return require("ami-chat.ui")._complete(findstart, base) end

--- Open the full interactive panel and focus the input.
-- The prompt keymaps, from config (chat.keymaps), with built-in defaults.
local function keymaps()
  return (require("ami.config").options.chat or {}).keymaps or {}
end

-- Normalize a config key (string, list, or nil/false) to a list of lhs strings.
local function keys(v)
  if not v then
    return {}
  end
  return type(v) == "table" and v or { v }
end

local function first(v, fallback)
  local k = keys(v)[1]
  return k or fallback
end

---@param ctl table { submit, new_session, close, stop, input_history, commands, files }
function M.open(ctl)
  ensure_prompt_buf()
  M._hist = { idx = nil, draft = nil } -- start on a fresh draft each open
  M.show()

  local km = keymaps()
  local l = layout()
  M.prompt_win = vim.api.nvim_open_win(M.prompt_buf, true, {
    relative = "editor",
    width = l.width,
    height = l.prompt.height,
    row = l.prompt.row,
    col = l.col,
    style = "minimal",
    border = "rounded",
    title = (" Ask  (%s send · %s new · %s close) "):format(
      first(km.send, "<CR>"), first(km.new_session, "<C-n>"), first(km.close, "q")),
    title_pos = "center",
  })
  vim.wo[M.prompt_win].wrap = true
  vim.wo[M.prompt_win].linebreak = true
  apply_blend(M.prompt_win)

  local opts = { buffer = M.prompt_buf, nowait = true, silent = true }
  local function map(modes, lhs, rhs)
    for _, k in ipairs(keys(lhs)) do
      vim.keymap.set(modes, k, rhs, opts)
    end
  end
  map("n", km.send, ctl.submit)
  map({ "n", "i" }, km.send_alt, ctl.submit)
  map({ "n", "i" }, km.new_session, ctl.new_session)
  map({ "n", "i" }, km.stop, ctl.stop)
  map("n", km.close, ctl.close)

  -- Recall previously sent messages with up/down, but only at the input's edges so
  -- the arrows still move the cursor within a multi-line draft: Up recalls an older
  -- message when on the first line, Down recalls a newer one (or restores the
  -- stashed draft) when on the last line. Elsewhere the real arrow key is passed
  -- through. The half-typed draft is remembered and restored on the way back down.
  local function set_input(text)
    local lines = vim.split(text or "", "\n", { plain = true })
    vim.api.nvim_buf_set_lines(M.prompt_buf, 0, -1, false, lines)
    if M.prompt_win and vim.api.nvim_win_is_valid(M.prompt_win) then
      local lastrow = #lines
      vim.api.nvim_win_set_cursor(M.prompt_win, { lastrow, #(lines[lastrow] or "") })
    end
  end

  local function nav(dir, key)
    local list = (ctl.input_history and ctl.input_history()) or {}
    local row = vim.api.nvim_win_get_cursor(0)[1]
    -- Let a visible completion menu own the arrows.
    local at_edge = vim.fn.pumvisible() == 0
      and ((dir == "prev" and row == 1)
        or (dir == "next" and row == vim.api.nvim_buf_line_count(M.prompt_buf)))
    if at_edge then
      local handled, text, state = M._recall(dir, list, M._hist, M.read_input())
      M._hist = state
      if handled then
        if text ~= nil then
          set_input(text)
        end
        return
      end
    end
    -- Not recalling: let the arrow do its normal thing (move the cursor).
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
  end

  local function bind_nav(lhs, dir)
    for _, k in ipairs(keys(lhs)) do
      vim.keymap.set({ "n", "i" }, k, function() nav(dir, k) end, opts)
    end
  end
  bind_nav(km.history_prev, "prev")
  bind_nav(km.history_next, "next")

  -- Completion popups. Typing "/" at the start of an empty draft opens the command
  -- menu; typing "@" at a word boundary opens the project-file menu. Both narrow as
  -- you type. The Up/Down recall above already defers to a visible menu, so the
  -- arrows navigate it.
  M._commands = ctl.commands
  M._files = ctl.files
  vim.bo[M.prompt_buf].completefunc = "v:lua.__ami_chat_completefunc"
  -- Show the menu without auto-inserting anything; keep it per-buffer where
  -- supported, else fall back to a saved/restored global.
  local co = "menu,menuone,noinsert,noselect"
  if not pcall(vim.api.nvim_set_option_value, "completeopt", co, { buf = M.prompt_buf }) then
    M._saved_completeopt = vim.o.completeopt
    vim.o.completeopt = co
  end

  vim.keymap.set("i", "/", function()
    local l = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    return (l == "" and col == 0) and "/<C-x><C-u>" or "/"
  end, { buffer = M.prompt_buf, expr = true, silent = true })

  -- "@" opens the file popup, but only when it starts a word (so emails and the
  -- like aren't hijacked).
  vim.keymap.set("i", "@", function()
    local l = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local prev = col > 0 and l:sub(col, col) or ""
    return (col == 0 or prev:match("%s")) and "@<C-x><C-u>" or "@"
  end, { buffer = M.prompt_buf, expr = true, silent = true })

  vim.keymap.set("i", "<Tab>", function()
    return vim.fn.pumvisible() == 1 and "<C-y>" or "<Tab>"
  end, { buffer = M.prompt_buf, expr = true, silent = true })

  vim.keymap.set("i", "<CR>", function()
    -- Accept the highlighted command; otherwise a normal newline in the draft.
    if vim.fn.pumvisible() == 1 and vim.fn.complete_info({ "selected" }).selected ~= -1 then
      return "<C-y>"
    end
    return "<CR>"
  end, { buffer = M.prompt_buf, expr = true, silent = true })

  vim.cmd("startinsert")
end

return M
