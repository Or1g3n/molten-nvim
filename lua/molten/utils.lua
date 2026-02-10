-- Utility functions for molten-nvim

local M = {}

--- Display an info notification
---@param msg string
function M.notify_info(msg)
  vim.schedule(function()
    vim.notify("[Molten] " .. msg, vim.log.levels.INFO, {})
  end)
end

--- Display a warning notification
---@param msg string
function M.notify_warn(msg)
  vim.schedule(function()
    vim.notify("[Molten] " .. msg, vim.log.levels.WARN, {})
  end)
end

--- Display an error notification
---@param msg string
function M.notify_error(msg)
  vim.schedule(function()
    vim.notify("[Molten] " .. msg, vim.log.levels.ERROR, {})
  end)
end

--- Generate a unique request ID
---@return string
function M.generate_request_id()
  return tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
end

--- Deep copy a table
---@param orig table
---@return table
function M.deepcopy(orig)
  local orig_type = type(orig)
  local copy
  if orig_type == "table" then
    copy = {}
    for orig_key, orig_value in next, orig, nil do
      copy[M.deepcopy(orig_key)] = M.deepcopy(orig_value)
    end
    setmetatable(copy, M.deepcopy(getmetatable(orig)))
  else
    copy = orig
  end
  return copy
end

--- Check if a value is in a list
---@param list table
---@param value any
---@return boolean
function M.contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

--- Get the Python interpreter path
---@return string
function M.get_python_command()
  -- Try vim.g.python3_host_prog first
  if vim.g.python3_host_prog and vim.g.python3_host_prog ~= "" then
    return vim.g.python3_host_prog
  end
  
  -- Try to find python3 or python in PATH
  local python_cmds = { "python3", "python" }
  for _, cmd in ipairs(python_cmds) do
    if vim.fn.executable(cmd) == 1 then
      return cmd
    end
  end
  
  return "python3" -- fallback
end

--- Find the molten bridge script path
---@return string|nil
function M.find_bridge_script()
  local scripts = vim.api.nvim_get_runtime_file("scripts/molten_bridge.py", false)
  if #scripts > 0 then
    return scripts[1]
  end
  return nil
end

return M
