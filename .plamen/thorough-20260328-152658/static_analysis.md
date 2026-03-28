# Static Analysis

## Slither MCP
SLITHER_AVAILABLE: false
(Slither MCP probe not attempted - running as grep-based fallback recon agent)

## Aderyn / Farofino MCP
Not probed (fallback mode).

## Manual Grep Analysis

### Reentrancy Patterns
Multiple reentrancy-related comments found in src/:
- `PolicyManager.sol:234-306` - `slither-disable-start/end reentrancy-benign` around `bindPolicy()` flow
- `PremiumCollector.sol:265` - `slither-disable-next-line calls-loop,reentrancy-no-eth` in `_distribute()`
- `ClaimManager.sol:232,234,353` - `slither-disable-next-line reentrancy-eth,reentrancy-no-eth` in `fileClaim()` and payout paths
- `UniswapV3Adapter.sol:186` - `slither-disable-next-line reentrancy-events`
- `CoveredVaultWrapper.sol:115,162,240,256,281,340,523,556` - multiple reentrancy disable comments
  - Most functions protected by `nonReentrant` modifier
  - Some specific slither-disable lines are for events-only or state-change patterns
- `CoveredVaultWrapper.sol:295,297` - `aderyn-fp-next-line reentrancy-state-change` with justification: "Only callable by trusted PolicyManager, executed once"

### Raw Low-level Calls
- `Swapper.sol:311` - `swapTarget.call(swapCalldata)` - arbitrary call to whitelisted swap target
- `Swapper.sol:330` - `recipient.call{value: amountOut}("")` - ETH transfer to recipient

### Division/Arithmetic Patterns
Potential divide-before-multiply to check:
- `ClaimManager.sol:533` - `(tokenStake * requestedAmount) / totalPayoutEquivalent` - multiplication first, then division (OK)
- `ClaimManager.sol:542` - `(requestedAmount * payoutEquivalent) / totalPayoutEquivalent` - multiplication first (OK)
- `ClaimManager.sol:645` - `quoted * (10_000 - maxSwapSlippageBps) / 10_000` - single division (OK)
- `CoveredVaultWrapper.sol:496` - `lastKnownMorphoValue * shares / totalShares` - multiplication first (OK, but rounding risk)

### Unchecked Returns
- `PolicyManager.sol:262` - `slither-disable-next-line unused-return` in `bindPolicy()`
- `CoveredVaultWrapper.sol:123` - `slither-disable-next-line reentrancy-state-change,unused-return` in `_deposit()`
- `CoveredVaultWrapper.sol:364` - `slither-disable-next-line unused-return` in `_claimInsurance()`
- `UniswapV3Adapter.sol:129` - `slither-disable-next-line unused-return`

### Unused State Variables (Transient Storage)
- `CoveredVaultStorage.sol:34,41,46` - `aderyn-fp-next-line(unused-state-variable)` for transient storage slot constants
  - These are used in inline assembly via `tstore/tload` (EIP-1153 transient storage)
  - Legitimate pattern for EVM cancun target

### Token Transfers
All production src/ token transfers use `safeTransfer`/`safeTransferFrom` (OpenZeppelin SafeERC20):
- `PremiumCollector.sol:290` - `safeTransfer` to premiumManager
- `ClaimManager.sol:679` - `safeTransfer` in `_transferToken()`
- `UniswapV3Adapter.sol:169` - `safeTransferFrom` from Swapper
- `Swapper.sol:139,283,333` - `safeTransfer`/`safeTransferFrom`
- `PremiumManager.sol:168,172` - `safeTransfer` to treasury and fee recipient
- `CoveredVaultAccrual.sol:75` - `safeTransfer` to premiumRecipient
- `CoveredVaultWrapper.sol:121,158` - `safeTransferFrom` and `safeTransfer`
- `CoveredVaultAdmin.sol:211` - `safeTransfer` in rescueTokens

### Loops with Storage Array Length
- `PolicyManager.sol:266` - `for (uint256 i = 0; i < tokens.length; ++i)` - loop over calldata array (safe)

### Costly Loops
- `PremiumCollector.sol:265` - `calls-loop` disabled for `_distribute()` which loops calling external vault/premiumManager

### Lint Warnings (from forge build)
- `CoveredVaultAdmin.sol:228` - `unsafe-typecast`: `uint64(block.timestamp + delay)` - confirmed by lint, acceptable given `STANDARD_DELAY = 2 days` and `UPGRADE_DELAY = 7 days` which are well within uint64 range
