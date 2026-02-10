-- MoltenKernel - Complete kernel management with cell tracking
-- Handles single kernel attached to multiple buffers

local M = {}

local code_cell_module = require("molten.code_cell")
local position_module = require("molten.position")
local outputchunks = require("molten.outputchunks")
local outputbuffer_module = require("molten.outputbuffer")
local utils = require("molten.utils")

---@class MoltenKernel
---@field runtime table Runtime instance
---@field canvas table Canvas for images
---@field highlight_namespace number Highlight namespace
---@field extmark_namespace number Extmark namespace
---@field buffers table List of buffer numbers
---@field kernel_id string Unique kernel identifier
---@field kernel_name string Kernel type name
---@field outputs table CodeCell -> OutputBuffer mapping
---@field current_output table|nil Currently executing cell
---@field queued_outputs table Queue of cells to execute
---@field selected_cell table|nil Cell under cursor
---@field should_show_floating_win boolean Show float window flag
---@field updating_interface boolean Update in progress flag
---@field options table MoltenOptions
---@field output_statuses table Cell -> OutputStatus mapping
local MoltenKernel = {}
MoltenKernel.__index = MoltenKernel

--- Create a new MoltenKernel
---@param runtime table Runtime instance
---@param canvas table Canvas instance
---@param highlight_namespace number
---@param extmark_namespace number
---@param main_buffer number Buffer number
---@param options table
---@param kernel_name string
---@param kernel_id string
---@return MoltenKernel
function M.new(runtime, canvas, highlight_namespace, extmark_namespace, main_buffer, options, kernel_name, kernel_id)
  local self = setmetatable({}, MoltenKernel)
  
  self.runtime = runtime
  self.canvas = canvas
  self.highlight_namespace = highlight_namespace
  self.extmark_namespace = extmark_namespace
  self.buffers = { main_buffer }
  self.kernel_id = kernel_id
  self.kernel_name = kernel_name
  
  self.outputs = {} -- CodeCell -> OutputBuffer
  self.current_output = nil
  self.queued_outputs = {} -- Queue (list) of CodeCell
  
  self.selected_cell = nil
  self.should_show_floating_win = false
  self.updating_interface = false
  
  self.options = options
  self.output_statuses = {}
  
  -- Trigger MoltenInitPre autocommand
  self:_doautocmd("MoltenInitPre")
  
  return self
end

--- Trigger an autocommand
---@param autocmd string
---@param opts table|nil
function MoltenKernel:_doautocmd(autocmd, opts)
  opts = opts or {}
  opts.pattern = autocmd
  vim.api.nvim_exec_autocmds("User", opts)
end

--- Add buffer to this kernel
---@param buffer number Buffer number
function MoltenKernel:add_nvim_buffer(buffer)
  table.insert(self.buffers, buffer)
end

--- Deinitialize kernel
function MoltenKernel:deinit()
  self:_doautocmd("MoltenDeinitPre")
  if self.runtime.shutdown then
    self.runtime:shutdown()
  end
  self:_doautocmd("MoltenDeinitPost")
end

--- Interrupt kernel
function MoltenKernel:interrupt()
  if self.runtime.interrupt then
    self.runtime:interrupt()
  end
end

--- Restart kernel
---@param delete_outputs boolean Whether to delete outputs
function MoltenKernel:restart(delete_outputs)
  if delete_outputs then
    self:clear_virt_outputs()
    self:clear_interface()
    self:clear_open_output_windows()
    self.outputs = {}
  else
    -- Mark running cells as failed
    for _, output_buf in pairs(self.outputs) do
      if output_buf.output.status == outputchunks.OutputStatus.RUNNING then
        output_buf.output.status = outputchunks.OutputStatus.DONE
        output_buf.output.success = false
      end
    end
  end
  
  if self.runtime.restart then
    self.runtime:restart()
  end
end

