# Hypotheses

## Hypothesis Table

| H-ID | Title | Severity | Status | Constituent Findings | Fix Summary |
|------|-------|----------|--------|---------------------|-------------|
| H-1 | gateGracePeriod Renders Grace Window Fully Uninsured While Premium Accrues | High | CONFIRMED | RS1-1, SGI-2, VS-UPDATE-RS1-1 | Clamp effectiveMaturity to raw maturityTime in _isPolicyActive OR have ClaimManager use effectiveMaturity |
| H-2 | Unbounded gateGracePeriod Accumulation via Repeated Gate Toggles | Medium | CONFIRMED | CS-1, PC1-4 | Cap gateGracePeriod or limit gate activation count per policy; fix in setMorphoGateActive |
| H-3 | totalPremiumLiability Phantom Residual After Deep-Loss Withdrawals | Medium | CONFIRMED | CS-2, SGI-1, VS-UPDATE-CS-2, VA-6, DEPTH-EC-2, DEPTH-ST-2 | Decrement totalPremiumLiability by uncappedPremium (not premiumForWithdrawal) in _settleWithdrawalTransfer |
| H-4 | Excess Swap Output Permanently Stranded in ClaimManager | High | CONFIRMED | PC3-1, VS-UPDATE-PC3-1, RS2-3, DEX-4 | Transfer surplus (swapOutput - remainingPayout) to beneficiary or add recoverTokens to ClaimManager |
| H-5 | UniswapV3Adapter Fee-Tier Desync Between Quote and Swap | High | CONFIRMED | PC3-2, VS-UPDATE-PC3-2, DEPTH-EX-4, DEPTH-TF-2 | Store fee tier alongside route calldata OR read pairFees in swap path too |
| H-6 | Stale Unlimited Approval Persists on Old RewardsManager | Medium | CONFIRMED | PC4-1, VS-UPDATE-PC4-1, DEPTH-TF-4 | Revoke approval on old rewardsManager before setting new one in setRewardsManager |
| H-7 | amountOutMin Falls to 1 When QuoterV2 Reverts, Enabling Near-Total Sandwich | Medium | CONFIRMED | TF-4, DEX-1, DEPTH-TF-3 | Revert or use configurable minimum floor when quoteSwap returns 0; do not default to 1 |
| H-8 | Retroactive deductibleBps/maxCoverableLossBps Changes Reduce Insurance Payout | Medium | CONFIRMED | CS-5, ITER2-ST-2 | Snapshot deductibleBps/maxCoverableLossBps at loss-event time or at policy binding |
| H-9 | Curator Can Permanently Block Claims via setPremiumDefaulted | Medium | CONFIRMED | AC-2 | Add timelock or admin override for setPremiumDefaulted; add depositor recourse mechanism |
| H-10 | Claim Approval Gate Serializes Concurrent Claimants (First-Claimer Race) | Medium | CONFIRMED | AC-3, SGI-6 | Batch approval or per-user approval tracking instead of global boolean reset |
| H-11 | _isPolicyActive External Call Blocks All Withdrawals During PolicyManager Downtime | Medium | PARTIAL | TF-7, DEPTH-EX-1, DEPTH-EX-2, BLIND-A-5 | Wrap _isPolicyActive in try/catch with safe fallback in _accruePremium; or cache policy active status |
| H-12 | Revoked Spec Still Callable by ClaimManager for Existing Policies | Medium | CONFIRMED | RS2-1, ITER2-ST-3, DEPTH-ST-7 | Have resolveSpec check _approvedSpecs OR add policy-level spec invalidation |
| H-13 | poolFeeBps Read Live at Distribution Enables Retroactive Fee Extraction | Medium | CONFIRMED | PC4-2, ITER2-FA-3, DEPTH-ST-8 | Snapshot poolFeeBps at accrual time or enforce timelock on poolFeeBps changes |
| H-14 | maxWithdraw/maxRedeem Double-Deducts Premium (ERC-4626 Spec Violation) | Medium | CONFIRMED | PC1-1, ITER2-LC-2, DEPTH-ST-9 | Fix maxWithdraw to not subtract owedPremium from totalAssets-based calculation (already excluded) |
| H-15 | previewRedeem/previewWithdraw Overstates Proceeds (ERC-4626 Spec Violation) | Medium | CONFIRMED | VA-3 | Include per-user premium deduction in preview functions |
| H-16 | CREATOR_ROLE Can Replace Infrastructure Addresses Without Timelock | Medium | CONFIRMED | AC-1 | Add timelock to CoverPoolFactory setImplementation/setDependency functions |
| H-17 | renounceOwnership Not Overridden in UniswapV3Adapter | Low | CONFIRMED | BLIND-C-1 | Override renounceOwnership to revert in UniswapV3Adapter |
| H-18 | PREMIUM_COLLECTOR_ROLE Not Granted in PremiumManager.initialize() | Low | CONFIRMED | BLIND-C-2 | Grant PREMIUM_COLLECTOR_ROLE to PremiumCollector address in initialize() |
| H-19 | Quote startTime Goes Stale Between Draft Creation and Policy Binding | Medium | CONFIRMED | PC2-1, DEPTH-ST-6 | Allow startTime to be current block.timestamp at bind time or add tolerance window |
| H-20 | Stale lastKnownMorphoValue During Morpho Downtime Inflates Premium Cap | Medium | PARTIAL | OZ-3, CS-3, DEPTH-EX-3, DEPTH-EC-3 | Auto-activate gate when convertToAssets reverts OR use zero fallback instead of stale cache |
| H-21 | Pre-Policy Phantom Premium When Checkpoint Predates startTime | Low | CONFIRMED | PC1-2, BLIND-A-3, DEPTH-EC-6, DEPTH-ST-10 | Clamp checkpoint to max(checkpoint, startTime) in _activeElapsedFrom |
| H-22 | Operator Can Waive Owner's Insurance via Emergency Exit | Medium | CONFIRMED | RS1-2 | Require SKIP_INSURANCE_SLOT to be set only by asset owner, not operator |
| H-23 | distributeBatch Reverts Entirely on Single Vault Failure | Low | CONFIRMED | RS2-2, DEPTH-EX-7 | Add per-vault try/catch in distributeBatch |
| H-24 | Oracle Revert in bindPolicy Blocks All Policy Binding | Low | PARTIAL | OZ-1, DEPTH-EX-8 | Add try/catch around Chainlink getUSDValue or use cached price fallback |
| H-25 | Old CoverPools Permanently Orphaned After Infrastructure Rotation | Medium | CONFIRMED | RS1-3, ITER2-FA-1, BLIND-B-2 | Add migration setter in CoverPool for specRegistry/stakeManager OR include them in CREATE2 salt |
| H-26 | Premium Rate Change Retroactive to All Existing Positions | Low | CONFIRMED | CS-4, DEPTH-ST-11 | Checkpoint premium before rate change; add longer timelock |
| H-27 | depositCap Reopens After Withdrawals During Loss Event | Low | CONFIRMED | CS-9, BLIND-A-1 | Check loss-event flag in maxDeposit; block deposits during active loss |
| H-28 | Deposits Accepted After Policy Maturity Without Insurance | Low | CONFIRMED | OZ-2, DEPTH-EC-9, DST-4 | Check maturityTime in maxDeposit; return 0 after maturity |
| H-29 | Fee-on-Transfer Collateral Tokens Cause Claim Revert | Low | PARTIAL | TF-5, DEPTH-TF-6 | Use balance-diff pattern in _processCollateral instead of trusted amounts |
| H-30 | userPremiumDebt Zeroed by Floor Rounding After Partial Withdrawal | Medium | CONFIRMED | VA-1 | Use rounding-up division for premium debt calculation |
| H-31 | evidenceHash Permanently Consumed Even on Rejected Claims | Low | CONFIRMED | PC3-5 | Move evidenceHash consumption after spec evaluation succeeds |
| H-32 | setNativeWrapper Does Not Disable Old WETH-Keyed Routes | Low | CONFIRMED | BLIND-C-3 | Clear stale routes or invalidate old wrapper-keyed entries in setNativeWrapper |
| H-33 | approveNextClaim Emits Misleading Event on Non-Gated Policy | Low | CONFIRMED | PC3-4 | Check _claimApprovalRequired before writing state and emitting event |
| H-34 | cumulativePremiumPerUnit Precision Loss With Small totalPrincipal | Low | PARTIAL | CS-6, SGI-4 | Use higher precision accumulator (e.g., 1e27 scaling) |
| H-35 | updateVault Missing nonReentrant Guard | Low | CONFIRMED | PC4-3, DEPTH-EX-6 | Add nonReentrant modifier to updateVault in PremiumCollector |
| H-36 | PremiumCollector Caches Vault Underlying at Registration | Low | PARTIAL | PC4-4 | Re-read vault.asset() at distribution time or validate at distribution |
| H-37 | executeUpgrade Clears Pending State After upgradeToAndCall | Low | CONFIRMED | AC-8 | Clear pending upgrade state BEFORE calling upgradeToAndCall |
| H-38 | rescueTokens Uses totalPrincipal>0 as Proxy for Tracked Shares | Low | CONFIRMED | OZ-5 | Track morpho shares separately from totalPrincipal for rescue guard |
| H-39 | Post-Expiry Premium Catch-Up Charges Full Lifetime Premium on Single Interaction | Medium | CONFIRMED | SGI-3 | Cap catch-up accrual to maturityTime; do not accrue past expiry |
| H-40 | Stale Evidence Hash From block.timestamp Causes Same-Block Claim Denial | Low | PARTIAL | RS3-2 | Add nonce or sender to evidenceHash to differentiate same-block claims |
| H-41 | bindPolicy Hook Single-Use Guard Permanently Blocks Re-Binding | Low | CONFIRMED | PC2-3 | Allow re-binding with new policyId or add reset mechanism |
| H-42 | PolicyManager._validateRequest Missing startTime Check (Defence-in-Depth) | Informational | CONFIRMED | PC2-5 | Add startTime >= block.timestamp check in _validateRequest |
| H-43 | PremiumCollector Missing recoverTokens Function | Informational | CONFIRMED | BLIND-C-4 | Add recoverTokens function consistent with sibling contracts |
| H-44 | block.timestamp as Swap Deadline (No MEV Time Protection) | Low | CONFIRMED | TF-1 | Use configurable deadline offset (block.timestamp + N seconds) |
| H-45 | Unsolicited Morpho Share Donation (No Attacker Profit) | Low | CONFIRMED | TF-3 | Informational — no fix needed; gift to depositors |
| H-46 | SpecRegistry whenNotPaused Cross-Contract Pause Dependency | Low | CONFIRMED | BLIND-B-3 | Document cross-contract pause dependency; consider independent pause |
| H-47 | Factory Uses Instant Admin Transfer While CoverPools Use 24h Delay | Low | CONFIRMED | BLIND-B-1 | Use AccessControlDefaultAdminRulesUpgradeable in CoverPoolFactory too |
| H-48 | _withdraw Decrements totalPrincipal After External Interactions | Informational | PARTIAL | PC1-3 | Move totalPrincipal decrement before external calls (CEI pattern) |
| H-49 | acceptOwnership Clears Timestamps But Not Pending Values | Informational | PARTIAL | BLIND-A-4 | Clear pending values in acceptOwnership |
| H-50 | Swapper Stored Route Calldata May Become Stale | Informational | CONFIRMED | TF-8 | Document route staleness risk; add route expiry mechanism |
| H-51 | PremiumManager approveSpender Allows Arbitrary ERC-20 Approvals | Informational | CONFIRMED | AC-9 | [ASSUMPTION-DEP: TRUSTED-ACTOR] — informational only |
| H-52 | coverageLimit Cached Locally vs Live Read in ClaimManager | Low | CONFIRMED | SC-8 | Synchronize coverageLimit source or document divergence risk |
| H-53 | _MAX_FEE_BPS Guard Semantically Misleading | Low | CONFIRMED | SC-5 | Rename or tighten guard to reflect actual max combined fee |
| H-54 | premiumRatePerSecond Missing WAD-Scaled Qualifier | Informational | CONFIRMED | SC-9 | Rename variable to include unit qualifier |
| H-55 | Combined Fee Cap Dead Code (100% Unreachable) | Informational | CONFIRMED | ITER2-FA-2 | Remove dead code or adjust constants |
| H-56 | morphoGateActive Toggle Has No Timelock | Low | PARTIAL | AC-4 | [ASSUMPTION-DEP: WITHIN-BOUNDS] — instant toggle is stated design |
| H-57 | _accruePremium Advances Timestamp When Rate is Zero | Informational | CONFIRMED | CS-10 | By design — prevents catch-up; document this invariant |
| H-58 | Fee Split Rounding Favors Restakers (2 wei dust) | Informational | CONFIRMED | CS-8 | No fix needed — dust level |
| H-59 | PremiumCollector._distribute Truncates to uint32 | Informational | CONFIRMED | CS-7 | Safe until 2106; no fix needed |
| H-60 | _isPolicyActive External Call on Every Deposit/Withdraw (Gas) | Informational | CONFIRMED | OZ-6 | Cache policy active status for gas optimization |
| H-61 | CoverPool Curator 24-Hour Admin Transfer Delay | Informational | PARTIAL | AC-6 | [ASSUMPTION-DEP: WITHIN-BOUNDS] — 24h is stated design |

