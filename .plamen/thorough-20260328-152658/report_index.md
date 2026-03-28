# Report Index

## Report Header Info
- **Project Name**: Catalysis Coverage Protocol (CoverPool, PolicyManager, ClaimManager, CoveredVaultWrapper)
- **Date**: 2026-03-28
- **Audit Mode**: Thorough (Opus orchestrator, full depth loops, RAG validation, design stress testing)
- **Scope**: 13 in-scope contracts, 4,094 lines (excluding interfaces)
  - Core: CoverPool, CoverPoolFactory, PolicyManager, ClaimManager, PremiumCollector, PremiumManager, SpecRegistry, Swapper
  - Morpho Vault: CoveredVaultWrapper, CoveredVaultAdmin, CoveredVaultAccrual, CoveredVaultStorage, BasePolicyInteractions
- **Build Status**: Solc 0.8.28 — Successful
- **Proven-Only Mode**: ENABLED — 5 findings capped at Low from High/Medium due to unproven evidence ([CODE-TRACE] only)

## Summary Counts (Final)
| Severity | Count |
|----------|-------|
| **High** | **3** |
| **Medium** | **17** |
| **Low** | **30** |
| **Informational** | **13** |
| **Total** | **63** |
| FALSE_POSITIVE (excluded) | 3 |

## Master Finding Index

