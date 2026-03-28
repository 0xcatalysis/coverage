# Final Verification Verdicts (Post Phase 5.1 Skeptic-Judge)

## Summary Counts (Final)
| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 3 |
| Medium | 17 |
| Low | 30 |
| Informational | 13 |
| **Total** | **63** |
| FALSE_POSITIVE | 3 |

## High Severity (3) — Upheld by Skeptic-Judge

| H-ID | Title | Evidence | Batch |
|------|-------|----------|-------|
| H-1 | gateGracePeriod Renders Grace Window Fully Uninsured While Premium Accrues | [POC-PASS] | B |
| H-5 | UniswapV3Adapter Fee-Tier Desync Between Quote and Swap | [POC-PASS] | B |
| CH-2 | Fee-Tier Desync Enables Deterministic Sandwich on Claim Payout | [POC-PASS] | A |

## Medium Severity (17)

| H-ID | Title | Evidence | Batch | Notes |
|------|-------|----------|-------|-------|
| H-2 | Unbounded gateGracePeriod Accumulation via Repeated Gate Toggles | [POC-PASS] | D | |
| H-3 | totalPremiumLiability Phantom Residual After Deep-Loss Withdrawals | [POC-PASS] | C | Skeptic downgraded from High |
| H-4 | Excess Swap Output Permanently Stranded in ClaimManager | [POC-PASS] | B | Downgraded from High (admin recoverTokens) |
| H-6 | Stale Unlimited Approval Persists on Old RewardsManager | [POC-PASS] | D | |
| H-8 | Retroactive deductibleBps/maxCoverableLossBps Changes Reduce Insurance Payout | [POC-PASS] | D | |
| H-11 | _isPolicyActive External Call Blocks All Withdrawals During PolicyManager Downtime | [POC-PASS] | D | |
| H-12 | Revoked Spec Still Callable by ClaimManager for Existing Policies | [POC-PASS] | D | |
| H-13 | poolFeeBps Read Live at Distribution Enables Retroactive Fee Extraction | [POC-PASS] | D | |
| H-14 | maxWithdraw/maxRedeem Double-Deducts Premium (ERC-4626) | [POC-PASS] | E | |
| H-16 | CREATOR_ROLE Can Replace Infrastructure Addresses Without Timelock | [POC-PASS] | E | |
| H-19 | Quote startTime Goes Stale Between Draft Creation and Policy Binding | [POC-PASS] | E | |
| H-22 | Operator Can Waive Owner's Insurance via Emergency Exit | [POC-PASS] | E | Confirmed owner self-waive |
| H-25 | Old CoverPools Permanently Orphaned After Infrastructure Rotation | [POC-PASS] | E | |
| CH-1 | Retroactive maxCoverableLossBps Reduction Amplifies Phantom Residual | [POC-PASS] | C | |
| CH-3 | Repeated Gate Toggles Create Arbitrarily Long Uninsured Window | [POC-PASS] | A | Skeptic downgraded from High |
| CH-4 | Morpho Loss During Grace Window Creates Permanent NAV Deflation | [POC-PASS] | A | Skeptic downgraded from High |
| CH-6 | Curator Combines Claim Denial with Retroactive Fee Extraction | [POC-PASS] | A | Skeptic downgraded from High; within curator trust bounds |

## Low Severity (30)