---

## Detailed Hypotheses

### H-1: gateGracePeriod Renders Grace Window Fully Uninsured While Premium Accrues
**Severity**: High
**Status**: CONFIRMED
**Constituent Findings**: RS1-1, SGI-2, VS-UPDATE-RS1-1
**Root Cause**: CoveredVaultWrapper extends _isPolicyActive via gateGracePeriod (effectiveMaturity = maturityTime + gateGracePeriod), but ClaimManager enforces raw maturityTime for claim eligibility. During the grace window, users pay premium (accrual continues) but cannot file claims (ClaimManager rejects as post-maturity).
**Attack Path**:
1. Owner activates morphoGate (legitimately or through accumulated toggles)
2. gateGracePeriod extends effectiveMaturity past raw maturityTime
3. Users continue accruing premium during grace window
4. If Morpho loss occurs during grace window, users file claim
5. ClaimManager checks `block.timestamp < maturityTime` (raw) and rejects the claim
6. Users have paid premium for a period with zero insurance coverage
**Impact**: Users lose premium payments with no insurance coverage during grace window. With accumulated gateGracePeriod, this window can be arbitrarily long. Estimated loss: full premium accrued during grace window per user.
**Recommendation**: Either (a) clamp effectiveMaturity to raw maturityTime for premium accrual purposes, or (b) pass effectiveMaturity to ClaimManager so claims are accepted during grace window.

