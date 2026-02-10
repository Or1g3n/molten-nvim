-- Save and load functionality for molten-nvim
-- Saves cell outputs to JSON files

local M = {}

local outputchunks = require("molten.outputchunks")
local code_cell_module = require("molten.code_cell")
local position_module = require("molten.position")

--- Get default save file path
---@param options table MoltenOptions
---@param bufnr number Buffer number
---@return string|nil Path to save file, or nil on error
function M.get_default_save_file(options, bufnr)
  local buftype = vim.api.nvim_buf_get_option(bufnr, "buftype")
  if buftype == "nofile" then
    return nil
  end
  
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == "" then
    return nil
  end
  
  -- Mangle the buffer name
  local mangled_name = bufname:gsub("%%", "%%%%"):gsub("/", "%%")
  
  -- Ensure save path exists
  local save_path = options.save_path or vim.fn.stdpath("data") .. "/molten"
  vim.fn.mkdir(save_path, "p")
  
  return save_path .. "/" .. mangled_name .. ".json"
end

--- Save kernel outputs to JSON file
---@param molten_kernel table MoltenKernel instance
---@param filepath string|nil Path to save to (nil for default)
---@return boolean success
function M.save(molten_kernel, filepath)
  local bufnr = molten_kernel.buffers[1]
  
  if not filepath then
    filepath = M.get_default_save_file(molten_kernel.options, bufnr)
    if not filepath then
      return false, "Cannot determine save file for this buffer"
    end
  end
  
  -- Get buffer content checksum (simple version)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  local content = table.concat(lines, "\n")
  local checksum = tostring(#content) -- Simple checksum
  
  -- Serialize cells
  local cells_data = {}
  for cell, output_buf in pairs(molten_kernel.outputs) do
    local output = output_buf.output
    
    -- Only save cells with jupyter-serializable data
    local chunks_data = {}
    for _, chunk in ipairs(output.chunks) do
      if chunk.jupyter_data then
        table.insert(chunks_data, {
          data = chunk.jupyter_data,
          metadata = chunk.jupyter_metadata or {},
        })
      end
    end
    
    if #chunks_data > 0 then
      table.insert(cells_data, {
        span = {
          begin = {
            lineno = cell.begin.lineno,
            colno = cell.begin.colno,
          },
          end_ = {
            lineno = cell.end_.lineno,
            colno = cell.end_.colno,
          },
        },
        execution_count = output.execution_count,
        status = output.status,
        success = output.success,
        chunks = chunks_data,
      })
    end
  end
  
  -- Create save data
  local save_data = {
    version = 1,
    kernel = molten_kernel.kernel_name,
    content_checksum = checksum,
    cells = cells_data,
  }
  
  -- Write to file
  local json_str = vim.fn.json_encode(save_data)
  local file = io.open(filepath, "w")
  if not file then
    return false, "Failed to open file for writing"
  end
  
  file:write(json_str)
  file:close()
  
  return true
end

--- Load kernel outputs from JSON file
---@param molten_kernel table MoltenKernel instance
---@param filepath string|nil Path to load from (nil for default)
---@param verify_checksum boolean Whether to verify content checksum
---@return boolean success
function M.load(molten_kernel, filepath, verify_checksum)
  verify_checksum = verify_checksum ~= false -- Default true
  local bufnr = molten_kernel.buffers[1]
  
  if not filepath then
    filepath = M.get_default_save_file(molten_kernel.options, bufnr)
    if not filepath then
      return false, "Cannot determine save file for this buffer"
    end
  end
  
  -- Check if file exists
  local file = io.open(filepath, "r")
  if not file then
    return false, "Save file does not exist"
  end
  
  local json_str = file:read("*a")
  file:close()
  
  -- Parse JSON
  local ok, save_data = pcall(vim.fn.json_decode, json_str)
  if not ok then
    return false, "Failed to parse save file"
  end
  
  -- Verify checksum if requested
  if verify_checksum then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
    local content = table.concat(lines, "\n")
    local checksum = tostring(#content)
    
    if checksum ~= save_data.content_checksum then
      return false, "Buffer content has changed since save"
    end
  end
  
  -- Load cells
  for _, cell_data in ipairs(save_data.cells or {}) do
    -- Create cell span with DynamicPosition
    local begin_pos = position_module.DynamicPosition(
      molten_kernel.extmark_namespace,
      bufnr,
      cell_data.span.begin.lineno,
      cell_data.span.begin.colno
    )
    
    local end_pos = position_module.DynamicPosition(
      molten_kernel.extmark_namespace,
      bufnr,
      cell_data.span.end_.lineno,
      cell_data.span.end_.colno,
      true -- right_gravity
    )
    
    local cell = code_cell_module.new(begin_pos, end_pos)
    
    -- Create output
    local output = outputchunks.Output(cell_data.execution_count)
    output.status = cell_data.status
    output.success = cell_data.success
    output.old = true -- Mark as old (loaded from save)
    
    -- Load chunks
    for _, chunk_data in ipairs(cell_data.chunks or {}) do
      local chunk = outputchunks.to_outputchunk(
        chunk_data.data,
        chunk_data.metadata,
        molten_kernel.options
      )
      table.insert(output.chunks, chunk)
    end
    
    -- Create OutputBuffer for this cell
    local outputbuffer_module = require("molten.outputbuffer")
    local output_buf = outputbuffer_module.new(
      molten_kernel.canvas,
      molten_kernel.extmark_namespace,
      molten_kernel.options
    )
    output_buf.output = output
    
    molten_kernel.outputs[cell] = output_buf
  end
  
  return true
end

return M
