-- Image canvas abstraction for molten-nvim
-- Provides interface for rendering images via different providers

local M = {}

---@class Canvas
---@field init function Initialize canvas
---@field deinit function Clean up canvas
---@field present function Render queued changes
---@field add_image function Add image to canvas
---@field remove_image function Remove image from canvas
---@field img_size function Get image dimensions

--- NoCanvas - Stub implementation that does nothing
---@class NoCanvas : Canvas
local NoCanvas = {}
NoCanvas.__index = NoCanvas

function M.NoCanvas()
  local self = setmetatable({}, NoCanvas)
  return self
end

function NoCanvas:init()
  -- No-op
end

function NoCanvas:deinit()
  -- No-op
end

function NoCanvas:present()
  -- No-op
end

function NoCanvas:add_image(path, identifier, x, y, bufnr, winnr)
  return identifier
end

function NoCanvas:remove_image(identifier)
  -- No-op
end

function NoCanvas:img_size(identifier)
  return { height = 0, width = 0 }
end

--- ImageNvimCanvas - Canvas using image.nvim plugin
---@class ImageNvimCanvas : Canvas
local ImageNvimCanvas = {}
ImageNvimCanvas.__index = ImageNvimCanvas

function M.ImageNvimCanvas()
  local self = setmetatable({}, ImageNvimCanvas)
  self.images = {}
  self.to_make_visible = {}
  self.to_hide = {}
  return self
end

function ImageNvimCanvas:init()
  -- Load image.nvim
  local ok, _ = pcall(require, "image")
  if not ok then
    require("molten.utils").notify_error("image.nvim not found")
    return
  end
  
  -- Load the helper module
  vim.cmd([[runtime lua/load_image_nvim.lua]])
  self.image_api = vim.g._image_api or {}
end

function ImageNvimCanvas:deinit()
  if self.image_api and self.image_api.clear_all then
    self.image_api.clear_all()
  end
end

function ImageNvimCanvas:add_image(path, identifier, x, y, bufnr, winnr)
  if not self.image_api or not self.image_api.from_file then
    return identifier
  end
  
  -- Create image if it doesn't exist
  if not self.images[identifier] then
    local opts = {
      x = x,
      y = y,
      buffer = bufnr,
      window = winnr,
    }
    self.image_api.from_file(path, opts)
    self.images[identifier] = path
  end
  
  -- Queue for visibility
  table.insert(self.to_make_visible, identifier)
  
  return identifier
end

function ImageNvimCanvas:remove_image(identifier)
  table.insert(self.to_hide, identifier)
end

function ImageNvimCanvas:present()
  if not self.image_api then
    return
  end
  
  -- Hide queued images
  for _, identifier in ipairs(self.to_hide) do
    if self.image_api.clear then
      self.image_api.clear(identifier)
    end
  end
  self.to_hide = {}
  
  -- Show queued images
  for _, identifier in ipairs(self.to_make_visible) do
    if self.image_api.render then
      self.image_api.render(identifier, {})
    end
  end
  self.to_make_visible = {}
end

function ImageNvimCanvas:img_size(identifier)
  -- Default size - would need image.nvim API to get actual size
  return { height = 10, width = 80 }
end

--- Get canvas based on configured provider
---@param options table MoltenOptions
---@return Canvas
function M.get_canvas(options)
  local provider = options.image_provider
  
  if provider == "none" then
    return M.NoCanvas()
  elseif provider == "image.nvim" then
    return M.ImageNvimCanvas()
  elseif provider == "snacks.nvim" then
    -- TODO: Implement SnacksCanvas
    require("molten.utils").notify_warn("snacks.nvim canvas not yet implemented, using NoCanvas")
    return M.NoCanvas()
  elseif provider == "wezterm" then
    -- TODO: Implement WeztermCanvas
    require("molten.utils").notify_warn("wezterm canvas not yet implemented, using NoCanvas")
    return M.NoCanvas()
  else
    return M.NoCanvas()
  end
end

return M
