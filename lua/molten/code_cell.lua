-- Code cell management for molten-nvim

local M = {}

---@class CodeCell
---@field begin Position|DynamicPosition
---@field end_ Position|DynamicPosition
---@field bufno number
local CodeCell = {}
CodeCell.__index = CodeCell

--- Create a new CodeCell
---@param begin Position|DynamicPosition
---@param end_ Position|DynamicPosition
---@return CodeCell
function M.new(begin, end_)
  assert(begin.bufno == end_.bufno, "begin and end must be in the same buffer")
  
  local self = setmetatable({}, CodeCell)
  self.begin = begin
  self.end_ = end_
  self.bufno = begin.bufno
  
  return self
end

--- Check if a position is within this cell
---@param pos Position|DynamicPosition
---@return boolean
function CodeCell:contains(pos)
  return self.bufno == pos.bufno and self.begin <= pos and pos < self.end_
end

--- Check if this cell overlaps with another
---@param other CodeCell
---@return boolean
function CodeCell:overlaps(other)
  return self.bufno == other.bufno 
    and self.begin < other.end_ 
    and other.begin < self.end_
end

--- Check if this cell is empty
---@return boolean
function CodeCell:empty()
  return self.end_ <= self.begin
end

--- Get the text content of this cell
---@return string
function CodeCell:get_text()
  assert(self.begin.bufno == self.end_.bufno)
  
  local lines = vim.api.nvim_buf_get_lines(
    self.bufno,
    self.begin.lineno,
    self.end_.lineno + 1,
    false
  )
  
  if #lines == 0 then
    return ""
  elseif #lines == 1 then
    return lines[1]:sub(self.begin.colno + 1, self.end_.colno)
  else
    local result = {}
    table.insert(result, lines[1]:sub(self.begin.colno + 1))
    for i = 2, #lines - 1 do
      table.insert(result, lines[i])
    end
    table.insert(result, lines[#lines]:sub(1, self.end_.colno))
    return table.concat(result, "\n")
  end
end

--- Clear the highlight of this cell
---@param highlight_namespace number
function CodeCell:clear_interface(highlight_namespace)
  vim.api.nvim_buf_clear_namespace(
    self.bufno,
    highlight_namespace,
    self.begin.lineno,
    self.end_.lineno + 1
  )
end

--- Compare cells by their begin position
---@param other CodeCell
---@return boolean
function CodeCell:__lt(other)
  return self.begin < other.begin
end

--- Compare cells by their begin position
---@param other CodeCell
---@return boolean
function CodeCell:__le(other)
  return self.begin <= other.begin
end

--- String representation
---@return string
function CodeCell:__tostring()
  return string.format("CodeCell(%s, %s)", tostring(self.begin), tostring(self.end_))
end

return M