### H-2: Unbounded gateGracePeriod Accumulation via Repeated Gate Toggles
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: CS-1, PC1-4
**Root Cause**: setMorphoGateActive(true) adds `maturityTime - block.timestamp` to gateGracePeriod each time, with no cap. Multiple activations cause unbounded accumulation.
**Attack Path**:
1. Owner calls setMorphoGateActive(true) during legitimate Morpho issue
2. Issue resolves, owner deactivates
3. New Morpho issue — owner activates again
4. gateGracePeriod now includes both windows, extending effectiveMaturity further
5. Repeat N times → gateGracePeriod grows to arbitrary duration
**Impact**: Compounds H-1 — each gate cycle adds more uninsured premium window. Owner (semi-trusted) can also deliberately accumulate this.
**Recommendation**: Cap gateGracePeriod at a maximum value (e.g., 30 days) or reset it on each new activation instead of accumulating.

### H-3: totalPremiumLiability Phantom Residual After Deep-Loss Withdrawals
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: CS-2, SGI-1, VS-UPDATE-CS-2, VA-6, DEPTH-EC-2, DEPTH-ST-2
**Root Cause**: During deep-loss withdrawal, totalPremiumLiability is decremented by premiumForWithdrawal (capped at assetsReceived) rather than uncappedPremium (full owed amount). The delta remains permanently in totalPremiumLiability, deflating totalAssets() for remaining holders.
**Attack Path**:
1. Morpho loss event occurs — vault assets drop significantly
2. User withdraws — assetsReceived < uncappedPremium (deep loss)
3. totalPremiumLiability decremented by premiumForWithdrawal (small), not uncappedPremium (large)
4. Delta (uncappedPremium - premiumForWithdrawal) remains permanently in totalPremiumLiability
5. totalAssets() = morphoValue - totalPremiumLiability - accrued is permanently suppressed
6. Remaining holders' shares are worth less than they should be
**Impact**: Permanent NAV deflation for remaining vault depositors. The phantom residual cannot be cleared without subsequent users overpaying premium.
**Recommendation**: Decrement totalPremiumLiability by uncappedPremium (the full obligation) regardless of how much was actually collected from the withdrawal proceeds.

