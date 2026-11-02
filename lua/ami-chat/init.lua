-- ami-chat: the advisor chat panel for ami, as a standalone extension.
--
-- The chat controller + its default floating renderer. It assembles each request
-- and streams it straight to the model (no daemon), and emits chat lifecycle events.
-- Install alongside ami and register it:
--
--   require("ami").setup({ extensions = { require("ami-chat") } })
--
-- It registers a "chat" model slot, provides the "chat" capability (so other
-- extensions reach the panel through api.chat.*), and adds the chat commands.
-- Multi-turn history/branching is a separate extension (ami-history.nvim) that
-- provides the "history" capability; the panel UI is swappable via "chat_ui"
-- (e.g. ami-chat-split.nvim).
local controller = require("ami-chat.controller")

return {
  name = "chat",

  -- Options (user overrides under `chat` in ami.setup win). endpoint/model are nil
  -- by default: the chat model slot inherits ami's default model slot.
  config = {
    -- endpoint = nil,  -- inherit ami's default model.endpoint
    -- model = nil,     -- inherit ami's default model.model (pick via :AmiModel chat)
    timeout_ms = 120000, -- give up if no token arrives within this long (cold load)
    -- `!cmd` in the input runs a shell command (in the project root) and echoes its
    -- output to the transcript — no LLM call. Set enabled = false to disable it.
    shell = {
      enabled = true,
      timeout_ms = 30000, -- kill a command that runs longer than this
      max_output_bytes = 100000, -- truncate output longer than this
    },
    ui = {
      position = "right",   -- "right" | "left" | "center"
      width = 0.4,          -- fraction of columns (<=1) or absolute columns (>1)
      height = 0.9,         -- fraction of lines (<=1) or absolute lines (>1)
      opacity = 0.8,        -- 0..1; lower = more see-through (via 'winblend')
      margin = 2,           -- columns of gap from the screen edge (right/left)
    },
    -- In-panel keys (each a string, a list of strings, or false to disable).
    -- `toggle` optionally maps :AmiChat globally (normal mode); nil = don't.
    keymaps = {
      send = "<CR>",                 -- send (normal mode)
      send_alt = "<C-s>",            -- send (normal + insert; terminals permitting)
      new_session = "<C-n>",         -- new session (normal + insert)
      stop = "<C-c>",                -- stop the in-flight reply (normal + insert)
      close = { "q", "<Esc>" },      -- hide the panel (normal mode)
      history_prev = "<Up>",         -- recall an older sent message (at the input top)
      history_next = "<Down>",       -- recall a newer one / restore the draft (at the bottom)
      toggle = nil,                  -- e.g. "<leader>ac" to map :AmiChat globally
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
    AmiStop = {
      desc = "Stop the in-flight advisor reply",
      fn = function() controller.cancel() end,
    },
  },

  setup = function(api)
    controller.init(api)

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

    -- Optional global mapping for toggling the panel.
    local toggle = (api.config.keymaps or {}).toggle
    if toggle then
      vim.keymap.set("n", toggle, controller.toggle, { desc = "ami: toggle chat panel" })
    end

    api.health(function(report)
      local eff = api.models.effective("chat")
      report.info(("chat model: %s @ %s"):format(tostring(eff.model), tostring(eff.endpoint)))
      report.info("reply timeout: " .. tostring(api.config.timeout_ms) .. "ms")
      if api.resolve("history") then
        report.ok("history provider present (multi-turn persisted)")
      else
        report.info("no history provider — in-memory, current session only (install ami-history.nvim)")
      end
    end)
  end,
}
