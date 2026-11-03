-- The context-size estimate: after a turn, _last_tokens breaks the request into
-- instructions / context / history / message / total, the header indicator updates,
-- and /tokens prints the breakdown.
local T = require("tests.minitest")
local H = require("tests.helpers")
local ui = require("ami-chat.ui")

T.describe("context estimate", function()
  local C = H.fresh_controller({ root = "/tmp", block = "CONTEXTBLOCK", reply = "hi" })
  local cfg = require("ami.config")
  cfg.options.chat = cfg.options.chat or {}
  cfg.options.chat.context_window = 32000
  C.ask("hello world")
  vim.wait(50)
  -- Snapshot now: `describe` bodies run at load time, so a later block's turn would
  -- otherwise overwrite the shared globals (ui._tokens, H.last_req) before these
  -- assertions execute.
  local t = C._last_tokens
  local req_sum = 0
  for _, m in ipairs(H.last_req.messages) do
    req_sum = req_sum + H.est(m.content)
  end
  local header_tokens = ui._tokens
  local header_window = ui._tokens_window

  T.it("populates a breakdown", function()
    T.ok(type(t) == "table")
  end)
  T.it("context = estimate(block)", function()
    T.eq(t.context, H.est("CONTEXTBLOCK"))
  end)
  T.it("history = 0 on the first turn", function()
    T.eq(t.history, 0)
  end)
  T.it("message = estimate('hello world')", function()
    T.eq(t.message, H.est("hello world"))
  end)
  T.it("budget defaults to 8000", function()
    T.eq(t.budget, 8000)
  end)
  T.it("total sums every message in the request", function()
    T.eq(t.total, req_sum)
  end)
  T.it("instructions = total - context - history - message", function()
    T.eq(t.instructions, t.total - t.context - t.history - t.message)
  end)
  T.it("updates the header indicator", function()
    T.eq(header_tokens, t.total)
  end)
  T.it("passes the context-window denominator through", function()
    T.eq(header_window, 32000)
  end)
end)

T.describe("/tokens", function()
  local C = H.fresh_controller({ block = "CTX", reply = "ok" })
  C.ask("hi")
  vim.wait(50)
  ui.clear()
  C.run_command("/tokens")
  local out = table.concat(ui.transcript_lines(), "\n")

  T.it("prints the total", function()
    T.ok(out:find("total sent", 1, true))
  end)
  T.it("flags history as what /compact reduces", function()
    T.ok(out:find("shrinks this", 1, true))
  end)
  T.it("shows the context budget", function()
    T.ok(out:find("budget", 1, true))
  end)
end)
