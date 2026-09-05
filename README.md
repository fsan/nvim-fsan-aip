# 󰚩 nvim-fsan-aip

![Demo](demo.gif)

**AIP** (AI Pane) — a floating programming chat assistant for Neovim, backed by
a [local Ollama](https://ollama.com) server. Toggle it anywhere, ask questions,
stream answers into a markdown-rendered transcript, then insert full replies —
or just their code blocks — back into the buffer you were editing.

```
┌─ main.py — your code ──┬──── AIP Chat ───────────────┐
│ def process(items):    │ ## You                      │
│     out = []           │                             │
│     for i in items:    │ ## qwen2.5-coder:7b         │
│         out.append(-i) │ ```python                   │
│     return out        │ items[::-1]                  │
│     # edits work here │ ```                         │
│                       ├──── Prompt ──────────────────┤
│                       │ ask anything…               │
│                       │ <CR> send · <C-b> your code  │
└───────────────────────┴─────────────────────────────┘
```

All panes are floating, so your window layout is untouched while the chat is
closed: **your buffer** on the left (fully editable — a real window into the
file you were editing), and on the right the **conversation** above the
**prompt** (70% / 30% of the height by default). `c`/`e` insert replies below
the buffer pane's cursor, and its cursor is carried back to your window when
you close the chat.

## Requirements

- Neovim **≥ 0.10** (`vim.system`)
- `curl` on your `PATH` (async HTTP + streaming — no other dependencies)
- Ollama running locally: `ollama serve` + a pulled model,
  e.g. `ollama pull qwen2.5-coder:7b`

## Installation (lazy.nvim)

```lua
{
  "fsan/nvim-fsan-aip",
  opts = {},
}
```

`opts` is merged over the defaults (below). Any option you don't set falls back
to the default.

## Usage

| Command | Action |
| --- | --- |
| `:AipChat` | toggle the chat pane |
| `:AipChat explain this` | open + immediately send the text as prompt |
| `:'<,'>AipChat explain this` | same, with the selection as extra context |
| `:'<,'>AipChat` | open with the selection as context in the prompt |
| `:AipModel [name]` | pick installed model from a list (or set one directly) |
| `:AipNew` | new conversation |
| `:AipStop` | abort the running generation |
| `:AipStatus` | show host, model and reachable-model count |

Inside the chat (transcript window):

| Key | Action |
| --- | --- |
| `i` | jump to the prompt (`<C-t>` returns to the transcript) |
| `y` | yank the last reply to the configured register |
| `c` | insert the last reply below the cursor in your file |
| `c` (visual) | insert only the selected lines of the transcript |
| `e` | insert only the fenced code blocks from the last reply |
| `m` / `n` | change model / new conversation |
| `<C-c>` / `q` | stop generating / close |

Prompt pane: `<CR>` sends, `<C-j>` inserts a newline (multi-line prompts),
`<C-t>` shows the transcript, `<C-b>` jumps to the buffer pane (your code,
edits work), `<C-c>` stops generating. `<C-w>w` cycles between all panes.

Prefer a full-width conversation with a short prompt and no buffer pane? Set
`window.layout = "stacked"`.

The model chosen at runtime is remembered between sessions
(`stdpath("data") .. "/aip-model"`), unless `save_model = false`.

## Code context & paste placeholders

Use `:'<,'>AipChat` or `<leader>ac` (if you mapped it, see below) to attach a
selection. Short selections (up to `paste_threshold` lines) are pasted inline
into the prompt as a fenced block with language and filename. Longer ones are
stored out of the way and referenced by a compact placeholder:

```
Review this function: [[Pasted text #1]]
```

When the message is **sent**, the placeholder is substituted with the full
fenced code block — the transcript stays readable while the model receives the
complete snippet (Claude Code style). `paste_threshold = false` disables
placeholders (always inline).

### Suggested keymaps

```lua
vim.keymap.set("n", "<leader>aa", function() require("nvim-fsan-aip.ui").toggle() end,
  { desc = "AIP: toggle chat" })
vim.keymap.set("x", "<leader>ac", function() require("nvim-fsan-aip.ui").chat_about_selection() end,
  { desc = "AIP: ask about selection" })
```

## Options

```lua
{
  host = "http://127.0.0.1:11434",  -- Ollama endpoint (https works too)
  model = "qwen2.5-coder:7b",       -- default model
  api_key = nil,                    -- optional bearer token (remote endpoints)
  system_prompt = "...",            -- sent with every conversation
  options = {},                     -- Ollama generation options
                                    --   e.g. { temperature = 0.2, num_ctx = 8192 }
  history_limit = 40,               -- max messages replayed as context
  paste_threshold = 5,              -- lines until selections become [[Pasted text #N]]
  yank_register = "+",              -- register for the in-chat `y` action
  save_model = true,                -- remember the runtime-picked model
  window = {
    layout = "columns",            -- "columns": buffer pane left, chat area
                                    -- (transcript over prompt) right;
                                    -- "stacked": full-width chat area only
    ratios = { file = 0.38, chat = 0.62 },
                                    -- horizontal split ("columns";
                                    -- file = 0 hides the buffer pane)
    transcript_ratio = 0.70,        -- vertical split of the chat area:
                                    -- transcript share (prompt gets the rest)
    width = 0.85,                   -- ≤ 1 → fraction of the screen
    height = 0.8,
    input_height = 3,               -- prompt lines ("stacked" layout)
    border = "rounded",
    winblend = 0,
  },
  keys = {                          -- keymaps inside the chat buffers
    close = "q",
    focus_input = "i",
    focus_transcript = "<C-t>",
    focus_buffer = "<C-b>",
    send = "<CR>",
    new_line = "<C-j>",
    stop = "<C-c>",
    yank_reply = "y",
    copy_reply = "c",
    copy_code = "e",
    select_model = "m",
    new_chat = "n",
  },
}
```

## How it works

Requests go through `curl` driven by `vim.system` with a streaming
`stdout` callback — nothing blocks the editor while the model answers. The
transcript is a markdown buffer (fenced code blocks highlight via tree-sitter
when a markdown parser is installed); replies stream in with token coalescing
(~25 appends/s max). Copy-back always inserts below the cursor of the window
the chat was opened from, falling back to the current window.
