# Depth Input: Token Flow Domain
# Agent: depth-token-flow
# Max 15 findings (prioritized by severity)

## Priority Findings for Token Flow Analysis

### [PC3-1] HIGH — Excess Swap Output Permanently Stranded in ClaimManager
Location: ClaimManager.sol:L663-L669
Root cause: swapOutput received in full; only remainingPayout transferred to vault; surplus locked in ClaimManager; vault stakers over-slashed
Verdict: CONFIRMED | Evidence: [TRACE][BOUNDARY]
Key question: Can surplus be recovered? Is this reachable for all claim types?

### [PC3-2] HIGH — UniswapV3Adapter Fee-Tier Mismatch Between quote and swap
Location: UniswapV3Adapter.sol:L127-L135, L155-L188
Root cause: pairFees (used by quoteSwap) vs stored calldata fee tier (used by executeSwap) are independent; fee migration creates desync — DoS scenario A or weakened slippage scenario B
Verdict: CONFIRMED | Evidence: [VARIATION][TRACE]
Key question: How often are fee tiers updated? Can an attacker trigger the desync?

### [TF-4] MEDIUM — quoteSwap Returns 0 on Route Failure → amountOutMin=1
Location: ClaimManager.sol:640-650
Root cause: quoteSwap() gracefully returns 0 on failure; caller uses amountOutMin=max(1,quote*slippage); if quote=0 then min=1 → near-total sandwich
Verdict: CONFIRMED | Evidence: -
Key question: How easy is it to cause quoteSwap to return 0 in production?

### [RS1-2] MEDIUM — Authorized Operators Can Waive Owner's Insurance
Location: CoveredVaultWrapper.sol:241-262
Root cause: ERC-20 operator can call emergencyRedeem/emergencyWithdraw, setting SKIP_INSURANCE_SLOT; owner loses insurance payout with no consent
Verdict: CONFIRMED | Evidence: -
Key question: Is there any path where this is exploitable for attacker profit vs just user harm?

### [PC4-1] MEDIUM — Stale Approval Persists on Old RewardsManager
Location: PremiumManager.sol:93-97, 102-113
Root cause: setRewardsManager updates pointer but leaves unlimited allowance on old rewardsManager; old contract can drain PremiumManager balances
Verdict: CONFIRMED | Evidence: [TRACE][BOUNDARY][VARIATION]
Key question: Who controls old RewardsManager after rotation? Can attacker become it?

### [TF-5] LOW — Fee-on-Transfer Collateral Tokens Cause Over-Approval
Location: ClaimManager.sol:586-670
Root cause: approve(collateralAmount) then transferFrom; fee-on-transfer token arrives at collateralAmount-fee; subsequent safeTransferFrom may fail
Verdict: PARTIAL | Precondition: fee-on-transfer collateral token
Key question: What collateral tokens are supported? Are any known fee-on-transfer?

### [TF-1] LOW — block.timestamp as Swap Deadline
Location: ClaimManager.sol:659
Root cause: No forward deadline; transaction valid in any future block
Verdict: CONFIRMED

### [RS2-3] INFO — Excess Collateral Stranded in ClaimManager
Location: ClaimManager.sol:599-613
Root cause: same-token path caps transfer at remainingPayout but slashes full collateralAmount; excess stays in ClaimManager
Verdict: CONFIRMED

### [TF-3] LOW — Morpho Share Donation Inflates _morphoValue()
Location: CoveredVaultAccrual.sol:139-147
Root cause: unsolicited Morpho share donation increases _morphoValue; benefits all depositors; attacker cannot extract
Verdict: CONFIRMED — positive for depositors

## VAULT_ACCOUNTING Injectable Questions (token-flow domain):
1. Can totalPrincipal and totalPremiumLiability become permanently inconsistent in the ERC-4626 accounting? (CS-2 depth — phantom liability after deep-loss)
2. Does the balance-diff pattern in _claimInsurance correctly measure payout, including edge cases where ClaimManager sends 0? (TF-6)
3. Does morphoValue correctly reflect the vault's real Morpho position, including during gate activation/deactivation? (OZ-3 depth)
4. Are there any paths where a user can withdraw more than they deposited (ignoring yield)?
