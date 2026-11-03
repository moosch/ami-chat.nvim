-- The chat cancel registry: cancel() stops the in-flight reply AND any producer
-- (ami-doc, …) that registered a canceller, all from one <C-c> / :AmiStop.
local T = require("tests.minitest")
local H = require("tests.helpers")

T.describe("controller cancel registry", function()
  T.it("returns false when nothing is streaming", function()
    local C = H.fresh_controller()
    T.falsy(C.cancel())
  end)

  T.it("runs a registered canceller once, then clears it", function()
    local C = H.fresh_controller()
    local n = 0
    C.register_cancel(function()
      n = n + 1
    end)
    T.ok(C.cancel())
    T.eq(n, 1)
    T.falsy(C.cancel()) -- nothing left
    T.eq(n, 1)
  end)

  T.it("unregister prevents the run", function()
    local C = H.fresh_controller()
    local n = 0
    local tok = C.register_cancel(function()
      n = n + 1
    end)
    C.unregister_cancel(tok)
    T.falsy(C.cancel())
    T.eq(n, 0)
  end)

  T.it("cancels the in-flight chat reply (kills it, flags [stopped])", function()
    local C = H.fresh_controller()
    local killed
    C.streaming = true
    C._inflight = { kill = function(_, sig)
      killed = sig
    end }
    T.ok(C.cancel())
    T.eq(killed, "sigterm")
    T.ok(C._cancelled)
  end)

  T.it("one cancel stops the reply and a producer together", function()
    local C = H.fresh_controller()
    local killed, prod = nil, 0
    C.streaming = true
    C._inflight = { kill = function(_, s)
      killed = s
    end }
    C.register_cancel(function()
      prod = prod + 1
    end)
    T.ok(C.cancel())
    T.eq(killed, "sigterm")
    T.eq(prod, 1)
  end)
end)
