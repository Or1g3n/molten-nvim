-- Output chunks for molten-nvim

local M = {}

--- Output status enum
M.OutputStatus = {
  NEW = "NEW", -- Cell was created, nothing run, no output
  HOLD = "HOLD", -- Waiting to run this cell
  RUNNING = "RUNNING", -- Currently running
  DONE = "DONE", -- Code has finished running
}

--- Clean up ANSI codes and carriage returns from text
---@param text string
---@return string
local function clean_up_text(text)
  -- Remove ANSI escape codes (CSI sequences used for terminal colors/formatting)
  -- Pattern matches: ESC [ <optional params> <final character>
  text = text:gsub("\x1b%[[@-Z\\-_][^@-~]*[@-~]", "")
  -- Replace CRLF with LF
  text = text:gsub("\r\n", "\n")
  -- Remove double newlines
  text = text:gsub("\n\n", "\n")
  return text
end

--- Remove text before carriage return on each line
---@param text string
---@return string
local function remove_carriage_return_overwrites(text)
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = line:gsub(".*\r", "")
  end
  return table.concat(lines, "\n")
end

---@class OutputChunk
---@field output_type string
---@field jupyter_data table|nil
---@field jupyter_metadata table|nil
---@field extras table
local OutputChunk = {}
OutputChunk.__index = OutputChunk

---@class TextOutputChunk : OutputChunk
---@field text string
local TextOutputChunk = setmetatable({}, { __index = OutputChunk })
TextOutputChunk.__index = TextOutputChunk

--- Create a new TextOutputChunk
---@param text string
---@return TextOutputChunk
function M.TextOutputChunk(text)
  local self = setmetatable({}, TextOutputChunk)
  self.text = text
  self.output_type = "display_data"
  self.jupyter_data = nil
  self.jupyter_metadata = nil
  self.extras = {}
  return self
end

--- Place text output (returns formatted text and extra lines)
---@param options table
---@param col number
---@param shape table
---@param hard_wrap boolean
---@return string, number
function TextOutputChunk:place(options, col, shape, hard_wrap)
  local text = clean_up_text(self.text)
  local extra_lines = 0
  
  if options.wrap_output then
    local win_width = shape[3]
    if hard_wrap then
      -- Skip wrapping if this looks like a progress bar
      if text:find("\r") then
        return text, 0
      end
      
      local lines = vim.split(text, "\n", { plain = true })
      local wrapped = {}
      
      for _, line in ipairs(lines) do
        if #line + col > win_width then
          -- Wrap this line
          local remaining = line
          -- First chunk considers column offset
          table.insert(wrapped, remaining:sub(1, win_width - col))
          remaining = remaining:sub(win_width - col + 1)
          
          -- Subsequent chunks use full width
          while #remaining > 0 do
            table.insert(wrapped, remaining:sub(1, win_width))
            remaining = remaining:sub(win_width + 1)
          end
        else
          table.insert(wrapped, line)
        end
      end
      
      text = table.concat(wrapped, "\n")
    else
      -- Count extra lines needed for soft wrap
      local lines = vim.split(text, "\n", { plain = true })
      for _, line in ipairs(lines) do
        if #line > win_width then
          extra_lines = extra_lines + math.floor(#line / win_width)
        end
      end
    end
  end
  
  return text, extra_lines
end

---@class ErrorOutputChunk : OutputChunk
---@field name string
---@field message string
---@field traceback table
local ErrorOutputChunk = setmetatable({}, { __index = OutputChunk })
ErrorOutputChunk.__index = ErrorOutputChunk

--- Create a new ErrorOutputChunk
---@param name string
---@param message string
---@param traceback table
---@return ErrorOutputChunk
function M.ErrorOutputChunk(name, message, traceback)
  local self = setmetatable({}, ErrorOutputChunk)
  self.name = name
  self.message = message
  self.traceback = traceback
  self.output_type = "error"
  self.jupyter_data = nil
  self.jupyter_metadata = nil
  self.extras = {}
  
  -- Format as text for display
  local lines = {
    string.format("[Error] %s: %s", name, message),
    "Traceback:",
  }
  for _, tb_line in ipairs(traceback) do
    table.insert(lines, tb_line)
  end
  self.text = table.concat(lines, "\n")
  
  return self
end

function ErrorOutputChunk:place(options, col, shape, hard_wrap)
  local text_chunk = M.TextOutputChunk(self.text)
  return text_chunk:place(options, col, shape, hard_wrap)
end

---@class ImageOutputChunk : OutputChunk
---@field img_path string
---@field img_identifier any
local ImageOutputChunk = setmetatable({}, { __index = OutputChunk })
ImageOutputChunk.__index = ImageOutputChunk

--- Create a new ImageOutputChunk
---@param img_path string
---@return ImageOutputChunk
function M.ImageOutputChunk(img_path)
  local self = setmetatable({}, ImageOutputChunk)
  self.img_path = img_path
  self.img_identifier = nil
  self.output_type = "display_data"
  self.jupyter_data = nil
  self.jupyter_metadata = nil
  self.extras = {}
  return self
end

--- Place an image (handled by canvas)
---@param bufnr number
---@param options table
---@param lineno number
---@param canvas table
---@param virtual boolean
---@param winnr number|nil
---@return string, number
function ImageOutputChunk:place(bufnr, options, lineno, canvas, virtual, winnr)
  local loc = options.image_location
  
  -- Check if we should display in this location
  if not (loc == "both" or (loc == "virt" and virtual) or (loc == "float" and not virtual)) then
    return "", 0
  end
  
  local prefix = virtual and "virt-" or ""
  self.img_identifier = canvas:add_image(
    self.img_path,
    prefix .. self.img_path,
    0,
    lineno,
    bufnr,
    winnr
  )
  
  -- Images are rendered into virtual lines
  local height = 0
  if self.img_identifier and canvas.img_size then
    local size = canvas:img_size(self.img_identifier)
    height = size.height or 0
  end
  
  return " \n", height
end

---@class MimetypesOutputChunk : OutputChunk
local MimetypesOutputChunk = setmetatable({}, { __index = OutputChunk })
MimetypesOutputChunk.__index = MimetypesOutputChunk

--- Create a debug output showing available mimetypes
---@param mimetypes table
---@return MimetypesOutputChunk
function M.MimetypesOutputChunk(mimetypes)
  local self = setmetatable({}, MimetypesOutputChunk)
  self.text = string.format("[DEBUG] Received mimetypes: %s", vim.inspect(mimetypes))
  self.output_type = "display_data"
  self.jupyter_data = nil
  self.jupyter_metadata = nil
  self.extras = {}
  return self
end

function MimetypesOutputChunk:place(options, col, shape, hard_wrap)
  local text_chunk = M.TextOutputChunk(self.text)
  return text_chunk:place(options, col, shape, hard_wrap)
end

---@class Output
---@field execution_count number|nil
---@field chunks table
---@field status string
---@field success boolean
---@field old boolean
---@field start_time number|nil
---@field end_time number|nil
---@field _should_clear boolean
local Output = {}
Output.__index = Output

--- Create a new Output
---@param execution_count number|nil
---@return Output
function M.Output(execution_count)
  local self = setmetatable({}, Output)
  self.execution_count = execution_count
  self.status = M.OutputStatus.HOLD
  self.chunks = {}
  self.success = true
  self.old = false
  self.start_time = nil
  self.end_time = nil
  self._should_clear = false
  return self
end

--- Merge consecutive text chunks (handles carriage return overwrites)
function Output:merge_text_chunks()
  if #self.chunks >= 2 then
    local c1 = self.chunks[#self.chunks - 1]
    local c2 = self.chunks[#self.chunks]
    
    if c1.text and c2.text then
      c1.text = c1.text .. c2.text
      -- Handle carriage returns (overwrite previous content on line)
      c1.text = remove_carriage_return_overwrites(c1.text)
      c1.jupyter_data = { ["text/plain"] = c1.text }
      table.remove(self.chunks)
    end
  elseif #self.chunks > 0 then
    local c1 = self.chunks[1]
    if c1.text then
      c1.text = remove_carriage_return_overwrites(c1.text)
    end
  end
end

--- Convert Jupyter message data to an OutputChunk
---@param data table
---@param metadata table
---@param options table
---@return OutputChunk
function M.to_outputchunk(data, metadata, options)
  local chunk = nil
  
  -- Check for images that have been written to temp files by the bridge
  if data then
    for mimetype, value in pairs(data) do
      if mimetype:match("^image/.+_path$") then
        -- Bridge has already written image to file
        chunk = M.ImageOutputChunk(value)
        break
      end
    end
  end
  
  -- Fallback to plain text
  if not chunk then
    if data and data["text/plain"] then
      chunk = M.TextOutputChunk(data["text/plain"])
    else
      -- No usable data
      local mimetypes = data and vim.tbl_keys(data) or {}
      chunk = M.TextOutputChunk(
        string.format("<No usable MIMEtype! Received mimetypes %s>", vim.inspect(mimetypes))
      )
    end
  end
  
  chunk.jupyter_data = data
  chunk.jupyter_metadata = metadata
  
  return chunk
end

return M
