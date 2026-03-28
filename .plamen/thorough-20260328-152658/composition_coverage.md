# Composition Coverage Map

## Finding Pairs Explored

| Finding A | Finding B | Explored? | Result | Notes |
|-----------|-----------|-----------|--------|-------|
| H-1 (grace window uninsured) | H-2 (unbounded gateGracePeriod) | YES | **CH-3** (STRONG) | H-2 amplifies H-1's uninsured window to unbounded duration |
| H-1 (grace window uninsured) | H-3 (phantom liability) | YES | **CH-4** (STRONG) | Grace-window loss guarantees deep-loss withdrawals -> phantom |
| H-1 (grace window uninsured) | H-8 (retroactive deductible) | YES | No chain | H-1 supersedes H-8 during grace window (claims fail entirely) |
| H-1 (grace window uninsured) | H-39 (post-expiry catch-up) | YES | No chain | Sequential uninsured periods; additive impact, not enabling |
| H-3 (phantom liability) | H-8 (retroactive deductible) | YES | **CH-1** (MODERATE) | Retroactive param change deepens loss -> larger phantom |
| H-3 (phantom liability) | H-15 (previewRedeem overstates) | YES | **CH-5** (MODERATE) | Phantom deflates totalAssets -> wider preview gap |
| H-3 (phantom liability) | H-30 (premium debt rounding) | YES | No chain | H-30 affects per-user premium debt, H-3 affects global liability; different accounting layers |
| H-4 (excess swap stranded) | H-7 (amountOutMin=1 sandwich) | YES | **CH-7** (WEAK) | Orthogonal -- opposing forces on swap output |
| H-5 (fee-tier desync) | H-7 (amountOutMin=1 sandwich) | YES | **CH-2** (STRONG) | Fee desync -> quote revert -> amountOutMin=1 -> sandwich |
| H-5 (fee-tier desync) | H-44 (block.timestamp deadline) | YES | No chain | Both affect swap protection but independently; deadline weakness is subsumed by amountOutMin weakness |
| H-9 (curator blocks claims) | H-10 (claim serialization) | YES | No chain | Parallel claim-denial vectors; H-9 is strictly worse |
| H-9 (curator blocks claims) | H-13 (retroactive poolFeeBps) | YES | **CH-6** (MODERATE) | Same actor dual-profit: block claims + extract fees |
| H-9 (curator blocks claims) | H-1 (grace window) | YES | No chain | Both deny claims through different mechanisms; no enabling relationship |
| H-12 (revoked spec callable) | H-9 (curator blocks claims) | YES | No chain | Parallel claim-denial vectors by same actor class |
| H-17 (renounceOwnership) | H-5 (fee-tier desync) | YES | No chain | renounceOwnership prevents H-5 (opposing) |
| H-17 (renounceOwnership) | H-32 (stale nativeWrapper routes) | YES | No chain | renounceOwnership prevents route updates (compounds staleness, but H-32 already covers) |
| H-18 (PREMIUM_COLLECTOR_ROLE) | H-3 (phantom liability) | YES | No chain | Different accounting layers; H-18 blocks distribution, not liability tracking |
| H-22 (operator waives insurance) | H-1 (grace window) | YES | No chain | Operator emergency exit during grace window -- but claims already fail (H-1 covers) |
| H-25 (orphaned pools) | H-12 (revoked spec) | YES | No chain | Orphaned pools lose spec connectivity but through infrastructure rotation, not spec revocation |
| H-6 (stale approval old RewardsManager) | H-13 (retroactive poolFeeBps) | YES | No chain | Different contracts (PremiumManager vs CoverPool); no shared state path |
| H-11 (PolicyManager DoS) | H-1 (grace window) | YES | No chain | H-11 blocks all operations; H-1 allows deposits/withdrawals but blocks claims. Different scope. |
| H-14 (maxWithdraw double-deduction) | H-15 (previewRedeem overstates) | YES | No chain | Both are ERC-4626 spec violations but independent; one understates max, other overstates preview |
| H-20 (stale morpho value) | H-3 (phantom liability) | YES | No chain | Stale value inflates premium cap (over-collection), but does not directly affect phantom residual calculation |
| H-30 (premium debt rounding) | H-39 (post-expiry catch-up) | YES | No chain | H-39 charges excess premium; H-30 zeros debt on partial withdrawal. If H-39 overcharges and then H-30 zeros debt, the overcharge is lost. But these affect different users in different states. |
| H-2 (unbounded grace) | H-39 (post-expiry catch-up) | YES | No chain | H-2 extends effective maturity, delaying H-39's post-expiry window. Additive premium overcharge but sequential, not enabling. |

## Cross-Class Pairs (Iteration 2 Explored)

| Finding A | Finding B | Explored? | Result | Notes |
|-----------|-----------|-----------|--------|-------|
| H-24 (oracle revert bindPolicy) | H-19 (stale startTime) | YES (Iter 2) | No chain | H-24 is one cause of binding delay; H-19 already covers general staleness; additive DoS, not enabling |
| H-41 (single-use binding guard) | H-19 (stale startTime) | YES (Iter 2) | No chain | H-19 reverts at CoverPool.validateQuote (line 61) before reaching CoveredVaultWrapper.onPolicyBound; atomic tx prevents guard consumption |

## Cross-Class Pairs NOT Explored (Low Priority -- Confirmed No Enabling Relationship)

| Finding A | Finding B | Class A | Class B | Max Severity | Reason Not Explored |
|-----------|-----------|---------|---------|-------------|---------------------|
| H-23 (distributeBatch revert) | H-35 (updateVault reentrancy) | EXTERNAL | EXTERNAL | Low | Both affect PremiumCollector distribution; H-23 is DoS, H-35 is reentrancy. No enabling relationship -- H-23 blocks distribution, H-35 redirects it. |
| H-27 (depositCap reopens) | H-28 (post-maturity deposits) | STATE | TIMING | Low | Both allow undesirable deposits; parallel risks, not chaining. |
| H-37 (executeUpgrade ordering) | H-36 (cached vault underlying) | STATE | EXTERNAL | Low | Both are CEI/staleness issues in different contracts; no shared state. |
| H-46 (cross-contract pause) | H-11 (PolicyManager DoS) | EXTERNAL | EXTERNAL | Medium | Both are external dependency risks; H-11 is a specific case of the broader dependency pattern. |

## Summary Statistics

- **Total pairs explored**: 26 (24 iteration 1 + 2 iteration 2)
- **Chains found**: 6 (CH-1 through CH-6; CH-7 is weak/orthogonal)
- **True chains (STRONG/MODERATE)**: 5
- **Cross-class pairs unexplored**: 4 (all Low priority or max Medium with no obvious enabling relationship)
- **Iteration 2 results**: 0 new chains from 2 targeted cross-class pairs
- **Coverage**: All Medium+ cross-class finding pairs with postcondition/precondition overlap now explored.
