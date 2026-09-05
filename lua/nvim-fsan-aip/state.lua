-- Conversation state: message history, origin window, runtime model choice.
--
-- The transcript/prompt buffers hold the rendered text; `history` holds the
-- raw role/content pairs that are replayed to Ollama as context.

local config = require("nvim-fsan-aip.config")

local M = {
  history = {}, -- { { role = "user"|"assistant", content = "..." }, ... }
  last_response = "", -- full text of the last assistant reply
  origin_win = nil, -- window the chat was opened from (copy-back target)
  streaming = false,
  handle = nil, -- streaming job handle ({ stop = fn } or nil)
  pastes = {}, -- payloads behind "[[Pasted text #N]]" prompt placeholders
}

function M.reset()
  M.history = {}
  M.last_response = ""
  M.streaming = false
  M.pastes = {}
  if M.handle then
    M.handle.stop()
    M.handle = nil
  end
end

-- Paste placeholders (Claude Code style) ------------------------------------------
-- Long code snippets are stored out of the prompt buffer and referenced by a
-- compact "[[Pasted text #N]]" token; substitute_pastes() (ui.lua) expands
-- them into fenced blocks when the message is sent.

-- Register `lines` as a paste; returns the placeholder token.
function M.add_paste(lines, ft, name)
  local id = #M.pastes + 1
  M.pastes[id] = { lines = lines, ft = ft or "", name = name or "" }
  return ("[[Pasted text #%d]]"):format(id)
end

-- Model persistence (chosen via <leader>am is remembered between sessions).

function M.model_file()
  return vim.fn.stdpath("data") .. "/aip-model"
end

function M.load_saved_model()
  local f = io.open(M.model_file(), "r")
  if not f then
    return nil
  end
  local name = f:read("*l") or ""
  f:close()
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  return name ~= "" and name or nil
end

function M.save_model(name)
  if not config.cfg.save_model then
    return
  end
  pcall(function()
    local f = io.open(M.model_file(), "w")
    if f then
      f:write(name, "\n")
      f:close()
    end
  end)
end

return M