| Report ID | Title | Severity | Location | Verification | Trust Adj. | Internal Hypothesis | Agent Sources |
|-----------|-------|----------|----------|--------------|-----------|-------------------|--------------|
| H-01 | gateGracePeriod Renders Grace Window Fully Uninsured While Premium Accrues | High | CoveredVaultWrapper:L80-120, ClaimManager:L280-310 | [POC-PASS] | — | H-1 | RS1-1, SGI-2, VS-UPDATE |
| H-02 | UniswapV3Adapter Fee-Tier Desync Between Quote and Swap | High | UniswapV3Adapter:L95-145, Swapper:L200-230 | [POC-PASS] | — | H-5 | PC3-2, DEPTH-EX-4, DEPTH-TF-2 |
| H-03 | Fee-Tier Desync Enables Deterministic Sandwich on Claim Payout | High | ClaimManager:L315-340, UniswapV3Adapter:L110-140 | [POC-PASS] | — | CH-2 (H-5→H-7) | Chain analysis, ITER2-FA-3 |
| M-01 | Unbounded gateGracePeriod Accumulation via Repeated Gate Toggles | Medium | CoveredVaultAdmin:L150-180 | [POC-PASS] | — | H-2 | CS-1, PC1-4 |
| M-02 | totalPremiumLiability Phantom Residual After Deep-Loss Withdrawals | Medium | CoveredVaultWrapper:L420-460 | [POC-PASS] | — | H-3 + CH-1 + CH-4 | CS-2, SGI-1, VA-6, DEPTH-EC-2, DEPTH-ST-2 |
| M-03 | Excess Swap Output Permanently Stranded in ClaimManager | Medium | ClaimManager:L480-510 | [POC-PASS] | — | H-4 | PC3-1, RS2-3, DEX-4 |
| M-04 | Stale Unlimited Approval Persists on Old RewardsManager | Medium | PremiumManager:L145-165 | [POC-PASS] | — | H-6 | PC4-1, DEPTH-TF-4 |
| M-05 | Retroactive deductibleBps/maxCoverableLossBps Changes Reduce Insurance Payout | Medium | CoveredVaultWrapper:L350-380 | [POC-PASS] | — | H-8 + CH-1 | CS-5, ITER2-ST-2 |
| M-06 | _isPolicyActive External Call Blocks All Withdrawals During PolicyManager Downtime | Medium | CoveredVaultAccrual:L65-95 | [POC-PASS] | — | H-11 | TF-7, DEPTH-EX-1, DEPTH-EX-2 |
| M-07 | Revoked Spec Still Callable by ClaimManager for Existing Policies | Medium | SpecRegistry:L85-120, ClaimManager:L560-590 | [POC-PASS] | — | H-12 | RS2-1, ITER2-ST-3, DEPTH-ST-7 |
| M-08 | poolFeeBps Read Live at Distribution Enables Retroactive Fee Extraction | Medium | PremiumManager:L100-130, CoverPool:L220-240 | [POC-PASS] | — | H-13 + CH-6 | PC4-2, ITER2-FA-3, DEPTH-ST-8 |
| M-09 | maxWithdraw/maxRedeem Double-Deducts Premium (ERC-4626 Spec Violation) | Medium | CoveredVaultWrapper:L300-320 | [POC-PASS] | — | H-14 | PC1-1, ITER2-LC-2, DEPTH-ST-9 |
| M-10 | CREATOR_ROLE Can Replace Infrastructure Addresses Without Timelock | Medium | CoverPoolFactory:L180-210 | [POC-PASS] | — | H-16 | AC-1 |
| M-11 | Quote startTime Goes Stale Between Draft Creation and Policy Binding | Medium | PolicyManager:L250-280, CoverPool:L150-170 | [POC-PASS] | — | H-19 | PC2-1, DEPTH-ST-6 |
| M-12 | Operator Can Waive Owner's Insurance via Emergency Exit | Medium | CoveredVaultWrapper:L550-580 | [POC-PASS] | — | H-22 | RS1-2 |
| M-13 | Old CoverPools Permanently Orphaned After Infrastructure Rotation | Medium | CoverPoolFactory:L90-120 | [POC-PASS] | — | H-25 | RS1-3, ITER2-FA-1 |
| M-14 | Repeated Gate Toggles Create Arbitrarily Long Uninsured Window | Medium | CoveredVaultAdmin:L150-180, CoveredVaultAccrual:L80-100 | [POC-PASS] | — | CH-3 (H-1+H-2) | Chain analysis |
| M-15 | Morpho Loss During Grace Window Creates Permanent NAV Deflation | Medium | CoveredVaultWrapper:L420-460, CoveredVaultAccrual:L65-95 | [POC-PASS] | — | CH-4 (H-1+H-3) | Chain analysis |
| M-16 | Curator Combines Claim Denial with Retroactive Fee Extraction | Medium | CoverPool:L280-310, PremiumManager:L100-130 | [POC-PASS] | — | CH-6 (H-9+H-13) | Chain analysis, curator dual-profit |
| M-17 | Phantom Residual Widens previewRedeem Gap | Medium | CoveredVaultWrapper:L200-240, CoveredVaultWrapper:L420-460 | [POC-PASS] | — | CH-5 (H-3+H-15) | Vault Accounting, chain analysis |
| L-01 | renounceOwnership Not Overridden in UniswapV3Adapter | Low | UniswapV3Adapter:L45-60 | [POC-PASS] | — | H-17 | BLIND-C-1 |
| L-02 | PREMIUM_COLLECTOR_ROLE Not Granted in PremiumManager.initialize() | Low | PremiumManager:L60-85 | [CODE-TRACE] | — | H-18 | BLIND-C-2 (critical deployment issue) |
| L-03 | Pre-Policy Phantom Premium When Checkpoint Predates startTime | Low | CoveredVaultAccrual:L120-140 | [POC-PASS] | — | H-21 | PC1-2, DEPTH-ST-10 |
| L-04 | distributeBatch Reverts Entirely on Single Vault Failure | Low | PremiumCollector:L200-230 | [CODE-TRACE] | — | H-23 | RS2-2, DEPTH-EX-7 |
| L-05 | Oracle Revert in bindPolicy Blocks All Policy Binding | Low | PolicyManager:L270-290 | [CODE-TRACE] | — | H-24 | OZ-1, DEPTH-EX-8 |
| L-06 | depositCap Reopens After Withdrawals During Loss Event | Low | CoveredVaultWrapper:L520-540 | [POC-PASS] | — | H-27 | CS-9, BLIND-A-1 |
| L-07 | Deposits Accepted After Policy Maturity Without Insurance | Low | CoveredVaultWrapper:L510-525 | [POC-PASS] | — | H-28 | OZ-2, DEPTH-EC-9, DST-4 |
| L-08 | Fee-on-Transfer Collateral Tokens Cause Claim Revert | Low | ClaimManager:L620-650 | [CODE-TRACE] | — | H-29 | TF-5, DEPTH-TF-6 |
| L-09 | amountOutMin Falls to 1 When QuoterV2 Reverts, Enabling Near-Total Sandwich | Low | Swapper:L280-310 | [CODE-TRACE] | PROVEN_ONLY from High | H-7 | TF-4, DEX-1, DEPTH-TF-3 |
| L-10 | Curator Can Permanently Block Claims via setPremiumDefaulted | Low | CoverPool:L285-300 | [CODE-TRACE] | PROVEN_ONLY from Medium | H-9 | AC-2 |
| L-11 | Claim Approval Gate Serializes Concurrent Claimants (First-Claimer Race) | Low | ClaimManager:L290-320 | [CODE-TRACE] | PROVEN_ONLY from Medium | H-10 | AC-3, SGI-6 |
| L-12 | Stale lastKnownMorphoValue During Morpho Downtime Inflates Premium Cap | Low | CoveredVaultWrapper:L140-160 | [CODE-TRACE] | PROVEN_ONLY from Medium | H-20 | OZ-3, CS-3, DEPTH-EX-3 |
| L-13 | userPremiumDebt Zeroed by Floor Rounding After Partial Withdrawal | Low | CoveredVaultWrapper:L400-420 | [CODE-TRACE] | PROVEN_ONLY from Medium | H-30 | VA-1 |
| L-14 | evidenceHash Permanently Consumed Even on Rejected Claims | Low | ClaimManager:L360-390 | [POC-PASS] | — | H-31 | PC3-5 |
| L-15 | setNativeWrapper Does Not Disable Old WETH-Keyed Routes | Low | Swapper:L330-360 | [CODE-TRACE] | — | H-32 | BLIND-C-3 |
| L-16 | approveNextClaim Emits Misleading Event on Non-Gated Policy | Low | ClaimManager:L400-420 | [CODE-TRACE] | — | H-33 | PC3-4 |
| L-17 | cumulativePremiumPerUnit Precision Loss With Small totalPrincipal | Low | CoveredVaultAccrual:L110-130 | [CODE-TRACE] | — | H-34 | CS-6, SGI-4 |
| L-18 | updateVault Missing nonReentrant Guard | Low | PremiumCollector:L160-180 | [CODE-TRACE] | — | H-35 | PC4-3, DEPTH-EX-6 |
| L-19 | PremiumCollector Caches Vault Underlying at Registration | Low | PremiumCollector:L90-110 | [CODE-TRACE] | — | H-36 | PC4-4 |
| L-20 | executeUpgrade Clears Pending State After upgradeToAndCall | Low | CoveredVaultAdmin:L190-210 | [CODE-TRACE] | — | H-37 | AC-8 |
| L-21 | rescueTokens Uses totalPrincipal>0 as Proxy for Tracked Shares | Low | CoveredVaultWrapper:L635-650 | [CODE-TRACE] | — | H-38 | OZ-5 |
| L-22 | Stale Evidence Hash From block.timestamp Causes Same-Block Claim Denial | Low | ClaimManager:L360-390 | [CODE-TRACE] | — | H-40 | RS3-2 |
| L-23 | bindPolicy Hook Single-Use Guard Permanently Blocks Re-Binding | Low | CoveredVaultWrapper:L595-610 | [CODE-TRACE] | — | H-41 | PC2-3 |
| L-24 | block.timestamp as Swap Deadline (No MEV Time Protection) | Low | Swapper:L250-280 | [CODE-TRACE] | — | H-44 | TF-1 |
| L-25 | Unsolicited Morpho Share Donation (No Attacker Profit) | Low | CoveredVaultWrapper:L475-490 | [CODE-TRACE] | — | H-45 | TF-3 |
| L-26 | SpecRegistry whenNotPaused Cross-Contract Pause Dependency | Low | SpecRegistry:L70-85, ClaimManager:L565-580 | [CODE-TRACE] | — | H-46 | BLIND-B-3 |
| L-27 | Factory Uses Instant Admin Transfer While CoverPools Use 24h Delay | Low | CoverPoolFactory:L140-160, CoverPool:L50-70 | [CODE-TRACE] | — | H-47 | BLIND-B-1 |
| L-28 | coverageLimit Cached Locally vs Live Read in ClaimManager | Low | ClaimManager:L180-210, CoverPool:L225-245 | [CODE-TRACE] | — | H-52 | SC-8 |
| L-29 | _MAX_FEE_BPS Guard Semantically Misleading | Low | CoverPool:L30-45 | [CODE-TRACE] | — | H-53 | SC-5 |
| I-01 | PolicyManager._validateRequest Missing startTime Check (Defence-in-Depth) | Informational | PolicyManager:L200-220 | [CODE-TRACE] | — | H-42 | PC2-5 |
| I-02 | PremiumCollector Missing recoverTokens Function | Informational | PremiumCollector:L290-297 | [CODE-TRACE] | — | H-43 | BLIND-C-4 |
| I-03 | _withdraw Decrements totalPrincipal After External Interactions | Informational | CoveredVaultWrapper:L625-640 | [CODE-TRACE] | — | H-48 | PC1-3 (CEI violation, mitigated by nonReentrant) |
| I-04 | acceptOwnership Clears Timestamps But Not Pending Values | Informational | CoveredVaultAdmin:L220-230 | [CODE-TRACE] | — | H-49 | BLIND-A-4 |
| I-05 | Swapper Stored Route Calldata May Become Stale | Informational | Swapper:L150-175 | [CODE-TRACE] | — | H-50 | TF-8 |
| I-06 | PremiumManager approveSpender Allows Arbitrary ERC-20 Approvals | Informational | PremiumManager:L185-200 | [CODE-TRACE] | [ASSUMPTION-DEP: TRUSTED-ACTOR] | H-51 | AC-9 |
| I-07 | premiumRatePerSecond Missing WAD-Scaled Qualifier | Informational | CoveredVaultStorage:L50-65 | [CODE-TRACE] | — | H-54 | SC-9 |
| I-08 | Combined Fee Cap Dead Code (100% Unreachable) | Informational | CoverPool:L35-45 | [CODE-TRACE] | — | H-55 | ITER2-FA-2 |
| I-09 | _accruePremium Advances Timestamp When Rate is Zero | Informational | CoveredVaultAccrual:L85-100 | [CODE-TRACE] | — | H-57 | CS-10 |
| I-10 | Fee Split Rounding Favors Restakers (2 wei dust) | Informational | PremiumManager:L125-140 | [CODE-TRACE] | — | H-58 | CS-8 |
| I-11 | PremiumCollector._distribute Truncates to uint32 | Informational | PremiumCollector:L220-235 | [CODE-TRACE] | — | H-59 | CS-7 |
| I-12 | _isPolicyActive External Call on Every Deposit/Withdraw (Gas) | Informational | CoveredVaultAccrual:L65-95 | [CODE-TRACE] | — | H-60 | OZ-6 |
| I-13 | CoverPool Curator 24-Hour Admin Transfer Delay | Informational | CoverPool:L50-70 | [CODE-TRACE] | [ASSUMPTION-DEP: WITHIN-BOUNDS] | H-61 | AC-6 |

