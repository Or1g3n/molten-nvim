--[[
Molten.nvim - Enhanced Lua-based architecture

Implementing production features:
- Multi-cell tracking and execution
- Visual output (virtual text and floating windows)
- Image rendering
- Multi-kernel/buffer support
--]]

local bridge_module = require("molten.bridge")
local runtime_module = require("molten.runtime")
local options_module = require("molten.options")
local utils = require("molten.utils")
local outputchunks = require("molten.outputchunks")
local position_module = require("molten.position")
local code_cell_module = require("molten.code_cell")
local outputbuffer_module = require("molten.outputbuffer")
local images_module = require("molten.images")

local M = {}

-- Plugin state
M.initialized = false
M.bridge = nil
M.options = nil
M.canvas = nil
M.kernels = {} -- kernel_id -> { runtime, outputs, cells, current_buffer }
M.buffers = {} -- bufnr -> list of kernel_ids
M.highlight_namespace = nil
M.extmark_namespace = nil
M.tick_timer = nil

--- Initialize the plugin
function M.initialize()
  if M.initialized then
    return true
  end
  
  -- Load options
  M.options = options_module.load()
  
  -- Initialize canvas
  M.canvas = images_module.get_canvas(M.options)
  M.canvas:init()
  
  -- Create namespaces
  M.highlight_namespace = vim.api.nvim_create_namespace("molten-highlights")
  M.extmark_namespace = vim.api.nvim_create_namespace("molten-extmarks")
  
  -- Start the bridge
  M.bridge = bridge_module.new()
  if not M.bridge:start() then
    utils.notify_error("Failed to start bridge subprocess")
    return false
  end
  
  -- Set up tick timer for UI updates
  M.tick_timer = vim.fn.timer_start(M.options.tick_rate, function()
    M.tick()
  end, { ['repeat'] = -1 })
  
  -- Set up autocommands
  M.setup_autocommands()
  
  M.initialized = true
  utils.notify_info("Molten initialized")
  return true
end

--- Initialize a kernel
---@param kernel_name string|nil
function M.molten_init(kernel_name)
  if not M.initialized then
    if not M.initialize() then
      return
    end
  end
  
  -- Default to python3 if no kernel specified
  kernel_name = kernel_name or "python3"
  
  -- Create runtime
  local runtime = runtime_module.new(M.bridge, kernel_name)
  
  -- Initialize kernel
  runtime:init(function(success, kernel_id_or_error)
    if success then
      local kernel_id = kernel_id_or_error
      M.kernels[kernel_id] = {
        runtime = runtime,
        outputs = {}, -- cell_id -> OutputBuffer
        cells = {}, -- list of CodeCell objects
        current_buffer = vim.api.nvim_get_current_buf(),
        kernel_name = kernel_name,
        selected_cell = nil,
        current_output = nil,
      }
      
      -- Register this kernel with current buffer
      local bufnr = vim.api.nvim_get_current_buf()
      if not M.buffers[bufnr] then
        M.buffers[bufnr] = {}
      end
      table.insert(M.buffers[bufnr], kernel_id)
      
      -- Set up event handler
      runtime:set_event_handler(function(event)
        M.handle_kernel_event(kernel_id, event)
      end)
      
      utils.notify_info(string.format("Kernel '%s' initialized", kernel_name))
    else
      utils.notify_error("Failed to initialize kernel: " .. kernel_id_or_error)
    end
  end)
end

--- Tick function - Update UI and process kernel messages
function M.tick()
  if not M.initialized then
    return
  end
  
  -- Process messages and update outputs for all kernels
  for kernel_id, kernel in pairs(M.kernels) do
    -- Update interface if needed
    M.update_interface_for_kernel(kernel_id)
  end
  
  -- Present canvas changes (batch image updates)
  if M.canvas and M.canvas.present then
    M.canvas:present()
  end
end

