-- The input up/down recall state machine (ui._recall), tested without windows.
-- `list` is sent messages oldest→newest; state = { idx, draft }.
local T = require("tests.minitest")
local ui = require("ami-chat.ui")

local LIST = { "first", "second", "third" }

T.describe("ui._recall", function()
  T.it("prev from a fresh draft stashes it and shows the newest", function()
    local handled, text, s = ui._recall("prev", LIST, { idx = nil, draft = nil }, "my draft")
    T.ok(handled)
    T.eq(text, "third")
    T.eq(s.idx, 1)
    T.eq(s.draft, "my draft")
  end)

  T.it("prev cycles to older messages", function()
    local _, _, s1 = ui._recall("prev", LIST, { idx = nil, draft = nil }, "d")
    local _, text, s2 = ui._recall("prev", LIST, s1, "d")
    T.eq(text, "second")
    T.eq(s2.idx, 2)
  end)

  T.it("prev at the oldest is swallowed (handled, no change)", function()
    local handled, text, s = ui._recall("prev", LIST, { idx = 3, draft = "d" }, "x")
    T.ok(handled)
    T.eq(text, nil)
    T.eq(s.idx, 3)
  end)

  T.it("next on the live draft is not handled (let the arrow move)", function()
    T.falsy(ui._recall("next", LIST, { idx = nil, draft = nil }, "d"))
  end)

  T.it("next walks newer, then restores the stashed draft", function()
    local _, t1, s1 = ui._recall("next", LIST, { idx = 2, draft = "stash" }, "x")
    T.eq(t1, "third")
    T.eq(s1.idx, 1)
    local _, t2, s2 = ui._recall("next", LIST, s1, "x")
    T.eq(t2, "stash")
    T.eq(s2.idx, nil)
  end)

  T.it("prev on an empty history is not handled", function()
    T.falsy(ui._recall("prev", {}, { idx = nil }, "d"))
  end)
end)
