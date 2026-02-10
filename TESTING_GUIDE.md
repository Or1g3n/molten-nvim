# Testing the Clean Implementation

This guide helps verify that the clean Lua implementation works correctly without any rplugin conflicts.

---

## Pre-flight Checks

### 1. Verify Clean State

```bash
# In your molten-nvim directory
ls rplugin/
# Should return: ls: cannot access 'rplugin/': No such file or directory

ls plugin/
# Should return: molten.vim

ls scripts/
# Should return: molten_bridge.py
```

### 2. Check Python Dependency

```bash
python3 -c "import jupyter_client; print(jupyter_client.__version__)"
# Should print version (e.g., 8.6.0)

# If not installed:
pip install --user jupyter_client
```

### 3. Check Neovim Version

```vim
:version
" Should show nvim 0.9.0 or higher
```

---

## Basic Functionality Test

### Test 1: Plugin Loads

```vim
" Start fresh Neovim session
nvim test.py

" Check if plugin loaded
:echo g:loaded_molten
" Expected: 1

" Check for command
:MoltenInit
" Should show available kernels or prompt
```

**✅ Pass:** Plugin loaded, commands available
**❌ Fail:** See troubleshooting below

### Test 2: Initialize Kernel

```vim
:MoltenInit python3
" Expected: Notification "Kernel python3 initialized"

" Verify kernel is running
:MoltenInfo
" Expected: Info window showing kernel details
```

**✅ Pass:** Kernel starts successfully
**❌ Fail:** Check Python installation

### Test 3: Execute Code

```vim
" Type in buffer:
print("Hello, Molten!")

" Execute line
:MoltenEvaluateLine
" Expected: Output appears (virtual text or float)
```

**✅ Pass:** Code executes, output displays
**❌ Fail:** Check error messages

### Test 4: Cell Navigation

```vim
" Execute a few lines to create cells
:MoltenEvaluateLine
" Move down, execute another line
j
:MoltenEvaluateLine

" Navigate between cells
:MoltenNext
" Expected: Cursor moves to next cell

:MoltenPrev
" Expected: Cursor moves to previous cell
```

**✅ Pass:** Navigation works
**❌ Fail:** Check cell creation

---

## Advanced Feature Tests

### Test 5: Persistence

```vim
" Execute some code
:MoltenEvaluateLine

" Save outputs
:MoltenSave /tmp/molten_test.json
" Expected: File created

" Delete cell
:MoltenDelete

" Load outputs
:MoltenLoad /tmp/molten_test.json
" Expected: Outputs restored
```

### Test 6: Multi-kernel

```vim
" Initialize another kernel
:MoltenInit python3

" Check running kernels
:echo MoltenRunningKernels()
" Expected: List of kernel names
```

### Test 7: Notebook Import

```vim
" Create or download a .ipynb file
:MoltenImportOutput /path/to/notebook.ipynb
" Expected: Cell outputs imported
```

---

## Conflict Detection

### Verify NO rplugin Loaded

```vim
" Check for rplugin manifest
:echo stdpath('data') . '/rplugin.vim'

" View the file (if it exists)
:edit <that path>

" Search for 'molten'
/molten

" Expected: No molten entries
" If molten entries exist, they're from old installation
```

**To Clean Old Manifest:**
```vim
" Delete the manifest
:call delete(stdpath('data') . '/rplugin.vim')

" Restart Neovim
" The new Lua plugin will load without conflict
```

### Check Process List

```bash
# While molten is running
ps aux | grep molten

# Expected output:
# python3 /path/to/scripts/molten_bridge.py

# Should NOT see:
# python3 -m pynvim
```

---

## Performance Verification

### Test Startup Speed

```vim
" Time plugin loading
:profile start /tmp/profile.log
:profile func *
:profile file *

" Restart Neovim
" Execute some commands
:MoltenInit python3
:MoltenEvaluateLine

:profile pause
:noautocmd qall!

" Check profile log
" molten.init.setup() should be < 10ms
```

### Test Responsiveness

```vim
" Execute many cells quickly
:MoltenEvaluateLine
j
:MoltenEvaluateLine
j
:MoltenEvaluateLine

" Expected: All execute without lag
```

---

## Troubleshooting

### Problem: "E117: Unknown function: MoltenInit"

**Diagnosis:**
```vim
:echo g:loaded_molten
" If 0 or undefined, plugin didn't load

:messages
" Check for error messages
```

**Solutions:**
1. Check Neovim version: `:version` (need 0.9+)
2. Check file exists: `:echo filereadable('plugin/molten.vim')`
3. Check Lua error: `:lua require('molten.init').setup()`

### Problem: "jupyter_client not found"

**Diagnosis:**
```bash
python3 -c "import jupyter_client"
# If error, not installed
```

**Solution:**
```bash
pip install --user jupyter_client
# or
pip3 install jupyter_client
```

### Problem: Subprocess not starting

**Diagnosis:**
```vim
:lua print(vim.g.python3_host_prog or "python3")
" Check Python path

:lua vim.fn.system('python3 -c "import jupyter_client"')
" Should have no error
```

**Solution:**
```vim
" Set Python path explicitly
let g:python3_host_prog = '/usr/bin/python3'
```

### Problem: Strange behavior or conflicts

**Diagnosis:**
```bash
# Check for old rplugin
ls rplugin/
# Should NOT exist

# Check plugin directory
ls plugin/
# Should only show molten.vim
```

**Solution:**
```bash
# If rplugin exists, remove it
rm -rf rplugin/

# Remove old manifest
rm ~/.local/share/nvim/rplugin.vim

# Restart Neovim
```

---

## Expected Output Examples

### MoltenInit Success
```
Kernel python3 initialized successfully
```

### MoltenEvaluateLine Success
```
[Virtual text showing output or floating window]
✓ Done in 0.12s
```

### MoltenInfo Window
```
╔═══════════════════════════════╗
║ Kernel: python3               ║
║ ID: abc123...                 ║
║ Status: idle                  ║
║                              ║
║ Buffers:                     ║
║   - test.py                  ║
║                              ║
║ Cells: 3 (3 complete)        ║
╚═══════════════════════════════╝
```

---

## Health Check

```vim
:checkhealth molten
```

**Expected output:**
- ✅ Neovim version OK
- ✅ Python found
- ✅ jupyter_client installed
- ✅ molten.init module loaded
- ✅ Bridge script found

---

## Success Criteria

Your installation is working correctly if:

1. ✅ Plugin loads without errors
2. ✅ `:MoltenInit` works
3. ✅ `:MoltenEvaluateLine` executes code
4. ✅ Output displays correctly
5. ✅ No rplugin conflicts
6. ✅ Fast startup (<10ms)
7. ✅ All 25 commands available

---

## Reporting Issues

If tests fail, gather this information:

```vim
" 1. Neovim version
:version

" 2. Plugin status
:echo g:loaded_molten

" 3. Check health
:checkhealth molten

" 4. Lua error (if any)
:lua require('molten.init').setup()

" 5. Messages
:messages
```

```bash
# 6. Python info
python3 --version
python3 -c "import jupyter_client; print(jupyter_client.__version__)"

# 7. Directory structure
ls -la plugin/
ls -la scripts/
ls -la rplugin/ 2>&1  # Should error - that's good!
```

Include this information when reporting issues.

---

## Next Steps

Once basic tests pass:
- Explore all 25 commands
- Configure options (`:help molten-config`)
- Set up image rendering
- Try notebook workflows
- Integrate with your workflow

**Happy coding with clean, conflict-free molten-nvim! 🚀**
