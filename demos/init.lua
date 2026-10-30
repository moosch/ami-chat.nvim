-- Minimal Neovim config for recording the ami-chat demo with VHS.
--   nvim -u demos/init.lua <file>
--
-- Needs ami core on the runtimepath. By default it looks for the core checkout
-- next to this repo (../ami.nvim, then ../ai-harness); override with $AMI_CORE.
-- Point at your LM Studio with $AMI_ENDPOINT / $AMI_CHAT_MODEL.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local parent = vim.fn.fnamemodify(root, ":h")
local function add(p)
  if p and vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:append(p)
    return true
  end
end

vim.opt.runtimepath:append(root) -- this extension (ami-chat)
if not add(os.getenv("AMI_CORE")) then
  local _ = add(parent .. "/ami.nvim") or add(parent .. "/ai-harness")
end

vim.o.termguicolors = true
vim.o.number = true
vim.o.signcolumn = "yes"
vim.o.laststatus = 0
vim.o.swapfile = false

local endpoint = os.getenv("AMI_ENDPOINT") or "http://localhost:1234/v1"
require("ami").setup({
  -- qwen3-coder gives the best advisor replies and is typically already loaded;
  -- override with AMI_CHAT_MODEL.
  model = { endpoint = endpoint, model = os.getenv("AMI_CHAT_MODEL") or "qwen3-coder" },
  extensions = { require("ami-chat") },
})
