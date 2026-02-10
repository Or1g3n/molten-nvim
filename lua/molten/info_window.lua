-- Info window for molten-nvim
-- Displays kernel information

local M = {}

--- Show kernel info in a floating window
---@param molten_kernel table MoltenKernel instance
function M.show_info(molten_kernel)
  local lines = {}
  
  -- Kernel info
  table.insert(lines, "Kernel Information")
  table.insert(lines, string.rep("=", 50))
  table.insert(lines, "")
  table.insert(lines, "Kernel Name: " .. molten_kernel.kernel_name)
  table.insert(lines, "Kernel ID: " .. molten_kernel.kernel_id)
  table.insert(lines, "")
  
  -- Buffer info
  table.insert(lines, "Attached Buffers:")
  for _, bufnr in ipairs(molten_kernel.buffers) do
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if bufname == "" then
      bufname = "[No Name]"
    end
    table.insert(lines, "  - " .. bufname .. " (" .. bufnr .. ")")
  end
  table.insert(lines, "")
  
  -- Cell count
  local cell_count = 0
  for _ in pairs(molten_kernel.outputs) do
    cell_count = cell_count + 1
  end
  table.insert(lines, "Cells: " .. cell_count)
  
  -- Execution status
  local running_count = 0
  local done_count = 0
  for _, output_buf in pairs(molten_kernel.outputs) do
    local status = output_buf.output.status
    if status == 2 then -- RUNNING
      running_count = running_count + 1
    elseif status == 3 then -- DONE
      done_count = done_count + 1
    end
  end
  table.insert(lines, "Running: " .. running_count)
  table.insert(lines, "Complete: " .. done_count)
  
  -- Create buffer for info window
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)
  vim.api.nvim_buf_set_option(bufnr, 'bufhidden', 'wipe')
  
  -- Calculate window size
  local width = 60
  local height = #lines + 2
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  
  -- Open floating window
  local win_opts = {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' Molten Info ',
    title_pos = 'center',
  }
  
  local winnr = vim.api.nvim_open_win(bufnr, true, win_opts)
  
  -- Set keybindings to close
  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'q', ':close<CR>', { noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(bufnr, 'n', '<Esc>', ':close<CR>', { noremap = true, silent = true })
  
  return winnr
end

return M
