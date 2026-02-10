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
local moltenbuffer_module = require("molten.moltenbuffer")

local M = {}

-- Plugin state
M.initialized = false
M.bridge = nil
M.options = nil
M.canvas = nil
M.molten_kernels = {} -- kernel_id -> MoltenKernel
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
  
  local bufnr = vim.api.nvim_get_current_buf()
  
  -- Create runtime
  local runtime = runtime_module.new(M.bridge, kernel_name)
  
  -- Initialize kernel
  runtime:init(function(success, kernel_id_or_error)
    if success then
      local kernel_id = kernel_id_or_error
      
      -- Create MoltenKernel instance
      local molten_kernel = moltenbuffer_module.new(
        runtime,
        M.canvas,
        M.highlight_namespace,
        M.extmark_namespace,
        bufnr,
        M.options,
        kernel_name,
        kernel_id
      )
      
      M.molten_kernels[kernel_id] = molten_kernel
      
      -- Register this kernel with current buffer
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
  for kernel_id, molten_kernel in pairs(M.molten_kernels) do
    molten_kernel:tick()
  end
  
  -- Present canvas changes (batch image updates)
  if M.canvas and M.canvas.present then
    M.canvas:present()
  end
end

--- Update interface for a specific kernel
---@param kernel_id string
function M.update_interface_for_kernel(kernel_id)
  local molten_kernel = M.molten_kernels[kernel_id]
  if molten_kernel then
    molten_kernel:update_interface()
  end
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
      for _, molten_kernel in pairs(M.molten_kernels) do
        molten_kernel:clear_open_output_windows()
      end
    end,
  })
  
  vim.api.nvim_create_autocmd({"CursorMoved", "CursorMovedI"}, {
    group = group,
    callback = function()
      M.on_cursor_moved(false)
    end,
  })
  
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      M.on_cursor_moved(true)
    end,
  })
  
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function()
      M.update_interface()
    end,
  })
  
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    callback = function(args)
      M.on_buffer_unload(args.buf)
    end,
  })
end

--- Handle cursor movement
---@param scrolled boolean
function M.on_cursor_moved(scrolled)
  if not M.initialized then
    return
  end
  
  local bufnr = vim.api.nvim_get_current_buf()
  local kernel_ids = M.buffers[bufnr]
  
  if not kernel_ids then
    return
  end
  
  for _, kernel_id in ipairs(kernel_ids) do
    local molten_kernel = M.molten_kernels[kernel_id]
    if molten_kernel then
      molten_kernel:on_cursor_moved(scrolled)
    end
  end
end

--- Update interface for all kernels in current buffer
function M.update_interface()
  if not M.initialized then
    return
  end
  
  local bufnr = vim.api.nvim_get_current_buf()
  local kernel_ids = M.buffers[bufnr]
  
  if not kernel_ids then
    return
  end
  
  for _, kernel_id in ipairs(kernel_ids) do
    local molten_kernel = M.molten_kernels[kernel_id]
    if molten_kernel then
      molten_kernel:update_interface()
    end
  end
end

--- Handle buffer unload
---@param bufnr number
function M.on_buffer_unload(bufnr)
  if not M.initialized then
    return
  end
  
  local kernel_ids = M.buffers[bufnr]
  if not kernel_ids then
    return
  end
  
  for _, kernel_id in ipairs(kernel_ids) do
    local molten_kernel = M.molten_kernels[kernel_id]
    if molten_kernel then
      molten_kernel:clear_buffer(bufnr)
    end
  end
end
--- Handle kernel events
---@param kernel_id string
---@param event table
function M.handle_kernel_event(kernel_id, event)
  local molten_kernel = M.molten_kernels[kernel_id]
  if not molten_kernel then
    return
  end
  
  local msg_type = event.msg_type
  local content = event.content
  
  if vim.g.molten_debug then
    print(string.format("[Molten] Event from %s: %s", kernel_id, msg_type))
  end
  
  -- Update output based on message type
  if molten_kernel.current_output then
    local output_buf = molten_kernel.outputs[molten_kernel.current_output]
    if output_buf then
      local output = output_buf.output
      
      if msg_type == "execute_input" then
        output.execution_count = content.execution_count
        if output.status == outputchunks.OutputStatus.HOLD then
          output.status = outputchunks.OutputStatus.RUNNING
          output.start_time = os.time()
        end
        
      elseif msg_type == "status" then
        if content.execution_state == "idle" then
          output.status = outputchunks.OutputStatus.DONE
          output.end_time = os.time()
        elseif content.execution_state == "busy" then
          output.status = outputchunks.OutputStatus.RUNNING
        end
        
      elseif msg_type == "execute_result" then
        local chunk = outputchunks.to_outputchunk(content.data, content.metadata or {}, M.options)
        table.insert(output.chunks, chunk)
        
      elseif msg_type == "stream" then
        local chunk = outputchunks.TextOutputChunk(content.text or "")
        table.insert(output.chunks, chunk)
        
      elseif msg_type == "error" then
        output.success = false
        local chunk = outputchunks.ErrorOutputChunk(
          content.ename or "Error",
          content.evalue or "",
          content.traceback or {}
        )
        table.insert(output.chunks, chunk)
        
      elseif msg_type == "display_data" then
        local chunk = outputchunks.to_outputchunk(content.data, content.metadata or {}, M.options)
        table.insert(output.chunks, chunk)
        
      elseif msg_type == "clear_output" then
        if not content.wait then
          output.chunks = {}
        end
      end
    end
  end
