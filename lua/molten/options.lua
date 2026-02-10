-- Configuration options for molten-nvim

local M = {}

--- Highlight group names
M.HL = {
  border_norm = "MoltenOutputBorder",
  border_fail = "MoltenOutputBorderFail",
  border_succ = "MoltenOutputBorderSuccess",
  win = "MoltenOutputWin",
  win_nc = "MoltenOutputWinNC",
  foot = "MoltenOutputFooter",
  cell = "MoltenCell",
  virtual_text = "MoltenVirtualText",
}

--- Default highlight group mappings
M.HL_DEFAULTS = {
  [M.HL.border_norm] = "FloatBorder",
  [M.HL.border_succ] = M.HL.border_norm,
  [M.HL.border_fail] = M.HL.border_norm,
  [M.HL.win] = "NormalFloat",
  [M.HL.win_nc] = M.HL.win,
  [M.HL.foot] = "FloatFooter",
  [M.HL.cell] = "CursorLine",
  [M.HL.virtual_text] = "Comment",
}

---@class MoltenOptions
---@field auto_image_popup boolean
---@field auto_init_behavior string
---@field auto_open_html_in_browser boolean
---@field auto_open_output boolean
---@field cover_empty_lines boolean
---@field cover_lines_starting_with table
---@field copy_output boolean
---@field enter_output_behavior string
---@field image_location string
---@field image_provider string
---@field limit_output_chars number
---@field open_cmd string|nil
---@field output_crop_border boolean
---@field output_show_exec_time boolean
---@field output_show_more boolean
---@field output_virt_lines boolean
---@field output_win_border string|table
---@field output_win_cover_gutter boolean
---@field output_win_hide_on_leave boolean
---@field output_win_max_height number
---@field output_win_max_width number
---@field output_win_style string|boolean
---@field output_win_zindex number
---@field save_path string
---@field split_direction string|nil
---@field split_size number|nil
---@field show_mimetype_debug boolean
---@field tick_rate number
---@field use_border_highlights boolean
---@field virt_lines_off_by_1 boolean
---@field virt_text_max_lines number
---@field virt_text_output boolean
---@field virt_text_truncate string
---@field wrap_output boolean
---@field floating_window_focus string
---@field hl table

local default_opts = {
  auto_image_popup = false,
  auto_init_behavior = "init", -- "raise" or "init"
  auto_open_html_in_browser = false,
  auto_open_output = true,
  cover_empty_lines = false,
  cover_lines_starting_with = {},
  copy_output = false,
  enter_output_behavior = "open_then_enter",
  image_location = "both", -- "both", "float", "virt"
  image_provider = "none",
  open_cmd = nil,
  output_crop_border = true,
  output_show_exec_time = true,
  output_show_more = false,
  output_virt_lines = false,
  output_win_border = { "", "━", "", "" },
  output_win_cover_gutter = true,
  limit_output_chars = 1000000,
  output_win_hide_on_leave = true,
  output_win_max_height = 999999,
  output_win_max_width = 999999,
  output_win_style = false,
  save_path = vim.fn.stdpath("data") .. "/molten",
  split_direction = "right",
  split_size = 40,
  show_mimetype_debug = false,
  tick_rate = 500,
  use_border_highlights = false,
  virt_lines_off_by_1 = false,
  virt_text_max_lines = 12,
  virt_text_output = false,
  wrap_output = false,
  output_win_zindex = 50,
  virt_text_truncate = "bottom",
  floating_window_focus = "top",
}

--- Load configuration from vim.g variables
---@return MoltenOptions
function M.load()
  local opts = {}
  
  for key, default_value in pairs(default_opts) do
    local var_name = "molten_" .. key
    opts[key] = vim.g[var_name] or default_value
  end
  
  opts.hl = M.HL
  
  return opts
end

--- Update a configuration option
---@param opts MoltenOptions
---@param option string
---@param value any
function M.update_option(opts, option, value)
  if option:sub(1, 7) == "molten_" then
    option = option:sub(8)
  end
  
  if opts[option] ~= nil then
    opts[option] = value
    -- Also update the global variable
    vim.g["molten_" .. option] = value
  else
    require("molten.utils").notify_error("Invalid option: " .. option)
  end
end

return M