--- Run code in a cell
---@param code string Code to execute
---@param span table CodeCell
function MoltenKernel:run_code(code, span)
  -- Check for overlapping cells
  if not self:try_delete_overlapping_cells(span) then
    return
  end
  
  self.output_statuses[span] = outputchunks.OutputStatus.RUNNING
  
  -- Execute code
  if self.runtime.execute then
    self.runtime:execute(code)
  end
  
  -- Create output buffer for this cell
  local output_buf = outputbuffer_module.new(self.canvas, self.extmark_namespace, self.options)
  self.outputs[span] = output_buf
  
  -- Queue this cell for output
  table.insert(self.queued_outputs, span)
  
  self.selected_cell = span
  
  if not self.options.virt_text_output then
    self.should_show_floating_win = true
  end
  
  self:update_interface()
  self:_check_if_done_running()
end

--- Re-evaluate all cells in order
function MoltenKernel:reevaluate_all()
  -- Sort cells by begin position
  local sorted_spans = {}
  for span in pairs(self.outputs) do
    table.insert(sorted_spans, span)
  end
  table.sort(sorted_spans, function(a, b)
    return a.begin < b.begin
  end)
  
  -- Re-run each cell
  for _, span in ipairs(sorted_spans) do
    local code = span:get_text()
    self:run_code(code, span)
  end
end

--- Re-evaluate cell at cursor
---@return boolean Success
function MoltenKernel:reevaluate_cell()
  self.selected_cell = self:_get_selected_span()
  if not self.selected_cell then
    return false
  end
  
  local code = self.selected_cell:get_text()
  self:run_code(code, self.selected_cell)
  return true
end

--- Check if done running and dequeue next
function MoltenKernel:_check_if_done_running()
  local is_idle = (not self.current_output or not self.outputs[self.current_output])
    or (self.current_output and self.outputs[self.current_output].output.status == outputchunks.OutputStatus.DONE)
  
  if is_idle and #self.queued_outputs > 0 then
    local key = table.remove(self.queued_outputs, 1)
    self.current_output = key
  end
end

--- Tick - process kernel messages and update UI
function MoltenKernel:tick()
  self:_check_if_done_running()
  
  local was_ready = self.runtime:is_ready()
  
  -- TODO: Integrate with runtime tick for message processing
  -- For now, the event handler in init.lua updates outputs directly
  
  -- Check if execution completed
  if self.current_output and self.outputs[self.current_output] then
    local output = self.outputs[self.current_output].output
    if output.status == outputchunks.OutputStatus.DONE then
      output.end_time = os.time()
      self:update_interface()
      self.output_statuses[self.current_output] = output.status
    end
  end
  
  -- Always update if showing exec time
  if self.options.output_show_exec_time then
    self:update_interface()
  end
  
  if not was_ready and self.runtime:is_ready() then
    self:_doautocmd("MoltenKernelReady", {
      data = {
        kernel_id = self.kernel_id,
      }
    })
    utils.notify_info(string.format("Kernel '%s' is ready", self.kernel_name))
  end
end

--- Enter output window
function MoltenKernel:enter_output()
  if not self.selected_cell then
    return
  end
  
  if self.options.enter_output_behavior ~= "no_open" then
    self.should_show_floating_win = true
  end
  
  if self.outputs[self.selected_cell] then
    self.should_show_floating_win = self.outputs[self.selected_cell]:enter(self.selected_cell.end_)
  end
end

--- Get cursor position
---@return Position
function MoltenKernel:_get_cursor_position()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local bufnr = vim.api.nvim_get_current_buf()
  return position_module.Position(bufnr, cursor[1] - 1, cursor[2])
end

--- Clear interface highlights
function MoltenKernel:clear_interface()
  if self.updating_interface then
    return
  end
  
  for _, bufnr in ipairs(self.buffers) do
    vim.api.nvim_buf_clear_namespace(bufnr, self.highlight_namespace, 0, -1)
  end
end