### H-4: Excess Swap Output Permanently Stranded in ClaimManager
**Severity**: High
**Status**: CONFIRMED
**Constituent Findings**: PC3-1, VS-UPDATE-PC3-1, RS2-3, DEX-4
**Root Cause**: When collateral swap produces output exceeding remainingPayout, only remainingPayout is transferred to beneficiary. The surplus (swapOutput - remainingPayout) remains locked in ClaimManager with no recovery mechanism.
**Attack Path**:
1. User files insurance claim
2. SlashingManager slashes collateral from vaults
3. Collateral swapped to payout token via Uniswap
4. Swap output > remainingPayout (favorable price movement)
5. Only remainingPayout transferred to claimant; surplus locked in ClaimManager
6. Vault stakers are over-slashed (they lost more collateral than the payout required)
**Impact**: Vault stakers permanently lose excess collateral value. Funds locked in ClaimManager without recoverTokens. Over time, material value can accumulate.
**Recommendation**: Transfer surplus to beneficiary, return to slashed vaults pro-rata, or add admin recoverTokens to ClaimManager.

### H-5: UniswapV3Adapter Fee-Tier Desync Between Quote and Swap
**Severity**: High
**Status**: CONFIRMED
**Constituent Findings**: PC3-2, VS-UPDATE-PC3-2, DEPTH-EX-4, DEPTH-TF-2
**Root Cause**: UniswapV3Adapter.quote() reads fee from pairFees mapping (updated by setPairFee), while swap() uses fee encoded in stored route calldata (frozen at configuration time). After setPairFee, quote uses new fee but swap uses old fee.
**Attack Path**:
1. Route configured with fee tier 3000 (0.3%)
2. Admin calls setPairFee(tokenA, tokenB, 500) to migrate to 0.05% pool
3. quote() now uses fee=500 (new pool, different liquidity)
4. swap() still uses fee=3000 (old pool, potentially drained liquidity)
5. Scenario A (DoS): Old pool has no liquidity → swap reverts → claim fails
6. Scenario B (Slippage): Old pool has poor liquidity → much worse execution → MEV extraction
**Impact**: Claims can be DoS'd or suffer significant slippage loss. High severity because it affects the critical claim payout path.
**Recommendation**: Store fee tier alongside route calldata and update both atomically, or read pairFees in swap path.

