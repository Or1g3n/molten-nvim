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

--- SnacksCanvas - Canvas using snacks.nvim plugin
---@class SnacksCanvas : Canvas
local SnacksCanvas = {}
SnacksCanvas.__index = SnacksCanvas

function M.SnacksCanvas()
  local self = setmetatable({}, SnacksCanvas)
  self.images = {}
  self.to_make_visible = {}
  self.to_hide = {}
  return self
end

function SnacksCanvas:init()
  -- Load snacks.nvim
  local ok, _ = pcall(require, "snacks")
  if not ok then
    require("molten.utils").notify_error("snacks.nvim not found")
    return
  end
  
  -- Load the helper module
  vim.cmd([[runtime lua/load_snacks_nvim.lua]])
  local loaded = package.loaded["load_snacks_nvim"]
  if loaded and loaded.snacks_api then
    self.snacks_api = loaded.snacks_api
  end
end

function SnacksCanvas:deinit()
  if self.snacks_api and self.snacks_api.clear_all then
    self.snacks_api.clear_all()
  end
end

function SnacksCanvas:add_image(path, identifier, x, y, bufnr, winnr)
  if not self.snacks_api or not self.snacks_api.from_file then
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
    self.snacks_api.from_file(path, opts)
    self.images[identifier] = path
  end
  
  -- Queue for visibility
  table.insert(self.to_make_visible, identifier)
  
  return identifier
end

function SnacksCanvas:remove_image(identifier)
  table.insert(self.to_hide, identifier)
end

function SnacksCanvas:present()
  if not self.snacks_api then
    return
  end
  
  -- Hide queued images
  for _, identifier in ipairs(self.to_hide) do
    if self.snacks_api.clear then
      self.snacks_api.clear(identifier)
    end
  end
  self.to_hide = {}
  
  -- Show queued images
  for _, identifier in ipairs(self.to_make_visible) do
    if self.snacks_api.render then
      self.snacks_api.render(identifier)
    end
  end
  self.to_make_visible = {}
end

function SnacksCanvas:img_size(identifier)
  if self.snacks_api and self.snacks_api.image_size then
    local size = self.snacks_api.image_size(identifier)
    return { height = size.height or 10, width = size.width or 80 }
  end
  return { height = 10, width = 80 }
end

--- WeztermCanvas - Canvas using wezterm.nvim plugin
---@class WeztermCanvas : Canvas
local WeztermCanvas = {}
WeztermCanvas.__index = WeztermCanvas

function M.WeztermCanvas()
  local self = setmetatable({}, WeztermCanvas)
  self.images = {}
  self.initial_pane_id = nil
  self.image_pane_id = nil
  return self
end

function WeztermCanvas:init()
  -- Load wezterm.nvim
  local ok, _ = pcall(require, "wezterm")
  if not ok then
    require("molten.utils").notify_error("wezterm.nvim not found")
    return
  end
  
  -- Load the helper module
  vim.cmd([[runtime lua/load_wezterm_nvim.lua]])
  local loaded = package.loaded["load_wezterm_nvim"]
  if loaded and loaded.wezterm_api then
    self.wezterm_api = loaded.wezterm_api
    
    -- Get initial pane ID
    if self.wezterm_api.get_pane_id then
      self.initial_pane_id = self.wezterm_api.get_pane_id()
    end
  end
end

function WeztermCanvas:deinit()
  if self.wezterm_api and self.wezterm_api.close_image_pane and self.image_pane_id then
    self.wezterm_api.close_image_pane(self.image_pane_id)
    self.image_pane_id = nil
  end
end

function WeztermCanvas:add_image(path, identifier, x, y, bufnr, winnr)
  if not self.wezterm_api then
    return identifier
  end
  
  -- Create image pane if not exists
  if not self.image_pane_id and self.wezterm_api.wezterm_molten_init then
    -- Get split direction and size from options
    local split_dir = vim.g.molten_split_dir or "right"
    local split_size = vim.g.molten_split_size or 40
    
    self.image_pane_id = self.wezterm_api.wezterm_molten_init(
      self.initial_pane_id,
      split_dir,
      split_size
    )
  end
  
  -- Send image to pane
  if self.image_pane_id and self.wezterm_api.send_image then
    self.wezterm_api.send_image(path, self.image_pane_id, self.initial_pane_id)
  end
  
  self.images[identifier] = path
  return identifier
end

function WeztermCanvas:remove_image(identifier)
  -- Wezterm displays images in a separate pane, so we don't need to explicitly remove
  -- Individual images are simply overwritten when new ones are sent
  self.images[identifier] = nil
end

function WeztermCanvas:present()
  -- Wezterm renders immediately, no batching needed
end

function WeztermCanvas:img_size(identifier)
  -- Wezterm displays in a separate pane, size is handled by the terminal
  return { height = 0, width = 0 }
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
    return M.SnacksCanvas()
  elseif provider == "wezterm" then
    return M.WeztermCanvas()
  else
    return M.NoCanvas()
  end
end

return M