end

--- Execute code in the active kernel
---@param code string
function M.molten_evaluate(code)
  if not M.initialized then
    utils.notify_error("Molten not initialized. Run :MoltenInit first")
    return
  end
  
  -- Find kernel for current buffer
  local bufnr = vim.api.nvim_get_current_buf()
  local kernel_ids = M.buffers[bufnr]
  
  if not kernel_ids or #kernel_ids == 0 then
    utils.notify_error("No active kernel. Run :MoltenInit first")
    return
  end
  
  -- Use first kernel (TODO: support selecting specific kernel)
  local kernel_id = kernel_ids[1]
  local molten_kernel = M.molten_kernels[kernel_id]
  
  if not molten_kernel then
    utils.notify_error("Kernel not found")
    return
  end
  
  -- Create cell span for this code
  local cursor = vim.api.nvim_win_get_cursor(0)
  local begin_pos = position_module.Position(bufnr, cursor[1] - 1, 0)
  local end_pos = position_module.Position(bufnr, cursor[1] - 1, #code)
  local cell = code_cell_module.new(begin_pos, end_pos)
  
  -- Run code in this cell
  molten_kernel:run_code(code, cell)
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
  
  local bufnr = vim.api.nvim_get_current_buf()
  local start_line = start_pos[2] - 1
  local end_line = end_pos[2] - 1
  local start_col = start_pos[3] - 1
  local end_col = end_pos[3]
  
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
  local code = table.concat(lines, "\n")
  
  -- Create proper cell span
  local begin_pos = position_module.Position(bufnr, start_line, start_col)
  local end_pos = position_module.Position(bufnr, end_line, end_col)
  
  -- Find kernel for this buffer
  local kernel_ids = M.buffers[bufnr]
  if not kernel_ids or #kernel_ids == 0 then
    utils.notify_error("No active kernel. Run :MoltenInit first")
    return
  end
  
  local kernel_id = kernel_ids[1]
  local molten_kernel = M.molten_kernels[kernel_id]
  
  if not molten_kernel then
    utils.notify_error("Kernel not found")
    return
  end
  
  local cell = code_cell_module.new(begin_pos, end_pos)
  molten_kernel:run_code(code, cell)
end

--- Deinitialize a kernel
function M.molten_deinit()
  -- Find kernel for current buffer
  local bufnr = vim.api.nvim_get_current_buf()
  local kernel_ids = M.buffers[bufnr]
  
  if not kernel_ids or #kernel_ids == 0 then
    utils.notify_warn("No active kernel")
    return
  end
  
  local kernel_id = kernel_ids[1]
  local molten_kernel = M.molten_kernels[kernel_id]
  
  if not molten_kernel then
    utils.notify_warn("Kernel not found")
    return
  end
  
  molten_kernel:deinit()
  M.molten_kernels[kernel_id] = nil
  M.buffers[bufnr] = nil
  
  utils.notify_info("Kernel shutdown")
end

--- Interrupt the active kernel
function M.molten_interrupt()
  local bufnr = vim.api.nvim_get_current_buf()
  local kernel_ids = M.buffers[bufnr]
  
  if not kernel_ids or #kernel_ids == 0 then
    utils.notify_warn("No active kernel")
    return
  end
  
  local kernel_id = kernel_ids[1]
  local molten_kernel = M.molten_kernels[kernel_id]
  
  if not molten_kernel then
    utils.notify_warn("Kernel not found")
    return
  end
  
  molten_kernel:interrupt()
  utils.notify_info("Kernel interrupted")
end

--- Show output for current cell
function M.molten_show_output()
  if not M.initialized then
    utils.notify_error("Molten not initialized")
    return
  end
  
  local bufnr = vim.api.nvim_get_current_buf()
  local kernel_ids = M.buffers[bufnr]
  
  if not kernel_ids or #kernel_ids == 0 then
    return
  end
  
  for _, kernel_id in ipairs(kernel_ids) do
    local molten_kernel = M.molten_kernels[kernel_id]
    if molten_kernel then
      molten_kernel.should_show_floating_win = true
      molten_kernel:update_interface()
    end
  end
end

--- Hide output windows
function M.molten_hide_output()
  if not M.initialized then
    return
  end
  
  -- Hide all output windows
  for _, molten_kernel in pairs(M.molten_kernels) do
    molten_kernel:clear_open_output_windows()
  end
end

--- Enter output window
function M.molten_enter_output()
  if not M.initialized then
    utils.notify_error("Molten not initialized")
    return
  end
  
  local bufnr = vim.api.nvim_get_current_buf()
  local kernel_ids = M.buffers[bufnr]
  
  if not kernel_ids or #kernel_ids == 0 then
    return
  end
  
  for _, kernel_id in ipairs(kernel_ids) do
    local molten_kernel = M.molten_kernels[kernel_id]
    if molten_kernel then
      molten_kernel:enter_output()
    end
  end
end

--- Restart kernel
---@param delete_outputs boolean
function M.molten_restart(delete_outputs)
  local bufnr = vim.api.nvim_get_current_buf()
  local kernel_ids = M.buffers[bufnr]
  
  if not kernel_ids or #kernel_ids == 0 then
    utils.notify_warn("No active kernel")
    return
  end
  
  local kernel_id = kernel_ids[1]
  local molten_kernel = M.molten_kernels[kernel_id]
  
  if not molten_kernel then
    utils.notify_warn("Kernel not found")
    return
  end
  
  molten_kernel:restart(delete_outputs)
  utils.notify_info("Kernel restarted")
end

--- Reevaluate cell at cursor
function M.molten_reevaluate_cell()
  if not M.initialized then
    utils.notify_error("Molten not initialized")
    return
  end
  
  local bufnr = vim.api.nvim_get_current_buf()
  local kernel_ids = M.buffers[bufnr]
  
  if not kernel_ids or #kernel_ids == 0 then
    utils.notify_error("No active kernel")
    return
  end
  
  local kernel_id = kernel_ids[1]
  local molten_kernel = M.molten_kernels[kernel_id]
  
  if not molten_kernel then
    utils.notify_error("Kernel not found")
    return
  end
  
  if not molten_kernel:reevaluate_cell() then
    utils.notify_warn("No cell at cursor")
  end
end

--- Reevaluate all cells
function M.molten_reevaluate_all()
  if not M.initialized then
    utils.notify_error("Molten not initialized")
    return
  end
  
  local bufnr = vim.api.nvim_get_current_buf()
  local kernel_ids = M.buffers[bufnr]
  
  if not kernel_ids or #kernel_ids == 0 then
    utils.notify_error("No active kernel")
    return
  end
  
  local kernel_id = kernel_ids[1]
  local molten_kernel = M.molten_kernels[kernel_id]
  
  if not molten_kernel then
    utils.notify_error("Kernel not found")
    return
  end
  
  molten_kernel:reevaluate_all()
  utils.notify_info("Re-evaluating all cells")
end

--- Delete current cell
function M.molten_delete()
  if not M.initialized then
    utils.notify_error("Molten not initialized")
    return
  end
  
  local bufnr = vim.api.nvim_get_current_buf()
  local kernel_ids = M.buffers[bufnr]
  
  if not kernel_ids or #kernel_ids == 0 then
    utils.notify_error("No active kernel")
    return
  end
  
  for _, kernel_id in ipairs(kernel_ids) do
    local molten_kernel = M.molten_kernels[kernel_id]
    if molten_kernel then
      molten_kernel:delete_current_cell()
    end
  end
end

--- Get all cells sorted by position
---@return table List of CodeCell objects
local function get_sorted_cells()
  local bufnr = vim.api.nvim_get_current_buf()
  local kernel_ids = M.buffers[bufnr]
  
  if not kernel_ids or #kernel_ids == 0 then
    return {}
  end
  
  local all_cells = {}
  for _, kernel_id in ipairs(kernel_ids) do
    local molten_kernel = M.molten_kernels[kernel_id]
    if molten_kernel then
      for cell in pairs(molten_kernel.outputs) do
        table.insert(all_cells, cell)
      end
    end
  end
  
  table.sort(all_cells, function(a, b)
    return a.begin < b.begin
  end)
  
  return all_cells
end

--- Jump to next cell
---@param count number Number of cells to jump
function M.molten_next(count)
  if not M.initialized then
    return
  end
  
  count = count or 1
  local cells = get_sorted_cells()
  
  if #cells == 0 then
    return
  end
  
  -- Find current cell
  local cursor = vim.api.nvim_win_get_cursor(0)
  local bufnr = vim.api.nvim_get_current_buf()
  local current_pos = position_module.Position(bufnr, cursor[1] - 1, cursor[2])
  
  local current_idx = 0
  for i, cell in ipairs(cells) do
    if cell:contains(current_pos) then
      current_idx = i
      break
    end
  end
  
  -- Jump to next cell
  local target_idx = current_idx + count
  if target_idx > #cells then
    target_idx = #cells
  end
  
  if target_idx > 0 and target_idx <= #cells then
    local target_cell = cells[target_idx]
    vim.api.nvim_win_set_cursor(0, { target_cell.begin.lineno + 1, target_cell.begin.colno })
  end
end

--- Jump to previous cell
---@param count number Number of cells to jump
function M.molten_prev(count)
  if not M.initialized then
    return
  end
  
  count = count or 1
  local cells = get_sorted_cells()
  
  if #cells == 0 then
    return
  end
  
  -- Find current cell
  local cursor = vim.api.nvim_win_get_cursor(0)
  local bufnr = vim.api.nvim_get_current_buf()
  local current_pos = position_module.Position(bufnr, cursor[1] - 1, cursor[2])
  
  local current_idx = #cells + 1
  for i, cell in ipairs(cells) do
    if cell:contains(current_pos) then
      current_idx = i
      break
    end
  end
  
  -- Jump to previous cell
  local target_idx = current_idx - count
  if target_idx < 1 then
    target_idx = 1
  end
  
  if target_idx > 0 and target_idx <= #cells then
    local target_cell = cells[target_idx]
    vim.api.nvim_win_set_cursor(0, { target_cell.begin.lineno + 1, target_cell.begin.colno })
  end
end

--- Jump to specific cell
---@param index number Cell index (1-based)
function M.molten_goto(index)
  if not M.initialized then
    return
  end
  
  local cells = get_sorted_cells()
  
  if index < 1 or index > #cells then
    utils.notify_warn(string.format("Cell %d does not exist (have %d cells)", index, #cells))
    return
  end
  
  local target_cell = cells[index]
  vim.api.nvim_win_set_cursor(0, { target_cell.begin.lineno + 1, target_cell.begin.colno })
end

--- Toggle virtual text output
function M.molten_toggle_virtual()
  if not M.initialized then
    return
  end
  
  -- Toggle the option
  M.options.virt_text_output = not M.options.virt_text_output
  
  local bufnr = vim.api.nvim_get_current_buf()
  local kernel_ids = M.buffers[bufnr]
  
  if not kernel_ids then
    return
  end
  
  for _, kernel_id in ipairs(kernel_ids) do
    local molten_kernel = M.molten_kernels[kernel_id]
    if molten_kernel then
      if M.options.virt_text_output then
        -- Show virtual text for all cells
        for cell, output_buf in pairs(molten_kernel.outputs) do
          output_buf:show_virtual_output(cell.end_)
        end
      else
        -- Hide all virtual text
        molten_kernel:clear_virt_outputs()
      end
    end
  end
  
  utils.notify_info("Virtual text output: " .. (M.options.virt_text_output and "ON" or "OFF"))
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
  
  vim.api.nvim_create_user_command("MoltenReevaluateCell", function()
    M.molten_reevaluate_cell()
  end, {})
  
  vim.api.nvim_create_user_command("MoltenReevaluateAll", function()
    M.molten_reevaluate_all()
  end, {})
  
  vim.api.nvim_create_user_command("MoltenDelete", function(opts)
    M.molten_delete(opts.bang)
  end, { bang = true })
  
  vim.api.nvim_create_user_command("MoltenNext", function(opts)
    local count = tonumber(opts.args) or 1
    M.molten_next(count)
  end, { nargs = "?" })
  
  vim.api.nvim_create_user_command("MoltenPrev", function(opts)
    local count = tonumber(opts.args) or 1
    M.molten_prev(count)
  end, { nargs = "?" })
  
  vim.api.nvim_create_user_command("MoltenGoto", function(opts)
    local index = tonumber(opts.args)
    if index then
      M.molten_goto(index)
    else
      utils.notify_error("MoltenGoto requires a cell number")
    end
  end, { nargs = 1 })
  
  vim.api.nvim_create_user_command("MoltenToggleVirtual", function()
    M.molten_toggle_virtual()
  end, {})
  
  -- TODO: Add remaining commands:
  -- - MoltenEvaluateOperator
  -- - MoltenEvaluateArgument
  -- - MoltenEvaluateRange
  -- - MoltenSave/Load
  -- - MoltenImportOutput/ExportOutput
  -- - MoltenInfo
  -- - MoltenOpenInBrowser
  -- - MoltenImagePopup
  -- - Status functions
end
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