### H-6: Stale Unlimited Approval Persists on Old RewardsManager
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: PC4-1, VS-UPDATE-PC4-1, DEPTH-TF-4
**Root Cause**: setRewardsManager replaces the rewardsManager reference and approves the new address but does not revoke the unlimited ERC-20 approval on the old address.
**Attack Path**:
1. Admin calls setRewardsManager(newAddr)
2. Old rewardsManager retains unlimited allowance on PremiumManager's token balance
3. If old rewardsManager is compromised or malicious, it can call transferFrom to drain PremiumManager
**Impact**: Complete drain of PremiumManager token balance by compromised old RewardsManager. Medium because it requires old contract compromise.
**Recommendation**: Add `IERC20(token).safeApprove(oldRewardsManager, 0)` before setting the new one.

### H-7: amountOutMin Falls to 1 When QuoterV2 Reverts, Enabling Near-Total Sandwich
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: TF-4, DEX-1, DEPTH-TF-3
**Root Cause**: When Uniswap QuoterV2.quoteExactInputSingle reverts, quoteSwap returns 0. The claim path then sets amountOutMin = max(quotedAmount, 1) = 1, providing zero effective slippage protection.
**Attack Path**:
1. QuoterV2 reverts (gas, network issues, pool state)
2. quoteSwap returns 0
3. amountOutMin set to 1 (hardcoded fallback)
4. MEV bot sandwiches the swap, extracting nearly all value
5. Claimant receives ~1 wei instead of expected payout
**Impact**: Near-total loss of claim payout to MEV. Requires QuoterV2 failure (external event) + MEV bot (always present).
**Recommendation**: Revert the claim if quoteSwap returns 0, or use a configurable minimum floor based on expected payout.

### H-8: Retroactive deductibleBps/maxCoverableLossBps Changes Reduce Insurance Payout
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: CS-5, ITER2-ST-2
**Root Cause**: deductibleBps and maxCoverableLossBps are read at withdrawal time, not snapshotted at policy binding or loss event. Owner can change these params after a loss occurs, retroactively changing payout calculations.
**Attack Path**:
1. Loss event occurs under original params (deductible=5%, maxLoss=50%)
2. Owner increases deductibleBps or decreases maxCoverableLossBps before users withdraw
3. Users withdraw — insurance payout calculated with new (worse) params
4. Compound effect: simultaneous deductible increase + maxLoss decrease can reduce payout by up to 75%
**Impact**: Users receive substantially less insurance than they expected under the original terms. Up to 75% payout reduction in compound case.
**Recommendation**: Snapshot deductibleBps/maxCoverableLossBps at loss-event time or at policy binding.

### H-9: Curator Can Permanently Block Claims via setPremiumDefaulted
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: AC-2
**Root Cause**: Curator can set premiumDefaulted=true, causing ClaimManager to return 0 payout for all claims. No timelock, no admin override, no depositor recourse.
**Attack Path**:
1. Morpho loss event occurs
2. Curator (who also has staking exposure) calls setPremiumDefaulted(true) to protect their stake
3. All claim payouts return 0 — users lose insurance coverage
4. No mechanism for users to override or escalate
**Impact**: Complete denial of insurance coverage. Curator's incentive (protect stake) directly conflicts with depositors' interest (receive insurance).
**Recommendation**: Add timelock to setPremiumDefaulted, or add admin override, or limit duration.

