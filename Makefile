.PHONY: test

# Headless spec suite (tests/*_spec.lua). Needs only Neovim — no plenary, no LM
# Studio. These specs exercise an ami extension, so they also need ami core on the
# path: tests/run.lua finds it beside this repo (../ami.nvim or ../ai-harness) or via
# AMI_CORE=/path/to/ami.nvim. Exits non-zero on any failure.
test:
	nvim --clean --headless -l tests/run.lua
