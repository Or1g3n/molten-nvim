-- Kernel runtime abstraction for molten-nvim

local M = {}

--- Runtime states
M.RuntimeState = {
  STARTING = "STARTING",
  IDLE = "IDLE",
  RUNNING = "RUNNING",
}

---@class Runtime
---@field bridge table
---@field kernel_id string|nil
---@field kernel_name string
---@field state string
---@field event_handler function|nil
local Runtime = {}
Runtime.__index = Runtime

--- Create a new Runtime
---@param bridge table
---@param kernel_name string
---@return Runtime
function M.new(bridge, kernel_name)
  local self = setmetatable({}, Runtime)
  
  self.bridge = bridge
  self.kernel_name = kernel_name
  self.kernel_id = nil
  self.state = M.RuntimeState.STARTING
  self.event_handler = nil
  
  return self
end

--- Initialize the kernel
---@param callback function
function Runtime:init(callback)
  self.bridge:start_kernel(self.kernel_name, function(response)
    if response.success then
      self.kernel_id = response.kernel_id
      self.state = M.RuntimeState.IDLE
      
      -- Register event handler
      self.bridge:register_event_handler(self.kernel_id, function(event)
        if self.event_handler then
          self.event_handler(event)
        end
      end)
      
      callback(true, response.kernel_id)
    else
      callback(false, response.message)
    end
  end)
end

--- Execute code
---@param code string
---@param callback function|nil
function Runtime:execute(code, callback)
  if not self.kernel_id then
    if callback then
      callback(false, "Kernel not initialized")
    end
    return
  end
  
  self.bridge:execute(self.kernel_id, code, callback)
end

--- Interrupt the kernel
---@param callback function|nil
function Runtime:interrupt(callback)
  if not self.kernel_id then
    if callback then
      callback(false, "Kernel not initialized")
    end
    return
  end
  
  self.bridge:interrupt(self.kernel_id, callback)
end

--- Restart the kernel
---@param callback function|nil
function Runtime:restart(callback)
  if not self.kernel_id then
    if callback then
      callback(false, "Kernel not initialized")
    end
    return
  end
  
  self.state = M.RuntimeState.STARTING
  self.bridge:restart(self.kernel_id, function(response)
    if response.success then
      self.state = M.RuntimeState.IDLE
    end
    if callback then
      callback(response.success, response.message)
    end
  end)
end

--- Shutdown the kernel
---@param callback function|nil
function Runtime:shutdown(callback)
  if not self.kernel_id then
    if callback then
      callback(false, "Kernel not initialized")
    end
    return
  end
  
  self.bridge:unregister_event_handler(self.kernel_id)
  self.bridge:shutdown(self.kernel_id, callback)
  self.kernel_id = nil
end

--- Set event handler for kernel messages
---@param handler function
function Runtime:set_event_handler(handler)
  self.event_handler = handler
end

--- Check if kernel is ready
---@return boolean
function Runtime:is_ready()
  return self.state ~= M.RuntimeState.STARTING
end

return M
