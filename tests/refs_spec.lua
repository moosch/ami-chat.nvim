-- @file references: _resolve_refs parses @path tokens, resolving only real files
-- inside the project root (a security boundary), and file_list walks the project for
-- the completion popup.
local T = require("tests.minitest")
local H = require("tests.helpers")

local function fixture()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/sub", "p")
  vim.fn.mkdir(root .. "/node_modules", "p")
  vim.fn.writefile({ "a" }, root .. "/a.lua")
  vim.fn.writefile({ "b" }, root .. "/sub/b.lua")
  vim.fn.writefile({ "j" }, root .. "/node_modules/pkg.js")
  return root
end

local function has(list, v)
  for _, x in ipairs(list) do
    if x == v then
      return true
    end
  end
  return false
end

T.describe("_resolve_refs", function()
  local root = fixture()
  local C = H.fresh_controller({ root = root })
  local function rel(msg)
    return select(2, C._resolve_refs(msg))
  end

  T.it("resolves existing files, project-relative, in order", function()
    T.eq(rel("see @a.lua and @sub/b.lua"), { "a.lua", "sub/b.lua" })
  end)
  T.it("ignores a missing file", function()
    T.eq(#rel("look at @nope.lua"), 0)
  end)
  T.it("ignores a bare @ in prose", function()
    T.eq(#rel("email me @ here"), 0)
  end)
  T.it("ignores an @word that is not a file", function()
    T.eq(#rel("the @param tag"), 0)
  end)
  T.it("trims trailing sentence punctuation", function()
    T.eq(rel("open @a.lua."), { "a.lua" })
  end)
  T.it("de-dupes repeats", function()
    T.eq(#rel("@a.lua and @a.lua again"), 1)
  end)
  T.it("refuses a path escaping the root", function()
    T.eq(#rel("@../secret"), 0)
  end)
end)

T.describe("file_list", function()
  local root = fixture()
  local C = H.fresh_controller({ root = root })
  local files = C.file_list()

  T.it("finds nested files", function()
    T.ok(has(files, "a.lua") and has(files, "sub/b.lua"))
  end)
  T.it("excludes ignored directories", function()
    T.falsy(has(files, "node_modules/pkg.js"))
  end)
  T.it("is sorted", function()
    local sorted = vim.deepcopy(files)
    table.sort(sorted)
    T.eq(files, sorted)
  end)
end)
