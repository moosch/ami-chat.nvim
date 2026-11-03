-- Headless test runner. Invoked via:  nvim --clean --headless -l tests/run.lua
--
-- These specs exercise an ami *extension*, so they need ami core on the path too
-- (require("ami.*")). We look for it via $AMI_CORE, then a sibling checkout
-- (../ami.nvim or ../ai-harness). Then we put this repo's lua/, core's lua/, and the
-- repo root (so require("tests.x") resolves) on package.path, load every
-- tests/*_spec.lua, run them, and exit non-zero on any failure so CI fails.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local tests_dir = vim.fs.dirname(here)
local root = vim.fs.dirname(tests_dir)
local parent = vim.fs.dirname(root)

local function core_at(dir)
  return (dir and vim.fn.filereadable(dir .. "/lua/ami/config.lua") == 1) and dir or nil
end
local core = core_at(os.getenv("AMI_CORE")) or core_at(parent .. "/ami.nvim") or core_at(parent .. "/ai-harness")

local paths = { root .. "/lua/?.lua", root .. "/lua/?/init.lua" }
if core then
  paths[#paths + 1] = core .. "/lua/?.lua"
  paths[#paths + 1] = core .. "/lua/?/init.lua"
else
  io.stderr:write("[ami tests] ami core not found — set AMI_CORE=/path/to/ami.nvim if a spec needs it.\n")
end
paths[#paths + 1] = root .. "/?.lua" -- require("tests.minitest"), require("tests.helpers")
paths[#paths + 1] = package.path
package.path = table.concat(paths, ";")

local T = require("tests.minitest")

-- Load every spec (sorted for stable order).
local specs = vim.fn.glob(tests_dir .. "/*_spec.lua", false, true)
table.sort(specs)
for _, path in ipairs(specs) do
  require("tests." .. vim.fn.fnamemodify(path, ":t:r"))
end

local ok = T.run()
-- `:cquit N` exits with code N so CI fails on a red suite; `:qa!` always exits 0.
if ok then
  vim.cmd("qa!")
else
  vim.cmd("cquit 1")
end
