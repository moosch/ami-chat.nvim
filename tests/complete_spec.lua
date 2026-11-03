-- The input completion function: one completefunc serves both /commands (leading
-- slash) and @files (an @token at a word boundary).
local T = require("tests.minitest")
local ui = require("ami-chat.ui")

-- Stub the sources the completefunc reads (normally wired up in ui.open()).
ui._files = function()
  return { "a.lua", "sub/b.lua", "x.md" }
end
ui._commands = function()
  return { { name = "help", desc = "h" }, { name = "new", desc = "n" } }
end

local function set_line(s, col)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { s })
  vim.api.nvim_win_set_cursor(0, { 1, col or #s })
end

local function words(items)
  local w = {}
  for _, it in ipairs(items) do
    w[#w + 1] = it.word
  end
  return w
end

local function has(list, v)
  for _, x in ipairs(list) do
    if x == v then
      return true
    end
  end
  return false
end

T.describe("_complete findstart", function()
  T.it("a command line completes from column 0", function()
    set_line("/he")
    T.eq(ui._complete(1, ""), 0)
  end)
  T.it("an @token completes from the @'s column", function()
    set_line("explain @src/fo")
    T.eq(ui._complete(1, ""), 8)
  end)
  T.it("@ mid-word is not a completion", function()
    set_line("foo@bar")
    T.eq(ui._complete(1, ""), -3)
  end)
  T.it("a leading @ completes from column 0", function()
    set_line("@a")
    T.eq(ui._complete(1, ""), 0)
  end)
  T.it("plain text is not a completion", function()
    set_line("hello there")
    T.eq(ui._complete(1, ""), -3)
  end)
end)

T.describe("_complete items", function()
  T.it("/h offers matching commands only", function()
    local w = words(ui._complete(0, "/h"))
    T.ok(has(w, "/help"))
    T.falsy(has(w, "/new"))
  end)
  T.it("@a offers matching files only", function()
    local w = words(ui._complete(0, "@a"))
    T.ok(has(w, "@a.lua"))
    T.falsy(has(w, "@x.md"))
  end)
  T.it("@sub/ narrows to that directory", function()
    T.ok(has(words(ui._complete(0, "@sub/")), "@sub/b.lua"))
  end)
  T.it("@ alone offers every file", function()
    T.eq(#ui._complete(0, "@"), 3)
  end)
end)
