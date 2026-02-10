-- Position management for molten-nvim

local M = {}

---@class Position
---@field bufno number
---@field lineno number
---@field colno number
local Position = {}
Position.__index = Position

--- Create a new Position
---@param bufno number
---@param lineno number
---@param colno number
---@return Position
function M.Position(bufno, lineno, colno)
  local self = setmetatable({}, Position)
  self.bufno = bufno
  self.lineno = lineno
  self.colno = colno
  return self
end

--- Compare two positions
---@param other Position
---@return boolean
function Position:__lt(other)
  if self.lineno == other.lineno then
    return self.colno < other.colno
  end
  return self.lineno < other.lineno
end

--- Compare two positions
---@param other Position
---@return boolean
function Position:__le(other)
  if self.lineno == other.lineno then
    return self.colno <= other.colno
  end
  return self.lineno < other.lineno
end

--- String representation
---@return string
function Position:__tostring()
  return string.format("Position(%d, %d, %d)", self.bufno, self.lineno, self.colno)
end

---@class DynamicPosition : Position
---@field extmark_namespace number
---@field extmark_id number
local DynamicPosition = setmetatable({}, { __index = Position })
DynamicPosition.__index = DynamicPosition

--- Create a new DynamicPosition backed by an extmark
---@param extmark_namespace number
---@param bufno number
---@param lineno number
---@param colno number
---@param right_gravity boolean|nil
---@return DynamicPosition
function M.DynamicPosition(extmark_namespace, bufno, lineno, colno, right_gravity)
  local self = setmetatable({}, DynamicPosition)
  
  self.bufno = bufno
  self.extmark_namespace = extmark_namespace
  
  -- Create extmark
  local opts = {
    right_gravity = right_gravity or false,
    strict = false,
  }
  
  self.extmark_id = vim.api.nvim_buf_set_extmark(
    bufno,
    extmark_namespace,
    lineno,
    colno,
    opts
  )
  
  return self
end

--- Get the current position from the extmark
---@return number, number
function DynamicPosition:_get_pos()
  local pos = vim.api.nvim_buf_get_extmark_by_id(
    self.bufno,
    self.extmark_namespace,
    self.extmark_id,
    {}
  )
  return pos[1], pos[2]
end

--- Get the current line number
---@return number
function DynamicPosition:get_lineno()
  local lineno, _ = self:_get_pos()
  return lineno
end

--- Get the current column number
---@return number
function DynamicPosition:get_colno()
  local _, colno = self:_get_pos()
  return colno
end

-- Override lineno/colno to be dynamic properties that query the extmark
-- Note: This is a non-standard pattern where lineno/colno appear to be properties
-- but actually call get_lineno()/get_colno() methods. This is necessary because
-- extmark positions change as the buffer is edited, so we need to query the
-- current position each time these properties are accessed. These are effectively
-- read-only properties backed by extmarks.
DynamicPosition.__index = function(self, key)
  if key == "lineno" then
    return self:get_lineno()
  elseif key == "colno" then
    return self:get_colno()
  else
    return rawget(DynamicPosition, key) or rawget(Position, key)
  end
end

--- Set virtual lines height at this position
---@param height number
function DynamicPosition:set_height(height)
  local virt_lines = {}
  for _ = 1, height do
    table.insert(virt_lines, { { "", "Normal" } })
  end
  
  vim.api.nvim_buf_set_extmark(
    self.bufno,
    self.extmark_namespace,
    self.lineno,
    self.colno,
    {
      id = self.extmark_id,
      virt_lines = virt_lines,
    }
  )
end

--- Delete the extmark
function DynamicPosition:delete()
  pcall(vim.api.nvim_buf_del_extmark, self.bufno, self.extmark_namespace, self.extmark_id)
end

--- String representation
---@return string
function DynamicPosition:__tostring()
  return string.format("DynamicPosition(%d, %d, %d)", self.bufno, self.lineno, self.colno)
end

return M
