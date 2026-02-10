-- Molten.nvim plugin entry point (Lua-based architecture prototype)
--
-- This loads the new Lua-based implementation that uses a Python subprocess bridge
-- instead of the pynvim remote plugin architecture.
--
-- NOTE: This is a minimal prototype. The original rplugin architecture still exists
-- and will continue to work. This new implementation demonstrates the viability of
-- the subprocess approach.

if vim.g.loaded_molten_lua then
  return
end
vim.g.loaded_molten_lua = 1

-- Check Neovim version
if vim.fn.has("nvim-0.9.4") == 0 then
  vim.api.nvim_err_writeln("molten-nvim requires Neovim 0.9.4+")
  return
end

-- Setup the plugin
local ok, molten = pcall(require, "molten.init")
if ok then
  molten.setup()
else
  vim.api.nvim_err_writeln("Failed to load molten: " .. tostring(molten))
end