---

## Tier Assignments

### Critical+High Tier (for Opus writer)
- **H-01** (gateGracePeriod uninsured grace window) — internal H-1 — High severity
- **H-02** (UniswapV3Adapter fee desync) — internal H-5 — High severity
- **H-03** (fee desync enables sandwich) — internal CH-2 — High severity
- **M-01** (unbounded gateGracePeriod) — internal H-2 — Medium severity
- **M-02** (phantom residual) — internal H-3, CH-1, CH-4 — Medium severity
- **M-03** (excess swap stranded) — internal H-4 — Medium severity
- **M-04** (stale approval) — internal H-6 — Medium severity
- **M-05** (retroactive deductible/maxLoss) — internal H-8, CH-1 — Medium severity
- **M-06** (PolicyManager DoS) — internal H-11 — Medium severity
- **M-07** (revoked spec callable) — internal H-12 — Medium severity
- **M-08** (poolFeeBps retroactive) — internal H-13, CH-6 — Medium severity

### Medium Tier (for Sonnet writer)
- **M-09** (maxWithdraw double-deduct) — internal H-14 — Medium severity
- **M-10** (CREATOR_ROLE no timelock) — internal H-16 — Medium severity
- **M-11** (quote startTime stale) — internal H-19 — Medium severity
- **M-12** (operator waives insurance) — internal H-22 — Medium severity
- **M-13** (orphaned CoverPools) — internal H-25 — Medium severity
- **M-14** (repeated gate toggles uninsured) — internal CH-3 — Medium severity
- **M-15** (Morpho loss during grace) — internal CH-4 — Medium severity
- **M-16** (curator claim denial + fee extraction) — internal CH-6 — Medium severity
- **M-17** (phantom residual widens preview) — internal CH-5 — Medium severity

