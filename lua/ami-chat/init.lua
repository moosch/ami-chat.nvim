-- ami-chat: the advisor chat panel for ami, as a standalone extension.
--
-- The chat controller, its default floating renderer, and the conversation-tree
-- viewer, extracted from ami core so core is a pure runtime. Install alongside ami
-- and register it:
--
--   require("ami").setup({ extensions = { require("ami-chat") } })
--
-- It registers a "chat" model slot, provides the "chat" capability (so other
-- extensions reach the panel through api.chat.*), and adds the chat commands. The
-- panel UI is itself swappable: another extension can provide "chat_ui" (e.g.
-- ami-chat-split.nvim) and this controller will drive it instead of the bundled one.
local controller = require("ami-chat.controller")
local tree = require("ami-chat.tree")

return {
  name = "chat",

  -- Options (user overrides under `chat` in ami.setup win). endpoint/model are nil
  -- by default: the chat model slot inherits ami's default model slot.
  config = {
    -- endpoint = nil,  -- inherit ami's default model.endpoint
    -- model = nil,     -- inherit ami's default model.model (pick via :AmiModel chat)
    ui = {
      position = "right",   -- "right" | "left" | "center"
      width = 0.4,          -- fraction of columns (<=1) or absolute columns (>1)
      height = 0.9,         -- fraction of lines (<=1) or absolute lines (>1)
      opacity = 0.8,        -- 0..1; lower = more see-through (via 'winblend')
      margin = 2,           -- columns of gap from the screen edge (right/left)
    },
  },

  commands = {
    AmiChat = {
      desc = "Toggle the advisor chat panel",
      fn = function() controller.toggle() end,
    },
    AmiAsk = {
      desc = "Ask the advisor (visual range sends the selection + its deps)",
      nargs = "+",
      range = true,
      fn = function(opts)
        local selection, range = nil, nil
        if opts.range > 0 then
          selection = require("ami.context").last_selection()
          range = { opts.line1, opts.line2 }
        end
        controller.ask(opts.args, selection, range)
      end,
    },
    AmiNewSession = {
      desc = "Start a fresh advisor session",
      nargs = "?",
      fn = function(opts) controller.new_session(opts.args) end,
    },
    AmiTree = {
      desc = "Open the conversation tree (branch/switch/summarize)",
      fn = function() tree.open(false) end,
    },
  },

  setup = function(api)
    controller.init(api)
    tree.init(api)

    -- Register the chat model slot (inherits ami's default when unset).
    api.models.register({
      name = "chat",
      label = "Chat / advisor",
      endpoint = function() return api.config.endpoint end,
      get = function() return api.config.model end,
      set = function(m) api.config.model = m end,
    })

    -- Offer the chat capability so other extensions (e.g. proactive) can reach the
    -- panel through api.chat.*.
    api.provide("chat", controller)
  end,
}