### H-10: Claim Approval Gate Serializes Concurrent Claimants (First-Claimer Race)
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: AC-3, SGI-6
**Root Cause**: After each successful claim payout, _claimApprovalRequired is set to true, blocking all subsequent claims until curator manually calls approveNextClaim. Creates first-claimer advantage.
**Attack Path**:
1. Loss event occurs affecting multiple depositors
2. First user to call withdraw gets insurance payout
3. _claimApprovalRequired set to true — all subsequent claims blocked
4. Curator must manually approve each subsequent claim
5. Delay → users exposed to additional losses or cannot exit
**Impact**: All but the first claimant are blocked from receiving insurance until curator individually approves. Creates unfair race condition and potential griefing vector for curator.
**Recommendation**: Use batch approval or per-user tracking instead of global boolean.

### H-11: _isPolicyActive External Call Blocks All Withdrawals During PolicyManager Downtime
**Severity**: Medium
**Status**: PARTIAL
**Constituent Findings**: TF-7, DEPTH-EX-1, DEPTH-EX-2, BLIND-A-5
**Root Cause**: _isPolicyActive makes uncaught external call to PolicyManager.policyMetadata. If PolicyManager is unavailable (upgrade, pause, bug), _accruePremium reverts, blocking all deposit/withdraw/view operations including emergency exits.
**Attack Path**:
1. PolicyManager becomes unavailable (upgrade in progress, paused, reverted)
2. Any call to _accruePremium reverts (no try/catch on _isPolicyActive)
3. All deposits, withdrawals, and emergency exits blocked
4. Users' funds locked until PolicyManager restored
**Impact**: Complete DoS on all vault operations. Emergency exit paths also affected. External dependency failure cascades to total fund lockup.
**Recommendation**: Wrap _isPolicyActive in try/catch with safe fallback (assume inactive if unavailable).

### H-12: Revoked Spec Still Callable by ClaimManager for Existing Policies
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: RS2-1, ITER2-ST-3, DEPTH-ST-7
**Root Cause**: revokeSpec clears _approvedSpecs but not _specs mapping. ClaimManager.resolveSpec reads _specs, so revoked specs remain callable. Harm direction (per ITER2-ST-3): curator+spec-admin can collude to deny valid claims by revoking and replacing spec with one that rejects claims.
**Attack Path**:
1. Spec admin registers legitimate spec
2. Policy bound with this spec
3. Spec admin revokes spec (clears _approvedSpecs)
4. Spec admin registers new spec at same ID that always rejects claims
5. OR: Revoked spec with known vulnerability continues evaluating claims
6. ClaimManager resolveSpec returns the revoked/replaced spec
7. Valid claims denied or evaluated against compromised logic
**Impact**: Valid insurance claims denied or evaluated against compromised spec logic. Requires spec-admin collusion.
**Recommendation**: Have resolveSpec check _approvedSpecs flag, or snapshot spec address at policy binding time.

### H-13: poolFeeBps Read Live at Distribution Enables Retroactive Fee Extraction
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: PC4-2, ITER2-FA-3, DEPTH-ST-8
**Root Cause**: PremiumManager reads poolFeeBps from CoverPool at distribution time, not at accrual time. Curator can increase poolFeeBps just before calling distributeBatch, retroactively extracting higher fees from all accumulated premium.
**Attack Path**:
1. Premium accrues over weeks at poolFeeBps=500 (5%)
2. Curator calls setPoolFeeBps(2000) (20%)
3. In same transaction, calls distributeBatch
4. Entire accumulated premium distributed at 20% curator fee instead of 5%
5. Restakers receive 15% less than expected
**Impact**: Up to 20pp retroactive fee extraction from accumulated premium. Single-transaction attack (confirmed by ITER2-FA-3).
**Recommendation**: Snapshot poolFeeBps at premium accrual time or enforce timelock on poolFeeBps changes.

### H-14: maxWithdraw/maxRedeem Double-Deducts Premium (ERC-4626 Spec Violation)
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: PC1-1, ITER2-LC-2, DEPTH-ST-9
**Root Cause**: maxWithdraw subtracts owedPremium from grossAssets, but grossAssets is derived from totalAssets() which already excludes totalPremiumLiability. This double-deduction understates the maximum withdrawable amount.
**Attack Path**:
1. User has deposited and accrued premium
2. User or integrator calls maxWithdraw to determine maximum withdrawal
3. maxWithdraw returns value lower than actual maximum (double-deduction)
4. ERC-4626 integrators may limit user withdrawals based on incorrect value
**Impact**: ERC-4626 spec violation. Integrators receive understated maxWithdraw, potentially limiting user exits. Understatement grows linearly with owedPremium.
**Recommendation**: Remove the additional owedPremium subtraction from maxWithdraw since totalAssets already accounts for it.

