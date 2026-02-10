" Test script for Vim functions
echo "Testing Molten Vim functions..."

" Check if functions exist
if exists("*MoltenEvaluateRange")
  echo "✓ MoltenEvaluateRange exists"
else
  echo "✗ MoltenEvaluateRange NOT FOUND"
endif

if exists("*MoltenEvaluateLine")
  echo "✓ MoltenEvaluateLine exists"
else
  echo "✗ MoltenEvaluateLine NOT FOUND"
endif

if exists("*MoltenRunningKernels")
  echo "✓ MoltenRunningKernels exists"
else
  echo "✗ MoltenRunningKernels NOT FOUND"
endif

if exists("*MoltenStatusLineKernels")
  echo "✓ MoltenStatusLineKernels exists"
else
  echo "✗ MoltenStatusLineKernels NOT FOUND"
endif

if exists("*MoltenAvailableKernels")
  echo "✓ MoltenAvailableKernels exists"
else
  echo "✗ MoltenAvailableKernels NOT FOUND"
endif

echo "Test complete!"
