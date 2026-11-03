-- A tiny zero-dependency test framework for ami's headless specs.
--
-- No plenary, no busted — just `nvim --headless` and plain Lua, so CI needs
-- nothing but Neovim. Spec files `require("tests.minitest")`, declare cases with
-- describe/it, assert with eq/ok/…, and the runner (tests/run.lua) calls run().
--
--   local T = require("tests.minitest")
--   T.describe("thing", function()
--     T.it("does x", function() T.eq(1 + 1, 2) end)
--   end)
--
-- Assertions raise on failure; the runner reports TAP-ish output and exits
-- non-zero if any case failed.
--
-- Vendored from ami core (ami.nvim/tests/minitest.lua) so this extension's suite
-- stands alone; keep the two in sync if the framework changes.
local M = {}

---@type { name: string, fn: function }[]
local cases = {}
local stack = {}

--- Group related cases; nests for readable names.
function M.describe(name, fn)
  stack[#stack + 1] = name
  local ok, err = pcall(fn)
  stack[#stack] = nil
  if not ok then
    error(err, 0)
  end
end

--- Declare a test case.
function M.it(name, fn)
  local prefix = #stack > 0 and (table.concat(stack, " › ") .. " › ") or ""
  cases[#cases + 1] = { name = prefix .. name, fn = fn }
end

-- Deep structural equality for tables (and primitives).
local function deep_equal(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function render(v)
  if type(v) == "table" then
    return vim.inspect(v)
  end
  return tostring(v)
end

--- Assert deep equality.
function M.eq(got, want, msg)
  if not deep_equal(got, want) then
    error(("%s\n  expected: %s\n  got:      %s"):format(msg or "values differ", render(want), render(got)), 2)
  end
end

--- Assert a value is truthy.
function M.ok(v, msg)
  if not v then
    error(msg or "expected a truthy value, got " .. render(v), 2)
  end
end

--- Assert a value is falsy (nil or false).
function M.falsy(v, msg)
  if v then
    error(msg or "expected a falsy value, got " .. render(v), 2)
  end
end

--- Assert `s` contains `sub` (plain substring).
function M.contains(s, sub, msg)
  if type(s) ~= "string" or not s:find(sub, 1, true) then
    error(("%s\n  %q\n  should contain %q"):format(msg or "substring not found", tostring(s), sub), 2)
  end
end

--- Assert `s` does NOT contain `sub`.
function M.excludes(s, sub, msg)
  if type(s) == "string" and s:find(sub, 1, true) then
    error(("%s\n  %q\n  should NOT contain %q"):format(msg or "unexpected substring", s, sub), 2)
  end
end

--- Assert calling `fn` raises, and (optionally) that the message contains `sub`.
function M.raises(fn, sub, msg)
  local ok, err = pcall(fn)
  if ok then
    error(msg or "expected the call to raise, but it did not", 2)
  end
  if sub and not tostring(err):find(sub, 1, true) then
    error(("%s\n  error %q should contain %q"):format(msg or "wrong error", tostring(err), sub), 2)
  end
end

--- Run every declared case. Returns true iff all passed.
function M.run()
  local pass, fail = 0, 0
  io.write(("TAP version 13\n1..%d\n"):format(#cases))
  for i, c in ipairs(cases) do
    local ok, err = pcall(c.fn)
    if ok then
      pass = pass + 1
      io.write(("ok %d - %s\n"):format(i, c.name))
    else
      fail = fail + 1
      io.write(("not ok %d - %s\n"):format(i, c.name))
      for line in (tostring(err) .. "\n"):gmatch("(.-)\n") do
        io.write("  " .. line .. "\n")
      end
    end
  end
  io.write(("\n# %d passed, %d failed, %d total\n"):format(pass, fail, #cases))
  return fail == 0
end

return M
