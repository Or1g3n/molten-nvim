-- Output buffer management for molten-nvim
-- Handles both virtual text and floating window output display

local M = {}

local outputchunks = require("molten.outputchunks")
local Position = require("molten.position").Position

--- Truncate lines from bottom
---@param lines table
---@param max_lines number
---@return table
local function truncate_bottom(lines, max_lines)
  local truncated = {}
  for i = 1, max_lines - 1 do
    table.insert(truncated, lines[i])
  end
  table.insert(truncated, string.format("󰁅 %d More lines ", #lines - max_lines + 1))
  return truncated
end

--- Truncate lines from top
---@param lines table
---@param max_lines number
---@return table
local function truncate_top(lines, max_lines)
  local truncated = { lines[1] }
  table.insert(truncated, string.format("↑ %d More lines", #lines - max_lines))
  for i = #lines - max_lines + 3, #lines do
    table.insert(truncated, lines[i])
  end
  return truncated
end

---@class OutputBuffer
---@field output table Output object
---@field display_buf number Buffer number for output display
---@field display_win number|nil Window handle for floating output
---@field display_virt_lines table|nil DynamicPosition for virtual lines
---@field extmark_namespace number Extmark namespace
---@field virt_text_id number|nil Extmark ID for virtual text
---@field virt_hidden boolean Whether virtual text is hidden
---@field displayed_status string Last displayed status
---@field options table MoltenOptions
---@field canvas table Canvas for image rendering
local OutputBuffer = {}
OutputBuffer.__index = OutputBuffer

--- Create a new OutputBuffer
---@param canvas table Canvas instance
---@param extmark_namespace number Extmark namespace
---@param options table MoltenOptions
---@return OutputBuffer
function M.new(canvas, extmark_namespace, options)
  local self = setmetatable({}, OutputBuffer)
  
  self.output = outputchunks.Output(nil)
  
  -- Create a scratch buffer for output display
  self.display_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(self.display_buf, 'bufhidden', 'wipe')
  
  self.display_win = nil
  self.display_virt_lines = nil
  self.extmark_namespace = extmark_namespace
  self.virt_text_id = nil
  self.virt_hidden = false
  self.displayed_status = outputchunks.OutputStatus.HOLD
  
  self.options = options
  self.canvas = canvas
  
  -- Set truncation function
  if options.virt_text_truncate == "bottom" then
    self.truncate_lines = truncate_bottom
  elseif options.virt_text_truncate == "top" then
    self.truncate_lines = truncate_top
  else
    self.truncate_lines = truncate_bottom -- default
  end
  
  return self
end

--- Calculate window position for a buffer line number
---@param lineno number Buffer line number
---@return number Window line number
function OutputBuffer:_buffer_to_window_lineno(lineno)
  -- Get window info and calculate position
  local win = vim.api.nvim_get_current_win()
  local win_info = vim.fn.getwininfo(win)[1]
  
  if not win_info then
    return lineno
  end
  
  -- Calculate relative position in window
  local topline = win_info.topline
  return lineno - topline + 1
end

--- Get header text for output
---@param output table Output object
---@return string Header text
function OutputBuffer:_get_header_text(output)
  local execution_count = output.execution_count or "..."
  
  local status
  if output.status == outputchunks.OutputStatus.HOLD then
    status = "* On Hold"
  elseif output.status == outputchunks.OutputStatus.DONE then
    if output.success then
      status = "✓ Done"
    else
      status = "✗ Failed"
    end
  elseif output.status == outputchunks.OutputStatus.RUNNING then
    status = "... Running"
  elseif output.status == outputchunks.OutputStatus.NEW then
    status = ""
  else
    status = "Unknown"
  end
  
  local old = output.old and "[OLD] " or ""
  
  local time = ""
  if not output.old and self.options.output_show_exec_time and output.start_time then
    local start_time = output.start_time
    local end_time = output.end_time or os.time()
    local diff = end_time - start_time
    
    if diff > 0 then
      local seconds = diff
      local minutes = math.floor(seconds / 60)
      seconds = seconds - minutes * 60
      
      if minutes > 0 then
        time = string.format("%dm %.1fs", minutes, seconds)
      else
        time = string.format("%.1fs", seconds)
      end
    end
  end
  
  if output.status == outputchunks.OutputStatus.NEW then
    return "Out[_]: Never Run"
  else
    return string.format("%sOut[%s]: %s %s", old, execution_count, status, time):gsub("%s+$", "")
  end
end

--- Build output text from chunks
---@param shape table Window shape {col, row, width, height}
---@param bufnr number Buffer number
---@param virtual boolean Whether this is for virtual text
---@return table lines, number virtual_lines
function OutputBuffer:build_output_text(shape, bufnr, virtual)
  local lines_str = ""
  local virtual_lines = 0
  
  if #self.output.chunks > 0 then
    local x = 0
    for _, chunk in ipairs(self.output.chunks) do
      local y = virtual and shape[2] or 1
      local winnr = virtual and vim.api.nvim_get_current_win() or nil
      
      local chunktext, virt_lines = chunk:place(self.options, x, shape, false)
      
      lines_str = lines_str .. chunktext
      virtual_lines = virtual_lines + virt_lines
      
      -- Update x position
      local last_newline = lines_str:reverse():find("\n")
      if last_newline then
        x = #lines_str - (#lines_str - last_newline + 1)
      else
        x = #lines_str
      end
    end
    
    -- Apply character limit
    local limit = self.options.limit_output_chars
    if limit and #lines_str > limit then
      lines_str = lines_str:sub(1, limit)
      lines_str = lines_str .. string.format("\n...truncated to %d chars\n", limit)
    end
  end
  
  local lines = vim.split(lines_str, "\n", { plain = true })
  
  -- Remove trailing empty lines
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  
  -- HACK: add extra line for snacks images
  if self.options.image_provider == "snacks.nvim" then
    table.insert(lines, "")
  end
  
  -- Add header at top
  table.insert(lines, 1, self:_get_header_text(self.output))
  
  return lines, #lines - 1 + virtual_lines
end

--- Calculate offset for covering empty lines
---@param anchor Position Anchor position
---@return number Offset
function OutputBuffer:calculate_offset(anchor)
  local offset = 0
  local lineno = anchor.lineno
  
  while lineno > 0 do
    local current_line = vim.api.nvim_buf_get_lines(anchor.bufno, lineno, lineno + 1, false)[1]
    
    if not current_line then
      break
    end
    
    local is_comment = false
    for _, prefix in ipairs(self.options.cover_lines_starting_with) do
      if vim.startswith(current_line, prefix) then
        is_comment = true
        break
      end
    end
    
    if current_line ~= "" and not is_comment then
      return offset
    else
      lineno = lineno - 1
      offset = offset - 1
    end
  end
  
  return 0
end

--- Show virtual text output
---@param anchor Position Anchor position
function OutputBuffer:show_virtual_output(anchor)
  if self.virt_hidden then
    return
  end
  
  if self.displayed_status == outputchunks.OutputStatus.DONE and self.virt_text_id then
    return
  end
  
  local offset = self.options.cover_empty_lines and self:calculate_offset(anchor) or 0
  self.displayed_status = self.output.status
  
  -- Clear existing virtual text
  if self.virt_text_id then
    vim.api.nvim_buf_del_extmark(anchor.bufno, self.extmark_namespace, self.virt_text_id)
    self.virt_text_id = nil
  end
  
  local win = vim.api.nvim_get_current_win()
  local win_info = vim.fn.getwininfo(win)[1]
  
  if not win_info then
    return
  end
  
  local win_col = win_info.wincol
  local win_row = anchor.lineno + offset
  local win_width = win_info.width - win_info.textoff
  local win_height = win_info.height
  local last = vim.fn.line("$")
  
  if self.options.virt_lines_off_by_1 and win_row < last - 1 then
    win_row = win_row + 1
  end
  
  if win_row > last then
    win_row = last
  end
  
  local shape = { win_col, win_row, win_width, win_height }
  local lines, _ = self:build_output_text(shape, anchor.bufno, true)
  
  if #lines > self.options.virt_text_max_lines then
    lines = self.truncate_lines(lines, self.options.virt_text_max_lines)
  end
  
  -- Create virtual lines
  local virt_lines = {}
  for _, line in ipairs(lines) do
    table.insert(virt_lines, { { line, self.options.hl.virtual_text } })
  end
  
  self.virt_text_id = vim.api.nvim_buf_set_extmark(anchor.bufno, self.extmark_namespace, win_row, 0, {
    virt_lines = virt_lines,
  })
  
  if self.canvas.present then
    self.canvas:present()
  end
end

--- Clear virtual text output
---@param bufnr number Buffer number
function OutputBuffer:clear_virt_output(bufnr)
  if self.virt_text_id then
    vim.api.nvim_buf_del_extmark(bufnr, self.extmark_namespace, self.virt_text_id)
    self.virt_text_id = nil
    self.virt_hidden = true
  end
  
  -- Clear any images
  local redraw = false
  for _, chunk in ipairs(self.output.chunks) do
    if chunk.img_identifier and self.canvas.remove_image then
      self.canvas:remove_image(chunk.img_identifier)
      redraw = true
    end
  end
  
  if redraw and self.canvas.present then
    self.canvas:present()
  end
end

--- Toggle virtual output visibility
---@param anchor Position Anchor position
function OutputBuffer:toggle_virtual_output(anchor)
  if self.virt_hidden then
    self.virt_hidden = false
    self:show_virtual_output(anchor)
  else
    self:clear_virt_output(anchor.bufno)
  end
end

--- Calculate border size
---@param border string|table Border configuration
---@return number width, number height
local function border_size(border)
  local width, height = 0, 0
  
  if type(border) == "table" then
    -- Count non-empty border characters
    local function char_size(idx)
      local item = border[idx % #border + 1]
      if type(item) == "string" then
        return #item
      elseif type(item) == "table" and type(item[1]) == "string" then
        return #item[1]
      end
      return 0
    end
    
    height = height + char_size(1) + char_size(5)
    width = width + char_size(7) + char_size(3)
  elseif border == "rounded" or border == "single" or border == "double" or border == "solid" then
    height = 2
    width = 2
  elseif border == "shadow" then
    height = 1
    width = 1
  end
  
  return width, height
end

--- Set border highlight colors
---@param border table Border configuration
---@return table Modified border
function OutputBuffer:set_border_highlight(border)
  local hl = self.options.hl.border_norm
  
  if not self.output.success then
    hl = self.options.hl.border_fail
  elseif self.output.status == outputchunks.OutputStatus.DONE then
    hl = self.options.hl.border_succ
  end
  
  if type(border) ~= "table" then
    require("molten.utils").notify_error("use_border_highlights only works with table borders")
    return border
  end
  
  local new_border = {}
  for i, item in ipairs(border) do
    if type(item) == "table" then
      new_border[i] = { item[1], hl }
    else
      new_border[i] = { item, hl }
    end
  end
  
  return new_border
end

--- Show floating window output
---@param anchor Position Anchor position
function OutputBuffer:show_floating_win(anchor)
  local win = vim.api.nvim_get_current_win()
  local win_col = 0
  local offset = 0
  
  if self.options.cover_empty_lines then
    offset = self:calculate_offset(anchor)
  end
  
  local win_row = self:_buffer_to_window_lineno(anchor.lineno + offset) + 1
  
  if win_row <= 0 then
    return -- anchor off screen
  end
  
  local win_width = vim.api.nvim_win_get_width(win)
  local win_height = vim.api.nvim_win_get_height(win)
  
  local border_w, border_h = border_size(self.options.output_win_border)
  
  win_height = win_height - border_h
  win_width = win_width - border_w
  
  -- Clear buffer
  vim.api.nvim_buf_set_lines(self.display_buf, 0, -1, false, {})
  
  local sign_col_width = 0
  local win_info = vim.fn.getwininfo(win)[1]
  if win_info and not self.options.output_win_cover_gutter then
    sign_col_width = win_info.textoff or 0
  end
  
  local shape = {
    win_col + sign_col_width,
    win_row,
    win_width - sign_col_width,
    win_height,
  }
  
  local lines, real_height = self:build_output_text(shape, self.display_buf, false)
  
  -- Set lines in buffer
  if #lines > 0 then
    vim.api.nvim_buf_set_lines(self.display_buf, 0, 0, false, { lines[1] })
    if #lines > 1 then
      vim.api.nvim_buf_set_lines(self.display_buf, 1, 1, false, vim.list_slice(lines, 2))
    end
  end
  
  vim.api.nvim_buf_set_option(self.display_buf, 'filetype', 'molten_output')
  
  if win_row >= win_height then
    return
  end
  
  local border = self.options.output_win_border
  local zindex = self.options.output_win_zindex
  local max_height = math.min(real_height + 1, self.options.output_win_max_height)
  local height = math.min(win_height - win_row, max_height)
  
  local cropped = false
  if height == win_height - win_row and max_height > height then
    if self.options.output_crop_border and type(border) == "table" then
      cropped = true
      -- Expand border for cropping
      local expanded_border = {}
      for i = 1, 8 do
        expanded_border[i] = border[(i - 1) % #border + 1]
      end
      expanded_border[6] = ""
      border = expanded_border
      height = height + 1
    end
  end
  
  if self.options.use_border_highlights then
    border = self:set_border_highlight(border)
  end
  
  local win_opts = {
    relative = "win",
    row = shape[2],
    col = shape[1],
    width = math.min(shape[3], self.options.output_win_max_width),
    height = height,
    border = border,
    focusable = true,
    zindex = zindex,
  }
  
  if self.options.output_win_style then
    win_opts.style = self.options.output_win_style
  end
  
  -- Add footer for "More Lines" indicator
  if self.options.output_show_more and not cropped and height == self.options.output_win_max_height then
    local buf_lines = vim.api.nvim_buf_line_count(self.display_buf)
    local hidden_lines = buf_lines - height
    if hidden_lines > 0 then
      win_opts.footer = { { string.format(" 󰁅 %d More Lines ", hidden_lines), self.options.hl.foot } }
      win_opts.footer_pos = "left"
    end
  end
  
  -- Create or update window
  if not self.display_win or not vim.api.nvim_win_is_valid(self.display_win) then
    self.display_win = vim.api.nvim_open_win(self.display_buf, false, win_opts)
    
    local hl = self.options.hl
    vim.api.nvim_win_set_option(
      self.display_win,
      "winhighlight",
      string.format("Normal:%s,NormalNC:%s", hl.win, hl.win_nc)
    )
    vim.api.nvim_win_set_option(self.display_win, "wrap", self.options.wrap_output)
    vim.api.nvim_win_set_option(self.display_win, "cursorline", false)
    
    if self.canvas.present then
      self.canvas:present()
    end
  else
    vim.api.nvim_win_set_config(self.display_win, win_opts)
  end
  
  -- Handle virtual lines
  if self.display_virt_lines then
    self.display_virt_lines:delete()
    self.display_virt_lines = nil
  end
  
  if self.options.output_virt_lines or self.options.cover_empty_lines then
    local virt_lines_y = anchor.lineno
    if self.options.cover_empty_lines then
      virt_lines_y = virt_lines_y + offset
    end
    local virt_lines_height = max_height + border_h
    if self.options.virt_lines_off_by_1 then
      virt_lines_y = virt_lines_y + 1
      virt_lines_height = virt_lines_height - 1
    end
    
    local DynamicPosition = require("molten.position").DynamicPosition
    self.display_virt_lines = DynamicPosition(self.extmark_namespace, anchor.bufno, virt_lines_y, 0)
    self.display_virt_lines:set_height(virt_lines_height)
  end
  
  -- Set cursor position
  if self.options.floating_window_focus == "top" then
    vim.api.nvim_win_set_cursor(self.display_win, { 1, 0 })
  elseif self.options.floating_window_focus == "bottom" then
    local line_count = vim.api.nvim_buf_line_count(self.display_buf)
    vim.api.nvim_win_set_cursor(self.display_win, { line_count, 0 })
  end
end

--- Clear floating window
function OutputBuffer:clear_float_win()
  if self.display_win and vim.api.nvim_win_is_valid(self.display_win) then
    vim.api.nvim_win_close(self.display_win, true)
    self.display_win = nil
    
    local redraw = false
    for _, chunk in ipairs(self.output.chunks) do
      if chunk.img_identifier and self.canvas.remove_image then
        self.canvas:remove_image(chunk.img_identifier)
        redraw = true
      end
    end
    
    if redraw and self.canvas.present then
      self.canvas:present()
    end
  end
  
  if self.display_virt_lines then
    self.display_virt_lines:delete()
    self.display_virt_lines = nil
  end
end

--- Enter the output window
---@param anchor Position Anchor position
---@return boolean Whether to keep showing on leave
function OutputBuffer:enter(anchor)
  local entered = false
  
  if not self.display_win then
    if self.options.enter_output_behavior == "open_then_enter" then
      self:show_floating_win(anchor)
    elseif self.options.enter_output_behavior == "open_and_enter" then
      self:show_floating_win(anchor)
      if self.display_win then
        entered = true
        vim.api.nvim_set_current_win(self.display_win)
      end
    end
  elseif self.options.enter_output_behavior ~= "no_open" then
    entered = true
    vim.api.nvim_set_current_win(self.display_win)
  end
  
  if entered then
    if self.options.output_show_more then
      self:remove_window_footer()
    end
    if self.options.output_win_hide_on_leave then
      return false
    end
  end
  
  return true
end

--- Remove footer from window
function OutputBuffer:remove_window_footer()
  if self.display_win and vim.api.nvim_win_is_valid(self.display_win) then
    vim.api.nvim_win_set_config(self.display_win, { footer = "" })
  end
end

return M
