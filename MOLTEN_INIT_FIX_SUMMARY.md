# MoltenInit Fix Summary

## Issue

`:MoltenInit` without arguments would say "Molten initialized" but wouldn't actually initialize a kernel, leading to "No active kernel" errors when trying to execute code.

## Root Cause

The implementation was silently defaulting to `python3`:

```lua
kernel_name = kernel_name or "python3"  -- Always used python3!
```

This caused:
1. No feedback to user about which kernel was being used
2. Failure if python3 wasn't installed
3. No way for user to select from available kernels
4. Confusing "initialized" message with no actual kernel

## Solution

Modified `molten_init()` to show kernel selector when no kernel specified:

```lua
-- If no kernel specified, show selection prompt
if not kernel_name or kernel_name == "" then
  M.bridge:list_kernels(function(success, data)
    if success and data.kernels then
      local prompt_module = require("prompt")
      local kernel_choices = {}
      for _, kname in ipairs(data.kernels) do
        table.insert(kernel_choices, {kname, false})
      end
      
      if #kernel_choices == 0 then
        utils.notify_error("No Jupyter kernels found. Install a kernel with: python -m ipykernel install --user")
        return
      end
      
      prompt_module.prompt_init(kernel_choices, "Select a kernel:")
    else
      utils.notify_error("Failed to list available kernels")
    end
  end)
  return
end
```

## How It Works

1. User runs `:MoltenInit` (no arguments)
2. Plugin queries Jupyter for available kernelspecs
3. Shows `vim.ui.select()` with list of kernels
4. User selects a kernel
5. Plugin initializes that specific kernel
6. User sees success message

## User Experience

### Before
```vim
:MoltenInit
" Output: "Molten initialized"
" Reality: Tried to start python3, may have failed silently
:MoltenEvaluateLine
" Output: "No active kernel. Run :MoltenInit first"
```

### After
```vim
:MoltenInit
" Shows selector: python3, julia, ir, etc.
" User selects "python3"
" Output: "Kernel 'python3' initialized"
:MoltenEvaluateLine
" Output: Code executes successfully!
```

## Edge Cases Handled

### No Kernels Installed
```vim
:MoltenInit
" Error: "No Jupyter kernels found. Install a kernel with: python -m ipykernel install --user"
```

### Direct Kernel Specification Still Works
```vim
:MoltenInit python3
" Directly starts python3 (no prompt shown)
```

### User Cancels Selection
```vim
:MoltenInit
" Selector appears
" User presses <Esc>
" No kernel initialized, no error
```

## Testing

### Test 1: Selector Appears
```vim
:MoltenInit
" Expected: vim.ui.select appears with kernel choices
```

### Test 2: Kernel Initializes After Selection
```vim
:MoltenInit
" Select "python3" from list
" Expected: "Kernel 'python3' initialized"
```

### Test 3: Can Execute Code After Init
```vim
:MoltenInit
" Select kernel
print("hello")
:MoltenEvaluateLine
" Expected: Output shows "hello"
```

### Test 4: Direct Init Still Works
```vim
:MoltenInit julia
" Expected: Directly starts Julia kernel without prompt
```

## Files Modified

- `lua/molten/init.lua` - Updated `molten_init()` function

## Dependencies

Uses existing modules:
- `lua/prompt.lua` - For `vim.ui.select()` interface
- `lua/molten/bridge.lua` - Has `list_kernels()` method
- `scripts/molten_bridge.py` - Has `cmd_list_kernels()` implementation

## Result

✅ `:MoltenInit` now works as expected
✅ Users can see and select from available kernels
✅ Helpful error messages when no kernels found
✅ Direct kernel specification still supported
✅ No more confusing "initialized" messages with no actual kernel
