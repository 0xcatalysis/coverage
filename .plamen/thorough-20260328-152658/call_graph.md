# Call Graph

> SLITHER_AVAILABLE: false (Slither MCP not probed - using manual grep fallback)
> Call graph unavailable from automated tool. Key call flows identified from source inspection:

## Key External Call Flows

### CoveredVaultWrapper (primary audit target)
- `deposit()` → `_deposit()` → `morphoVault.deposit()` [external: Morpho vault]
- `redeem()` → `_withdraw()` → `_executeWithdrawal()` → `morphoVault.redeem()` [external: Morpho vault]
- `emergencyRedeem()` → direct redemption bypassing insurance logic
- `collectPremium()` (CoveredVaultAccrual) → `claimManager.fileClaim()` [external: ClaimManager]
- `onPolicyBound()` → called by PolicyManager [inbound: PolicyManager]
- `evaluate()` → called by ClaimManager [inbound: ClaimManager]
- `_claimInsurance()` → `claimManager.fileClaim()` [external: ClaimManager]
- `_deposit()` → `morphoVault.deposit()` then tracks user NAV

### PremiumCollector
- `distributeBatch()` → `_distribute()` → `IERC4626(vault).redeem()` [external: vault] → `premiumManager.distributePremium()` [external: PremiumManager]
- `registerVault()` checks pool registration via `coverPoolFactory`

### ClaimManager
- `fileClaim()` → `_fileClaimWithMetadata()` → `_capAndExecutePayout()` → `_executeSlashingAndPayout()` → `slashingManager.slash()` [external]
- `_processCollateral()` → `swapper.executeSwap()` [external: Swapper]
- `_evaluateSpec()` → `specRegistry.resolveSpec()` → `ISpec.evaluate()` [external: Spec]

### Swapper
- `executeSwap()` → `_handleTokenInput()` → `_performSwap()` → `swapTarget.call(swapCalldata)` [external: arbitrary whitelisted target]
- `_handleTokenOutput()` → `recipient.call{value: amountOut}("")` [external: ETH recipient]

### PolicyManager
- `requestCoverage()` → policy draft creation
- `bindPolicy()` → `ICoverPool(pool).bindPolicyForRequest()` [external: CoverPool]
- `bindPolicy()` → `hook.onPolicyBound()` [external: bindPolicyHook, if set]

### CoverPool
- `bindPolicyForRequest()` → `_verifyQuote()` → ECDSA signature verification
- `bindPolicyForRequest()` → `policyManager.bindPolicy()` [external: PolicyManager]
