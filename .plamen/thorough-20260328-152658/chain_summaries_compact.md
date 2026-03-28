# Chain Summaries Compact
# Extracted from all depth/scanner/niche agent output files for Phase 4c chain analysis

---

# Source: depth_token_flow_findings.md

## Chain Summary

| Finding ID | Dangerous State | Postconditions | Precondition Type |
|------------|----------------|----------------|-------------------|
| DEPTH-TF-1 | Excess payout token stranded in ClaimManager after swap cap | Restaker over-slashed, surplus admin-recoverable only | BALANCE |
| DEPTH-TF-2 | Fee tier desync between quote and swap paths | Claims DoS or weakened slippage; two admin roles must coordinate | STATE, EXTERNAL |
| DEPTH-TF-3 | amountOutMin=1 when QuoterV2 reverts | Near-total MEV extraction from claim swap | EXTERNAL |
| DEPTH-TF-4 | Stale ERC-20 approval on old RewardsManager | Old address retains pull access to PremiumManager funds | ACCESS, BALANCE |
| DEPTH-TF-5 | Operator waives owner's insurance via emergency exit | Owner loses insurance payout; operator gets less (griefing only) | ACCESS |
| DEPTH-TF-6 | Fee-on-transfer collateral causes claim revert | DoS on claims for fee-on-transfer collateral vaults | EXTERNAL |
| DEPTH-TF-7 | block.timestamp deadline is no-op | No practical impact (on-chain quote provides protection) | - |
| DEPTH-TF-8 | Same-token excess collateral stranded (multi-vault) | Minor surplus in ClaimManager, admin-recoverable | BALANCE |

---

# Source: depth_state_trace_findings.md

## Chain Summary

| Finding ID | Dangerous State | Postconditions | Precondition Type |
|---|---|---|---|
| DEPTH-ST-1 | Grace window: premium paid, insurance uncollectable | Users lose premium + 0 insurance; pendingPremium inflated | STATE + TIMING |
| DEPTH-ST-2 | Phantom totalPremiumLiability after deep loss | Permanent NAV deflation for remaining holders; inflated liability | STATE + BALANCE |
| DEPTH-ST-3 | Unbounded gateGracePeriod | Indefinitely extended premium window past maturity | STATE + TIMING |
| DEPTH-ST-4 | Gate + parameter change combo | Users have no exit window at original terms | STATE + TIMING + ACCESS |
| DEPTH-ST-5 | Dual claim-blocking flags both active | All claims blocked, two curator actions needed | STATE + ACCESS |
| DEPTH-ST-6 | Quote startTime stale at bind time | Policy binding fails; operational friction | TIMING |
| DEPTH-ST-7 | Revoked spec still callable | Claims evaluated by potentially compromised logic | ACCESS + STATE |
| DEPTH-ST-8 | poolFeeBps live read at distribution | Retroactive fee extraction up to 20% | BALANCE |
| DEPTH-ST-9 | maxWithdraw double premium deduction | Understated maxWithdraw for integrators | STATE |
| DEPTH-ST-10 | Pre-policy checkpoint gap | Phantom premium for pre-startTime period | STATE + TIMING |
| DEPTH-ST-11 | Premium rate 2h notice period | All positions face new rate with minimal notice | STATE + BALANCE |

---

# Source: depth_edge_case_findings.md

## Chain Summary

| Finding ID | Dangerous State | Postconditions | Precondition Type |
|------------|----------------|----------------|-------------------|
| DEPTH-EC-2 | totalPremiumLiability residual after all users exit in deep-loss | totalAssets() suppressed for future depositors; ghost liability never collectible | STATE |
| DEPTH-EC-3 | lastKnownMorphoValue stale after gate deactivation | Off-chain integrators see incorrect TVL; on-chain calculations unaffected once interaction occurs | STATE |
| DEPTH-EC-6 | Pre-policy phantom premium charged when checkpoint < startTime and policy becomes active | premiumRecipient over-collects from early depositors; charged for pre-policy period | TIMING |
| DEPTH-EC-8 | depositCap = 0 if coverageLimit = 0 in onPolicyBound | Vault sealed; no deposits possible | STATE |
| DEPTH-EC-9 | Expired policy + active Morpho gate simultaneously | Users deposit without insurance AND cannot withdraw | TIMING + STATE |

