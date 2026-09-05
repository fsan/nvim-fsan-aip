-- Async Ollama HTTP client.
--
-- Talks to the Ollama REST API through `curl` driven by vim.system(), so
-- requests never block the editor. The chat request uses stream=true and
-- parses the newline-delimited JSON chunks as they arrive.
--
-- All callbacks are invoked from libuv context: callers must vim.schedule()
-- anything that touches Neovim state.

local M = {}

local function auth_args(api_key)
  if not api_key then
    return {}
  end
  return { "-H", ("Authorization: Bearer %s"):format(api_key) }
end

-- GET /api/tags → cb(names, err): installed model names, sorted.
function M.tags(host, api_key, cb)
  local cmd = { "curl", "-s", "--max-time", "5" }
  vim.list_extend(cmd, auth_args(api_key))
  table.insert(cmd, ("%s/api/tags"):format(host))

  vim.system(cmd, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        local why = (obj.stderr or ""):match("%S.*")
        cb(nil, ("cannot reach Ollama at %s (%s) — is `ollama serve` running?")
          :format(host, (why or ("curl exited %d"):format(obj.code))))
        return
      end
      local ok, data = pcall(vim.json.decode, obj.stdout or "")
      if not ok or type(data) ~= "table" or type(data.models) ~= "table" then
        cb(nil, ("unexpected response from %s/api/tags"):format(host))
        return
      end
      local names = {}
      for _, m in ipairs(data.models) do
        names[#names + 1] = m.name
      end
      table.sort(names)
      cb(names, nil)
    end)
  end)
end

-- POST /api/chat (streaming).
--
-- req: { host, api_key, model, messages, options }
-- handlers: { on_token(text), on_done(full_text, stats), on_error(message) }
--
-- Returns a handle with :stop() to abort generation.
function M.chat(req, handlers)
  local payload = {
    model = req.model,
    messages = req.messages,
    stream = true,
  }
  if type(req.options) == "table" and next(req.options) ~= nil then
    payload.options = req.options
  end
  local body = vim.json.encode(payload)

  local cmd = { "curl", "-sN", "-X", "POST", "-H", "Content-Type: application/json" }
  vim.list_extend(cmd, auth_args(req.api_key))
  vim.list_extend(cmd, { "--data-binary", body, ("%s/api/chat"):format(req.host) })

  local acc = {}
  local finished = false
  local aborted = false
  local stderr_tail = ""

  local function dispatch_line(line)
    if line == "" then
      return
    end
    local ok, data = pcall(vim.json.decode, line)
    if not ok then
      return -- tolerate keep-alive junk / partial writes
    end
    if type(data.error) == "string" then
      finished = true
      handlers.on_error(data.error)
      return
    end
    local content = (data.message or {}).content
    if type(content) == "string" and content ~= "" then
      acc[#acc + 1] = content
      handlers.on_token(content)
    end
    if data.done then
      finished = true
      handlers.on_done(table.concat(acc), data)
    end
  end

  local pending = ""
  local sysobj
  sysobj = vim.system(cmd, {
    text = false,
    stdout = function(err, chunk)
      if err then
        return
      end
      if not chunk then
        -- EOF: dispatch a trailing line that was not \n-terminated
        if pending ~= "" then
          dispatch_line(pending)
          pending = ""
        end
        return
      end
      chunk = chunk:gsub("\r\n", "\n")
      pending = pending .. chunk
      local start = 1
      while true do
        local nl = pending:find("\n", start, true)
        if not nl then
          break
        end
        dispatch_line(pending:sub(start, nl - 1))
        start = nl + 1
      end
      pending = pending:sub(start)
    end,
    stderr = function(err, chunk)
      if not err and chunk then
        stderr_tail = (stderr_tail .. chunk):sub(-400)
      end
    end,
  }, function(obj)
    if finished or aborted then
      return
    end
    local msg
    if obj.code ~= 0 then
      msg = ("curl exited %d: %s"):format(obj.code, stderr_tail ~= "" and stderr_tail or "no error output")
    else
      msg = "Ollama closed the connection before finishing"
    end
    vim.schedule(function()
      if not finished and not aborted then
        finished = true
        handlers.on_error(msg)
      end
    end)
  end)

  return {
    stop = function()
      if not finished then
        aborted = true
        finished = true
        sysobj:kill("sigterm")
      end
    end,
  }
end

return M