--[[
Molten.nvim - Minimal prototype of Lua-based architecture

This is a minimal working prototype demonstrating the new architecture.
It implements basic functionality to prove the concept:
- Kernel initialization
- Code execution  
- Simple output display

Full feature parity will require additional work on:
- All 40+ commands
- Complete UI components (floating windows, virtual text, images)
- Persistence (save/load, import/export)
- Multi-buffer/multi-kernel management
- All configuration options
--]]

local bridge_module = require("molten.bridge")
local runtime_module = require("molten.runtime")
local options_module = require("molten.options")
local utils = require("molten.utils")
local outputchunks = require("molten.outputchunks")
local position_module = require("molten.position")
local code_cell_module = require("molten.code_cell")

local M = {}

-- Plugin state
M.initialized = false
M.bridge = nil
M.options = nil
M.kernels = {} -- kernel_id -> { runtime, outputs, current_buffer }
M.highlight_namespace = nil
M.extmark_namespace = nil

--- Initialize the plugin
function M.initialize()
  if M.initialized then
    return true
  end
  
  -- Load options
  M.options = options_module.load()
  
  -- Create namespaces
  M.highlight_namespace = vim.api.nvim_create_namespace("molten-highlights")
  M.extmark_namespace = vim.api.nvim_create_namespace("molten-extmarks")
  
  -- Start the bridge
  M.bridge = bridge_module.new()
  if not M.bridge:start() then
    utils.notify_error("Failed to start bridge subprocess")
    return false
  end
  
  M.initialized = true
  utils.notify_info("Molten initialized (prototype)")
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
        outputs = {}, -- CodeCell -> Output
        current_buffer = vim.api.nvim_get_current_buf(),
        kernel_name = kernel_name,
      }
      
      -- Set up event handler
      runtime:set_event_handler(function(event)
        M.handle_kernel_event(kernel_id, event)
      end)
      
      utils.notify_info(string.format("Kernel '%s' initialized with ID: %s", kernel_name, kernel_id))
    else
      utils.notify_error("Failed to initialize kernel: " .. kernel_id_or_error)
    end
  end)
end

--- Handle kernel events
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
  
  -- TODO: Add remaining 35+ commands
  
  -- Cleanup on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      if M.bridge and M.bridge.running then
        M.bridge:stop()
      end
    end,
  })
end

return M