---

# Source: depth_external_findings.md

## Chain Summary

| Finding ID | Location | Root Cause (1-line) | Verdict | Severity | Precondition Type | Postcondition Type |
|------------|----------|---------------------|---------|----------|-------------------|--------------------|
| DEPTH-EX-1 | CoveredVaultAccrual.sol:153-159, CoveredVaultWrapper.sol:241-262 | emergencyRedeem/emergencyWithdraw call _accruePremium which calls _isPolicyActive with no try/catch | CONFIRMED | Medium | EXTERNAL (PolicyManager availability) | TIMING (all exits blocked during PM downtime) |
| DEPTH-EX-2 | CoveredVaultAccrual.sol:116-136 | _activeElapsedFrom makes two external PolicyManager calls, neither wrapped | CONFIRMED | Low | EXTERNAL | N/A (same as DEPTH-EX-1) |
| DEPTH-EX-3 | CoveredVaultAccrual.sol:139-147, CoveredVaultAdmin.sol:168-186 | lastKnownMorphoValue frozen during Morpho downtime until owner manually gates; stale cap enables over-accrual | CONFIRMED | Medium | TIMING (owner response delay) | STATE (inflated totalPremiumLiability) |
| DEPTH-EX-4 | UniswapV3Adapter.sol:127-135,155-188 | quote() uses pairFees mapping while swap() uses fee from stored calldata; desync after setPairFee call | CONFIRMED | High | EXTERNAL (route configuration) | EXTERNAL (claim DoS or weakened slippage) |
| DEPTH-EX-5 | ClaimManager.sol:629-670 | Failed executeSwap reverts entire fileClaim atomically; no partial state | REFUTED | N/A | N/A | N/A |
| DEPTH-EX-6 | PremiumCollector.sol:147-158, 265-296 | updateVault lacks nonReentrant; external vault.redeem() can reenter to corrupt pool/policyId routing | CONFIRMED | Low | ACCESS (requires admin to violate trust) | STATE (premium routed to wrong policy) |
| DEPTH-EX-7 | PremiumCollector.sol:163-168 | distributeBatch has no per-vault try/catch; one failing vault reverts entire batch | CONFIRMED | Low | EXTERNAL (any vault's redeem failure) | TIMING (all vaults miss distribution window) |
| DEPTH-EX-8 | PolicyManager.sol:266-274 | Chainlink getUSDValue has no try/catch in bindPolicy loop; stale feed blocks all new bindings | CONFIRMED | Low | EXTERNAL (Chainlink feed availability) | TIMING (new policy binding blocked) |

---

# Source: blind_spot_A_findings.md

## Chain Summary

| Finding ID | Location | Root Cause (1-line) | Verdict | Severity | Precondition Type | Postcondition Type |
|------------|----------|--------------------:|---------|----------|-------------------|-------------------|
| BLIND-A-1 | CoveredVaultAdmin.sol:57-69, CoveredVaultWrapper.sol:467-469 | maxCoverableLossBps increase reduces depositCap below totalPrincipal, blocking all new deposits | CONFIRMED | Low | STATE | STATE (maxDeposit=0) |
| BLIND-A-2 | CoveredVaultAccrual.sol:70-78, CoveredVaultAdmin.sol:196-213 | premiumRecipient receiving blocked ERC-20 (e.g., USDC blocklist) causes pendingPremium lockup with no fast rescue path | CONFIRMED | Low | EXTERNAL | STATE (stuck premium, 2d recovery) |
| BLIND-A-3 | CoveredVaultAccrual.sol:116-136 | Active policy path in _activeElapsedFrom does not clamp checkpoint to startTime, causing phantom pre-start premium accrual | PARTIAL | Low | STATE / TIMING | STATE (overcollected premium) |
| BLIND-A-4 | CoveredVaultAdmin.sol:116-124 | acceptOwnership clears timestamps but not pending values, leaving stale state visible in storage | PARTIAL | Informational | STATE | STATE (stale storage, no execution risk) |
| BLIND-A-5 | CoveredVaultAccrual.sol:116-136, CoveredVaultWrapper.sol:106-110 | _activeElapsedFrom calls _isPolicyActive() twice per call path, extending PolicyManager DoS blast radius to all view functions | CONFIRMED | Informational | EXTERNAL | STATE (all view functions break on PolicyManager DoS) |

---

# Source: blind_spot_B_findings.md

## Chain Summary

| Finding ID | Location | Root Cause (1-line) | Verdict | Severity | Precondition Type | Postcondition Type |
|------------|----------|---------------------|---------|----------|-------------------|-------------------|
| BLIND-B-1 | CoverPoolFactory.sol:45-73 | Factory uses AccessControlUpgradeable (instant admin transfer) while CoverPools it creates use AccessControlDefaultAdminRulesUpgradeable (24h delay) | CONFIRMED | Low | ACCESS | ACCESS |
| BLIND-B-2 | SpecRegistry.sol:50-56 | setCoverPoolFactory is one-time write with no update path; factory re-deployment would permanently break spec registration | CONFIRMED | Low | STATE | STATE, EXTERNAL |
| BLIND-B-3 | CoverPool.sol:180, SpecRegistry.sol:100 | SpecRegistry whenNotPaused propagates through CoverPool.bindPolicyForRequest as undocumented cross-contract pause dependency | CONFIRMED | Low | STATE | STATE, TIMING |

---

# Source: blind_spot_C_findings.md

## Chain Summary

| Finding ID | Location | Root Cause (1-line) | Verdict | Severity | Precondition Type | Postcondition Type |
|------------|----------|---------------------|---------|----------|-------------------|-------------------|
| BLIND-C-1 | UniswapV3Adapter.sol:116, Ownable.sol:76 | renounceOwnership() not overridden in UniswapV3Adapter; owner can permanently destroy setPairFee() reachability | CONFIRMED | Medium | ACCESS | STATE, ACCESS |
| BLIND-C-2 | PremiumManager.sol:54-74, 147 | PREMIUM_COLLECTOR_ROLE not granted in PremiumManager.initialize(); admin must grant it separately or all distributions silently fail | CONFIRMED | Low | ACCESS | STATE, TIMING |
| BLIND-C-3 | Swapper.sol:123-127, 231-234 | setNativeWrapper() changes wrapper but does not disable old WETH-keyed routes; stale routes remain executable via ERC20 path | CONFIRMED | Low | STATE | STATE, EXTERNAL |
| BLIND-C-4 | PremiumCollector.sol (missing) | No recoverTokens() on PremiumCollector despite all sibling UUPS contracts having one; stranded tokens unrecoverable | CONFIRMED | Informational | EXTERNAL | BALANCE |

---

# Source: validation_sweep_findings.md

## Chain Summary

| Finding ID | Location | Root Cause (1-line) | Verdict | Severity | Precondition Type | Postcondition Type |
|------------|----------|---------------------|---------|----------|-------------------|-------------------|
| VS-1 | CoveredVaultAccrual.sol:158, ClaimManager.sol:307 | Strict `<` in wrapper vs non-strict `<=` in ClaimManager at maturity boundary creates 1-second coverage gap | CONFIRMED | Informational | TIMING | TIMING |
| VS-UPDATE-RS1-1 | CoveredVaultAccrual.sol:156-158, ClaimManager.sol:306-309 | Vault effectiveMaturity includes gateGracePeriod; ClaimManager uses raw maturityTime — grace window is fully uninsured while premium accrues | CONFIRMED | High | TIMING, STATE | BALANCE, STATE |
| VS-UPDATE-CS-2 | CoveredVaultWrapper.sol:578-583 | totalPremiumLiability decremented by premiumForWithdrawal (actual) not uncappedPremium (owed), creating permanent phantom residual | CONFIRMED | Medium | STATE | STATE, BALANCE |
| VS-UPDATE-PC4-1 | PremiumManager.sol:93-97 | setRewardsManager replaces reference without revoking unlimited approval on old address | CONFIRMED | Medium | ACCESS | BALANCE |
| VS-UPDATE-PC3-1 | ClaimManager.sol:663-667 | swapOutput excess above remainingPayout transferred to beneficiary; delta stranded in ClaimManager | CONFIRMED | High | STATE, BALANCE | BALANCE |
| VS-UPDATE-PC3-2 | UniswapV3Adapter.sol:127-135, 193-198 | pairFees updated live but swap calldata encodes frozen fee tier from route configuration time | CONFIRMED | High | STATE | STATE |

---

# Source: niche_SIGNATURE_VERIFICATION_AUDIT_findings.md

## Chain Summary

| Finding ID | Title | Severity | Verdict | Postconditions Created | Preconditions Blocked |
|-----------|-------|----------|---------|----------------------|----------------------|
| SIG-1 | basePremium signed but not persisted post-binding | Informational | CONFIRMED | None (no funds at risk) | N/A |
| SIG-2 | Role revocation does not invalidate prior signatures | Informational | REFUTED | None | Live role check at bind time |
| SIG-3 | EIP-712 domain separator correct (positive) | Informational | CONFIRMED (positive) | N/A | N/A |
| SIG-4 | ECDSA malleability | Informational | REFUTED | None | OZ high-s rejection |
| SIG-5 | Cross-pool quote replay | Informational | REFUTED | None | Domain separator + pool field |
| SIG-6 | Nonce-free system — replay analysis | Informational | CONFIRMED (design adequate) | None | policyCommit invalidation + draft status |
| SIG-7 | buyer excluded from signed quote | Informational | CONFIRMED (design adequate) | None | Draft storage binding |

---

# Source: niche_SEMANTIC_CONSISTENCY_AUDIT_findings.md

## Chain Summary

| Finding ID | Title | Severity | Verdict | Potential Chain With |
|------------|-------|----------|---------|---------------------|
| SC-5 | _MAX_FEE_BPS=100% guard semantically misleading; no reachable underflow today but future regression risk if fee caps raised | Low | CONFIRMED | PC4-2 (poolFeeBps live-read front-run) |
| SC-8 | CoveredVaultWrapper caches coverageLimit locally; ClaimManager reads live from PolicyManager — dual-source divergence on upgrade | Low | CONFIRMED | RS1-1 (ClaimManager maturityTime vs wrapper effectiveMaturity) |
| SC-9 | premiumRatePerSecond missing WAD-scaled qualifier in name; naming inconsistency not exploitable but ambiguous for integrators | Informational | CONFIRMED | None |
| SC-1 | gateGracePeriod seconds unit consistent between producer (setMorphoGateActive) and consumer (_activeElapsedFrom, _isPolicyActive) | Informational | REFUTED | N/A |
| SC-2 | ClaimManager raw maturityTime vs wrapper effectiveMaturity — duplicate of RS1-1 | (Duplicate) | REFUTED | N/A |
| SC-3 | coverageLimit units consistent (payout-token raw amount) across all contracts | Informational | REFUTED | N/A |
| SC-4 | _BPS_DENOMINATOR naming isolated per-contract, both 10_000, no shared semantic | Informational | REFUTED | N/A |
| SC-6 | deductibleBps/maxCoverableLossBps invisible to ClaimManager (wrapper handles pre-computation) | Informational | REFUTED | N/A |
| SC-7 | policyId starts at 1 (pre-increment), wrapper guard policyId != 0 correctly calibrated | Informational | REFUTED | N/A |
| SC-10 | All BPS parameters consistently use 10_000 = 100% across all contracts | Informational | REFUTED | N/A |

---

# Source: niche_SEMANTIC_GAP_INVESTIGATOR_findings.md

## Chain Summary

| Finding ID | Title | Verdict | Severity | Root Cause Type | Interacts With |
|-----------|-------|---------|----------|-----------------|---------------|
| SGI-1 | totalPremiumLiability Phantom After Deep-Loss | CONFIRMED | Medium | SYNC_GAP 2 (Pass 1) — permanent accumulation | CS-2 (same root cause, confirms PERMANENT) |
| SGI-2 | gateGracePeriod Extends Accrual Past ClaimManager maturityTime | CONFIRMED | High | SYNC_GAP vs ClaimManager raw maturity — coverage gap | RS1-1, PC1-4, CS-1 |
| SGI-3 | Catch-Up Accrual Charges Full Policy Lifetime Premium on Single Interaction | CONFIRMED | Medium | ACCUMULATION_EXPOSURE — expired policy catch-up window | CS-4 (retroactive rate), RS1-1 |
| SGI-4 | _safeSub Zero Silences Rounding Drift in userPremiumDebt | PARTIAL | Low | CONDITIONAL_WRITE — rounding artifact | CS-6 (precision loss) |
| SGI-5 | totalPremiumLiability Phantom When redeemShares==0 | PARTIAL | Low | CONDITIONAL_WRITE C2c (Pass 2) — abnormal precondition | SGI-1 (same phantom mechanism) |
| SGI-6 | _claimApprovalRequired Silently Blocks All Concurrent Claimants | CONFIRMED | Medium | SYNC_GAP 5 (Pass 1) — Level 3 terminal impact confirmed | AC-3 (curator blocking) |
| SGI-7 | First-Second Premium Discount on Deposit | PARTIAL | Informational | CONDITIONAL_WRITE — by design | CS-6 |
| SGI-8 | collectPremium() Permissionless — Adversarial Checkpoint Manipulation | CONFIRMED | Low | NEW — not in Pass 1/2 | CS-10, gate mechanism |

---

# Source: depth_vault_accounting_injectable_findings.md

## Chain Summary

| Finding ID | Title | Severity | Verdict | Potential Chain With | Postcondition Created |
|-----------|-------|----------|---------|---------------------|----------------------|
| VA-1 | userPremiumDebt Zeroed by Rounding After Partial Withdrawal | Medium | CONFIRMED | CS-2, PC1-1 | userPremiumDebt[user]=0 → next withdrawal overcharges premium → user receives less than expected, potentially triggering insurance for a loss that isn't real |
| VA-2 | totalAssets() Returns 0 When totalPremiumLiability Exceeds Post-Loss morphoValue | Low | PARTIAL | CS-2, OZ-3 | totalAssets()=0 → all previewRedeem()=0 → false insolvency signal for ERC-4626 integrators |
| VA-3 | previewRedeem/previewWithdraw Overstate Proceeds Due to Per-User Premium Not Deducted | Medium | CONFIRMED | PC1-1 (maxWithdraw also wrong) | Returns > actual → ERC-4626 integrators receive less than previewRedeem said → downstream ops may fail |
| VA-4 | Donation Attack Infeasible Due to Decimal Offset | Informational | REFUTED | — | No postcondition (attack blocked) |
| VA-5 | Round-Trip Share Math Loses ≤1 Wei per Deposit | Informational | CONFIRMED | — | Dust loss per deposit; no chain potential |
| VA-6 | Cross-User totalAssets() Distortion from Deep-Loss Residual Premium | Low | CONFIRMED | CS-2 (extends it) | Remaining users' view functions show understated share value; actual funds unaffected |
| VA-7 | userShortfall() Overstates by 1 Unit Due to Mixed Rounding | Informational | CONFIRMED | VA-1 (rounding interactions compound) | Off-chain monitors may misread health; at most 1 unit incorrectly claimed as insurance |

---

# Source: depth_dex_integration_injectable_findings.md

## Chain Summary

| Finding ID | Title | Severity | Verdict | Chains With |
|-----------|-------|----------|---------|-------------|
| DEX-1 | Static amountOutMinimum=0 Eliminates Uniswap-Level Slippage Guard | Medium | CONFIRMED | Compounds TF-4 (quoteSwap=0 path): DEX-1 + TF-4 together create complete slippage bypass with no fallback |
| DEX-2 | SWAP_EXECUTOR_ROLE Can Override Route Calldata to Bypass amountOutMin | Low | PARTIAL | Enabler for DEX-1 exploitation via any future SWAP_EXECUTOR |
| DEX-3 | UniswapV3Adapter amountIn Derived From Approval — Approval Race Window | N/A | REFUTED | — |
| DEX-4 | Large Claim Swaps Execute With No Price Impact Limit | Low | CONFIRMED | Compounds PC3-1 (excess swap output stranded): large price-impacted swap creates excess output that is stranded in ClaimManager per PC3-1 |

---

# Source: design_stress_findings.md

## Chain Summary

| Finding | Dimension | Verdict | Severity | Mechanism | Existential? |
|---------|-----------|---------|----------|-----------|--------------|
| DST-1 | Premium Drain Spiral | CONFIRMED | Design Limit | MAX_PREMIUM_RATE = 50% APR; no yield-floor circuit breaker; depositors can lose 40%+ per year to premium without a Morpho loss event | No — accounting holds, but economically damaging |
| DST-2 | Systemic Morpho Exploit | CONFIRMED | Design Limit | Claim approval gate serializes insurance: only 1st withdrawer gets insurance per curator approval cycle; claim approval gate is per-policyId | Partial failure under mass-withdrawal |
| DST-3 | Curator Claim Denial | CONFIRMED | Structural | setPremiumDefaulted has no timelock; curator can block all claims in same block as Morpho loss with zero notice; direct misalignment between curator's incentive (preserve stake) and depositor's interest (receive insurance) | No — but represents a critical trust assumption violation risk |
| DST-4 | Lifecycle Uninsured Windows | CONFIRMED | Design Adequacy | Deposits open before startTime (State 1 gap) and after maturity (State 3: maxDeposit() doesn't check policy expiry) | No — bounded short-term, but ongoing post-maturity |
| DST-5 | Coverage Adequacy | CONFIRMED | Design Adequacy | Insurance covers losses only in [deductibleBps, maxCoverableLossBps] band; 30% Morpho loss → 9% payout, 21% user loss; formula structurally consistent but narrow coverage window | No — design tradeoff, not a bug |

---

# Source: depth_iter2_state_findings.md

## Chain Summary

| Finding | Source Finding(s) | Agreement | Key Extension |
|---------|------------------|-----------|---------------|
| ITER2-ST-1 | PC2-1 | REFUTES buyer-griefer concern | Binding is `onlyRole(DEFAULT_ADMIN_ROLE)` on CoverPool — buyer cannot trigger or delay it; curator holds all timing risk |
| ITER2-ST-2 | CS-5 | EXTENDS with compound path | Simultaneous maxCoverableLossBps + deductibleBps changes create nonlinear payout reduction; confirmed ClaimManager is NOT affected by vault deductible params |
| ITER2-ST-3 | RS2-1 | CONTRADICTS iteration 1's attack direction | Revocation cannot enable false claims (claimer restricted); instead it fails to block manipulated spec evaluations that deny valid claims |

---

# Source: depth_iter2_factory_findings.md

## Chain Summary

| Finding ID | Severity | Location | Title | Source | Iteration 1 Relation |
|------------|----------|----------|-------|--------|---------------------|
| ITER2-FA-1 | Medium | CoverPool.sol:99-103; CoverPoolFactory.sol:140-158 | Old CoverPools Permanently Orphaned After StakeManager/SpecRegistry Rotation | RS1-3 | EXTENDS — adds concrete blast radius: no migration setter in CoverPool, CREATE2 re-deploy blocked |
| ITER2-FA-2 | Informational | PremiumManager.sol:159-160 | Combined Fee Cap of 100% Is Unreachable Given Current Constants (Dead Code) | PC4-2 (adjacent) | NEW — not in iteration 1 scope |
| ITER2-FA-3 | Medium | PremiumManager.sol:154; CoverPool.sol:123-130; PremiumCollector.sol:163-168 | Curator Can Retroactively Extract Accumulated Premium via Fee Spike Before Self-Triggered Distribution | PC4-2 | EXTENDS — confirms retroactive capture, single-tx execution, 20pp max extraction magnitude |

---

# Source: depth_iter2_lowconf_findings.md

## Chain Summary

| Finding ID | Location | Verdict | Source | New Evidence |
|------------|----------|---------|--------|--------------|
| ITER2-LC-1 | CoveredVaultAccrual.sol:70-78 | REFUTED | SGI-8 | [TRACE] _accruePremium checkpoints before advancing timestamp — no erasure possible |
| ITER2-LC-2 | CoveredVaultWrapper.sol:442-453 | CONFIRMED (Medium) | PC1-1 | [BOUNDARY][TRACE] maxRedeem asymmetry identified; internal usage confirmed absent; bounded understatement magnitude |
| ITER2-LC-3 | CoveredVaultAdmin.sol:168-186 | REFUTED | AC-4 | [TRACE] _accruePremium called first; owner cannot profit from toggle timing |
| ITER2-LC-4 | PremiumCollector.sol:105-108 | REFUTED | PC4-4 | [BOUNDARY][TRACE] ERC-7201 storage slot survives UUPS logic upgrade |
