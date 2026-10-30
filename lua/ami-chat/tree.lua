-- ami-chat.tree: a viewer for the conversation tree.
--
-- Renders the branching history as an indented tree in a right-hand split.
-- Keys: <CR> switch the active branch to a node, s summarize up to a node,
-- r refresh, q close. Switching/summarizing re-render the chat transcript to
-- match the active path (via the chat controller).
local controller = require("ami-chat.controller")

local M = {
  buf = nil,
  win = nil,
  data = nil,
  node_by_id = {},
  line_to_id = {},
}

local A = nil -- ami extension API, set in M.init()

function M.init(api)
  A = api
end

local function req_base()
  return {
    session_id = controller.session_id,
    project_root = controller.project_root(),
    model = A.models.effective("chat").model, -- used by /summarize; ignored elsewhere
  }
end

local function build_lines(data)
  local by_parent, by_id = {}, {}
  for _, n in ipairs(data.nodes or {}) do
    by_id[n.id] = n
    local p = n.parent or ""
    by_parent[p] = by_parent[p] or {}
    table.insert(by_parent[p], n)
  end
  for _, kids in pairs(by_parent) do
    table.sort(kids, function(a, b)
      return (tonumber((a.id:gsub("%D", ""))) or 0) < (tonumber((b.id:gsub("%D", ""))) or 0)
    end)
  end
  local path_set = {}
  for _, id in ipairs(data.path or {}) do
    path_set[id] = true
  end

  local lines, map = {}, {}
  local function walk(parent, depth)
    for _, n in ipairs(by_parent[parent] or {}) do
      local head = (n.id == data.head) and "*" or (path_set[n.id] and "|" or " ")
      local col = n.collapsed and "~" or " "
      local role = (n.role == "assistant") and "A" or "U"
      local text = (n.content or ""):gsub("%s+", " ")
      if #text > 48 then
        text = text:sub(1, 48) .. "…"
      end
      lines[#lines + 1] = string.format("%s%s %s%s %s: %s", head, col, string.rep("  ", depth), n.id, role, text)
      map[#lines] = n.id
      walk(n.id, depth + 1)
    end
  end
  walk("", 0)
  if #lines == 0 then
    lines = { "(empty session — ask something first)" }
  end
  return lines, map, by_id
end

local function path_nodes()
  local out = {}
  for _, id in ipairs((M.data or {}).path or {}) do
    if M.node_by_id[id] then
      out[#out + 1] = M.node_by_id[id]
    end
  end
  return out
end

local function ensure_buf()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    return
  end
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].bufhidden = "hide"
  vim.bo[M.buf].filetype = "ami-tree"
  vim.api.nvim_buf_set_name(M.buf, "ami://tree")

  local opts = { buffer = M.buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", M.switch, opts)
  vim.keymap.set("n", "s", M.summarize, opts)
  vim.keymap.set("n", "r", function() M.open() end, opts)
  vim.keymap.set("n", "q", M.close, opts)
end

local function show_win()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    return
  end
  local cur = vim.api.nvim_get_current_win()
  vim.cmd("botright vsplit")
  M.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.win, M.buf)
  vim.api.nvim_win_set_width(M.win, math.max(48, math.floor(vim.o.columns * 0.35)))
  vim.wo[M.win].number = false
  vim.wo[M.win].relativenumber = false
  vim.wo[M.win].winbar = "tree  <CR> switch · s summarize · r refresh · q close"
  vim.api.nvim_set_current_win(cur)
end

local function render()
  ensure_buf()
  local lines, map, by_id = build_lines(M.data)
  M.line_to_id, M.node_by_id = map, by_id
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
end

--- Open/refresh the tree viewer. If sync_transcript, also re-render the chat.
function M.open(sync_transcript)
  A.client.post_json("/tree", req_base(), function(ok, data)
    if not ok then
      A.log.error("tree: " .. tostring(data))
      return
    end
    M.data = data
    render()
    show_win()
    if sync_transcript then
      controller.render_nodes(path_nodes())
    end
  end)
end

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win = nil
end

local function node_under_cursor()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(M.win)[1]
  return M.line_to_id[line]
end

function M.switch()
  local id = node_under_cursor()
  if not id then
    return
  end
  local body = req_base()
  body.node_id = id
  A.client.post_json("/branch", body, function(ok, data)
    if not ok then
      A.log.error("branch: " .. tostring(data))
      return
    end
    controller.render_nodes(data.path)
    M.open(false)
    vim.notify("ami: switched to branch at " .. id, vim.log.levels.INFO)
  end)
end

function M.summarize()
  local id = node_under_cursor()
  if not id then
    return
  end
  local body = req_base()
  body.node_id = id
  vim.notify("ami: summarizing up to " .. id .. "…", vim.log.levels.INFO)
  A.client.post_json("/summarize", body, function(ok, data)
    if not ok then
      A.log.error("summarize: " .. tostring(data))
      return
    end
    A.log.info("summarize: done (" .. #(data.summary or "") .. " chars)")
    M.open(true)
    vim.notify("ami: summarized up to " .. id, vim.log.levels.INFO)
  end, { timeout_s = 180 })
end

return M
