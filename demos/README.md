# Demo

`chat.tape` is a [VHS](https://github.com/charmbracelet/vhs) script — the source
for `chat.gif` shown in the main README. GitHub doesn't render `.tape`; render it to
a `.gif` and commit the `.gif`.

## Render

```sh
# from this repo's root, with ami core checked out as a sibling:
vhs demos/chat.tape

# or point at your server / pick the chat model:
AMI_ENDPOINT=http://192.168.68.100:1234/v1 AMI_CHAT_MODEL=deepseek-coder vhs demos/chat.tape

git add demos/chat.gif && git commit -m "docs: update demo gif"
```

`demos/init.lua` loads **ami core** (found next to this repo as `../ami.nvim` or
`../ai-harness`, or via `$AMI_CORE`) plus this extension. Requires `vhs`
(`brew install vhs`) and a running LM Studio.

The tape waits on a real streamed reply — lengthen the `Sleep` after the question
for slower models. `gifsicle` (optional) shrinks the result: `gifsicle -O3
--lossy=80 -b demos/chat.gif`.
