" Molten.nvim - Interactive code evaluation for Neovim
"
" This plugin uses a Lua-based architecture with a Python subprocess bridge
" for Jupyter kernel communication. No :UpdateRemotePlugins required!
"
" Architecture:
"   - Lua: UI, state management, and Neovim integration
"   - Python subprocess: Jupyter protocol via jupyter_client
"   - JSON protocol: Communication over stdio pipes

if exists('g:loaded_molten')
  finish
endif
let g:loaded_molten = 1

" Check Neovim version
if !has("nvim-0.9")
  echoerr "molten-nvim requires Neovim 0.9+"
  finish
endif

lua << EOF
  local ok, molten = pcall(require, "molten.init")
  if ok then
    molten.setup()
  else
    vim.api.nvim_err_writeln("Failed to load molten: " .. tostring(molten))
  end
EOF
