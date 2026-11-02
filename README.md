# ami-chat.nvim

The chat advisor panel for [ami](https://github.com/moosch/ami.nvim).

A floating transcript + prompt where you discuss your thinking and get streamed,
**advice-only** feedback grounded in your open file, selection, `README.md`/
`PLAN.md`, and — via LSP — the files your code depends on. It assembles each request
and streams it straight to LM Studio (no daemon).

It provides ami's `chat` capability (so other extensions can reach the panel) and a
`chat` model slot. The panel UI is swappable — install
[`ami-chat-split.nvim`](https://github.com/moosch/ami-chat-split.nvim) for a
split-window layout, or write your own `chat_ui` provider.

For multi-turn memory, branching, and `:AmiTree`, install
[`ami-history.nvim`](https://github.com/moosch/ami-history.nvim) (it provides the
`history` capability). Without it, chat keeps an in-memory history for the current
session only.

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
| `:AmiStop` | Stop the in-flight reply (also `<C-c>` in the panel) |

Pick the chat model live with `:AmiModel chat`. A reply also stops if you close the
panel, and gives up on its own if no token arrives within `timeout_ms`.

## Slash commands

A message typed into the input that begins with `/` is a **command**, not a prompt to
the model. Type `/` at the start of an empty prompt and a **popup lists the available
commands** (name + description), narrowing as you type — like Claude/OpenCode. Move
through it with the arrows (or `<C-n>`/`<C-p>`) and accept with `<Tab>` or `<CR>`; or
just `/help` to print the list into the transcript.

| Command | What it does | From |
| --- | --- | --- |
| `/help` | List the available commands | ami-chat |
| `/new [name]` | Start a fresh session | ami-chat |
| `/model [slot]`, `/models` | Pick a model for a slot (`:AmiModel`) / show each slot's model (`:AmiModels`) | ami (core) |
| `/compact [keep=N]`, `/compress` | Summarize earlier turns into one summary, so future turns carry the summary instead of the whole history — shrinking the context sent to the model | [ami-history.nvim](https://github.com/moosch/ami-history.nvim) |
| `/persona [name\|off]` | Switch the advisor's persona (`:AmiPersona`) | [ami-persona.nvim](https://github.com/moosch/ami-persona.nvim) |

The list reflects what's installed — commands from an extension appear only when it's
loaded (e.g. `/persona` needs ami-persona). `/model`, `/models` and `/persona` mirror
the `:Ami*` commands, so they're available at the whiteboard without leaving the input.

`/compact` is the context-saver: on a long conversation it folds everything so far
into a single summary (preserving decisions, constraints, and open questions). Pass
`keep=N` to leave the **last N turns verbatim** and summarize only what came before
them (e.g. `/compact keep=2`). The reduction applies to the **next** turn; your
transcript scrollback is kept as-is as a readable log. It needs `ami-history.nvim`
(which owns summarization); without it the command simply isn't listed.

To send a message that genuinely starts with a slash, double it: `//what about /tmp`
sends `/what about /tmp`.

### Shell commands

A message that begins with `!` runs the rest as a **shell command** instead of calling
the model — like `:!` or Claude's bash mode. It runs in the background, in your
project root, and its output is echoed into the transcript; nothing is sent to the LLM
and the turn isn't recorded in history.

```
!pwd
!git status -s
!cargo test 2>&1 | tail -20
```

Long-running commands are killed after `shell.timeout_ms`, and very long output is
truncated at `shell.max_output_bytes`. Turn the whole thing off with
`chat.shell.enabled = false` (then `!…` is just sent to the model like any message).

**Extensions can add their own commands** by returning a `{ name = { desc, fn } }`
table from the `chat.commands` collector — see
[`docs/extensions.md`](https://github.com/moosch/ami.nvim/blob/main/docs/extensions.md).
Commands run in-editor; ami-chat doesn't shell out.

## Configuration

Options live under `chat` in ami's `setup()`:

| Key | Default | Meaning |
| --- | --- | --- |
| `endpoint` | `nil` | provider base URL; `nil` ⇒ ami's default `model.endpoint` |
| `model` | `nil` | chat model; `nil` ⇒ ami's default `model.model` (pick via `:AmiModel chat`) |
| `timeout_ms` | `120000` | give up if no token arrives within this long (covers cold model loads) |
| `shell.enabled` | `true` | allow `!cmd` in the input to run a shell command |
| `shell.timeout_ms` | `30000` | kill a `!cmd` that runs longer than this |
| `shell.max_output_bytes` | `100000` | truncate `!cmd` output longer than this |
| `ui.position` | `"right"` | `"right"` \| `"left"` \| `"center"` |
| `ui.width` / `ui.height` | `0.4` / `0.9` | fraction of screen (`<=1`) or absolute cells (`>1`) |
| `ui.opacity` | `0.8` | `0`..`1`; lower = more see-through (via `winblend`) |
| `ui.margin` | `2` | columns of gap from the screen edge |
| `keymaps.send` | `"<CR>"` | send the prompt (normal mode) |
| `keymaps.send_alt` | `"<C-s>"` | send (normal + insert; some terminals eat `<C-s>`) |
| `keymaps.new_session` | `"<C-n>"` | start a new session (normal + insert) |
| `keymaps.stop` | `"<C-c>"` | stop the in-flight reply (normal + insert) |
| `keymaps.close` | `{ "q", "<Esc>" }` | hide the panel (normal mode) |
| `keymaps.history_prev` | `"<Up>"` | recall an older sent message (when the cursor is on the input's first line) |
| `keymaps.history_next` | `"<Down>"` | recall a newer one, then restore your draft (when on the last line) |
| `keymaps.toggle` | `nil` | optional global normal-mode map for `:AmiChat` (e.g. `"<leader>ac"`) |

Each `keymaps.*` value is a string, a list of strings, or `false` to disable that
binding. `ui.*`/`keymaps.*` apply to the built-in floating panel; when a `chat_ui`
provider like `ami-chat-split.nvim` is active, that extension's own options apply.
You can also always `vim.keymap.set` the `:AmiChat`/`:AmiAsk`/`:AmiNewSession`
commands yourself.

### Recalling previous messages

The input remembers the messages you've sent this editor session. With the cursor on
the **first** line of the prompt, `<Up>` cycles back through them (newest first); with
the cursor on the **last** line, `<Down>` cycles forward again. Anywhere else in a
multi-line draft the arrows just move the cursor, as usual. Anything you'd already
typed is stashed when you start browsing and restored when you press `<Down>` past the
newest message — so recalling never loses your half-written draft. The list is shared
across sessions for the current Neovim session and isn't persisted to disk.

## Syntax highlighting

The transcript is a markdown buffer highlighted like telescope's previewer — it uses
**whatever's available in your Neovim**:

- **Treesitter** (preferred): started automatically when the `markdown` parser is
  installed. This highlights headers, inline code, and — via markdown injections —
  fenced code blocks **in their own language**. Per-language code highlighting needs
  that language's parser too, e.g. `:TSInstall go lua` (install `markdown` and
  `markdown_inline` for the base).
- **Regex syntax** (fallback): if no treesitter parser is available, it falls back to
  the built-in markdown syntax (headers + inline code; fenced blocks per
  `vim.g.markdown_fenced_languages`).

Either way it's automatic and has no hard dependency — with nothing installed you
still get plain, readable text.

### Role colours

On top of the markdown highlighting, each turn's header is tinted so the conversation
is easy to scan — **You**, **Advisor**, **Shell** and **💡 Suggestion** each get a
distinct accent, with muted/error tints for status lines. The colours are **derived
from your colourscheme** (borrowed from the `Diagnostic*` groups) and refreshed on
`:colorscheme`, so they adapt to light/dark automatically.

Override any of them — set the `AmiChat*` groups (ideally in a `ColorScheme`
autocmd, since they're re-derived on theme change):

```lua
vim.api.nvim_set_hl(0, "AmiChatRoleUser", { fg = "#7aa2f7", bold = true })
vim.api.nvim_set_hl(0, "AmiChatRoleAdvisor", { fg = "#bb9af7", bold = true })
-- also: AmiChatRoleShell, AmiChatRoleSuggestion, AmiChatError, AmiChatMuted
```

## Replacing the panel UI

The chat controller draws nothing itself — it drives whatever `chat_ui` provider is
registered, falling back to the bundled floating panel (`lua/ami-chat/ui.lua`). See
ami's [`docs/extensions.md`](https://github.com/moosch/ami.nvim/blob/main/docs/extensions.md)
for the `chat_ui` contract.

## License

[MIT](LICENSE)