### H-15: previewRedeem/previewWithdraw Overstates Proceeds (ERC-4626 Spec Violation)
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: VA-3
**Root Cause**: previewRedeem/previewWithdraw do not deduct per-user premium from the returned value. Users/integrators expect to receive the previewed amount but actually receive less after premium deduction.
**Attack Path**:
1. User calls previewRedeem(shares) — returns X assets
2. User calls redeem(shares) — receives X - premiumDeduction assets
3. Integrator that pre-approved based on previewRedeem sees shortfall
**Impact**: ERC-4626 spec violation. Integrators receive less than previewed, potentially causing downstream failures (e.g., insufficient assets for a swap or repayment).
**Recommendation**: Include per-user premium deduction in preview functions.

### H-16: CREATOR_ROLE Can Replace Infrastructure Addresses Without Timelock
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: AC-1
**Root Cause**: CoverPoolFactory allows CREATOR_ROLE to instantly replace implementation addresses and dependency references (stakeManager, specRegistry) that affect all future pool deployments.
**Attack Path**:
1. Compromised CREATOR_ROLE calls setImplementation with malicious contract
2. All subsequently created pools use malicious implementation
3. No timelock allows instant replacement with no warning
**Impact**: All future pools can be deployed with malicious implementations. Existing pools unaffected (uses clones of prior implementation).
**Recommendation**: Add timelock to CoverPoolFactory admin functions.

### H-19: Quote startTime Goes Stale Between Draft Creation and Policy Binding
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: PC2-1, DEPTH-ST-6
**Root Cause**: validateQuote enforces startTime >= block.timestamp at bind time, but the quote is created/signed before binding. Any non-zero delay causes startTime to be in the past at bind time, causing the transaction to revert.
**Attack Path**:
1. Coverage requested with startTime = block.timestamp (at request time)
2. Curator processes request and calls bindPolicyForRequest in a later block
3. startTime is now in the past relative to the bind block
4. validateQuote reverts with "startTime must be >= block.timestamp"
5. Policy binding fails — must re-request with new quote
**Impact**: Operational friction — every policy binding requires same-block execution or future-dated startTime. Curator must coordinate timing precisely.
**Recommendation**: Allow startTime to be within a tolerance window of block.timestamp at bind time.

### H-20: Stale lastKnownMorphoValue During Morpho Downtime Inflates Premium Cap
**Severity**: Medium
**Status**: PARTIAL
**Constituent Findings**: OZ-3, CS-3, DEPTH-EX-3, DEPTH-EC-3
**Root Cause**: When Morpho's convertToAssets reverts, _morphoValue falls back to cached lastKnownMorphoValue. If Morpho value has decreased since last cache, premium accrual uses inflated cap, over-collecting from users.
**Attack Path**:
1. lastKnownMorphoValue cached at 1M USDC
2. Morpho vault suffers loss, actual value drops to 500K
3. Morpho enters maintenance — convertToAssets reverts
4. _morphoValue returns stale 1M (cache)
5. Premium accrual uses 1M as cap — over-accrues relative to actual assets
**Impact**: Premium over-collection during Morpho downtime. Requires prolonged downtime + owner not activating gate promptly.
**Recommendation**: Auto-activate gate when convertToAssets reverts, or use zero fallback instead of stale cache.

### H-22: Operator Can Waive Owner's Insurance via Emergency Exit
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: RS1-2
**Root Cause**: ERC-4626 operators (via allowance) can call emergencyRedeem/emergencyWithdraw which sets SKIP_INSURANCE_SLOT, bypassing insurance claim. Asset owner loses insurance coverage without consent.
**Attack Path**:
1. Owner grants ERC-20 approval to operator (standard ERC-4626 pattern)
2. Loss event occurs — owner is entitled to insurance payout
3. Operator calls emergencyRedeem on behalf of owner
4. SKIP_INSURANCE_SLOT set — insurance claim skipped
5. Owner receives assets minus premium but zero insurance payout
**Impact**: Owner loses insurance payout. Operator can grief owner by choosing emergency path without consent.
**Recommendation**: Only allow asset owner (not operator) to set SKIP_INSURANCE_SLOT, or require explicit opt-in for insurance waiver.

### H-25: Old CoverPools Permanently Orphaned After Infrastructure Rotation
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: RS1-3, ITER2-FA-1, BLIND-B-2
**Root Cause**: CoverPool has no setter for specRegistry/stakeManager. CoverPoolFactory CREATE2 salt excludes these addresses. If infrastructure contracts are rotated, existing pools cannot be updated and cannot be re-deployed at the same address.
**Attack Path**:
1. specRegistry or stakeManager is upgraded/rotated
2. CoverPoolFactory updates its references
3. Existing CoverPools still point to old infrastructure
4. No migration path — no setter in CoverPool, CREATE2 address collision blocks re-deploy
5. Existing pools become permanently orphaned
**Impact**: All existing CoverPools lose connectivity to updated infrastructure. Policies in those pools cannot bind or execute claims against new infrastructure.
**Recommendation**: Add migration setter for specRegistry/stakeManager in CoverPool, or include them in CREATE2 salt.