--- Clear all open output windows
function MoltenKernel:clear_open_output_windows()
  for _, output_buf in pairs(self.outputs) do
    output_buf:clear_float_win()
  end
end

--- Clear all virtual text outputs
function MoltenKernel:clear_virt_outputs()
  for cell, output_buf in pairs(self.outputs) do
    output_buf:clear_virt_output(cell.bufno)
  end
end

--- Get selected cell (cell containing cursor)
---@return table|nil CodeCell
function MoltenKernel:_get_selected_span()
  local current_position = self:_get_cursor_position()
  local selected = nil
  
  -- Find cell containing cursor (reverse order to prefer later cells)
  local cells = {}
  for span in pairs(self.outputs) do
    table.insert(cells, span)
  end
  
  for i = #cells, 1, -1 do
    local span = cells[i]
    if span:contains(current_position) then
      selected = span
      break
    end
  end
  
  return selected
end

--- Try to delete overlapping cells
---@param span table CodeCell
---@return boolean Success (false if overlaps with running cell)
function MoltenKernel:try_delete_overlapping_cells(span)
  local cells_to_delete = {}
  
  for output_span in pairs(self.outputs) do
    if output_span:overlaps(span) then
      table.insert(cells_to_delete, output_span)
    end
  end
  
  for _, cell in ipairs(cells_to_delete) do
    if not self:_delete_cell(cell) then
      return false
    end
  end
  
  return true
end

--- Delete a cell
---@param cell table CodeCell
---@param quiet boolean Don't show warnings
---@return boolean Success (false if cell is running)
function MoltenKernel:_delete_cell(cell, quiet)
  quiet = quiet or false
  
  if self.outputs[cell] and self.outputs[cell].output.status == outputchunks.OutputStatus.RUNNING then
    if not quiet then
      utils.notify_warn("Cannot delete a running cell. Wait for it to finish or use :MoltenInterrupt.")
    end
    return false
  end
  
  if self.outputs[cell] then
    self.outputs[cell]:clear_float_win()
    self.outputs[cell]:clear_virt_output(cell.bufno)
  end
  
  cell:clear_interface(self.highlight_namespace)
  self.outputs[cell] = nil
  
  if self.current_output == cell then
    self.current_output = nil
  end
  
  if self.selected_cell == cell then
    self.selected_cell = nil
  end
  
  return true
end

--- Delete current cell (cell at cursor)
function MoltenKernel:delete_current_cell()
  self.selected_cell = self:_get_selected_span()
  if not self.selected_cell then
    return
  end
  
  self:_delete_cell(self.selected_cell)
  self.selected_cell = nil
end

--- Clear empty cells
function MoltenKernel:clear_empty_spans()
  local to_delete = {}
  
  for span in pairs(self.outputs) do
    if span:empty() then
      table.insert(to_delete, span)
    end
  end
  
  for _, span in ipairs(to_delete) do
    self:_delete_cell(span, true)
  end
end

--- Clear all cells from a buffer
---@param buffer_number number
function MoltenKernel:clear_buffer(buffer_number)
  local to_delete = {}
  
  for cell in pairs(self.outputs) do
    if cell.bufno == buffer_number then
      table.insert(to_delete, cell)
    end
  end
  
  for _, cell in ipairs(to_delete) do
    self:_delete_cell(cell, true)
  end
end

