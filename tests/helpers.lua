-- Shared fixtures for the ami-chat specs: a fake ami extension API, a fresh copy of
-- the controller (reloaded so module-local state doesn't leak between specs), and a
-- couple of small utilities. Not a spec itself (the runner only loads *_spec.lua).
local H = { last_req = nil }

--- The same rough token estimate ami core uses (~4 chars/token), for assertions.
function H.est(s)
  return math.floor(#(s or "") / 4)
end

--- Build a fake `api` (what ami passes to an extension's setup / injects as `A`).
--- opts: { root, block, reply, stream_mode = "stall" }.
---  * gather_async / assemble are synchronous and return a fixed context block.
---  * client.stream_chat records the request in H.last_req; with stream_mode="stall"
---    it never completes on its own (so a cancel can kill it), otherwise it streams
---    `reply` then finishes.
function H.make_api(opts)
  opts = opts or {}
  return {
    context = {
      gather_async = function(_, _, _, _, cb)
        cb({ project_root = opts.root or "/tmp", dep_paths = {} })
      end,
      assemble = function()
        return opts.block or "CTX"
      end,
      estimate_tokens = H.est,
      project_root = function()
        return opts.root or "/tmp"
      end,
      last_selection = function()
        return ""
      end,
    },
    models = { effective = function()
      return { endpoint = "x", model = "m" }
    end },
    client = {
      stream_chat = function(_, req, cb)
        H.last_req = req
        if opts.stream_mode == "stall" then
          return { kill = function()
            vim.schedule(function()
              if cb.on_error then
                cb.on_error("interrupted (signal 15)")
              end
            end)
          end }
        end
        vim.schedule(function()
          if cb.on_token then
            cb.on_token(opts.reply or "ok")
          end
          if cb.on_done then
            cb.on_done()
          end
        end)
        return { kill = function() end }
      end,
    },
    emit = function() end,
    emit_collect = function()
      return {}
    end,
    on = function() end,
    resolve = function()
      return nil
    end,
    provide = function() end,
    health = function() end,
    log = { debug = function() end, error = function() end, info = function() end, warn = function() end },
  }
end

--- A freshly-reloaded controller wired to a fake api built from `opts`. Reloading
--- resets the module's local state (cancellers, caches, _last_tokens, …) so specs
--- don't interfere.
function H.fresh_controller(opts)
  package.loaded["ami-chat.controller"] = nil
  local C = require("ami-chat.controller")
  C.init(H.make_api(opts))
  return C
end

--- Let deferred UI work (e.g. /apply's diff windows) run, then collapse back to a
--- single tab/window so later specs start clean.
function H.drain_windows()
  vim.wait(20)
  pcall(vim.cmd, "silent! tabonly!")
  pcall(vim.cmd, "silent! only!")
end

return H
