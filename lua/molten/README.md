# Molten-nvim Lua Architecture Prototype

## Overview

This directory contains a **minimal working prototype** of the new Lua-based architecture for molten-nvim. The goal is to replace the pynvim remote plugin architecture with a lightweight Python subprocess bridge that communicates with Lua over stdio using JSON lines.

## Current Status: PROTOTYPE

This is a **proof-of-concept implementation** that demonstrates the viability of the new architecture. It is **NOT feature-complete** and should not be used in production.

### What's Implemented ✓

#### Phase 1: Foundation (Complete)
- ✅ `scripts/molten_bridge.py` - Python subprocess that wraps jupyter_client
  - JSON protocol over stdin/stdout
  - Multiple kernel management
  - All basic commands: start_kernel, execute, interrupt, restart, shutdown
  - Image handling (writes to temp files)
  - Event streaming from IOPub and stdin channels

- ✅ `lua/molten/bridge.lua` - Subprocess lifecycle manager
  - jobstart-based subprocess management
  - JSON message parsing and routing
  - Request/response handling with callbacks
  - Event handler registration per kernel

- ✅ `lua/molten/utils.lua` - Utility functions
  - Notifications (info/warn/error)
  - Python path detection
  - Bridge script discovery

- ✅ `lua/molten/options.lua` - Configuration management
  - All vim.g.molten_* variables
  - Runtime option updates

#### Phase 2: Core Data Structures (Complete)
- ✅ `lua/molten/position.lua` - Position and DynamicPosition
  - Extmark-backed dynamic positions
  - Position comparison operators
  
- ✅ `lua/molten/code_cell.lua` - Code cell tracking
  - Extmark-based cell boundaries
  - Overlap detection
  - Text extraction

- ✅ `lua/molten/outputchunks.lua` - Output chunk types
  - TextOutputChunk with wrapping
  - ErrorOutputChunk with formatting
  - ImageOutputChunk (basic)
  - Output aggregation and status

#### Phase 3: Kernel Runtime (Partial)
- ✅ `lua/molten/runtime.lua` - Runtime abstraction
  - Kernel initialization
  - Code execution
  - Interrupt/restart/shutdown
  - Event handler registration

- ✅ `lua/molten/init.lua` - Main plugin module (minimal)
  - Basic command setup
  - Simple kernel management
  - Event handling (basic)

#### Commands Implemented
- ✅ `MoltenInit [kernel_name]` - Initialize a kernel
- ✅ `MoltenDeinit` - Shutdown kernel
- ✅ `MoltenEvaluateLine` - Execute current line
- ✅ `MoltenEvaluateVisual` - Execute visual selection
- ✅ `MoltenInterrupt` - Interrupt kernel

### What's NOT Implemented ❌

#### Missing Core Components
- ❌ `lua/molten/outputbuffer.lua` - Complete output display
  - Virtual text rendering
  - Floating window management
  - Window positioning and updates
  
- ❌ `lua/molten/images.lua` - Canvas abstraction
  - Integration with image.nvim
  - Integration with snacks.nvim
  - Integration with wezterm
  - Image lifecycle management

- ❌ `lua/molten/moltenbuffer.lua` - MoltenKernel full implementation
  - Multi-buffer support
  - Cell tracking and updates
  - Output queueing
  - Interface updates

#### Missing Features
- ❌ `lua/molten/save_load.lua` - Persistence
- ❌ `lua/molten/ipynb.lua` - Notebook import/export
- ❌ `lua/molten/info_window.lua` - Info window display

#### Missing Commands (35+)
- ❌ `MoltenEvaluateOperator`
- ❌ `MoltenEvaluateArgument`
- ❌ `MoltenReevaluateCell`
- ❌ `MoltenReevaluateAll`
- ❌ `MoltenDelete`
- ❌ `MoltenShowOutput`
- ❌ `MoltenHideOutput`
- ❌ `MoltenEnterOutput`
- ❌ `MoltenToggleVirtual`
- ❌ `MoltenRestart`
- ❌ `MoltenSave` / `MoltenLoad`
- ❌ `MoltenImportOutput` / `MoltenExportOutput`
- ❌ `MoltenInfo`
- ❌ `MoltenNext` / `MoltenPrev` / `MoltenGoto`
- ❌ `MoltenOpenInBrowser`
- ❌ `MoltenImagePopup`
- ❌ And 20+ more internal commands/functions

#### Missing UI Components
- ❌ Virtual text output display
- ❌ Floating window output display
- ❌ Cell highlighting
- ❌ Execution count display
- ❌ Execution time display
- ❌ Progress indicators