| H-ID | Title | Evidence | Notes |
|------|-------|----------|-------|
| H-7 | amountOutMin Falls to 1 When QuoterV2 Reverts | [CODE-TRACE] | PROVEN_ONLY demotion from High |
| H-9 | Curator Can Permanently Block Claims via setPremiumDefaulted | [CODE-TRACE] | PROVEN_ONLY demotion from High |
| H-10 | Claim Approval Gate Serializes Concurrent Claimants | [CODE-TRACE] | PROVEN_ONLY demotion from Medium |
| H-17 | renounceOwnership Not Overridden in UniswapV3Adapter | [POC-PASS] | |
| H-18 | PREMIUM_COLLECTOR_ROLE Not Granted in PremiumManager.initialize() | [CODE-TRACE] | Critical deployment issue |
| H-20 | Stale lastKnownMorphoValue Inflates Premium Cap | [CODE-TRACE] | PROVEN_ONLY demotion from Medium |
| H-21 | Pre-Policy Phantom Premium When Checkpoint Predates startTime | [POC-PASS] | |
| H-23 | distributeBatch Reverts Entirely on Single Vault Failure | [CODE-TRACE] | |
| H-24 | Oracle Revert in bindPolicy Blocks All Policy Binding | [CODE-TRACE] | |
| H-27 | depositCap Reopens After Withdrawals During Loss Event | [POC-PASS] | |
| H-28 | Deposits Accepted After Policy Maturity Without Insurance | [POC-PASS] | |
| H-29 | Fee-on-Transfer Collateral Tokens Cause Claim Revert | [CODE-TRACE] | |
| H-30 | userPremiumDebt Zeroed by Floor Rounding After Partial Withdrawal | [CODE-TRACE] | PROVEN_ONLY demotion from Medium |
| H-31 | evidenceHash Permanently Consumed Even on Rejected Claims | [POC-PASS] | |
| H-32 | setNativeWrapper Does Not Disable Old WETH-Keyed Routes | [CODE-TRACE] | |
| H-33 | approveNextClaim Emits Misleading Event on Non-Gated Policy | [CODE-TRACE] | |
| H-34 | cumulativePremiumPerUnit Precision Loss With Small totalPrincipal | [CODE-TRACE] | |
| H-35 | updateVault Missing nonReentrant Guard | [CODE-TRACE] | |
| H-36 | PremiumCollector Caches Vault Underlying at Registration | [CODE-TRACE] | |
| H-37 | executeUpgrade Clears Pending State After upgradeToAndCall | [CODE-TRACE] | |
| H-38 | rescueTokens Uses totalPrincipal>0 as Proxy for Tracked Shares | [CODE-TRACE] | |
| H-40 | Stale Evidence Hash From block.timestamp Causes Same-Block Claim Denial | [CODE-TRACE] | |
| H-41 | bindPolicy Hook Single-Use Guard Permanently Blocks Re-Binding | [CODE-TRACE] | |
| H-44 | block.timestamp as Swap Deadline (No MEV Time Protection) | [CODE-TRACE] | |
| H-45 | Unsolicited Morpho Share Donation (No Attacker Profit) | [CODE-TRACE] | |
| H-46 | SpecRegistry whenNotPaused Cross-Contract Pause Dependency | [CODE-TRACE] | |
| H-47 | Factory Uses Instant Admin Transfer While CoverPools Use 24h Delay | [CODE-TRACE] | |
| H-52 | coverageLimit Cached Locally vs Live Read in ClaimManager | [CODE-TRACE] | |
| H-53 | _MAX_FEE_BPS Guard Semantically Misleading | [CODE-TRACE] | |
| CH-5 | Phantom Residual Widens previewRedeem Gap | [POC-PASS] | |

Note: H-56 (morphoGateActive no timelock) [ASSUMPTION-DEP: WITHIN-BOUNDS] — not reported as Low finding; confirmed design

## Informational (13)

| H-ID | Title | Evidence | Notes |
|------|-------|----------|-------|
| H-42 | PolicyManager._validateRequest Missing startTime Check | [CODE-TRACE] | |
| H-43 | PremiumCollector Missing recoverTokens Function | [CODE-TRACE] | |
| H-48 | _withdraw Decrements totalPrincipal After External Interactions | [CODE-TRACE] | CEI violation, mitigated by nonReentrant |
| H-49 | acceptOwnership Clears Timestamps But Not Pending Values | [CODE-TRACE] | |
| H-50 | Swapper Stored Route Calldata May Become Stale | [CODE-TRACE] | |
| H-51 | PremiumManager approveSpender Allows Arbitrary ERC-20 Approvals | [CODE-TRACE] | [ASSUMPTION-DEP: TRUSTED-ACTOR] |
| H-54 | premiumRatePerSecond Missing WAD-Scaled Qualifier | [CODE-TRACE] | |
| H-55 | Combined Fee Cap Dead Code (100% Unreachable) | [CODE-TRACE] | |
| H-57 | _accruePremium Advances Timestamp When Rate is Zero | [CODE-TRACE] | By design |
| H-58 | Fee Split Rounding Favors Restakers (2 wei dust) | [CODE-TRACE] | |
| H-59 | PremiumCollector._distribute Truncates to uint32 | [CODE-TRACE] | Safe until 2106 |
| H-60 | _isPolicyActive External Call on Every Deposit/Withdraw | [CODE-TRACE] | |
| H-61 | CoverPool Curator 24-Hour Admin Transfer Delay | [CODE-TRACE] | [ASSUMPTION-DEP: WITHIN-BOUNDS] |

## FALSE_POSITIVE (excluded from report)

| H-ID | Title | Reason |
|------|-------|--------|
| H-15 | previewRedeem/previewWithdraw Overstates Proceeds | previewRedeem correctly reflects totalAssets-based calculation; single-user test shows exact equality |
| H-26 | Premium Rate Change Retroactive to All Existing Positions | executePremiumRate() calls _accruePremium() before changing rate; strictly prospective |
| H-39 | Post-Expiry Premium Catch-Up Charges Full Lifetime Premium | _activeElapsedFrom caps at effectiveMaturity, not block.timestamp; only charges missed window |

## PROVEN_ONLY Impact Summary
Under PROVEN_ONLY=true mode:
- 5 findings demoted from High/Medium to Low: H-7, H-9, H-10, H-20, H-30
- Report notes: "Proven-only mode enabled: 5 findings capped at Low from High/Medium due to unproven evidence ([CODE-TRACE] only)"

## Verification Coverage Assert
- Total hypotheses in hypotheses.md: 61 (H-1..H-61) + 6 chains (CH-1..CH-6) = 67
- Verified in batches A-H: 67 ✓
- Excluded (FALSE_POSITIVE): 3 (H-15, H-26, H-39)
- Absorbed into report findings: 0 separate
- Coverage: 67/67 = 100% ✓