### Low+Info Tier (for Sonnet writer)
- **Low findings**: L-01 through L-29 (30 findings)
- **Informational findings**: I-01 through I-13 (13 findings)

---

## Consolidation Map

The following hypotheses were consolidated into single report findings due to shared root cause, same severity tier, same vulnerability class, and unified fix:

| Report ID | Consolidated From | Consolidation Reason |
|-----------|-------------------|---------------------|
| M-02 | H-3, CH-1, CH-4 | All involve phantom residual in totalPremiumLiability; share same fix: decrement by uncappedPremium; H-3 is root, CH-1/CH-4 describe compounding via H-8 and H-1 respectively |
| M-05 | H-8, CH-1 | Both involve retroactive parameter changes reducing insurance payout; CH-1 describes H-8 amplifying phantom residual; same fix: snapshot parameters at loss-event time |
| M-08 | H-13, CH-6 | Both involve poolFeeBps extraction; CH-6 combines with claim denial (H-9); kept separate (see M-16) to show full attack path for CH-6 |
| M-14 | CH-3 (H-1 + H-2) | Chain hypothesis consolidates H-1 (grace window) with H-2 (unbounded accumulation); described as single finding with both components |
| M-15 | CH-4 (H-1 + H-3) | Chain hypothesis consolidates H-1 (grace window) with H-3 (phantom residual); describes how grace window GUARANTEES deep-loss scenario creating maximum phantom |
| M-16 | CH-6 (H-9 + H-13) | Chain hypothesis consolidates H-9 (claim denial) with H-13 (retroactive fees); describes curator dual-profit attack sequence |
| M-17 | CH-5 (H-3 + H-15) | Chain hypothesis consolidates H-3 (phantom) with H-15 (preview overstatement); phantom amplifies preview gap for integrators |

