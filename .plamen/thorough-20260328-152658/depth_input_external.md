# Depth Input: External Domain
# Agent: depth-external
# Max 15 findings (prioritized by severity)

## Priority Findings for External Analysis

### [OZ-3] MEDIUM — _morphoValue Fallback to Stale lastKnownMorphoValue
Location: CoveredVaultAccrual.sol:139-147
Root cause: convertToAssets() reverts → fallback to lastKnownMorphoValue; if Morpho gated without owner activating morphoGateActive, lastKnownMorphoValue could be very stale
Verdict: PARTIAL | Precondition: Morpho downtime + owner inaction
Key question: How long can Morpho be down before the fallback value becomes dangerously stale?

### [TF-7] MEDIUM — _isPolicyActive External Call Blocks All Withdrawals
Location: CoveredVaultAccrual.sol:153-159, CoveredVaultWrapper.sol:328
Root cause: PolicyManager unavailability propagates through _accruePremium to block ALL withdrawals including emergency path
Verdict: PARTIAL | Precondition: PolicyManager failure/revert
Key question: Does the emergency path truly also call _accruePremium? If so, this is a DoS on fund recovery.

### [TF-4] MEDIUM — quoteSwap Returns 0 → amountOutMin=1
Location: ClaimManager.sol:640-650
Root cause: quoteSwap graceful failure returns 0; amountOutMin falls to 1; near-total MEV sandwich possible
Verdict: CONFIRMED
External aspect: quoteSwap calls Uniswap V3 quoter which can fail on pool state

### [OZ-1] LOW — Oracle Revert DoS on bindPolicy
Location: PolicyManager.sol:266-274
Root cause: No try/catch on Chainlink getUSDValue; oracle malfunction = DoS
Verdict: PARTIAL

### [TF-5] LOW — Fee-on-Transfer Token Over-Approval
Location: ClaimManager.sol:586-670
Root cause: approve(collateralAmount) but receive less due to fee; downstream operations fail
Verdict: PARTIAL

### [TF-8] INFO — Swapper Stored Calldata May Become Stale
Location: Swapper.sol:240-241, 146-173
Root cause: Route calldata is static; pool address changes or liquidity migration makes route fail silently
Verdict: CONFIRMED

### [RS2-2] LOW — PremiumCollector.distributeBatch Has No Per-Vault Error Isolation
Location: PremiumCollector.sol:163-168, 265-296
Root cause: Single vault revert collapses entire distribution batch; premium deferred for all healthy vaults
Verdict: CONFIRMED
External aspect: Each vault's collectPremium is an external call

### [PC4-3] LOW — updateVault Missing nonReentrant During _distribute External Calls
Location: PremiumCollector.sol:147-158, 283, 293
Root cause: _distribute calls vault.collectPremium; vault could re-enter updateVault; premium redirectable mid-flight
Verdict: CONFIRMED
Key question: What state is writable via updateVault? Is there real profit opportunity from reentrancy?

### [PC4-4] LOW — PremiumCollector Caches Vault Underlying at Registration
Location: PremiumCollector.sol:105-108, 283-290
Root cause: Stale underlying token if vault's asset() changes (non-standard vault)
Verdict: PARTIAL

### [AC-4] LOW — morphoGateActive Toggle No Timelock
Location: CoveredVaultAdmin.sol:168-186
Root cause: Owner can toggle gate instantly; no timelock constraint; creates SYNC_GAP 4 (stale lastKnownMorphoValue)
Verdict: PARTIAL

### [OZ-6] INFO — _isPolicyActive External Call on Every Op (Gas)
Location: CoveredVaultAccrual.sol:153-159
Root cause: PolicyManager.getPolicy called on every deposit/withdraw
Verdict: CONFIRMED (gas efficiency)

## DEX_INTEGRATION_SECURITY Injectable Questions (external domain):
1. In UniswapV3Adapter, does the stored calldata path correctly handle single-hop vs multi-hop routes? Is fee tier encoded in path or separate?
2. If executeSwap returns less than amountOutMin (e.g., revert), does ClaimManager correctly propagate the failure or silently continue with 0?
3. Is there any path where a failed swap leaves partial state in ClaimManager (collateral transferred, swap failed, payout not sent)?
4. Can SWAP_MANAGER_ROLE configure routes that bypass slippage protection via a malicious amountOutMin computation?