#### Missing Features
- ❌ Multiple kernels per buffer
- ❌ Shared kernels across buffers
- ❌ External kernel connections (JSON file)
- ❌ Remote Jupyter server connections (HTTP)
- ❌ Stdin/input support (partial in bridge)
- ❌ HTML output rendering
- ❌ Rich display_data handling
- ❌ Output window navigation
- ❌ Autocommands (MoltenInitPre/Post, etc.)
- ❌ Tick timer for UI updates

## Testing the Prototype

### Prerequisites
```bash
# Ensure you have jupyter_client installed
pip install jupyter_client

# Optional: ipykernel for Python kernel
pip install ipykernel
```

### Basic Usage
```vim
" Start a Python kernel
:MoltenInit python3

" Execute current line
:MoltenEvaluateLine

" Execute visual selection (in visual mode)
:'<,'>MoltenEvaluateVisual

" Interrupt kernel
:MoltenInterrupt

" Shutdown kernel
:MoltenDeinit
```

### Known Limitations
1. **No output display** - Results are only shown as notifications
2. **Single kernel only** - No multi-kernel or multi-buffer support
3. **No cell tracking** - Code cells are not tracked or highlighted
4. **No persistence** - Cannot save/load state
5. **No image rendering** - Images are written to files but not displayed
6. **Limited error handling** - May crash or behave unexpectedly

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│ Neovim (Lua)                                            │
│                                                         │
│  ┌──────────────┐         ┌────────────────────────┐   │
│  │  lua/molten  │◄────────│  User Commands         │   │
│  │  /init.lua   │         │  :MoltenInit, etc.     │   │
│  └──────┬───────┘         └────────────────────────┘   │
│         │                                              │
│         │ manages                                      │
│         ▼                                              │
│  ┌──────────────────────────────────────────────┐     │
│  │  lua/molten/bridge.lua                       │     │
│  │  - jobstart() subprocess                     │     │
│  │  - JSON protocol                             │     │
│  │  - Request/response matching                 │     │
│  └──────────────┬───────────────────────────────┘     │
│                 │                                      │
└─────────────────┼──────────────────────────────────────┘
                  │ stdin/stdout (JSON lines)
                  │
┌─────────────────▼──────────────────────────────────────┐
│ Python Subprocess (scripts/molten_bridge.py)           │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  MoltenBridge                                   │   │
│  │  - select() loop (stdin + message polling)     │   │
│  │  - Multiple KernelInfo instances                │   │
│  └─────────────────────┬───────────────────────────┘   │
│                        │                               │
│                        │ wraps                         │
│                        ▼                               │
│  ┌─────────────────────────────────────────────────┐   │
│  │  jupyter_client.KernelManager                   │   │
│  │  jupyter_client.KernelClient                    │   │
│  │  - IOPub channel (outputs)                      │   │
│  │  - Stdin channel (input requests)               │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

## Next Steps for Full Implementation

### Phase 4: Complete Output Display
1. Implement `lua/molten/outputbuffer.lua` with:
   - Virtual text rendering using nvim_buf_set_extmark
   - Floating window management
   - Window positioning logic
   - Update/clear operations

2. Implement `lua/molten/images.lua` with:
   - Canvas interface
   - Integration with existing image loaders
   - Image lifecycle management

### Phase 5: Complete MoltenKernel
1. Implement `lua/molten/moltenbuffer.lua`:
   - Multi-buffer support
   - Cell tracking with extmarks
   - Output queueing
   - Interface update logic
   - Cell navigation

### Phase 6: Remaining Commands
1. Implement all 40+ user commands
2. Add operator-mode evaluation
3. Add cell navigation commands
4. Add output management commands

### Phase 7: Advanced Features
1. Implement save/load (`lua/molten/save_load.lua`)
2. Implement ipynb import/export (`lua/molten/ipynb.lua`)
3. Implement info window (`lua/molten/info_window.lua`)
4. Add tick timer for UI updates
5. Add all autocommands

### Phase 8: Testing & Polish
1. Create test suite
2. Test all configuration options
3. Test multi-kernel scenarios
4. Test image rendering with all providers
5. Performance optimization
6. Documentation updates

## Migration from pynvim

Once the full implementation is complete:

1. Users will NO LONGER need `:UpdateRemotePlugins`
2. The plugin will load instantly (no remote plugin startup)
3. All functionality will work identically to the current version
4. The `rplugin/` directory can be removed

## Contributing

This is a large refactoring effort. Contributions are welcome! Focus areas:
- Complete the OutputBuffer implementation
- Add missing commands
- Improve error handling
- Add tests
- Documentation

## License

Same as molten-nvim (Apache 2.0)