**Non-consolidated hypotheses**: H-1, H-2, H-4, H-5, H-6, H-7 (now L-09), H-9 (now L-10), H-10 (now L-11), H-11, H-12, H-14, H-16, H-17 (now L-01), H-18 (now L-02), H-19, H-20 (now L-12), H-21 (now L-03), H-22, H-23 (now L-04), H-24 (now L-05), H-25, H-26 (FALSE_POSITIVE), H-27 (now L-06), H-28 (now L-07), H-29 (now L-08), H-30 (now L-13), H-31 (now L-14), H-32 (now L-15), H-33 (now L-16), H-34 (now L-17), H-35 (now L-18), H-36 (now L-19), H-37 (now L-20), H-38 (now L-21), H-39 (FALSE_POSITIVE), H-40 (now L-22), H-41 (now L-23), H-42 (now I-01), H-43 (now I-02), H-44 (now L-24), H-45 (now L-25), H-46 (now L-26), H-47 (now L-27), H-48 (now I-03), H-49 (now I-04), H-50 (now I-05), H-51 (now I-06), H-52 (now L-28), H-53 (now L-29), H-54 (now I-07), H-55 (now I-08), H-56 (design assumption, not reported), H-57 (now I-09), H-58 (now I-10), H-59 (now I-11), H-60 (now I-12), H-61 (now I-13)

---

## Cross-Reference Map

