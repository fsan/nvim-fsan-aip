-- Configuration: defaults + user option merging.
--
-- User overrides go in lua/plugins/chat.lua (the `opts` table of the spec);
-- anything not overridden falls back to the values below.

local M = {
  cfg = {},
}

M.defaults = {
  -- Ollama server (change for a remote host; https needs a working `curl`).
  host = "http://127.0.0.1:11434",
  -- Default model; overwritten at runtime via <leader>am / :AipModel.
  model = "qwen2.5-coder:7b",
  -- Optional bearer token for proxied/remote Ollama endpoints.
  api_key = nil,
  -- System prompt sent with every conversation.
  system_prompt = "You are a concise programming assistant embedded in a Neovim editor. "
    .. "Prefer short, actionable answers. Give code in fenced code blocks with a "
    .. "language tag, and keep prose outside the blocks to a minimum.",
  -- Ollama generation options passed through as-is
  -- (e.g. { temperature = 0.2, num_ctx = 8192 }).
  options = {},
  -- Max user/assistant messages sent as context (oldest turns are dropped).
  history_limit = 40,
  -- Selections up to this many lines are pasted inline into the prompt;
  -- longer ones become a compact "[[Pasted text #N]]" placeholder that is
  -- substituted with the full fenced block when the message is sent
  -- (Claude Code style). Set to false to always paste inline.
  paste_threshold = 5,
  -- Register used by the in-chat `y` yank action.
  yank_register = "+",
  -- Remember the model chosen at runtime across sessions
  -- (stdpath("data") .. "/aip-model").
  save_model = true,

  window = {
    -- "columns": 3 side-by-side panes — buffer | conversation | prompt.
    -- "stacked": conversation on top, a short prompt at the bottom.
    layout = "columns",
    -- Pane widths for "columns" (fractions of the chat area; the remainder
    -- goes to the conversation). Set file = 0 to hide the buffer pane.
    ratios = { file = 0.38, chat = 0.42, prompt = 0.20 },
    width = 0.85, -- <= 1 → fraction of the screen, otherwise columns
    height = 0.8, -- <= 1 → fraction of the screen, otherwise rows
    input_height = 3, -- prompt content lines ("stacked" layout)
    border = "rounded",
    winblend = 0,
  },

  -- Keymaps inside the chat buffers. Set any to "" to disable.
  keys = {
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

function M.setup(opts)
  opts = opts or {}
  local merged = vim.tbl_deep_extend("force", M.defaults, opts)
  -- Keep the table identity stable (references stay valid across re-setup).
  for k, v in pairs(merged) do
    M.cfg[k] = v
  end
  return M.cfg
end

return M