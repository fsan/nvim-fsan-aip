-- Floating chat UI.
--
-- Two stacked floating windows: a read-only markdown transcript (rendered with
-- tree-sitter, so fenced code blocks are highlighted) and a prompt buffer.
-- Responses stream in live; replies can be yanked or inserted back into the
-- buffer the chat was opened from — fully or just their code blocks.

local config = require("nvim-fsan-aip.config")
local state = require("nvim-fsan-aip.state")
local ollama = require("nvim-fsan-aip.ollama")

local M = {}

-- Persistent across open/close so the conversation survives toggling.
local chat = {
  open = false,
  buf = nil, -- transcript buffer
  win = nil,
  input_buf = nil,
  input_win = nil,
  file_win = nil, -- buffer pane (shows the buffer the chat was opened from)
  origin_buf = nil, -- buffer displayed in the file pane
  augroup = nil,
  pending = "", -- streamed text not yet flushed to the transcript
  flush_timer = nil,
  reply_start = 1, -- transcript line where the current reply starts
}

local function cfg()
  return config.cfg
end

local function valid_win(w)
  return w and vim.api.nvim_win_is_valid(w)
end

local function valid_buf(b)
  return b and vim.api.nvim_buf_is_valid(b)
end

-- Buffer/writing helpers ------------------------------------------------------

local function append_lines(lines)
  if not valid_buf(chat.buf) or #lines == 0 then
    return
  end
  vim.bo[chat.buf].modifiable = true
  vim.api.nvim_buf_set_lines(chat.buf, -1, -1, false, lines)
  vim.bo[chat.buf].modifiable = false
  M.scroll_to_bottom()
end

function M.scroll_to_bottom()
  if not valid_win(chat.win) then
    return
  end
  local count = vim.api.nvim_buf_line_count(chat.buf)
  if vim.api.nvim_get_current_win() == chat.win then
    local row = vim.api.nvim_win_get_cursor(chat.win)[1]
    if row < count - 1 then
      return -- the reader scrolled up; don't fight them
    end
  end
  pcall(vim.api.nvim_win_set_cursor, chat.win, { count, 0 })
end

-- Streamed text may split mid-line: only flush up to the last newline and keep
-- the remainder buffered until it is complete (or the reply is done).
function M.flush_pending()
  local text = chat.pending
  if text == "" then
    return
  end
  local lines = vim.split(text, "\n", { plain = true })
  local partial = table.remove(lines)
  if #lines > 0 then
    append_lines(lines)
  end
  chat.pending = partial
end

local function flush_timer_start()
  if chat.flush_timer then
    return
  end
  local timer = vim.uv.new_timer()
  chat.flush_timer = timer
  timer:start(40, 0, function()
    vim.schedule(function()
      if chat.flush_timer == timer then
        chat.flush_timer = nil
      end
      timer:close()
      M.flush_pending()
    end)
  end)
end