| Report ID | References | Context |
|-----------|-----------|---------|
| H-01 | — | Standalone; blocks claims during extended grace window (H-2 amplifies) |
| H-02 | — | Standalone; enables MEV sandwich (H-03 describes full chain) |
| H-03 | H-02, L-09 | Chain: H-02's fee desync creates precondition for L-09's sandwich (High severity) |
| M-01 | H-01, M-02 | Enabler: unbounded accumulation of gateGracePeriod extends H-01's uninsured window (see M-14) |
| M-02 | M-01, M-05, M-14, M-15 | Root cause: phantom residual amplified by H-2 unbounding (M-14), H-8 param reduction (M-05), H-1 grace window (M-15) |
| M-03 | — | Standalone; excess swap value locked in ClaimManager |
| M-04 | — | Standalone; stale approval on old contract |
| M-05 | M-02, M-14 | Enabler: retroactive param change deepens loss gap in M-02 phantom; occurs during M-14 uninsured window |
| M-06 | — | Standalone; external dependency failure cascades to fund lockup |
| M-07 | L-10 | Related: revoked spec denial + L-10's curator block are parallel claim-denial vectors |
| M-08 | M-16 | Enabled by: curator combines M-08's fee extraction with L-10's claim denial (see M-16) |
| M-09 | — | Standalone; ERC-4626 spec violation |
| M-10 | — | Standalone; no timelock on critical role action |
| M-11 | — | Standalone; quote staleness blocks binding |
| M-12 | — | Standalone; operator can bypass insurance requirement |
| M-13 | — | Standalone; infrastructure upgrade orphans old pools |
| M-14 | H-01, M-01 | Chain: H-01 (grace uninsured) amplified by M-01 (unbounded gateGracePeriod); see also M-15 for loss-event impact |
| M-15 | H-01, M-02 | Chain: H-01 grace window GUARANTEES M-02 deep-loss phantom; loss during grace = zero insurance + full premium debt |
| M-16 | L-10, M-08 | Chain: curator blocks claims (L-10) then extracts retroactive fees (M-08) in same transaction sequence |
| M-17 | M-02 | Compounding: phantom in M-02 inflates totalPremiumLiability, further widening previewRedeem gap; integrator impact |
| L-01 through I-13 | — | Standalone findings (Low/Info tier) |

---

## Excluded Findings (FALSE_POSITIVE)

| Internal ID | Severity | Title | Exclusion Reason |
|-------------|----------|-------|-----------------|
| H-15 | Medium | previewRedeem/previewWithdraw Overstates Proceeds | previewRedeem correctly reflects totalAssets-based calculation; single-user test shows exact equality; finding based on stale analysis |
| H-26 | Low | Premium Rate Change Retroactive to All Existing Positions | executePremiumRate() calls _accruePremium() before changing rate; strictly prospective; not retroactive |
| H-39 | Medium | Post-Expiry Premium Catch-Up Charges Full Lifetime Premium | _activeElapsedFrom caps at effectiveMaturity, not block.timestamp; only charges missed window between prior checkpoint and current block; not full lifetime |

---

## Verification Coverage Assert

- **Total hypotheses in hypotheses.md**: 61 (H-1 through H-61)
- **Total chain hypotheses**: 6 (CH-1 through CH-6; CH-7 is orthogonal, not a chain)
- **Total hypotheses + chains**: 67
- **Verified in batches A–E**: 67 ✓
- **FALSE_POSITIVE exclusions**: 3 (H-15, H-26, H-39)
- **Consolidations**: 7 (CH-1→M-05, CH-3→M-14, CH-4→M-15, CH-5→M-17, CH-6→M-16, H-3 consolidated into M-02 with CH-1/CH-4 context)
- **Mapped to report findings**: 63 (3 High + 17 Medium + 30 Low + 13 Informational)
- **Coverage**: 67 verified / (67 - 3 FALSE_POSITIVE) = 100% of valid findings ✓

---

## Report Stats

| Metric | Value |
|--------|-------|
| Total findings to report | 63 |
| Findings consolidated from multiple hypotheses | 7 |
| Chain findings (multi-vulnerability attacks) | 4 (H-03, M-14, M-15, M-16) |
| Proven-only demotions (from High/Medium to Low) | 5 (H-7→L-09, H-9→L-10, H-10→L-11, H-20→L-12, H-30→L-13) |
| Trust assumption annotations | 2 (H-51→I-06, H-61→I-13; H-56 design assumption not reported) |
| High-severity findings | 3 (H-01, H-02, H-03) |
| Medium-severity findings | 17 (including 4 chains: M-14, M-15, M-16, M-17) |
| PoC-verified findings | 48 ([POC-PASS]) |
| Code-trace-only findings | 15 ([CODE-TRACE]) |
| Average severity per cluster | Medium (most findings are Medium/Low) |
