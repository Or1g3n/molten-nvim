-- ipynb.lua - Jupyter notebook import/export support
-- Provides functionality to import outputs from .ipynb files and export to .ipynb files

local utils = require("molten.utils")
local OutputBuffer = require("molten.outputbuffer")
local CodeCell = require("molten.code_cell")
local DynamicPosition = require("molten.position").DynamicPosition
local Output = require("molten.outputchunks").Output
local OutputStatus = require("molten.outputchunks").OutputStatus
local to_outputchunk = require("molten.outputchunks").to_outputchunk
local ErrorOutputChunk = require("molten.outputchunks").ErrorOutputChunk

local M = {}

local NOTEBOOK_VERSION = 4

---Get default import/export file path (same directory as current file with .ipynb extension)
---@param bufnr number Buffer number
---@return string|nil filepath or nil if not a file buffer
function M.get_default_import_export_file(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buftype = vim.bo[bufnr].buftype
  
  if buftype and buftype ~= "" then
    utils.notify_error("Buffer does not correspond to a file")
    return nil
  end
  
  local file_name = vim.fn.expand("%")
  if file_name == "" then
    utils.notify_error("Buffer does not have a filename")
    return nil
  end
  
  local cwd = vim.fn.getcwd()
  local full_path = vim.fn.fnamemodify(cwd .. "/" .. file_name, ":p")
  local base = vim.fn.fnamemodify(full_path, ":r")
  return base .. ".ipynb"
end

---Read and parse a .ipynb file
---@param filepath string Path to .ipynb file
---@return table|nil notebook Parsed notebook or nil on error
local function read_notebook(filepath)
  if not filepath:match("%.ipynb$") then
    filepath = filepath .. ".ipynb"
  end
  
  if vim.fn.filereadable(filepath) ~= 1 then
    utils.notify_warn(string.format("Cannot import from file: %s because it does not exist.", filepath))
    return nil
  end
  
  local file = io.open(filepath, "r")
  if not file then
    utils.notify_error(string.format("Cannot open file: %s", filepath))
    return nil
  end
  
  local content = file:read("*a")
  file:close()
  
  local ok, notebook = pcall(vim.fn.json_decode, content)
  if not ok or not notebook then
    utils.notify_error(string.format("Failed to parse notebook: %s", filepath))
    return nil
  end
  
  return notebook
end

---Write a notebook to a .ipynb file
---@param filepath string Path to .ipynb file
---@param notebook table Notebook data structure
---@return boolean success
local function write_notebook(filepath, notebook)
  if not filepath:match("%.ipynb$") then
    filepath = filepath .. ".ipynb"
  end
  
  local content = vim.fn.json_encode(notebook)
  
  local file = io.open(filepath, "w")
  if not file then
    utils.notify_error(string.format("Cannot write to file: %s", filepath))
    return false
  end
  
  file:write(content)
  file:close()
  
  return true
end

---Handle different output types from notebook
---@param output_type string Type of output (stream, error, execute_result, display_data)
---@param output_data table Output data from notebook
---@param kernel table MoltenKernel instance
---@return table chunk Output chunk
---@return boolean success Whether output represents success
local function handle_output_types(output_type, output_data, kernel)
  local chunk
  local success = true
  
  if output_type == "stream" then
    -- Stream output (stdout/stderr)
    chunk = to_outputchunk(
      { ["text/plain"] = output_data.text },
      output_data.metadata or {},
      kernel.runtime
    )
  elseif output_type == "error" then
    -- Error output
    chunk = ErrorOutputChunk.new(
      output_data.ename,
      output_data.evalue,
      output_data.traceback
    )
    chunk.extras = output_data
    success = false
  else
    -- execute_result, display_data, etc.
    chunk = to_outputchunk(
      output_data.data or {},
      output_data.metadata or {},
      kernel.runtime
    )
  end
  
  return chunk, success
end

---Import outputs from a .ipynb file
---@param kernel table MoltenKernel instance
---@param filepath string Path to .ipynb file
function M.import_outputs(kernel, filepath)
  local notebook = read_notebook(filepath)
  if not notebook then
    return
  end
  
  if not notebook.cells or #notebook.cells == 0 then
    utils.notify_warn("Notebook has no cells")
    return
  end
  
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer_contents = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local buf_line = 0
  
  local molten_outputs = {}  -- Map of CodeCell to Output
  
  for _, cell in ipairs(notebook.cells) do
    if cell.cell_type == "code" and cell.outputs then
      -- Split notebook cell source into lines
      local nb_contents = {}
      if type(cell.source) == "string" then
        nb_contents = vim.split(cell.source, "\n", { plain = true })
      elseif type(cell.source) == "table" then
        for _, line in ipairs(cell.source) do
          -- Remove trailing newlines that nbformat includes
          line = line:gsub("\n$", "")
          table.insert(nb_contents, line)
        end
      end
      
      -- Try to find matching code in buffer
      local nb_line = 0
      while buf_line < #buffer_contents do
        if #nb_contents == 0 then
          break
        end
        
        if nb_contents[nb_line + 1] ~= buffer_contents[buf_line + 1] then
          -- No match, move to next buffer line and reset nb_line
          nb_line = 0
          buf_line = buf_line + 1
        else
          -- Lines match
          if nb_line >= #nb_contents - 1 then
            -- We found a complete match! Create the output
            local output = Output.new(cell.execution_count)
            output.old = true
            output.success = true
            
            if output.execution_count then
              output.status = OutputStatus.DONE
            else
              output.status = OutputStatus.NEW
            end
            
            -- Process all outputs for this cell
            for _, output_data in ipairs(cell.outputs) do
              local chunk, success = handle_output_types(
                output_data.output_type,
                output_data,
                kernel
              )
              table.insert(output.chunks, chunk)
              output.success = output.success and success
            end
            
            -- Create CodeCell for this output
            local start_line = buf_line - (#nb_contents - 1)
            local end_line = buf_line
            local end_col = #buffer_contents[end_line + 1]
            
            local start = DynamicPosition.new(
              kernel.extmark_namespace,
              bufnr,
              start_line,
              0
            )
            local end_pos = DynamicPosition.new(
              kernel.extmark_namespace,
              bufnr,
              end_line,
              end_col
            )
            
            local code_cell = CodeCell.new(start, end_pos)
            molten_outputs[code_cell] = output
            
            nb_line = 0
            buf_line = buf_line + 1
            break  -- Out of while loop, move to next notebook cell
          end
          
          buf_line = buf_line + 1
          nb_line = nb_line + 1
        end
      end
    end
  end
  
  -- Add outputs to kernel, checking for overlaps
  local failed = 0
  for span, output in pairs(molten_outputs) do
    if kernel:try_delete_overlapping_cells(span) then
      local output_buffer = OutputBuffer.new(
        kernel.canvas,
        kernel.extmark_namespace,
        kernel.options
      )
      output_buffer.output = output
      kernel.outputs[span] = output_buffer
      kernel:update_interface()
    else
      failed = failed + 1
    end
  end
  
  local loaded = vim.tbl_count(molten_outputs) - failed
  
  if vim.tbl_count(molten_outputs) == 0 then
    utils.notify_warn("No cell outputs to import")
  elseif loaded > 0 then
    utils.notify_info(string.format("Successfully loaded %d output cells", loaded))
  end
  
  if failed > 0 then
    utils.notify_error(
      string.format("Failed to load output for %d running cells that would be overridden", failed)
    )
  end
end

---Compare contents of notebook cell and buffer cell (ignoring comments)
---@param nb_cell table Notebook cell
---@param code_cell table CodeCell instance
---@param lang string Programming language
---@return boolean match Whether contents match
local function compare_contents(nb_cell, code_cell, lang)
  -- Get molten cell text
  local molten_contents = code_cell:get_text()
  
  -- Get notebook cell source
  local nb_source = ""
  if type(nb_cell.source) == "string" then
    nb_source = nb_cell.source
  elseif type(nb_cell.source) == "table" then
    nb_source = table.concat(nb_cell.source, "")
  end
  
  -- Remove comments using treesitter
  local remove_comments = require("remove_comments").remove_comments
  local clean_nb = remove_comments(nb_source .. "\n", lang)
  local clean_molten = remove_comments(molten_contents .. "\n", lang)
  
  return clean_nb == clean_molten
end

---Export outputs to a .ipynb file
---@param kernel table MoltenKernel instance
---@param filepath string Path to .ipynb file
---@param overwrite boolean Whether to overwrite the original file
function M.export_outputs(kernel, filepath, overwrite)
  if not filepath:match("%.ipynb$") then
    filepath = filepath .. ".ipynb"
  end
  
  local notebook = read_notebook(filepath)
  if not notebook then
    return
  end
  
  -- Sort cells by position
  local molten_cells = {}
  for cell, output_buf in pairs(kernel.outputs) do
    table.insert(molten_cells, { cell, output_buf })
  end
  table.sort(molten_cells, function(a, b)
    return a[1].begin.lineno < b[1].begin.lineno
  end)
  
  if #molten_cells == 0 then
    utils.notify_warn("No cell outputs to export")
    return
  end
  
  -- Filter to only code cells
  local nb_cells = {}
  for _, cell in ipairs(notebook.cells or {}) do
    if cell.cell_type == "code" then
      table.insert(nb_cells, cell)
    end
  end
  
  -- Get kernel language for comment removal
  local lang = kernel.runtime.kernel_name or "python"
  
  -- Match molten cells to notebook cells
  local nb_index = 1
  for _, mcell_data in ipairs(molten_cells) do
    local code_cell, output_buf = mcell_data[1], mcell_data[2]
    local matched = false
    
    while nb_index <= #nb_cells do
      local nb_cell = nb_cells[nb_index]
      nb_index = nb_index + 1
      
      if compare_contents(nb_cell, code_cell, lang) then
        matched = true
        
        -- Build outputs array for notebook
        local outputs = {}
        for _, chunk in ipairs(output_buf.output.chunks) do
          local output_entry = {
            output_type = chunk.output_type,
          }
          
          -- Add output data
          if chunk.jupyter_data then
            for k, v in pairs(chunk.jupyter_data) do
              output_entry[k] = v
            end
          end
          
          -- Add metadata if present
          if chunk.jupyter_metadata then
            output_entry.metadata = chunk.jupyter_metadata
          end
          
          -- Add any extras (for error outputs)
          if chunk.extras then
            for k, v in pairs(chunk.extras) do
              output_entry[k] = v
            end
          end
          
          table.insert(outputs, output_entry)
        end
        
        nb_cell.outputs = outputs
        nb_cell.execution_count = output_buf.output.execution_count
        break
      end
    end
    
    if not matched then
      utils.notify_error(
        string.format(
          "No cell matching cell at line: %d in notebook: %s. Bailing.",
          code_cell.begin.lineno + 1,
          filepath
        )
      )
      return
    end
  end
  
  -- Determine output path
  local write_to = filepath
  if not overwrite then
    local dir = vim.fn.fnamemodify(filepath, ":h")
    local tail = vim.fn.fnamemodify(filepath, ":t")
    write_to = dir .. "/copy-of-" .. tail
  end
  
  utils.notify_info(string.format("Exporting %d cell output(s) to %s", #molten_cells, write_to))
  
  if not write_notebook(write_to, notebook) then
    utils.notify_error("Failed to write notebook")
  end
end

return M