local function transcript_text(from)
  if not valid_buf(chat.buf) then
    return ""
  end
  from = math.max(1, from or 1)
  local lines = vim.api.nvim_buf_get_lines(chat.buf, from - 1, -1, false)
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    lines[#lines] = nil
  end
  return table.concat(lines, "\n")
end

-- Buffer-pane helpers ------------------------------------------------------------------

-- Only plain file buffers make sense in the buffer pane (no terminals,
-- quickfix, help, ... — those fall back to a 2-pane layout).
local function file_pane_ok(buf)
  if not valid_buf(buf) then
    return false
  end
  local bt = vim.bo[buf].buftype
  return (bt == "" or bt == "acwrite") and vim.bo[buf].buflisted
end

local function file_pane_title(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  return (name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]") .. " — your code"
end

-- Layout ----------------------------------------------------------------------

local function layout()
  local w = cfg().window
  local columns, screen_rows = vim.o.columns, vim.o.lines
  local width = w.width <= 1 and math.floor(columns * w.width) or w.width
  local height = w.height <= 1 and math.floor(screen_rows * w.height) or w.height
  width = math.min(width, columns - 4)
  height = math.min(height, screen_rows - 4)
  local L = {
    width = width,
    height = height,
    row = math.floor((screen_rows - height) / 2),
    col = math.floor((columns - width) / 2),
  }
  if w.layout == "columns" and (w.ratios.file or 0) > 0 and file_pane_ok(chat.origin_buf) then
    -- buffer pane left, chat area (transcript over prompt) right
    local content = width - 5 -- 2 borders + 1 gap between the two columns
    L.mode = "columns"
    L.file_w = math.max(8, math.floor(content * (w.ratios.file or 0.38)))
    L.chat_w = math.max(20, content - L.file_w)
  elseif w.layout == "columns" then
    -- no buffer pane: chat area at full width
    L.mode = "columns"
    L.file_w = 0
    L.chat_w = math.max(20, width - 2)
  else
    local input_h = w.input_height + 2 -- + border
    L.mode = "stacked"
    L.transcript_h = math.max(3, height - input_h - 1) -- 1 row gap
    L.input_lines = w.input_height
  end
  return L
end

-- Ordered pane specs ({kind, width, height, row, col, title}) for the current
-- layout — shared by open_windows() and resize().
local function pane_geometry()
  local L = layout()
  local specs = {}
  local function add(kind, width, height, row, col, title)
    specs[#specs + 1] = { kind = kind, width = width, height = height, row = row, col = col, title = title }
  end
  if L.mode == "columns" then
    local x = L.col
    if L.file_w > 0 then
      add("file", L.file_w, L.height - 2, L.row, x, " " .. file_pane_title(chat.origin_buf) .. " ")
      x = x + L.file_w + 3 -- border (2) + gap (1)
    end
    -- the chat area is split vertically: transcript on top, prompt below
    local chat_h = L.height - 5 -- 2 borders per window + 1 row gap
    local t_h = math.max(3, math.floor(chat_h * (cfg().window.transcript_ratio or 0.70)))
    local p_h = math.max(1, chat_h - t_h)
    add("chat", L.chat_w, t_h, L.row, x, " AIP Chat ")
    add("prompt", L.chat_w, p_h, L.row + t_h + 3, x, " Prompt ")
  else
    add("chat", L.width, L.transcript_h, L.row, L.col, " AIP Chat ")
    add("prompt", L.width, L.input_lines, L.row + L.transcript_h + 2 + 1, L.col, " Prompt ")
  end
  return specs
end

-- Buffers & keymaps ------------------------------------------------------------

local function make_buffer(name, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = ft or ""
  pcall(vim.api.nvim_buf_set_name, buf, name)
  return buf
end

local function map(mode, buf, lhs, rhs, desc)
  if lhs == "" or not lhs then
    return
  end
  vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = "AIP: " .. desc })
end

local function set_keymaps()
  local K = cfg().keys
  local b, ib = chat.buf, chat.input_buf

  -- Transcript (normal mode)
  map("n", b, K.close, M.close, "close chat")
  map("n", b, K.focus_input, M.focus_input, "jump to prompt")
  map("n", b, K.stop, M.stop, "stop generation")
  map("n", b, K.yank_reply, M.yank_last_reply, "yank last reply")
  map("n", b, K.copy_reply, M.copy_last_reply, "insert last reply into file")
  map("n", b, K.copy_code, M.copy_code_blocks, "insert code blocks from last reply")
  map("n", b, K.select_model, M.select_model, "change model")
  map("n", b, K.new_chat, M.new_chat, "new conversation")
  -- Transcript (visual mode): insert the selected lines into the file
  map("x", b, K.copy_reply, M.copy_selection, "insert selection into file")

  -- Prompt (insert + normal mode)
  map("i", ib, K.send, M.send, "send prompt")
  map("n", ib, K.send, M.send, "send prompt")
  map("i", ib, K.stop, M.stop, "stop generation")
  map("n", ib, K.stop, M.stop, "stop generation")
  map("n", ib, K.close, M.close, "close chat")
  map("i", ib, K.new_line, M.insert_newline, "new line in prompt")
  map("i", ib, K.focus_transcript, M.focus_transcript, "view transcript")
  map("i", ib, K.focus_buffer, M.focus_file_pane, "edit the buffer pane")
end

function M.update_winbars()
  if not valid_win(chat.win) then
    return
  end
  local c = cfg()
  local status = state.streaming and " · ⋯ generating" or ""
  vim.wo[chat.win].winbar = ("󰚩 AIP · %s%s %%= i input · y yank · c copy · e code · m model · n new · q close")
    :format(c.model, status)
  if valid_win(chat.input_win) then
    vim.wo[chat.input_win].winbar = "» Prompt %= ⏎ send · ⌃J newline · ⌃T transcript · ⌃B buffer · ⌃C stop"
  end
end

-- Rendering ---------------------------------------------------------------------

function M.render_welcome()
  local c = cfg()
  local K = c.keys
  append_lines({
    "# 󰚩 AIP Chat",
    "",
    ("**Model:** `%s` · **Host:** `%s`"):format(c.model, c.host),
    "",
    "Ask a question in the prompt below and press `<CR>` to send.",
    "",
    "| Key | Action |",
    "| --- | --- |",
    ("| `%s` | jump to the prompt (`%s` inserts a new line) |"):format(K.focus_input, K.new_line),
    ("| `%s` | yank the last reply to register `%s` |"):format(K.yank_reply, c.yank_register),
    ("| `%s` | insert the last reply into your file (visual `%s`: insert only the selection) |"):format(K.copy_reply, K.copy_reply),
    ("| `%s` | insert only the fenced code blocks from the last reply |"):format(K.copy_code),
    ("| `%s` / `%s` | change model / new conversation |"):format(K.select_model, K.new_chat),
    ("| `%s` / `%s` | stop generating / close the chat |"):format(K.stop, K.close),
    "",
    "Add code context with `<leader>ac` — long selections become a compact",
    "`[[Pasted text #N]]` placeholder, expanded to the full code on send.",
    "",
    "With the 3-pane layout your code shows in the left pane — edit it freely",
    ("while chatting; `c`/`e` insert below its cursor, and `%s` jumps to it."):format(K.focus_buffer),
    "",
  })
end

-- Prompt helpers --------------------------------------------------------------

function M.get_prompt_text()
  if not valid_buf(chat.input_buf) then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(chat.input_buf, 0, -1, false)
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    lines[#lines] = nil
  end
  while #lines > 0 and lines[1]:match("^%s*$") do
    table.remove(lines, 1)
  end
  return table.concat(lines, "\n")
end

local function set_prompt_lines(lines)
  if not valid_buf(chat.input_buf) then
    return
  end
  vim.api.nvim_buf_set_lines(chat.input_buf, 0, -1, false, lines)
  if valid_win(chat.input_win) then
    pcall(vim.api.nvim_win_set_cursor, chat.input_win, { math.max(1, #lines), 0 })
  end
end

-- Insert lines at the prompt cursor, keeping whatever is already typed
-- there (the insertion lands after the cursor's line; the cursor moves to
-- the end of the inserted text).
local function insert_prompt_lines(lines)
  if not valid_buf(chat.input_buf) or not lines or #lines == 0 then
    return
  end
  local count = vim.api.nvim_buf_line_count(chat.input_buf)
  local empty = count == 1
    and (vim.api.nvim_buf_get_lines(chat.input_buf, 0, 1, false)[1] or ""):match("^%s*$") ~= nil
  local row = 1
  if valid_win(chat.input_win) then
    row = vim.api.nvim_win_get_cursor(chat.input_win)[1]
  end
  local at = empty and 0 or row
  vim.api.nvim_buf_set_lines(chat.input_buf, at, at, false, lines)
  if valid_win(chat.input_win) then
    pcall(vim.api.nvim_win_set_cursor, chat.input_win, { at + #lines, 0 })
  end
end

local function ensure_insert()
  if #vim.api.nvim_list_uis() > 0 then
    vim.schedule(function()
      pcall(vim.cmd, "startinsert")
    end)
  end
end

function M.insert_newline()
  if not valid_win(chat.input_win) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(chat.input_win)[1]
  vim.api.nvim_buf_set_lines(chat.input_buf, row, row, false, { "" })
  pcall(vim.api.nvim_win_set_cursor, chat.input_win, { row + 1, 0 })
end

function M.focus_input()
  if not valid_win(chat.input_win) then
    return
  end
  vim.api.nvim_set_current_win(chat.input_win)
  local count = vim.api.nvim_buf_line_count(chat.input_buf)
  local last = vim.api.nvim_buf_get_lines(chat.input_buf, -2, -1, false)
  last = last[1] or ""
  pcall(vim.api.nvim_win_set_cursor, chat.input_win, { count, #last })
  if #vim.api.nvim_list_uis() > 0 then
    vim.schedule(function()
      pcall(vim.cmd, "startinsert")
    end)
  end
end

function M.focus_transcript()
  if not valid_win(chat.win) then
    return
  end
  vim.api.nvim_set_current_win(chat.win)
  pcall(vim.cmd, "stopinsert")
  M.scroll_to_bottom()
end

-- Jump to the buffer pane (your code, fully editable).
function M.focus_file_pane()
  if not valid_win(chat.file_win) then
    vim.notify("AIP: no buffer pane open", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_set_current_win(chat.file_win)
  pcall(vim.cmd, "stopinsert")
end

-- Open / close / toggle -----------------------------------------------------------

function M.is_open()
  return chat.open and valid_win(chat.win) and valid_win(chat.input_win)
end

-- Accessors (mostly for tests / statusline integration).
function M.wins()
  return {
    buf = chat.buf,
    win = chat.win,
    input_buf = chat.input_buf,
    input_win = chat.input_win,
    file_win = chat.file_win,
    origin_buf = chat.origin_buf,
  }
end

local function open_windows()
  local buffers = { chat = chat.buf, prompt = chat.input_buf, file = chat.origin_buf }
  for _, spec in ipairs(pane_geometry()) do
    local win = vim.api.nvim_open_win(buffers[spec.kind], spec.kind == "prompt", {
      relative = "editor",
      width = spec.width,
      height = spec.height,
      row = spec.row,
      col = spec.col,
      border = cfg().window.border,
      style = "minimal",
      zindex = 40,
      title = spec.title,
      title_pos = "center",
    })
    if spec.kind == "chat" then
      chat.win = win
    elseif spec.kind == "prompt" then
      chat.input_win = win
    else
      chat.file_win = win
    end

    -- Window options common to all panes
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].winblend = cfg().window.winblend
    vim.wo[win].spell = false
    vim.wo[win].scrolloff = 0
    vim.wo[win].foldenable = false
    if spec.kind == "file" then
      -- The buffer pane is a real window into the user's buffer: keep it
      -- editable, mirror the origin cursor, show line numbers.
      vim.wo[win].number = true
      vim.wo[win].relativenumber = false
      vim.wo[win].signcolumn = "yes"
      vim.wo[win].cursorline = true
      if valid_win(state.origin_win) and vim.api.nvim_win_get_buf(state.origin_win) == chat.origin_buf then
        pcall(vim.api.nvim_win_set_cursor, win, vim.api.nvim_win_get_cursor(state.origin_win))
      end
    end
  end

  M.update_winbars()
end

function M.open(opts)
  opts = opts or {}
  if M.is_open() then
    if opts.focus ~= false then
      M.focus_input()
    end
    return
  end
  if vim.fn.executable("curl") ~= 1 then
    vim.notify("AIP: `curl` is required but was not found on PATH", vim.log.levels.ERROR)
    return
  end

  state.origin_win = vim.api.nvim_get_current_win()
  chat.origin_buf = vim.api.nvim_win_get_buf(state.origin_win)

  if not valid_buf(chat.buf) then
    chat.buf = make_buffer("nvim-fsan-aip://transcript", "markdown")
    chat.input_buf = make_buffer("nvim-fsan-aip://input", "")
    vim.bo[chat.buf].modifiable = false
    vim.bo[chat.buf].undolevels = -1
    vim.bo[chat.input_buf].formatoptions = ""
    vim.bo[chat.input_buf].textwidth = 0
    -- indent guides make no sense in the chat
    pcall(function()
      local ibl = require("ibl")
      ibl.setup_buffer(chat.buf, { enabled = false })
      ibl.setup_buffer(chat.input_buf, { enabled = false })
    end)
  end
  set_keymaps()

  open_windows()
  chat.open = true

  if #state.history == 0 and vim.api.nvim_buf_line_count(chat.buf) < 2 then
    M.render_welcome()
  end

  chat.augroup = vim.api.nvim_create_augroup("AipWin", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = chat.augroup,
    callback = M.resize,
  })

  if opts.focus ~= false then
    M.focus_input()
  end
end

function M.close()
  if not chat.open then
    return
  end
  chat.open = false
  -- Carry the buffer-pane cursor back to the origin window (same buffer only).
  if valid_win(chat.file_win) and valid_win(state.origin_win)
    and vim.api.nvim_win_get_buf(chat.file_win) == vim.api.nvim_win_get_buf(state.origin_win) then
    pcall(vim.api.nvim_win_set_cursor, state.origin_win, vim.api.nvim_win_get_cursor(chat.file_win))
  end
  for _, w in ipairs({ chat.win, chat.input_win, chat.file_win }) do
    if valid_win(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  chat.win, chat.input_win, chat.file_win = nil, nil, nil
  if chat.augroup then
    pcall(vim.api.nvim_del_augroup_by_name, "AipWin")
    chat.augroup = nil
  end
  if valid_win(state.origin_win) then
    pcall(vim.api.nvim_set_current_win, state.origin_win)
  end
  -- Note: a running generation keeps streaming into the (now hidden)
  -- transcript buffer; it will be visible on the next open().
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.resize()
  if not M.is_open() then
    return
  end
  local wins = { chat = chat.win, prompt = chat.input_win, file = chat.file_win }
  for _, spec in ipairs(pane_geometry()) do
    local win = wins[spec.kind]
    if valid_win(win) then
      vim.api.nvim_win_set_config(win, {
        relative = "editor",
        width = spec.width,
        height = spec.height,
        row = spec.row,
        col = spec.col,
      })
    end
  end
end

-- Streaming ---------------------------------------------------------------------

local function build_messages()
  local c = cfg()
  local msgs = {}
  if c.system_prompt ~= "" then
    msgs[#msgs + 1] = { role = "system", content = c.system_prompt }
  end
  local h = state.history
  local from = 1
  if c.history_limit and #h > c.history_limit then
    from = #h - c.history_limit + 1
  end
  for i = from, #h do
    msgs[#msgs + 1] = h[i]
  end
  return msgs
end

function M.send()
  if state.streaming then
    vim.notify(("AIP: still generating — press %s to stop first"):format(cfg().keys.stop),
      vim.log.levels.WARN)
    return
  end
  local raw = M.get_prompt_text()
  if raw == "" then
    return
  end
  if vim.fn.executable("curl") ~= 1 then
    vim.notify("AIP: `curl` is required but was not found on PATH", vim.log.levels.ERROR)
    return
  end

  local model = cfg().model
  -- Expand "[[Pasted text #N]]" tokens for the model; the transcript keeps
  -- the compact placeholders.
  local text = M.substitute_pastes(raw)
  table.insert(state.history, { role = "user", content = text })

  local out = { "", "## You", "" }
  vim.list_extend(out, vim.split(raw, "\n", { plain = true }))
  vim.list_extend(out, { "", ("## %s"):format(model), "" })
  append_lines(out)
  chat.reply_start = vim.api.nvim_buf_line_count(chat.buf) + 1
  set_prompt_lines({})

  state.streaming = true
  M.update_winbars()

  local c = cfg()
  chat.pending = ""
  state.handle = ollama.chat({
    host = c.host,
    api_key = c.api_key,
    model = model,
    messages = build_messages(),
    options = c.options,
  }, {
    on_token = function(tok)
      chat.pending = chat.pending .. tok
      flush_timer_start()
    end,
    on_done = function(full, stats)
      vim.schedule(function()
        M.stream_done(full, stats)
      end)
    end,
    on_error = function(err)
      vim.schedule(function()
        M.stream_error(err)
      end)
    end,
  })
end

local function finalize_reply(reply, stats)
  if chat.pending ~= "" then
    append_lines(vim.split(chat.pending, "\n", { plain = true }))
    chat.pending = ""
  end
  if reply and reply ~= "" then
    state.last_response = reply
    table.insert(state.history, { role = "assistant", content = reply })
  end
  if stats and stats.eval_count then
    local secs = stats.total_duration and (stats.total_duration / 1e9) or 0
    append_lines({ "", ("*(%d tokens · %.1fs)*"):format(stats.eval_count, secs) })
  end
  state.streaming = false
  state.handle = nil
  M.update_winbars()
end

function M.stream_done(full, stats)
  if not state.streaming then
    return
  end
  finalize_reply(full, stats)
end

function M.stream_error(err)
  if not state.streaming then
    return
  end
  finalize_reply(nil, nil)
  append_lines({ "", ("> ⚠ **%s**"):format(err:gsub("[%*`|]", "`")), "" })
  vim.notify("AIP: " .. err, vim.log.levels.ERROR)
  M.scroll_to_bottom()
end

function M.stop()
  if not state.streaming or not state.handle then
    return
  end
  state.handle.stop()
  state.handle = nil
  -- flush whatever was still being streamed
  M.flush_pending()
  if chat.pending ~= "" then
    append_lines(vim.split(chat.pending, "\n", { plain = true }))
    chat.pending = ""
  end
  local partial = transcript_text(chat.reply_start)
  if partial ~= "" then
    state.last_response = partial
    table.insert(state.history, { role = "assistant", content = partial })
  end
  state.streaming = false
  append_lines({ "", "*⋯ stopped*" })
  M.update_winbars()
  vim.notify("AIP: stopped")
end

function M.new_chat()
  M.stop()
  state.reset()
  if valid_buf(chat.buf) then
    vim.bo[chat.buf].modifiable = true
    vim.api.nvim_buf_set_lines(chat.buf, 0, -1, false, {})
    vim.bo[chat.buf].modifiable = false
  end
  set_prompt_lines({})
  M.render_welcome()
  M.focus_input()
end

-- Copy-back into the edited file ----------------------------------------------

-- Insert `text` below the cursor of the window the chat was opened from
-- (falls back to the current window if that window is gone).
local function insert_into_origin(text)
  -- Prefer the visible buffer pane (that's where the user is looking);
  -- fall back to the hidden origin window, then to the current window.
  local win = valid_win(chat.file_win) and chat.file_win
    or (valid_win(state.origin_win) and state.origin_win or vim.api.nvim_get_current_win())
  local buf = vim.api.nvim_win_get_buf(win)
  local row = vim.api.nvim_win_get_cursor(win)[1] -- 1-based
  local lines = vim.split(text, "\n", { plain = true })
  local ok = pcall(vim.api.nvim_buf_set_lines, buf, row, row, false, lines)
  if not ok then
    vim.notify("AIP: cannot insert (target buffer is not modifiable)", vim.log.levels.ERROR)
    return
  end
  pcall(vim.api.nvim_win_set_cursor, win, { row + 1, 0 })
  local name = vim.api.nvim_buf_get_name(buf)
  local label = name ~= "" and vim.fn.fnamemodify(name, ":t") or ("buffer %d"):format(buf)
  vim.notify(("AIP: inserted %d line%s into %s")
    :format(#lines, #lines == 1 and "" or "s", label))
end

function M.yank_last_reply()
  if state.last_response == "" then
    vim.notify("AIP: no reply to yank yet", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg(cfg().yank_register, state.last_response, "l")
  vim.notify(("AIP: last reply → register %s"):format(cfg().yank_register))
end

function M.copy_last_reply()
  if state.last_response == "" then
    vim.notify("AIP: no reply to copy yet", vim.log.levels.WARN)
    return
  end
  insert_into_origin(state.last_response)
end

function M.copy_code_blocks()
  local text = state.last_response
  if text == "" then
    vim.notify("AIP: no reply to copy yet", vim.log.levels.WARN)
    return
  end
  local skip = { text = true, txt = true, output = true, console = true, log = true, plaintext = true }
  local blocks = {}
  for lang, body in text:gmatch("```([%w_%-]*)[^\n]*\n(.-)```") do
    if not skip[lang:lower()] then
      blocks[#blocks + 1] = body:gsub("%s+$", "")
    end
  end
  if #blocks == 0 then
    vim.notify("AIP: no fenced code blocks in the last reply", vim.log.levels.WARN)
    return
  end
  insert_into_origin(table.concat(blocks, "\n\n"))
end

-- Insert the visual selection of the transcript into the file.
function M.copy_selection()
  if not valid_buf(chat.buf) then
    return
  end
  local a = vim.api.nvim_buf_get_mark(chat.buf, "<")
  local b = vim.api.nvim_buf_get_mark(chat.buf, ">")
  if not a or not b or a[1] < 1 or b[1] < a[1] then
    vim.notify("AIP: nothing selected", vim.log.levels.WARN)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(chat.buf, a[1] - 1, b[1], false)
  insert_into_origin(table.concat(lines, "\n"))
end

-- Model -------------------------------------------------------------------------

function M.set_model(name)
  cfg().model = name
  state.save_model(name)
  M.update_winbars()
  vim.notify("AIP: model → " .. name)
end

function M.select_model()
  local c = cfg()
  ollama.tags(c.host, c.api_key, function(names, err)
    if err then
      vim.notify("AIP: " .. err, vim.log.levels.ERROR)
      return
    end
    if #names == 0 then
      vim.notify(("AIP: no models installed — try `ollama pull %s`"):format(c.model),
        vim.log.levels.WARN)
      return
    end
    pcall(vim.ui.select, names, {
      prompt = "Ollama model:",
      kind = "nvim-fsan-aip.model",
    }, function(choice)
      if choice then
        M.set_model(choice)
      end
    end)
  end)
end

function M.status()
  local c = cfg()
  ollama.tags(c.host, c.api_key, function(names, err)
    if err then
      vim.notify("AIP: ✗ " .. err, vim.log.levels.ERROR)
      return
    end
    local has_current = false
    for _, n in ipairs(names) do
      if n == c.model then
        has_current = true
      end
    end
    vim.notify(("AIP: ● host %s · model %s · %d models installed%s")
      :format(c.host, c.model, #names, has_current and "" or " (current model not pulled — `ollama pull` it)"))
  end)
end

-- Entry points --------------------------------------------------------------------

-- Build the prompt text for a buffer range: an inline fenced block for short
-- selections, a compact "[[Pasted text #N]]" placeholder for long ones.
-- Returns nil for an empty range. Call this while the buffer is still current
-- (i.e. before opening the chat).
function M.context_snippet(buf, line1, line2)
  if not valid_buf(buf) or not line1 or not line2 or line2 < 1 or line2 < line1 then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
  if #lines == 0 then
    return nil
  end
  local ft = vim.bo[buf].filetype
  local name = vim.api.nvim_buf_get_name(buf)
  name = name ~= "" and vim.fn.fnamemodify(name, ":t") or ("buffer %d"):format(buf)

  local c = cfg()
  if c.paste_threshold == false or #lines <= c.paste_threshold then
    local block = { ("```%s — %s"):format(ft, name) }
    vim.list_extend(block, lines)
    table.insert(block, "```")
    return table.concat(block, "\n")
  end
  return state.add_paste(lines, ft, name)
end

-- Expand "[[Pasted text #N]]" tokens into their stored fenced content.
-- Unknown tokens are left as literal text.
function M.substitute_pastes(text)
  return (text:gsub("%[%[Pasted text #(%d+)%]%]", function(id)
    local p = state.pastes[tonumber(id)]
    if not p then
      return nil
    end
    local block = { ("```%s — %s"):format(p.ft, p.name) }
    vim.list_extend(block, p.lines)
    table.insert(block, "```")
    return table.concat(block, "\n")
  end))
end

-- Open the chat with a code selection as context (visual selection,
-- `:'<,'>AipChat` or <leader>ac). The context is ADDED at the prompt cursor —
-- existing prompt text is never erased — and the cursor lands right after it.
function M.open_with_context(line1, line2)
  local buf = vim.api.nvim_get_current_buf()
  local snippet = M.context_snippet(buf, line1, line2)
  if not snippet then
    M.open()
    return
  end
  local block = vim.split(snippet, "\n", { plain = true })
  table.insert(block, "")
  table.insert(block, "")

  local was_open = M.is_open()
  M.open({ focus = not was_open }) -- keep the prompt cursor if already open
  insert_prompt_lines(block) -- add at the cursor; never erase the draft
  ensure_insert()
end

function M.chat_about_selection()
  local a, b
  if vim.fn.mode():match("^[vV\22]") then
    -- still in visual mode (mapping context): line("v")/line(".") are reliable
    local v, dot = vim.fn.line("v"), vim.fn.line(".")
    a, b = { math.min(v, dot) }, { math.max(v, dot) }
  else
    a = vim.api.nvim_buf_get_mark(0, "<")
    b = vim.api.nvim_buf_get_mark(0, ">")
  end
  if a and b and a[1] >= 1 and b[1] >= a[1] then
    M.open_with_context(a[1], b[1])
  else
    M.open()
  end
end

-- Open the chat and immediately send `text` as the prompt. The text is
-- appended after anything already typed in the prompt (never erased).
function M.open_and_send(text)
  M.open()
  local lines = vim.split(text, "\n", { plain = true })
  table.insert(lines, "")
  insert_prompt_lines(lines)
  M.send()
end

return M