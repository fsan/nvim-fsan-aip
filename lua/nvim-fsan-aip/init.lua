-- nvim-fsan-aip — a floating programming assistant pane backed by a local
-- Ollama server ("AIP" = AI Pane).
--
--   :AipChat            toggle the chat (also <leader>aa)
--   :'<,'>AipChat [q]   open with the selection as context (also <leader>ac)
--   :AipModel [n]       pick/set the model (no arg → picker, <leader>am)
--   :AipNew             new conversation (<leader>an)
--   :AipStop            stop generating (<leader>as)
--   :AipStatus          host/model/status line
--   :AipEdit [prompt]   Copilot-style inline edit (<leader>ai): the visual
--                       selection (or, with none, the cursor line) is the target;
--                       the reply can be accepted (replaces the selection /
--                       inserts below the cursor) or rejected.
--
-- Configuration: defaults in lua/nvim-fsan-aip/config.lua, overridden via the
-- `opts` of the spec in lua/plugins/chat.lua (host, model, system_prompt,
-- window geometry, in-chat keymaps, ...).

local config = require("nvim-fsan-aip.config")

local M = {}

local commands_defined = false

local function define_commands()
  if commands_defined then
    return
  end
  commands_defined = true

  local ui = function()
    return require("nvim-fsan-aip.ui")
  end

  vim.api.nvim_create_user_command("AipChat", function(o)
    if o.args ~= "" then
      local args = o.args
      if o.range > 0 then
        -- register the range BEFORE opening (while its buffer is still current)
        local snip = ui().context_snippet(vim.api.nvim_get_current_buf(), o.line1, o.line2)
        if snip then
          args = args .. "\n\n" .. snip
        end
      end
      ui().open_and_send(args)
    elseif o.range > 0 then
      ui().open_with_context(o.line1, o.line2)
    else
      ui().toggle()
    end
  end, {
    nargs = "*",
    range = true,
    desc = "AIP: toggle chat (args → prompt, range → selection as context)",
  })

  vim.api.nvim_create_user_command("AipModel", function(o)
    if o.args ~= "" then
      require("nvim-fsan-aip.ui").set_model(o.args)
    else
      require("nvim-fsan-aip.ui").select_model()
    end
  end, { nargs = "?", desc = "AIP: choose model (no arg → picker)" })

  vim.api.nvim_create_user_command("AipNew", function()
    require("nvim-fsan-aip.ui").new_chat()
  end, { desc = "AIP: new conversation" })

  vim.api.nvim_create_user_command("AipStop", function()
    require("nvim-fsan-aip.ui").stop()
  end, { desc = "AIP: stop generating" })

  vim.api.nvim_create_user_command("AipEdit", function(o)
    local ui = require("nvim-fsan-aip.ui")
    if o.range > 0 then
      ui.edit_open(o.line1, o.line2, o.args ~= "" and table.concat(o.args, " ") or nil,
        o.args ~= "")
    else
      ui.edit_open(nil, nil, o.args ~= "" and table.concat(o.args, " ") or nil, o.args ~= "")
    end
  end, {
    nargs = "*",
    range = true,
    desc = "AIP: inline edit — selection → replaced, no range → insert at cursor",
  })

  vim.api.nvim_create_user_command("AipStatus", function()
    require("nvim-fsan-aip.ui").status()
  end, { desc = "AIP: show host/model status" })
end

-- setup(opts) is called by the lazy.nvim spec in lua/plugins/chat.lua.
function M.setup(opts)
  config.setup(opts)

  -- Remember the model chosen at runtime in a previous session, unless the
  -- user explicitly configured one now.
  if not (opts and opts.model) and config.cfg.save_model then
    local saved = require("nvim-fsan-aip.state").load_saved_model()
    if saved then
      config.cfg.model = saved
    end
  end

  define_commands()
  return M
end

-- Convenience passthroughs (also handy for statusline/integration).
M.open = function() return require("nvim-fsan-aip.ui").open() end
M.toggle = function() return require("nvim-fsan-aip.ui").toggle() end
M.close = function() return require("nvim-fsan-aip.ui").close() end
M.new_chat = function() return require("nvim-fsan-aip.ui").new_chat() end
M.select_model = function() return require("nvim-fsan-aip.ui").select_model() end
M.set_model = function(name) return require("nvim-fsan-aip.ui").set_model(name) end
M.stop = function() return require("nvim-fsan-aip.ui").stop() end
M.status = function() return require("nvim-fsan-aip.ui").status() end

return M