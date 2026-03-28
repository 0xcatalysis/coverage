# Findings Inventory

**Total: 55 findings (33 original Phase 1-3 + 22 new from Phase 3b/3c; 4 discarded as duplicates + 1 REFUTED)**

## Findings Inventory Table

| # | Finding ID | Agent | Severity | Location | Title | Verdict | Step Execution | Rules Applied | Notes |
|---|-----------|-------|----------|----------|-------|---------|---------------|---------------|-------|
| 1 | CS-1 | Core State Economics (#1) | Medium | CoveredVaultAdmin.sol:178-181, CoveredVaultAccrual.sol:124,156-157 | Unbounded gateGracePeriod Accumulation Extends Insurance Eligibility Indefinitely | CONFIRMED | ✓1,2,3,3b,4,5 | R4:✗(clear), R5:✗(single entity), R6:✓, R8:✓, R10:✓, R14:✓ | [TRACE] evidence tag present |
| 2 | CS-2 | Core State Economics (#1) | Medium | CoveredVaultWrapper.sol:574-583, 106-109 | totalPremiumLiability Residual Inflates After Deep-Loss Withdrawals | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✓, R8:✓, R10:✓, R14:✓ | [BOUNDARY][TRACE] evidence tags present |
| 3 | CS-3 | Core State Economics (#1) | Low | CoveredVaultAccrual.sol:39-47, 139-147, CoveredVaultAdmin.sol:170-177 | Stale lastKnownMorphoValue During Gate Allows Accrual Cap to Use Outdated Value | PARTIAL | ✓1,2,3,3b,4,5 | R4:✗(clear), R5:✗(single entity), R6:✓, R8:✓, R10:✓, R16:✗(no oracle) | [VARIATION] evidence tag |
| 4 | CS-4 | Core State Economics (#1) | Low | CoveredVaultAdmin.sol:34-44 | Premium Rate Change is Retroactive to All Existing Positions | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✓, R6:✓, R8:✓, R10:✓, R13:✓, R14:✗(no aggregate) | [TRACE] evidence tag |
| 5 | CS-5 | Core State Economics (#1) | Medium | CoveredVaultAdmin.sol:57-69,80-89, CoveredVaultWrapper.sol:628-635 | deductibleBps and maxCoverableLossBps Changes Apply Retroactively to Pre-Existing Losses | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✓, R6:✓, R8:✓, R10:✓, R13:✓, R14:✓ | [BOUNDARY][VARIATION] evidence tags |
| 6 | CS-6 | Core State Economics (#1) | Low | CoveredVaultAccrual.sol:63-64, CoveredVaultWrapper.sol:622-625 | cumulativePremiumPerUnit Precision Loss With Small totalPrincipal | PARTIAL | ✓1,2,3,4,5 | R4:✗(clear), R5:✓, R8:✗(single-step), R10:✓, R14:✗(no aggregate) | [BOUNDARY] evidence tag |
| 7 | CS-7 | Core State Economics (#1) | Informational | PremiumCollector.sol:289 | PremiumCollector._distribute Truncates lastDistributeTime to uint32 | CONFIRMED | ✓1,2,3 | R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✓ | Truncation safe until 2106 |
| 8 | CS-8 | Core State Economics (#1) | Informational | PremiumManager.sol:193-206 | Fee Split Rounding in PremiumManager.getFeeSplits Favors Restakers | CONFIRMED | ✓1,2,3 | R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✗(single state) | At most 2 wei dust |
| 9 | CS-9 | Core State Economics (#1) | Low | CoveredVaultWrapper.sol:467-469 | depositCap Reopens After Withdrawals Enabling Re-Deposit After Loss Event | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✓, R6:✗(no role), R8:✗(single-step), R10:✓, R13:✓, R15:✗(no flash-loan) | [TRACE] evidence tag |
| 10 | CS-10 | Core State Economics (#1) | Informational | CoveredVaultAccrual.sol:27-67 | _accruePremium Advances lastPremiumAccrualTime Even When premiumRatePerSecond == 0 | CONFIRMED | ✓1,2,3 | R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✗(single state) | By design — prevents catch-up |
| 11 | AC-1 | Access Control (#2) | Medium | CoverPoolFactory.sol:L115-158 | CREATOR_ROLE Can Replace Critical Infrastructure Addresses Without Timelock | CONFIRMED | ✓1,2,3,4,5,6 | R6:✓, R8:✗(single-step setter), R10:✓, R12:✓, R13:✗(not design), R14:✗(no aggregate) | Future-pools-only blast radius |
| 12 | AC-2 | Access Control (#2) | Medium | CoverPool.sol:L147-149, ClaimManager.sol:L297 | CoverPool Curator Can Permanently Block Claims via setPremiumDefaulted | CONFIRMED | ✓1,2,3,4,5,6 | R6:✓, R10:✓, R12:✓, R13:✓, R14:✗(no aggregate) | Blocked by try/catch — returns 0 payout |
| 13 | AC-3 | Access Control (#2) | Medium | ClaimManager.sol:L179-184, L209, L235 | Claim Approval Gate Allows Curator to Permanently Block Multi-Claim Policies | CONFIRMED | ✓1,2,3,4,5,6 | R6:✓, R10:✓, R12:✓, R13:✓, R14:✗(no aggregate) | Race condition for insurance payouts |
| 14 | AC-4 | Access Control (#2) | Low | CoveredVaultAdmin.sol:L168-186 | CoveredVaultWrapper Owner morphoGateActive Toggle Has No Timelock | PARTIAL | ✓1,2,3,4,5,6 | R6:✓, R8:✗(single-step), R10:✓, R12:✓, R13:✓, R14:✗(no aggregate) | Stale value risk during normal Morpho ops |
| 15 | AC-5 | Access Control (#2) | Informational | Swapper.sol:L146-173 | SWAP_MANAGER_ROLE Route Configuration Constrained by Whitelist | REFUTED | ✓1,2,3,4,5,6 | R6:✓, R8:✗(single-step), R10:✓, R12:✗(no dangerous precondition) | Whitelist mitigates fully |
| 16 | AC-6 | Access Control (#2) | Informational | CoverPool.sol:L93 | CoverPool Curator 24-Hour Admin Transfer Delay is Short | PARTIAL | ✓1,2,3,4,5,6 | R6:✓, R10:✓, R12:✗(no dangerous precondition), R13:✓, R14:✗(no aggregate) | Two-step sound; short window noted |
| 17 | AC-7 | Access Control (#2) | Informational | CoveredVaultAdmin.sol:L116-124 | CoveredVaultWrapper Ownership Uses Ownable2Step but Pending Timelocks Cleared on Transfer | CONFIRMED | ✓1,2,3,4,5,6 | R6:✓, R8:✓, R10:✓, R12:✗(no dangerous precondition), R13:✗(not design) | Positive finding — defensive design |
| 18 | AC-8 | Access Control (#2) | Low | CoveredVaultAdmin.sol:L141-149 | Pending Upgrade State Not Cleared Before upgradeToAndCall in executeUpgrade | CONFIRMED | ✓1,2,3,4,5,6 | R6:✓, R8:✓, R10:✓, R12:✗(no dangerous precondition), R13:✗(not design) | Low risk due to 7d timelock |
| 19 | AC-9 | Access Control (#2) | Informational | PremiumManager.sol:L102-114 | PremiumManager approveSpender Allows Arbitrary ERC-20 Approvals | CONFIRMED | ✓1,2,3,4,5,6 | R6:✗(FULLY_TRUSTED), R10:✓, R12:✗(no dangerous precondition), R13:✗(not design) | FULLY_TRUSTED admin; informational |
| 20 | OZ-1 | Oracle/Zero-State (#4) | Low | PolicyManager.sol:L266-274 | Oracle Revert in bindPolicy Causes Unrecoverable DoS on Policy Binding | PARTIAL | ✓1,2,3,3d,5b,6 | R4:✓, R5:✗(single oracle), R6:✗(no role), R8:✗(single-step), R10:✓, R16:✓ | Admin can replace chainlinkPriceFeed |
| 21 | OZ-2 | Oracle/Zero-State (#4) | Low | CoveredVaultWrapper.sol:L467-469 | Deposits Accepted After Policy Maturity Without Insurance Coverage | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✓, R13:✓, R16:✗(no oracle) | User informational gap — no fraud |
| 22 | OZ-3 | Oracle/Zero-State (#4) | Medium | CoveredVaultAccrual.sol:L139-147 | _morphoValue() Fallback to Stale lastKnownMorphoValue Can Misrepresent Assets During Morpho Downtime | PARTIAL | ✓1,2,3,4,5 | R4:✓, R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R16:✗(not oracle per se) | [TRACE][VARIATION] evidence tags |
| 23 | OZ-4 | Oracle/Zero-State (#4) | N/A | CoverPool.sol:L329-343 | EfficientHashLib Quote Hash Truncates basePremium Field — REFUTED | REFUTED | ✓1,2 | R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✗(single state) | No truncation found |
| 24 | OZ-5 | Oracle/Zero-State (#4) | Low | CoveredVaultAdmin.sol:L196-213 | rescueTokens for Morpho Shares Uses totalPrincipal > 0 as Proxy for Tracked Shares | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✗(single entity), R6:✓, R8:✗(single-step), R10:✓, R14:✓ | [TRACE][BOUNDARY] dust scenario only |
| 25 | OZ-6 | Oracle/Zero-State (#4) | Informational | CoveredVaultAccrual.sol:L153-159 | _isPolicyActive() Makes External Call to PolicyManager on Every Deposit/Withdraw | CONFIRMED | ✓1,2,3 | R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✗(single state) | Gas optimization only |
| 26 | TF-1 | Token Flow/External (#3) | Low | ClaimManager.sol:659 | ClaimManager uses block.timestamp as swap deadline providing zero MEV protection | CONFIRMED | ✓1,2,3,4,5,6,7,8,9 | R4:✗(clear), R5:✗(single entity), R6:✓, R8:✗(single-step), R10:✓, R11:✗(no external tokens), R15:✗(no flash-loan), R16:✗(no oracle) | amountOutMin provides partial protection |
| 27 | TF-2 | Token Flow/External (#3) | Informational | CoveredVaultAdmin.sol:205-209 | rescueTokens Morpho Shares Proxy Check — REFUTED | REFUTED | ✓1,2,3,4,5 | R4:✗(clear), R5:✗(single entity), R6:✗(no role — owner action), R8:✗(single-step), R10:✓, R14:✓ | Dust cleanup is intended behavior |
| 28 | TF-3 | Token Flow/External (#3) | Low | CoveredVaultAccrual.sol:139-147 | Unsolicited Morpho Share Donation Inflates _morphoValue() But Yields No Attacker Profit | CONFIRMED | ✓1,2,3,4,5,5b | R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✓, R11:✓, R15:✓ | Gift to depositors; no extraction |
| 29 | TF-4 | Token Flow/External (#3) | Medium | ClaimManager.sol:640-650 | quoteSwap Returns 0 on Route Failure — amountOutMin=1 Enables Near-Total Sandwich | CONFIRMED | ✓1,2,3,4,5,8 | R4:✓, R5:✗(single entity), R6:✓, R8:✗(single-step), R10:✓, R11:✗(no external tokens), R15:✗(no flash-loan state) | Requires simultaneous quote failure + MEV |
| 30 | TF-5 | Token Flow/External (#3) | Low | ClaimManager.sol:586-670 | Fee-on-Transfer Collateral Tokens Cause _executeCollateralSwap to Approve More Than Received | PARTIAL | ✓1,2,3,8,9 | R4:✓, R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✓, R11:✗(no unsolicited), R16:✗(no oracle) | Depends on collateral token type |
| 31 | TF-6 | Token Flow/External (#3) | Informational | CoveredVaultWrapper.sol:341-380 | _claimInsurance balance-diff Pattern Correctly Measures Payout — Positive Finding | CONFIRMED | ✓1,2,3,5,8 | R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✗(single state), R11:✗, R16:✗ | Positive confirmation — design sound |
| 32 | TF-7 | Token Flow/External (#3) | Medium | CoveredVaultAccrual.sol:153-159, CoveredVaultWrapper.sol:328 | _isPolicyActive External Call to PolicyManager Blocks All Withdrawals When PolicyManager Unavailable | PARTIAL | ✓1,2,3 | R4:✓, R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✓, R12:✗(no dangerous precondition), R16:✗(no oracle) | Emergency path also affected via _accruePremium |
| 33 | TF-8 | Token Flow/External (#3) | Informational | Swapper.sol:240-241, 146-173 | Swapper _performSwap Stored Route Calldata Static and May Become Stale | CONFIRMED | ✓1,2,3,8 | R4:✗(clear), R5:✗(single entity), R6:✓, R8:✓, R10:✗(single state), R11:✗, R16:✗ | Swapper-level check is effective gate |
| 34 | RS1-1 | Re-Scan Agent #1 | High | CoveredVaultAccrual.sol:116-136, CoveredVaultAccrual.sol:150-159, ClaimManager.sol:306-309 | gateGracePeriod Extension Renders Insurance Uncollectable During Grace Window | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✓, R6:✓, R8:✓, R10:✓, R12:✓, R13:✓, R11:✗, R14:✗, R15:✗, R16:✗ | ClaimManager enforces raw maturityTime; vault uses effectiveMaturity; users pay premium with zero coverage in grace window |
| 35 | RS1-2 | Re-Scan Agent #1 | Medium | CoveredVaultWrapper.sol:241-262 | Authorized Operators Can Waive Owner's Insurance by Calling emergencyRedeem/emergencyWithdraw | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✗(single entity), R6:✓, R8:✗(single-step), R10:✓, R12:✓, R13:✓, R11:✗, R14:✗, R15:✗, R16:✗ | Operator sets SKIP_INSURANCE_SLOT; owner bears economic loss with no insurance; requires allowance |
| 36 | RS1-3 | Re-Scan Agent #1 | Low | CoverPoolFactory.sol:222-229 | CoverPoolFactory Salt Excludes specRegistry and stakeManager — computeCoverPoolAddress Returns Stale Address After Infrastructure Rotation | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✗(single entity), R6:✓, R8:✓, R10:✓, R12:✗, R13:✗, R11:✗, R14:✗, R15:✗, R16:✗ | PC2-2 adds consequence re address prediction use case — merged here |
| 37 | RS2-1 | Re-Scan Agent #2 | Medium | SpecRegistry.sol:84-88, SpecRegistry.sol:127-130 | SpecRegistry.revokeSpec Does Not Prevent Existing Policies From Using Revoked Specs | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✓, R6:✓, R8:✗(single-step setter), R10:✓, R12:✓, R13:✓, R14:✗ | PC2-4 is duplicate of this finding (same root cause, same location) — discarded |
| 38 | RS2-2 | Re-Scan Agent #2 | Low | PremiumCollector.sol:163-168, PremiumCollector.sol:265-296 | PremiumCollector.distributeBatch Has No Per-Vault Error Isolation | CONFIRMED | ✓1,2,3,4,5 | R4:✓, R5:✓, R6:✗(no role), R8:✗(single-step), R10:✓, R12:✗, R13:✓ | No fund loss; premium distribution deferred; single failing vault collapses entire batch |
| 39 | RS2-3 | Re-Scan Agent #2 | Informational | ClaimManager.sol:599-613 | Excess Collateral Stranded in ClaimManager When Same-Token Payout Exceeds Remaining Coverage | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✓, R11:✓, R13:✓, R15:✗ | PC3-3 is duplicate of this finding — discarded |
| 40 | RS3-2 | Re-Scan Agent #3 | Low | CoveredVaultWrapper.sol:358, ClaimManager.sol:293 | Stale Evidence Hash from block.timestamp Can Cause Second Same-Block Claim Denial | PARTIAL | ✓1,2,3,✗4(narrow conditions),5 | R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R11:✗, R12:✗, R13:✗, R14:✗, R15:✗, R16:✗ | Requires same-block same-user same-cappedClaim collision; PARTIAL due to narrow preconditions |
| 41 | PC1-1 | Per-Contract Agent #1 | Low | CoveredVaultWrapper.sol:442-453 | maxWithdraw() Double-Deducts Premium, Systematically Understating Maximum Withdrawable Assets | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✓, R6:✗(no role), R8:✗(single-step view), R10:✓, R13:✓, R11:✗, R12:✗, R14:✗, R15:✗, R16:✗ | [BOUNDARY][VARIATION][TRACE] depth evidence; ERC-4626 maxWithdraw spec violation; understatement grows with owedPremium |
| 42 | PC1-2 | Per-Contract Agent #1 | Low | CoveredVaultAccrual.sol:116-136 | _activeElapsedFrom Returns Stale Catch-Up Window When lastPremiumAccrualTime Predates Policy Start | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R11:✗, R12:✗, R13:✗, R14:✗, R15:✗, R16:✗ | [BOUNDARY][VARIATION][TRACE] depth evidence; phantom premium accrual for pre-policy period |
| 43 | PC1-3 | Per-Contract Agent #1 | Informational | CoveredVaultWrapper.sol:186-195, CoveredVaultWrapper.sol:583-584 | _withdraw Decrements totalPrincipal After External Interactions, Creating Transient Invariant Break During Morpho/ClaimManager Callbacks | PARTIAL | ✓1,2,3,4,5 | R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R12:✓, R13:✗, R14:✓, R11:✗, R15:✗, R16:✗ | [TRACE][BOUNDARY][VARIATION] depth evidence; design hygiene; no current exploitation path |
| 44 | PC1-4 | Per-Contract Agent #1 | Low | CoveredVaultAdmin.sol:168-186, CoveredVaultAccrual.sol:116-136, CoveredVaultStorage.sol:160-161 | setMorphoGateActive Allows Multiple Activations Without Cap, Unboundedly Growing gateGracePeriod Without Audit Trail | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✗(single entity), R6:✓, R8:✓, R10:✓, R12:✓, R13:✓, R11:✗, R14:✗, R15:✗, R16:✗ | [BOUNDARY][VARIATION][TRACE] depth evidence; compounds RS1-1; no cap enforced; owner can extend effective maturity indefinitely |
| 45 | PC2-1 | Per-Contract Agent #2 | Medium | CoverPool.sol:L61, PolicyManager.sol:L155–L203 | Quote Requires startTime >= block.timestamp But Binding Happens After Draft Creation — All Quotes Go Stale | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✗(single path), R6:✗(no semi-trusted shortcut), R8:✓, R10:✓, R11:✗, R12:✗, R13:✗, R14:✗, R15:✗, R16:✗ | [BOUNDARY][TRACE][VARIATION] depth evidence; policy binding fails on any non-zero delay between requestCoverage and bindPolicyForRequest |
| 46 | PC2-3 | Per-Contract Agent #2 | Low | PolicyManager.sol:L299–L306, CoveredVaultWrapper.sol:L282–L309 | bindPolicy Calls onPolicyBound Hook After Setting PolicyStatus.Bound — Misconfigured Wrapper Permanently Blocks Binding | CONFIRMED | ✓1,2,3,4,5 | R4:✓, R5:✗(single vault hook), R6:✗, R8:✓, R10:✓, R11:✗, R12:✗, R13:✗, R14:✗, R15:✗, R16:✗ | [TRACE][VARIATION][BOUNDARY] depth evidence; single-use policyBoundExecuted guard; misconfigured wrapper permanently blocks re-binding |
| 47 | PC2-5 | Per-Contract Agent #2 | Informational | PolicyManager.sol:L358–L373, CoverPool.sol:L51–L64 | PolicyManager._validateRequest Does Not Enforce startTime >= block.timestamp — Defence-in-Depth Gap | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✗(single entity), R6:✗, R8:✓, R10:✓, R11:✗, R12:✗, R13:✗, R14:✗, R15:✗, R16:✗ | [BOUNDARY][TRACE][VARIATION] depth evidence; CoverPool enforces check before PolicyManager; future pool implementation could bypass |
| 48 | PC3-1 | Per-Contract Agent #3 | High | ClaimManager.sol:L663-L669 | Excess Swap Output Permanently Stranded in ClaimManager | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✓, R6:✗(no role), R8:✓, R10:✓, R11:✓, R12:✓, R13:✗, R14:✗, R15:✗, R16:✗ | [TRACE][BOUNDARY] depth evidence; surplus swapOutput - remainingPayout locked in ClaimManager; vault stakers over-slashed |
| 49 | PC3-2 | Per-Contract Agent #3 | High | UniswapV3Adapter.sol:L127-L135, UniswapV3Adapter.sol:L155-L188 | UniswapV3Adapter Fee-Tier Mismatch Between quote and swap Breaks Slippage Calculation | CONFIRMED | ✓1,2,3,4,5 | R4:✓, R5:✓, R6:✗(no role), R8:✓, R10:✓, R11:✓, R12:✓, R13:✗, R14:✗, R15:✗, R16:✗ | [VARIATION][TRACE] depth evidence; pairFees vs stored calldata desync; claim DoS (scenario A) or weakened slippage (scenario B) |
| 50 | PC3-4 | Per-Contract Agent #3 | Low | ClaimManager.sol:L179-L185 | approveNextClaim Emits Misleading Event When Called on Non-Gated Policy | CONFIRMED | ✓1,2,3,4,✗5(N/A) | R4:✗(clear), R5:✗(single entity), R6:✗, R8:✗(single-step), R10:✓, R11:✗, R12:✗, R13:✓, R14:✗, R15:✗, R16:✗ | [BOUNDARY] depth evidence; off-chain monitoring receives false approval signals |
| 51 | PC3-5 | Per-Contract Agent #3 | Low | ClaimManager.sol:L311, ClaimManager.sol:L222-L225 | _fileClaimWithMetadata Permanently Consumes evidenceHash Even on Subsequently Rejected Claims | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✓, R6:✗(no role), R8:✓, R10:✓, R11:✗, R12:✗, R13:✓, R14:✗, R15:✗, R16:✗ | [TRACE][BOUNDARY] depth evidence; legitimate claimant permanently blocked from re-filing same evidence after transient rejection |
| 52 | PC4-1 | Per-Contract Agent #4 | Medium | PremiumManager.sol:93-97, PremiumManager.sol:102-113 | Stale Approval Persists on Old RewardsManager After setRewardsManager Update | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✗(single entity flow), R6:✗, R8:✓, R10:✓, R11:✓, R12:✓, R13:✗, R14:✗, R15:✗, R16:✗ | [TRACE][BOUNDARY][VARIATION] depth evidence; unlimited allowance persists; old rewardsManager can drain PremiumManager token balances |
| 53 | PC4-2 | Per-Contract Agent #4 | Medium | PremiumManager.sol:154, CoverPool.sol:123-130 | poolFeeBps Read Live at Distribution Time Enables Retroactive Fee Increase on Accrued Premium | CONFIRMED | ✓1,2,3,4,5 | R4:✗(clear), R5:✗(single pool), R6:✓, R8:✓, R10:✓, R12:✓, R13:✓, R11:✗, R14:✗, R15:✗, R16:✗ | [TRACE][VARIATION][BOUNDARY] depth evidence; curator can front-run distribution with fee spike; restakers systematically underpaid |
| 54 | PC4-3 | Per-Contract Agent #4 | Low | PremiumCollector.sol:147-158, PremiumCollector.sol:283, 293 | updateVault Missing nonReentrant While External Calls in _distribute Can Reach It | CONFIRMED | ✓1,2,3,4,✗5(N/A—admin-controlled) | R4:✗(clear), R5:✗(single vault), R6:✓, R8:✓, R10:✓, R11:✗, R12:✗, R13:✗, R14:✗, R15:✗, R16:✗ | [TRACE][BOUNDARY] depth evidence; premium distribution redirectable mid-flight via re-entrant updateVault; requires admin-level trust violation |
| 55 | PC4-4 | Per-Contract Agent #4 | Low | PremiumCollector.sol:105-108, PremiumCollector.sol:283-290 | PremiumCollector Caches Vault Underlying at Registration — Mismatch Causes Wrong Token Transfer | PARTIAL | ✓1,2,3,✗4(N/A standard vaults),5 | R4:✗(clear), R5:✗(single vault), R6:✗, R8:✓, R10:✓, R11:✓, R12:✓, R13:✗, R14:✗, R15:✗, R16:✗ | [TRACE][BOUNDARY] depth evidence; requires non-standard vault with mutable asset(); PARTIAL due to precondition on non-standard vault |

---

## Phase 3b/3c Duplicate/Refuted Findings (Not Added)

| Discarded ID | Agent | Duplicate Of | Reason |
|-------------|-------|-------------|--------|
| RS3-1 | Re-Scan Agent #3 | RS1-1 | Same root cause: gateGracePeriod/ClaimManager maturityTime mismatch, same locations |
| PC2-2 | Per-Contract Agent #2 | RS1-3 | Same root cause: CoverPoolFactory salt excludes stakeManager/specRegistry; PC2-2 consequence (address prediction use case) merged into RS1-3 notes |
| PC2-4 | Per-Contract Agent #2 | RS2-1 | Same root cause: revokeSpec clears _approvedSpecs but not _specs mapping, same location SpecRegistry.sol:84-88, 127-130 |
| PC3-3 | Per-Contract Agent #3 | RS2-3 | Same root cause: excess collateral stranded on same-token path, same location ClaimManager.sol:599-613 |
| PC1-5 | Per-Contract Agent #1 | N/A | REFUTED: _withdraw burns shares before Morpho redeem but unconditional revert on Morpho failure rolls back entire tx atomically |

---

## Chain Summary

| Finding ID | Location | Root Cause (1-line) | Verdict | Severity | Precondition Type | Postcondition Type |
|-----------|----------|---------------------|---------|----------|-------------------|-------------------|
| CS-1 | CoveredVaultAdmin.sol:178-181 | gateGracePeriod accumulates unboundedly across each gate cycle, extending effective maturity and premium accrual | CONFIRMED | Medium | STATE | STATE, TIMING |
| CS-2 | CoveredVaultWrapper.sol:574-583 | totalPremiumLiability decremented by min(uncappedPremium, assetsReceived) leaving phantom delta for deep-loss withdrawals | CONFIRMED | Medium | STATE | STATE, BALANCE |
| CS-3 | CoveredVaultAccrual.sol:139-147 | lastKnownMorphoValue cached at gate activation may be stale if convertToAssets still reverts during gate | PARTIAL | Low | EXTERNAL | STATE |
| CS-4 | CoveredVaultAdmin.sol:34-44 | New premium rate applies to all existing depositors' principal with only 2h operational notice | CONFIRMED | Low | ACCESS | STATE |
| CS-5 | CoveredVaultAdmin.sol:57-89 | deductibleBps and maxCoverableLossBps read at withdrawal time, not at loss-event time, retroactively reducing payouts | CONFIRMED | Medium | ACCESS | STATE, BALANCE |
| CS-6 | CoveredVaultAccrual.sol:63-64 | mulDiv rounding in reward-per-token accumulator causes dust premium under-collection at small totalPrincipal | PARTIAL | Low | STATE | STATE |
| CS-9 | CoveredVaultWrapper.sol:467-469 | depositCap reopens after withdrawals, increasing coverage pool's insured principal exposure during loss | CONFIRMED | Low | STATE | STATE, BALANCE |
| AC-1 | CoverPoolFactory.sol:115-158 | CREATOR_ROLE can replace implementation and dependency addresses with no timelock; only affects future pools | CONFIRMED | Medium | ACCESS | STATE, ACCESS |
| AC-2 | CoverPool.sol:147-149, ClaimManager.sol:297 | Curator can set premiumDefaulted=true blocking all future claims; try/catch returns 0 insurance payout | CONFIRMED | Medium | ACCESS | STATE, ACCESS |
| AC-3 | ClaimManager.sol:179-235 | _claimApprovalRequired set true after each payout; curator must manually reset, creating first-claimer race condition | CONFIRMED | Medium | ACCESS | STATE, ACCESS |
| AC-4 | CoveredVaultAdmin.sol:168-186 | morphoGateActive toggle without timelock allows owner to cache stale Morpho value if activated during normal operation | PARTIAL | Low | ACCESS | STATE, TIMING |
| AC-8 | CoveredVaultAdmin.sol:141-149 | executeUpgrade clears pending state AFTER upgradeToAndCall; stale pending values exist in new impl context momentarily | CONFIRMED | Low | STATE | STATE |
| OZ-1 | PolicyManager.sol:266-274 | No try/catch around Chainlink oracle calls in bindPolicy; oracle failure causes full DoS on policy binding | PARTIAL | Low | EXTERNAL | STATE |
| OZ-2 | CoveredVaultWrapper.sol:467-469 | maxDeposit only checks policyBoundExecuted, not maturity; post-maturity deposits accepted with no insurance | CONFIRMED | Low | TIMING | STATE, TIMING |
| OZ-3 | CoveredVaultAccrual.sol:139-147 | _morphoValue falls back to stale lastKnownMorphoValue when convertToAssets reverts; owner gate not activated promptly | PARTIAL | Medium | EXTERNAL + ACCESS | STATE, TIMING |
| OZ-5 | CoveredVaultAdmin.sol:196-213 | rescueTokens uses totalPrincipal>0 as proxy for tracked morpho shares; when totalPrincipal=0 all shares can be swept | CONFIRMED | Low | ACCESS | ACCESS, BALANCE |
| TF-1 | ClaimManager.sol:659 | block.timestamp as swap deadline provides no MEV time protection; slippage amountOutMin is partial mitigation | CONFIRMED | Low | TIMING | TIMING |
| TF-4 | ClaimManager.sol:640-650 | quoteSwap return value of 0 leaves amountOutMin=1 when quote fails, enabling near-total sandwich extraction | CONFIRMED | Medium | EXTERNAL | EXTERNAL, BALANCE |
| TF-5 | ClaimManager.sol:586-670 | Fee-on-transfer collateral token balance less than approved amount causes safeTransferFrom to revert | PARTIAL | Low | EXTERNAL | EXTERNAL |
| TF-7 | CoveredVaultAccrual.sol:153-159 | _isPolicyActive makes uncaught external call that propagates through _accruePremium blocking ALL withdrawals | PARTIAL | Medium | EXTERNAL | STATE, EXTERNAL |
| RS1-1 | CoveredVaultAccrual.sol:116-136, ClaimManager.sol:306-309 | gateGracePeriod extends vault _isPolicyActive window past raw maturityTime; ClaimManager enforces raw maturityTime; all grace-window claims silently fail | CONFIRMED | High | STATE, TIMING | STATE, EXTERNAL |
| RS1-2 | CoveredVaultWrapper.sol:241-262 | emergencyRedeem/emergencyWithdraw accessible to ERC-20 operators who can waive owner's insurance via SKIP_INSURANCE_SLOT without owner consent | CONFIRMED | Medium | ACCESS | STATE, BALANCE |
| RS1-3 | CoverPoolFactory.sol:222-229 | CoverPoolFactory CREATE2 salt excludes stakeManager/specRegistry; infrastructure rotation leaves existing pools on old addresses; CREATE2 collision blocks re-deployment with same params | CONFIRMED | Low | STATE | STATE |
| RS2-1 | SpecRegistry.sol:84-88, 127-130 | revokeSpec clears _approvedSpecs flag but not _specs mapping; resolveSpec reads only _specs; revoked specs remain callable by ClaimManager indefinitely | CONFIRMED | Medium | ACCESS | STATE |
| RS2-2 | PremiumCollector.sol:163-168, 265-296 | distributeBatch no try/catch per vault; single vault revert collapses entire batch; premium distribution deferred for all healthy vaults | CONFIRMED | Low | EXTERNAL | TIMING |
| RS2-3 | ClaimManager.sol:599-613 | Same-token path caps transfer at remainingPayout but slashes full collateralAmount; excess stranded in ClaimManager | CONFIRMED | Informational | STATE | BALANCE |
| RS3-2 | CoveredVaultWrapper.sol:358, ClaimManager.sol:293 | evidenceHash constructed from block.timestamp; same-block same-user same-cappedClaim collision silently denies second claim | PARTIAL | Low | TIMING, STATE | STATE |
| PC1-1 | CoveredVaultWrapper.sol:442-453 | maxWithdraw subtracts owedPremium from grossAssets which already excludes it via totalAssets(); double-deduction grows linearly with owedPremium | CONFIRMED | Low | STATE | STATE |
| PC1-2 | CoveredVaultAccrual.sol:116-136 | _activeElapsedFrom active-policy branch returns block.timestamp-checkpoint without clamping to meta.startTime; enables phantom pre-policy premium accrual | CONFIRMED | Low | TIMING | STATE, BALANCE |
| PC1-3 | CoveredVaultWrapper.sol:186-195 | totalPrincipal decremented after _executeWithdrawal returns; stale value observable during Morpho/ClaimManager callbacks via view calls | PARTIAL | Informational | EXTERNAL | STATE |
| PC1-4 | CoveredVaultAdmin.sol:168-186 | gateGracePeriod accumulates unboundedly across gate cycles with no cap; owner can extend effective maturity indefinitely; compounds RS1-1 (every grace cycle = more no-coverage premium) | CONFIRMED | Low | ACCESS | STATE, TIMING |
| PC2-1 | CoverPool.sol:L61, PolicyManager.sol:L155-L203 | validateQuote enforces startTime >= block.timestamp at bind time but quotes are created before bind; any delay causes startTime to be in past → binding revert | CONFIRMED | Medium | TIMING | STATE, TIMING |
| PC2-3 | PolicyManager.sol:L299-L306, CoveredVaultWrapper.sol:L282-L309 | onPolicyBound hook single-use guard permanently blocks re-binding; misconfigured wrapper causes opaque InvalidData revert on bindPolicy | CONFIRMED | Low | STATE, EXTERNAL | STATE |
| PC2-5 | PolicyManager.sol:L358-L373, CoverPool.sol:L51-L64 | PolicyManager._validateRequest omits startTime >= block.timestamp check; defence-in-depth gap; CoverPool enforces it before PolicyManager is called | CONFIRMED | Informational | EXTERNAL | STATE, TIMING |
| PC3-1 | ClaimManager.sol:L663-L669 | swap output capped at remainingPayout but full swapOutput received; surplus locked in ClaimManager; vault stakers over-slashed | CONFIRMED | High | STATE | BALANCE, STATE |
| PC3-2 | UniswapV3Adapter.sol:L127-L135, L155-L188 | pairFees mapping (used by quote) and stored calldata fee (used by swap) are independent; fee migration creates desync causing DoS (scenario A) or weakened slippage (scenario B) | CONFIRMED | High | STATE | EXTERNAL, STATE |
| PC3-4 | ClaimManager.sol:L179-L185 | approveNextClaim writes false without checking if approval was required; emits NextClaimApproved as no-op; misleads off-chain monitoring | CONFIRMED | Low | STATE | STATE |
| PC3-5 | ClaimManager.sol:L311, L222-L225 | _usedEvidenceHashes set before spec evaluation; rejected claim permanently consumes evidenceHash; legitimate claimer cannot refile same evidence | CONFIRMED | Low | STATE | STATE |
| PC4-1 | PremiumManager.sol:93-97, 102-113 | setRewardsManager does not revoke prior ERC20 allowance; old rewardsManager retains unlimited pull access to PremiumManager balances | CONFIRMED | Medium | ACCESS | ACCESS, BALANCE |
| PC4-2 | PremiumManager.sol:154, CoverPool.sol:123-130 | poolFeeBps read live at distribution time; curator can front-run distributor by spiking fee; retroactive application to full accrual period | CONFIRMED | Medium | ACCESS | STATE, BALANCE |
| PC4-3 | PremiumCollector.sol:147-158, 283, 293 | updateVault lacks nonReentrant while _distribute makes external calls; malicious vault can re-enter updateVault to redirect distribution mid-flight | CONFIRMED | Low | EXTERNAL | STATE, BALANCE |
| PC4-4 | PremiumCollector.sol:105-108, 283-290 | underlying cached at registerVault; if vault.asset() changes (non-standard vault), distribution sends wrong token to PremiumManager | PARTIAL | Low | EXTERNAL | BALANCE, STATE |

---

## REFUTED Findings (for Depth Second Opinion)

| Finding ID | Agent | Reason for REFUTED | Missing Precondition | Domain |
|-----------|-------|---------------------|---------------------|--------|
| AC-5 | Access Control (#2) | SWAP_MANAGER_ROLE route configuration mitigated by whitelist double-gate at setup + execution time | Whitelist check prevents malicious route execution | Access Control |
| OZ-4 | Oracle/Zero-State (#4) | EfficientHashLib has proper 11-param overload; address casts correctly zero-extend; no truncation | N/A — design is sound | Oracle/Encoding |
| TF-2 | Token Flow/External (#3) | totalPrincipal==0 with meaningful userMorphoShares is practically impossible due to atomic deposit/withdraw; dust cleanup is intended | N/A — dust cleanup intended | Token Accounting |

---

## CONTESTED Findings (for Depth Priority)

| Finding ID | Agent | External Dep Involved | Worst-Case Severity | Notes |
|-----------|-------|-----------------------|---------------------|-------|
| TF-4 | Token Flow/External (#3) | UniswapV3 QuoterV2 (off-chain quoter) | High (near-total loss of claim payout) | Requires simultaneous QuoterV2 failure + MEV bot — R4 applied adversarially |
| TF-7 | Token Flow/External (#3) | PolicyManager (upgradeable proxy) | High (all user funds locked) | Emergency withdrawal also affected via _accruePremium path |
| OZ-3 | Oracle/Zero-State (#4) | Morpho V2 vault (convertToAssets revert) | Medium | Requires prolonged Morpho downtime + owner inaction |

---

## Incomplete Analysis Flags

| Finding ID | Missing Steps | Reason Invalid? | Flag for Depth? |
|-----------|--------------|-----------------|-----------------|
| CS-7 | Steps 4,5 not listed (marked ✓1,2,3 only) | Valid — simple uint32 truncation with 80-year horizon, no additional steps needed | NO |
| CS-8 | Steps 4,5 not listed (marked ✓1,2,3 only) | Valid — single-step rounding, no roles or multi-step involved | NO |
| CS-10 | Steps 4,5 not listed (marked ✓1,2,3 only) | Valid — informational/by-design finding | NO |
| TF-7 | Steps 4-9 listed as N/A | Valid — only step 1-3 relevant to the external dependency DoS finding | NO |
| TF-2 | Steps 6,7 listed as not applicable | Valid — refuted finding, design correct | NO |

No findings with ✗(no reason) or ? requiring depth review flagged.

---

## Rule Application Violations

| Finding ID | Rule | Expected | Actual | Violation? |
|-----------|------|----------|--------|------------|
| TF-2 | R6 | ✓ (owner action on user funds) | ✗(no role — owner action) | FLAG — owner IS a semi-trusted role; however OZ-5 (same location) correctly applies R6:✓. TF-2 is REFUTED so low risk. |
| CS-6 | R5 | ✓ (multi-user interaction) | ✓ | OK |
| OZ-3 | R16 | ✓ (Morpho dependency discussed) | R16:✗(not oracle per se) | MINOR — not an oracle finding, Morpho is ERC-4626 vault not oracle. Justified. |

**No high-severity rule violations found. TF-2 R6 omission is acceptable given REFUTED verdict.**

---

## Assumption Dependency Audit

| Finding ID | Attack Actor | Actor Trust Level | Within Bounds? | Tag | Original Severity |
|-----------|-------------|-------------------|----------------|-----|-------------------|
| CS-1 | CoveredVaultWrapper Owner | SEMI_TRUSTED(timelocked) | PARTIAL — toggling gate is within bounds; accumulating gateGracePeriod is NOT unlimited by stated bounds | No tag — real finding | Medium |
| CS-2 | N/A (systemic accounting) | N/A | N/A | No tag | Medium |
| CS-3 | CoveredVaultWrapper Owner | SEMI_TRUSTED(timelocked) | YES — activating gate is within bounds; stale value is a side effect of design | [ASSUMPTION-DEP: WITHIN-BOUNDS] | Low |
| CS-4 | CoveredVaultWrapper Owner | SEMI_TRUSTED(timelocked) | YES — setting premium rate within timelock bounds is stated capability | [ASSUMPTION-DEP: WITHIN-BOUNDS] | Low |
| CS-5 | CoveredVaultWrapper Owner | SEMI_TRUSTED(timelocked) | NO — retroactive impact on existing positions during active loss events exceeds expected bounds | No tag — real finding (harm during loss events is outside stated bounds) | Medium |
| CS-6 | N/A (precision) | N/A | N/A | No tag | Low |
| CS-7 | N/A (code quality) | N/A | N/A | No tag | Informational |
| CS-8 | N/A (rounding) | N/A | N/A | No tag | Informational |
| CS-9 | N/A (design behavior) | N/A | N/A | [ASSUMPTION-DEP: WITHIN-BOUNDS] (depositCap calculation is documented behavior) | Low |
| CS-10 | N/A (by design) | N/A | N/A | No tag | Informational |
| AC-1 | CREATOR_ROLE | SEMI_TRUSTED (designated creator) | NO — capability to replace protocol implementation exceeds "designated creator" bounds | No tag — real finding | Medium |
| AC-2 | CoverPool Curator | SEMI_TRUSTED(bounds: pool-scoped) | PARTIAL — setPremiumDefaulted IS within stated bounds (row 15 of trust table) BUT permanent denial without recourse is disproportionate | [ASSUMPTION-DEP: WITHIN-BOUNDS] for the mechanism; real finding for lack of recourse | Medium |
| AC-3 | CoverPool Curator | SEMI_TRUSTED(bounds: pool-scoped) | PARTIAL — approveNextClaim is within bounds, but its effect creates a race condition that harms users unequally | No tag — race condition is real harm | Medium |
| AC-4 | CoveredVaultWrapper Owner | SEMI_TRUSTED(timelocked) | YES — morphoGateActive toggle is explicitly stated as instant (no timelock); stale value risk during normal ops is edge case | [ASSUMPTION-DEP: WITHIN-BOUNDS] | Low |
| AC-5 | SWAP_MANAGER_ROLE | SEMI_TRUSTED | N/A — REFUTED | No tag | N/A |
| AC-6 | CoverPool Curator | SEMI_TRUSTED(bounds: 24h admin transfer) | YES — 24h delay IS the stated bound | [ASSUMPTION-DEP: WITHIN-BOUNDS] | Informational |
| AC-7 | N/A (positive design) | N/A | N/A | No tag | Informational |
| AC-8 | CoveredVaultWrapper Owner | SEMI_TRUSTED(timelocked) | YES — executeUpgrade is within owner bounds; ordering concern is low-risk | [ASSUMPTION-DEP: WITHIN-BOUNDS] | Low |
| AC-9 | DEFAULT_ADMIN_ROLE | FULLY_TRUSTED | YES — FULLY_TRUSTED can approve spenders | [ASSUMPTION-DEP: TRUSTED-ACTOR] | Informational → Informational (no change; already lowest tier) |
| OZ-1 | External (oracle failure) | EXTERNAL | N/A | No tag | Low |
| OZ-2 | N/A (design gap) | N/A | N/A | No tag | Low |
| OZ-3 | External (Morpho failure) | EXTERNAL | N/A | No tag | Medium |
| OZ-4 | N/A — REFUTED | N/A | N/A | No tag | N/A |
| OZ-5 | CoveredVaultWrapper Owner | SEMI_TRUSTED | NO — accessing user funds (even dust) is beyond stated rescue bounds when totalPrincipal logic is the proxy | No tag — real finding | Low |
| OZ-6 | N/A (gas) | N/A | N/A | No tag | Informational |
| TF-1 | MEV/External | UNTRUSTED | N/A | No tag | Low |
| TF-2 | N/A — REFUTED | N/A | N/A | No tag | N/A |
| TF-3 | UNTRUSTED (attacker) | UNTRUSTED | N/A | No tag | Low |
| TF-4 | MEV/External + UNTRUSTED | UNTRUSTED | N/A | No tag | Medium |
| TF-5 | External (token type) | EXTERNAL | N/A | No tag | Low |
| TF-6 | N/A — positive finding | N/A | N/A | No tag | Informational |
| TF-7 | External (PolicyManager) | SEMI_TRUSTED dependency | N/A | No tag | Medium |
| TF-8 | N/A — informational | N/A | N/A | No tag | Informational |

**Trust adjustment summary**:
- [ASSUMPTION-DEP: TRUSTED-ACTOR]: AC-9 (Informational → Informational; no tier change)
- [ASSUMPTION-DEP: WITHIN-BOUNDS] (flag only, no severity change): CS-3, CS-4, CS-9, AC-2 (mechanism only), AC-4, AC-6, AC-8

---

## Slither Finding Promotion

Slither MCP unavailable; grep-based static analysis reviewed:

| Pattern | Location | Finding |
|---------|----------|---------|
| `.call{` after state changes | Swapper.sol:330 (`recipient.call{value:...}`) | State changes occur before this ETH transfer in executeSwap; covered by nonReentrant. No new hypothesis needed. |
| Division before multiplication | CoveredVaultWrapper.sol:496 (`lastKnownMorphoValue * shares / totalShares`) | Multiplication before division (OK per static_analysis.md). No issue. |
| Loops with `.length` on storage arrays | PolicyManager.sol:266 | Loop over calldata array (safe). No issue. |

**Slither findings promoted: 0**

---

## Side Effect Trace Audit

| # | External Call | Side Effect | Token Type | Landing | Consuming Code | Handled? | Breadth Coverage | Finding |
|---|-------------|-------------|-----------|---------|---------------|----------|-----------------|---------|
| 1 | IVaultV2.deposit() | Returns Morpho shares | Morpho ERC-4626 shares | CoveredVaultWrapper._deposit (L124) | stored in userMorphoShares; required > 0 (L125) | YES — revert if 0 | YES (TF-3 — unsolicited shares) | None new |
| 2 | IVaultV2.redeem() | Returns underlying assets | Underlying ERC-20 | CoveredVaultWrapper._executeWithdrawal (L563) | assetsReceived passed to _settleWithdrawalTransfer | YES — try/catch (MorphoRedeemReverted) | YES (TF-7 — _accruePremium DoS) | None new |
| 3 | ClaimManager.fileClaim() | Sends payout token to beneficiary (wrapper) | Underlying ERC-20 | CoveredVaultWrapper (balance-diff) | balance-diff at L376-377 | YES — try/catch returns 0 | YES (TF-6 positive, AC-2/AC-3) | None new |
| 4 | SlashingManager.executeSlashing() | Returns collateral tokens to ClaimManager | Various ERC-20 | ClaimManager._processCollateral | _approveIfERC20 → Swapper.safeTransferFrom | PARTIAL — pre-fee amount approved | YES (TF-5) | None new — TF-5 covers this |
| 5 | Swapper.executeSwap() | Sends payout token out; returns amountOut | Payout ERC-20 | ClaimManager._capAndExecutePayout | amountOut returned for payout total | YES — post-swap check | YES (TF-4 — amountOutMin=1) | None new |
| 6 | ISpec.evaluate() → CoveredVaultWrapper.evaluate() | View callback during fileClaim | None | CoveredVaultWrapper state read | determines payable/shortfall | YES — view, no state change | Covered by reentrancy analysis | None new |
| 7 | IVaultV2.convertToAssets() | Returns asset equivalent of shares | None (view) | _morphoValue() | totalAssets(), premium accrual cap | PARTIAL — stale cache fallback | YES (CS-3, OZ-3) | None new |
| 8 | _policyManager.policyMetadata() | Returns policy struct | None (view) | _isPolicyActive() | _accruePremium(), _computeInsurance() | NO try/catch | YES (TF-7) | None new |
| 9 | IChainlinkPriceFeed.getUSDValue() | Returns USD value | None (view) | PolicyManager.bindPolicy() L266-274 | totalStakeUSD comparison | NO try/catch | YES (OZ-1) | None new |

**New SE findings: 0** (all side effects covered by breadth findings)

---

## Elevated Signal Audit

| Signal | Tag | Addressed? | Finding ID / Depth Flag |
|--------|-----|-----------|------------------------|
| Complex multi-inheritance storage layout | [ELEVATE: PROXY_STORAGE] | PARTIAL | AC-8 covers upgrade storage ordering. No storage layout collision found. Flag for STORAGE_LAYOUT depth review. |
| Per-user mappings with no nonce — state confusion on redeposit | [ELEVATE: SINGLE_MAPPING_PER_USER] | YES | Addressed by OZ sweep (Sweep 3 zero-state analysis) — new depositors get correct debt offset via cumulativePremiumPerUnit. No redeposit confusion. |
| Asymmetric deposit/withdraw paths | [ELEVATE: ASYMMETRIC_DEPOSIT_WITHDRAW] | YES | CS-2 (premium residual), CS-5 (retroactive params), TF-4 (swap slippage), TF-7 (PolicyManager DoS) all address asymmetry in withdraw path. |
| Assembly transient storage blocks | [ELEVATE: ASSEMBLY_BLOCKS] | YES | Addressed in OZ agent zero-state sweep: SKIP_INSURANCE_SLOT, PENDING_CLAIM_AMOUNT_SLOT, ACTUAL_OUT_SLOT patterns reviewed. No issue found. |
| EIP-712 signatures | [ELEVATE: EIP712_SIGNATURES] | YES | OZ-4 (REFUTED — correct implementation). Sweep 2 confirmed replay protection sound. |
| Callback patterns (fileClaim re-entry, onPolicyBound) | [ELEVATE: CALLBACK_PATTERN] | PARTIAL | TF-7 covers PolicyManager unavailability path. Re-entrancy: nonReentrant guards in place. SKIP_INSURANCE_SLOT transient mechanism for emergency paths analyzed. Depth review recommended for fileClaim→evaluate callback. |
| External low-level call in Swapper | [ELEVATE: EXTERNAL_LOW_LEVEL_CALL] | YES | AC-5 (REFUTED — whitelist protects). Swapper.sol:311 `swapTarget.call()` is whitelisted; Swapper.sol:330 ETH transfer is after state changes with nonReentrant. No new finding. |
| Fee-on-transfer risk in collateral | [ELEVATE: FEE_ON_TRANSFER_RISK] | YES | TF-5 covers this directly. |