--- Update interface - sync UI with state
function MoltenKernel:update_interface()
  local current_buf = vim.api.nvim_get_current_buf()
  
  -- Check if current buffer is managed by this kernel
  local is_managed = false
  for _, bufnr in ipairs(self.buffers) do
    if bufnr == current_buf then
      is_managed = true
      break
    end
  end
  
  if not is_managed then
    return
  end
  
  -- Check if current window's buffer is managed
  local win_buf = vim.api.nvim_win_get_buf(0)
  is_managed = false
  for _, bufnr in ipairs(self.buffers) do
    if bufnr == win_buf then
      is_managed = true
      break
    end
  end
  
  if not is_managed then
    return
  end
  
  self.updating_interface = true
  
  -- Clear empty cells
  self:clear_empty_spans()
  
  local new_selected_cell = self:_get_selected_span()
  
  -- Clear the cell we just left
  if self.selected_cell ~= new_selected_cell and self.selected_cell then
    if self.outputs[self.selected_cell] then
      self.outputs[self.selected_cell]:clear_float_win()
    end
    self.selected_cell:clear_interface(self.highlight_namespace)
  end
  
  if not new_selected_cell then
    self.should_show_floating_win = false
  end
  
  self.selected_cell = new_selected_cell
  
  -- Show selected cell if not done
  if self.selected_cell and self.output_statuses[self.selected_cell] ~= outputchunks.OutputStatus.DONE then
    self:_show_selected(self.selected_cell)
  end
  
  -- Show virtual text for all cells if enabled
  if self.options.virt_text_output then
    for span, output_buf in pairs(self.outputs) do
      output_buf:show_virtual_output(span.end_)
    end
  end
  
  -- Present canvas changes
  if self.canvas.present then
    self.canvas:present()
  end
  
  self.updating_interface = false
end

--- Handle cursor movement
---@param scrolled boolean Whether this was triggered by scrolling
function MoltenKernel:on_cursor_moved(scrolled)
  local new_selected_cell = self:_get_selected_span()
  
  -- Auto-open output when entering a cell
  if not self.selected_cell and new_selected_cell and self.options.auto_open_output then
    self.should_show_floating_win = true
  end
  
  -- If still in same cell and scrolled, update interface
  if self.selected_cell == new_selected_cell and new_selected_cell then
    if scrolled then
      local end_line = new_selected_cell.end_.lineno
      local win_bottom = vim.fn.line("w$")
      if end_line < win_bottom and self.should_show_floating_win then
        self:update_interface()
      end
    end
    return
  end
  
  self:update_interface()
end

--- Show selected cell with highlighting
---@param span table CodeCell
function MoltenKernel:_show_selected(span)
  local bufnr = vim.api.nvim_get_current_buf()
  
  -- Check if buffer is managed
  local is_managed = false
  for _, buf in ipairs(self.buffers) do
    if buf == bufnr then
      is_managed = true
      break
    end
  end
  
  if not is_managed then
    return
  end
  
  -- Highlight cell
  if span.begin.lineno == span.end_.lineno then
    -- Single line
    vim.api.nvim_buf_add_highlight(
      bufnr,
      self.highlight_namespace,
      self.options.hl.cell,
      span.begin.lineno,
      span.begin.colno,
      span.end_.colno
    )
  else
    -- Multi-line
    -- First line
    vim.api.nvim_buf_add_highlight(
      bufnr,
      self.highlight_namespace,
      self.options.hl.cell,
      span.begin.lineno,
      span.begin.colno,
      -1
    )
    
    -- Middle lines
    for lineno = span.begin.lineno + 1, span.end_.lineno - 1 do
      vim.api.nvim_buf_add_highlight(
        bufnr,
        self.highlight_namespace,
        self.options.hl.cell,
        lineno,
        0,
        -1
      )
    end
    
    -- Last line
    vim.api.nvim_buf_add_highlight(
      bufnr,
      self.highlight_namespace,
      self.options.hl.cell,
      span.end_.lineno,
      0,
      span.end_.colno
    )
  end
  
  -- Show or hide floating window
  if self.should_show_floating_win and self.outputs[span] then
    self.outputs[span]:show_floating_win(span.end_)
  elseif self.outputs[span] then
    self.outputs[span]:clear_float_win()
  end
end

--- Get content checksum for buffer
---@return string MD5 checksum
function MoltenKernel:_get_content_checksum()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, true)
  local content = table.concat(lines, "\n")
  
  -- Simple checksum (Lua doesn't have md5 built-in)
  -- This is a placeholder - for production, would use a proper hash
  return tostring(#content)
end

return M