--- Update interface for a specific kernel
---@param kernel_id string
function M.update_interface_for_kernel(kernel_id)
  local kernel = M.kernels[kernel_id]
  if not kernel then
    return
  end
  
  -- Find selected cell (cell containing cursor)
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local bufnr = vim.api.nvim_get_current_buf()
  
  -- Check if this buffer has this kernel
  if not M.buffers[bufnr] or not vim.tbl_contains(M.buffers[bufnr], kernel_id) then
    return
  end
  
  -- TODO: Implement cell selection and output display
  -- For now, just ensure outputs are visible if configured
end

--- Set up autocommands
function M.setup_autocommands()
  local group = vim.api.nvim_create_augroup("Molten", { clear = true })
  
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if M.bridge and M.bridge.running then
        M.bridge:stop()
      end
      if M.tick_timer then
        vim.fn.timer_stop(M.tick_timer)
      end
    end,
  })
  
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    callback = function()
      -- Clear any open output windows
      for _, kernel in pairs(M.kernels) do
        for _, output_buf in pairs(kernel.outputs) do
          if output_buf.clear_float_win then
            output_buf:clear_float_win()
          end
        end
      end
    end,
  })
end
---@param kernel_id string
---@param event table
function M.handle_kernel_event(kernel_id, event)
  local kernel = M.kernels[kernel_id]
  if not kernel then
    return
  end
  
  local msg_type = event.msg_type
  local content = event.content
  
  -- For now, just log events
  if vim.g.molten_debug then
    print(string.format("[Molten] Event from %s: %s", kernel_id, msg_type))
  end
  
  -- TODO: Update output buffers based on event
  -- This requires full OutputBuffer implementation
  
  if msg_type == "execute_result" or msg_type == "stream" then
    -- Simple text output - just show a notification for now
    if content.text then
      utils.notify_info("Output: " .. content.text)
    elseif content.data and content.data["text/plain"] then
      utils.notify_info("Output: " .. content.data["text/plain"])
    end
  elseif msg_type == "error" then
    utils.notify_error(string.format("Error: %s", content.evalue or "Unknown error"))
  end
end

--- Execute code in the active kernel
---@param code string
function M.molten_evaluate(code)
  if not M.initialized then
    utils.notify_error("Molten not initialized. Run :MoltenInit first")
    return
  end
  
  -- Find the first available kernel (simplified - should handle multiple kernels per buffer)
  -- TODO: This uses next() which has undefined iteration order. For proper multi-kernel
  -- support, we should track the "current" or "active" kernel explicitly.
  local kernel_id = next(M.kernels)
  if not kernel_id then
    utils.notify_error("No active kernel. Run :MoltenInit first")
    return
  end
  
  local kernel = M.kernels[kernel_id]
  kernel.runtime:execute(code, function(response)
    if response.success then
      utils.notify_info("Code executed")
    else
      utils.notify_error("Failed to execute: " .. (response.message or "unknown error"))
    end
  end)
end

--- Evaluate current line
function M.molten_evaluate_line()
  local line = vim.api.nvim_get_current_line()
  M.molten_evaluate(line)
end

--- Evaluate visual selection
function M.molten_evaluate_visual()
  -- Get visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  
  local start_line = start_pos[2] - 1
  local end_line = end_pos[2]
  
  local lines = vim.api.nvim_buf_get_lines(0, start_line, end_line, false)
  local code = table.concat(lines, "\n")
  
  M.molten_evaluate(code)
end

--- Deinitialize a kernel
function M.molten_deinit()
  -- Find active kernel
  local kernel_id = next(M.kernels)
  if not kernel_id then
    utils.notify_warn("No active kernel")
    return
  end
  
  local kernel = M.kernels[kernel_id]
  kernel.runtime:shutdown(function(response)
    if response.success then
      M.kernels[kernel_id] = nil
      utils.notify_info("Kernel shutdown")
    else
      utils.notify_error("Failed to shutdown kernel: " .. (response.message or "unknown"))
    end
  end)
end

--- Interrupt the active kernel
function M.molten_interrupt()
  local kernel_id = next(M.kernels)
  if not kernel_id then
    utils.notify_warn("No active kernel")
    return
  end
  
  local kernel = M.kernels[kernel_id]
  kernel.runtime:interrupt(function(response)
    if response.success then
      utils.notify_info("Kernel interrupted")
    else
      utils.notify_error("Failed to interrupt: " .. (response.message or "unknown"))
    end
  end)
