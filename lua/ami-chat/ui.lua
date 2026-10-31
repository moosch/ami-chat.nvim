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

local function ensure_transcript_buf()
  if M.transcript_buf and vim.api.nvim_buf_is_valid(M.transcript_buf) then
    return
  end
  M.transcript_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.transcript_buf].bufhidden = "hide"
  vim.bo[M.transcript_buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(M.transcript_buf, "ami://chat")
  start_highlight(M.transcript_buf)
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
  if transcript_visible() then
    vim.api.nvim_win_set_cursor(M.transcript_win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

function M.clear()
  ensure_transcript_buf()
  vim.api.nvim_buf_set_lines(M.transcript_buf, 0, -1, false, {})
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
end

function M.close()
  if M.prompt_win and vim.api.nvim_win_is_valid(M.prompt_win) then
    vim.api.nvim_win_close(M.prompt_win, true)
  end
  M.prompt_win = nil
  if M.transcript_win and vim.api.nvim_win_is_valid(M.transcript_win) then
    vim.api.nvim_win_close(M.transcript_win, true)
  end
  M.transcript_win = nil
end

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

---@param ctl table { submit, new_session, close }
function M.open(ctl)
  ensure_prompt_buf()
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
  map("n", km.close, ctl.close)

  vim.cmd("startinsert")
end

return M
