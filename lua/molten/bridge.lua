-- Bridge manager for molten-nvim Python subprocess

local utils = require("molten.utils")

local M = {}

---@class Bridge
---@field job_id number|nil
---@field running boolean
---@field pending_requests table
---@field event_handlers table
---@field buffer string
local Bridge = {}
Bridge.__index = Bridge

--- Create a new bridge instance
---@return Bridge|nil
function M.new()
  local self = setmetatable({}, Bridge)
  
  self.job_id = nil
  self.running = false
  self.pending_requests = {}
  self.event_handlers = {}
  self.buffer = ""
  
  return self
end

--- Start the bridge subprocess
---@return boolean success
function Bridge:start()
  if self.running then
    utils.notify_warn("Bridge already running")
    return false
  end
  
  local python_cmd = utils.get_python_command()
  local bridge_script = utils.find_bridge_script()
  
  if not bridge_script then
    utils.notify_error("Could not find molten_bridge.py script")
    return false
  end
  
  local self_ref = self
  
  self.job_id = vim.fn.jobstart({ python_cmd, bridge_script }, {
    on_stdout = function(_, data, _)
      self_ref:on_stdout(data)
    end,
    on_stderr = function(_, data, _)
      self_ref:on_stderr(data)
    end,
    on_exit = function(_, code, _)
      self_ref:on_exit(code)
    end,
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = false,
  })
  
  if self.job_id <= 0 then
    utils.notify_error("Failed to start bridge subprocess")
    return false
  end
  
  self.running = true
  return true
end

--- Stop the bridge subprocess
function Bridge:stop()
  if not self.running then
    return
  end
  
  -- Send quit command
  self:send_command({ cmd = "quit", id = utils.generate_request_id() })
  
  -- Wait a bit and force kill if needed
  vim.defer_fn(function()
    if self.job_id and self.running then
      vim.fn.jobstop(self.job_id)
    end
  end, 1000)
  
  self.running = false
  self.job_id = nil
end

--- Send a command to the bridge
---@param cmd table
---@param callback function|nil
---@return string request_id
function Bridge:send_command(cmd, callback)
  if not self.running then
    if callback then
      callback({ type = "error", message = "Bridge not running" })
    end
    return ""
  end
  
  local req_id = cmd.id or utils.generate_request_id()
  cmd.id = req_id
  
  if callback then
    self.pending_requests[req_id] = callback
  end
  
  local json_str = vim.fn.json_encode(cmd) .. "\n"
  vim.fn.chansend(self.job_id, json_str)
  
  return req_id
end

--- Register an event handler for a kernel
---@param kernel_id string
---@param handler function
function Bridge:register_event_handler(kernel_id, handler)
  self.event_handlers[kernel_id] = handler
end

--- Unregister an event handler
---@param kernel_id string
function Bridge:unregister_event_handler(kernel_id)
  self.event_handlers[kernel_id] = nil
end

--- Handle stdout data from bridge
---@param data table
function Bridge:on_stdout(data)
  for _, line in ipairs(data) do
    if line and line ~= "" then
      -- Accumulate data in buffer
      self.buffer = self.buffer .. line
      
      -- Try to parse complete JSON objects
      while true do
        local newline_pos = self.buffer:find("\n")
        if not newline_pos then
          break
        end
        
        local json_str = self.buffer:sub(1, newline_pos - 1)
        self.buffer = self.buffer:sub(newline_pos + 1)
        
        -- Parse JSON
        local ok, msg = pcall(vim.fn.json_decode, json_str)
        if ok and type(msg) == "table" then
          self:handle_message(msg)
        else
          -- Log malformed JSON for debugging
          if vim.g.molten_debug then
            vim.schedule(function()
              vim.notify("[Molten Bridge] Malformed JSON: " .. json_str, vim.log.levels.WARN)
            end)
          end
        end
      end
    end
  end
end

--- Handle stderr data from bridge (for logging/debugging)
---@param data table
function Bridge:on_stderr(data)
  for _, line in ipairs(data) do
    if line and line ~= "" then
      -- Log stderr for debugging
      if vim.g.molten_debug then
        print("[Bridge stderr] " .. line)
      end
    end
  end
end

--- Handle bridge exit
---@param code number
function Bridge:on_exit(code)
  self.running = false
  self.job_id = nil
  
  if code ~= 0 then
    utils.notify_error("Bridge subprocess exited with code " .. code)
  end
  
  -- Call all pending request callbacks with error
  for req_id, callback in pairs(self.pending_requests) do
    callback({ type = "error", id = req_id, message = "Bridge exited" })
  end
  self.pending_requests = {}
end

--- Handle a message from the bridge
---@param msg table
function Bridge:handle_message(msg)
  local msg_type = msg.type
  
  if msg_type == "response" or msg_type == "error" then
    -- Handle response to a command
    local req_id = msg.id
    local callback = self.pending_requests[req_id]
    if callback then
      self.pending_requests[req_id] = nil
      callback(msg)
    end
  elseif msg_type == "event" then
    -- Handle kernel event
    local kernel_id = msg.kernel_id
    local handler = self.event_handlers[kernel_id]
    if handler then
      handler(msg)
    end
  end
end

--- Start a kernel
---@param kernel_name string
---@param callback function
function Bridge:start_kernel(kernel_name, callback)
  self:send_command({
    cmd = "start_kernel",
    kernel_name = kernel_name,
  }, callback)
end

--- Execute code in a kernel
---@param kernel_id string
---@param code string
---@param callback function|nil
function Bridge:execute(kernel_id, code, callback)
  self:send_command({
    cmd = "execute",
    kernel_id = kernel_id,
    code = code,
  }, callback)
end

--- Interrupt a kernel
---@param kernel_id string
---@param callback function|nil
function Bridge:interrupt(kernel_id, callback)
  self:send_command({
    cmd = "interrupt",
    kernel_id = kernel_id,
  }, callback)
end

--- Restart a kernel
---@param kernel_id string
---@param callback function|nil
function Bridge:restart(kernel_id, callback)
  self:send_command({
    cmd = "restart",
    kernel_id = kernel_id,
  }, callback)
end

--- Shutdown a kernel
---@param kernel_id string
---@param callback function|nil
function Bridge:shutdown(kernel_id, callback)
  self:send_command({
    cmd = "shutdown",
    kernel_id = kernel_id,
  }, callback)
end

--- List available kernels
---@param callback function
function Bridge:list_kernels(callback)
  self:send_command({
    cmd = "list_kernels",
  }, callback)
end

--- Send input reply to a kernel
---@param kernel_id string
---@param value string
---@param callback function|nil
function Bridge:input_reply(kernel_id, value, callback)
  self:send_command({
    cmd = "input_reply",
    kernel_id = kernel_id,
    value = value,
  }, callback)
end

--- Check if a kernel is ready
---@param kernel_id string
---@param callback function
function Bridge:is_ready(kernel_id, callback)
  self:send_command({
    cmd = "is_ready",
    kernel_id = kernel_id,
  }, callback)
end

return M
