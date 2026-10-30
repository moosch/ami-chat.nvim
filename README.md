# ami-chat.nvim

The chat advisor panel for [ami](https://github.com/moosch/ami.nvim).

A floating transcript + prompt where you discuss your thinking and get streamed,
**advice-only** feedback grounded in your open file, selection, `README.md`/
`PLAN.md`, and — via LSP — the files your code depends on. Includes the **branching
history tree** (branch, switch, summarize). Extracted from ami core into its own
extension so core stays a small runtime.

It provides ami's `chat` capability (so other extensions can reach the panel) and a
`chat` model slot. The panel UI is itself swappable — install
[`ami-chat-split.nvim`](https://github.com/moosch/ami-chat-split.nvim) for a
split-window layout, or write your own `chat_ui` provider.

## Demo

Discuss a problem, get advice-only feedback in the right-docked, see-through panel:

![chat advisor demo](demos/chat.gif)

> Rendered from [`demos/chat.tape`](demos/chat.tape); see
> [`demos/README.md`](demos/README.md) to (re)generate it.

## Requirements

- [ami.nvim](https://github.com/moosch/ami.nvim) (the runtime: daemon, model
  registry, extension API).

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim), install it alongside ami and
register it:

```lua
{
  "moosch/ami.nvim",
  dependencies = { "moosch/ami-chat.nvim" },
  build = "make build",
  config = function()
    require("ami").setup({
      extensions = { require("ami-chat") },
      -- chat = { ui = { position = "right", opacity = 0.8 } },  -- optional
    })
  end,
}
```

## Commands

| Command | What it does |
| --- | --- |
| `:AmiChat` | Toggle the panel (`<CR>` normal-mode = send, `<C-n>` new session, `q`/`<Esc>` hide) |
| `:AmiAsk {text}` | One-shot question; visual mode sends the selection + its deps |
| `:AmiNewSession [name]` | Start a fresh conversation |
| `:AmiTree` | Conversation tree — `<CR>` switch, `s` summarize, `r` refresh, `q` close |

Pick the chat model live with `:AmiModel chat`.

## Configuration

Options live under `chat` in ami's `setup()`:

| Key | Default | Meaning |
| --- | --- | --- |
| `endpoint` | `nil` | provider base URL; `nil` ⇒ ami's default `model.endpoint` |
| `model` | `nil` | chat model; `nil` ⇒ ami's default `model.model` (pick via `:AmiModel chat`) |
| `ui.position` | `"right"` | `"right"` \| `"left"` \| `"center"` |
| `ui.width` / `ui.height` | `0.4` / `0.9` | fraction of screen (`<=1`) or absolute cells (`>1`) |
| `ui.opacity` | `0.8` | `0`..`1`; lower = more see-through (via `winblend`) |
| `ui.margin` | `2` | columns of gap from the screen edge |

> `ui.*` applies to the built-in floating panel. When a `chat_ui` provider like
> `ami-chat-split.nvim` is active, that extension's own options apply instead.

## Replacing the panel UI

The chat controller draws nothing itself — it drives whatever `chat_ui` provider is
registered, falling back to the bundled floating panel (`lua/ami-chat/ui.lua`). See
ami's [`docs/extensions.md`](https://github.com/moosch/ami.nvim/blob/main/docs/extensions.md)
for the `chat_ui` contract.

## License

[MIT](LICENSE)