end

--- Show output for current cell
function M.molten_show_output()
  if not M.initialized then
    utils.notify_error("Molten not initialized")
    return
  end
  
  -- TODO: Find selected cell and show its output
  utils.notify_warn("ShowOutput not fully implemented yet")
end

--- Hide output windows
function M.molten_hide_output()
  if not M.initialized then
    return
  end
  
  -- Hide all output windows
  for _, kernel in pairs(M.kernels) do
    for _, output_buf in pairs(kernel.outputs) do
      if output_buf.clear_float_win then
        output_buf:clear_float_win()
      end
    end
  end
end

--- Enter output window
function M.molten_enter_output()
  if not M.initialized then
    utils.notify_error("Molten not initialized")
    return
  end
  
  -- TODO: Enter the output window for selected cell
  utils.notify_warn("EnterOutput not fully implemented yet")
end

--- Restart kernel
---@param delete_outputs boolean
function M.molten_restart(delete_outputs)
  local kernel_id = next(M.kernels)
  if not kernel_id then
    utils.notify_warn("No active kernel")
    return
  end
  
  local kernel = M.kernels[kernel_id]
  
  if delete_outputs then
    -- Clear all outputs
    for _, output_buf in pairs(kernel.outputs) do
      if output_buf.clear_float_win then
        output_buf:clear_float_win()
      end
      if output_buf.clear_virt_output then
        local bufnr = kernel.current_buffer
        output_buf:clear_virt_output(bufnr)
      end
    end
    kernel.outputs = {}
    kernel.cells = {}
  end
  
  kernel.runtime:restart(function(response)
    if response.success then
      utils.notify_info("Kernel restarted")
    else
      utils.notify_error("Failed to restart: " .. (response.message or "unknown"))
    end
  end)
end

--- Get available kernels
---@return table
function M.molten_available_kernels()
  if not M.initialized then
    if not M.initialize() then
      return {}
    end
  end
  
  local result = {}
  M.bridge:list_kernels(function(response)
    if response.success then
      result = response.kernels or {}
    end
  end)
  
  -- Wait a bit for response (synchronous-ish)
  vim.wait(1000, function()
    return #result > 0
  end)
  
  return result
end

--- Setup commands
function M.setup()
  -- Initialize on first command
  vim.api.nvim_create_user_command("MoltenInit", function(opts)
    M.molten_init(opts.args ~= "" and opts.args or nil)
  end, { nargs = "?" })
  
  vim.api.nvim_create_user_command("MoltenDeinit", function()
    M.molten_deinit()
  end, {})
  
  vim.api.nvim_create_user_command("MoltenEvaluateLine", function()
    M.molten_evaluate_line()
  end, {})
  
  vim.api.nvim_create_user_command("MoltenEvaluateVisual", function()
    M.molten_evaluate_visual()
  end, { range = true })
  
  vim.api.nvim_create_user_command("MoltenInterrupt", function()
    M.molten_interrupt()
  end, {})
  
  vim.api.nvim_create_user_command("MoltenRestart", function(opts)
    M.molten_restart(opts.bang)
  end, { bang = true })
  
  vim.api.nvim_create_user_command("MoltenShowOutput", function()
    M.molten_show_output()
  end, {})
  
  vim.api.nvim_create_user_command("MoltenHideOutput", function()
    M.molten_hide_output()
  end, {})
  
  vim.api.nvim_create_user_command("MoltenEnterOutput", function()
    M.molten_enter_output()
  end, {})
  
  -- TODO: Add remaining 30+ commands
  -- - MoltenEvaluateOperator
  -- - MoltenEvaluateArgument
  -- - MoltenReevaluateCell
  -- - MoltenReevaluateAll
  -- - MoltenDelete
  -- - MoltenNext/Prev/Goto
  -- - MoltenToggleVirtual
  -- - MoltenSave/Load
  -- - MoltenImportOutput/ExportOutput
  -- - MoltenInfo
  -- - etc.
end

return M
