# Build Status

## Build Result
**Status**: SUCCESS
**Compiler**: solc 0.8.28 (pinned, auto_detect_solc=false)
**EVM Version**: cancun
**Optimizer**: enabled (150 runs default, 1000 runs prod profile)
**via_ir**: false (default), true (prod profile)
**Output**: Compilation skipped (no files changed - artifacts up to date)

## Build Warnings (non-blocking)
- `unsafe-typecast`: `uint64(block.timestamp + delay)` in `CoveredVaultAdmin.sol:228` - lint warning only
- `erc20-unchecked-transfer`: Multiple test/mock files - all in test/mock scope, not src/ production code
- `unaliased-plain-import`: Several test files use plain `import "forge-std/Test.sol"` - style only
- `screaming-snake-case-immutable`: Test mock `ForkClaimManager.sol` - style only

## Submodules
`git submodule update --init --recursive` - completed successfully (no output = already initialized)

## Foundry Configuration
- src = "src"
- out = "out"
- libs = ["lib"]
- test = "test"
- fuzz.runs = 250 (default), 500 (ci profile)
- invariant.runs = 50 (default), 100 (ci profile)
- ffi = true
- ast = true
- build_info = true

## Medusa
MEDUSA_AVAILABLE: false
(medusa binary not found in PATH)

## Trident
trident_available: false

## RAG Tools
RAG_TOOLS_AVAILABLE: unknown (not probed - will attempt during recon)