### H-30: userPremiumDebt Zeroed by Floor Rounding After Partial Withdrawal
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: VA-1
**Root Cause**: When a user withdraws a small portion of shares, the premium debt calculation can round to zero due to integer division floor, effectively zeroing the user's premium debt. On the next withdrawal, premium is recalculated from zero, causing overcharge.
**Attack Path**:
1. User has accumulated premium debt
2. User makes small partial withdrawal — premium calculation rounds to 0
3. userPremiumDebt set to 0 (wiped)
4. On next withdrawal, full premium recalculated from accumulated cumulativePremiumPerUnit
5. User overcharged for premium they already "paid" (via the rounded-to-zero deduction)
**Impact**: Users can be overcharged premium after partial withdrawals. The overcharge equals the premium that was rounded away.
**Recommendation**: Use rounding-up division for premium debt calculation to prevent zero-rounding.

### H-39: Post-Expiry Premium Catch-Up Charges Full Lifetime Premium on Single Interaction
**Severity**: Medium
**Status**: CONFIRMED
**Constituent Findings**: SGI-3
**Root Cause**: If no interaction occurs between policy start and well past maturity, the first post-expiry interaction triggers _accruePremium which charges premium for the full elapsed period including post-maturity time.
**Attack Path**:
1. Policy active from T=0 to T=maturity
2. No deposits/withdrawals during policy lifetime
3. User interacts at T=maturity+1year
4. _accruePremium charges for full elapsed time (maturity + 1 year worth)
5. User charged premium for post-maturity period when no insurance existed
**Impact**: Excessive premium charge for post-maturity period. Can be significant if long gap between maturity and first interaction.
**Recommendation**: Cap accrual elapsed time to min(block.timestamp, effectiveMaturity) in _accruePremium.

---

## Design Stress Findings (Non-Vulnerability)

| DST-ID | Title | Classification | Severity | Notes |
|--------|-------|---------------|----------|-------|
| DST-1 | Premium Drain Spiral — No Circuit Breaker | Design Limit | Informational | MAX_PREMIUM_RATE = 50% APR; no yield-floor breaker; accounting holds but economically damaging |
| DST-2 | Systemic Morpho Exploit — Serialized Claims | Design Limit | Informational | Claim approval gate serializes insurance; covered by H-10 as a finding |
| DST-3 | Curator Claim Denial | Structural Risk | Informational | Covered by H-9 as a finding |
| DST-4 | Lifecycle Uninsured Windows | Design Adequacy | Informational | Covered by H-28 (post-maturity) and H-1 (grace window) |
| DST-5 | Coverage Adequacy — Narrow Band | Design Tradeoff | Informational | Structural design choice, not a bug |

---

## Signature Findings (Non-Vulnerability)

| SIG-ID | Title | Verdict | Notes |
|--------|-------|---------|-------|
| SIG-1 | basePremium signed but not persisted | CONFIRMED (Informational) | No funds at risk |
| SIG-3 | EIP-712 domain separator correct | CONFIRMED (positive) | N/A |
| SIG-6 | Nonce-free system adequate | CONFIRMED (design adequate) | policyCommit invalidation + draft binding |
| SIG-7 | buyer excluded from signed quote | CONFIRMED (design adequate) | Draft storage binding |

SIG-2, SIG-4, SIG-5 REFUTED — no findings.

---

## REFUTED Findings (Excluded)

| Finding ID | Reason | Included? |
|-----------|--------|-----------|
| AC-5 | Whitelist mitigates fully | NO |
| OZ-4 | No truncation found | NO |
| TF-2 | Dust cleanup intended | NO |
| TF-6 | Positive finding — design sound | NO (positive confirmation) |
| VA-4 | Donation attack infeasible due to decimal offset | NO |
| DEX-3 | Approval race window not exploitable | NO |
| DEPTH-EX-5 | No partial state on fileClaim revert | NO |
| SGI-8 | REFUTED in iter2 (ITER2-LC-1) — no checkpoint manipulation possible | NO |
| SC-1, SC-2, SC-3, SC-4, SC-6, SC-7, SC-10 | Semantic consistency checks passed | NO |
| SIG-2, SIG-4, SIG-5 | Signature checks passed | NO |
