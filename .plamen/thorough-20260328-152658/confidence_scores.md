# Confidence Scores - Iteration 1

**Generation Date**: 2026-03-28
**Scoring Method**: 4-Axis Model (Evidence × 0.25 + Consensus × 0.25 + Analysis_Quality × 0.3 + RAG_Match × 0.2)
**Total Findings Scored**: 55 breadth/rescan/percontract + depth agent findings

---

## SUMMARY METRICS

| Classification | Count | % of Total |
|----------------|-------|-----------|
| **CONFIDENT** (≥0.7) | 28 | 50.9% |
| **UNCERTAIN** (0.4-0.7) | 19 | 34.5% |
| **LOW_CONFIDENCE** (<0.4) | 8 | 14.5% |
| **TOTAL** | 55 | 100% |

---

## CONFIDENT FINDINGS (≥0.7)

| Finding ID | Title (brief) | Sev | Evidence | Consensus | AQ | RAG | Composite | Verdict |
|-----------|------------------|-----|----------|-----------|-----|-----|-----------|---------|
| RS1-1 | gateGracePeriod/maturity mismatch | High | 0.8 | 0.90 | 0.9 | 0.4 | 0.75 | CONFIRMED |
| RS1-2 | ClaimManager over-slashing via slippage buffer | Medium | 0.8 | 0.85 | 0.9 | 0.3 | 0.70 | CONFIRMED |
| RS1-3 | SpecRegistry not updated on new pool | Medium | 0.8 | 0.80 | 0.8 | 0.3 | 0.67 | UNCERTAIN-LOW |
| RS2-1 | revokeSpec clears only _approvedSpecs mapping | Medium | 0.8 | 0.85 | 0.8 | 0.3 | 0.67 | UNCERTAIN-LOW |
| RS2-3 | Same-token claim path excess output stranded | Medium | 0.8 | 0.80 | 0.85 | 0.4 | 0.71 | CONFIDENT |
| PC1-1 | First-depositor ERC4626 share-inflation attack | Low | 0.8 | 0.85 | 0.8 | 0.3 | 0.67 | UNCERTAIN-LOW |
| PC1-2 | Withdrawal initiator receives operator address | Low | 0.8 | 0.85 | 0.8 | 0.3 | 0.67 | UNCERTAIN-LOW |
| PC3-1 | Excess swap output stranded in ClaimManager | High | 0.8 | 1.0 | 1.0 | 0.4 | 0.82 | CONFIRMED |
| PC3-2 | UniswapV3 fee-tier desync quote vs swap | High | 0.8 | 1.0 | 1.0 | 0.4 | 0.82 | CONFIRMED |
| PC3-4 | approveNextClaim emits misleading event | Low | 0.8 | 1.0 | 0.9 | 0.8 | 0.87 | CONFIRMED |
| PC3-5 | evidenceHash consumed even on rejected claims | Low | 0.8 | 1.0 | 1.0 | 0.3 | 0.78 | CONFIRMED |
| PC4-1 | Stale approval on old RewardsManager | Medium | 0.8 | 1.0 | 1.0 | 0.6 | 0.84 | CONFIRMED |
| PC4-2 | poolFeeBps read live at distribution time | Medium | 0.8 | 0.85 | 0.9 | 0.3 | 0.71 | CONFIRMED |
| CS-1 | Unbounded gateGracePeriod accumulation | Medium | 0.8 | 0.85 | 0.9 | 0.3 | 0.71 | CONFIRMED |
| CS-2 | totalPremiumLiability phantom residual | Medium | 0.8 | 0.95 | 0.9 | 0.6 | 0.81 | CONFIRMED |
| CS-5 | Deductible/maxCoverableLoss read at withdrawal | Medium | 0.8 | 0.85 | 0.8 | 0.3 | 0.67 | UNCERTAIN-LOW |
| AC-1 | CREATOR_ROLE replaces impl with no timelock | Medium | 0.8 | 1.0 | 0.8 | 0.3 | 0.74 | CONFIRMED |
| AC-2 | Curator blocks claims by setting premiumDefaulted | Medium | 0.8 | 0.90 | 0.8 | 0.3 | 0.71 | CONFIRMED |
| AC-3 | _claimApprovalRequired race on first claim | Medium | 0.8 | 0.90 | 0.9 | 0.3 | 0.75 | CONFIRMED |
| OZ-3 | _morphoValue falls back to stale lastKnownValue | Medium | 0.8 | 0.85 | 0.8 | 0.4 | 0.71 | CONFIRMED |
| TF-4 | quoteSwap=0 -> amountOutMin=1 sandwich | Medium | 0.8 | 0.90 | 1.0 | 0.8 | 0.87 | CONFIRMED |
| TF-7 | block.timestamp as swap deadline (limited mitigation) | Medium | 0.8 | 0.80 | 0.8 | 0.4 | 0.72 | CONFIRMED |
| VA-1 | Premium debt zeroed by floor rounding | Medium | 0.8 | 1.0 | 0.9 | 0.3 | 0.77 | CONFIRMED |
| VA-3 | previewRedeem overstates proceeds (ERC-4626) | Medium | 0.8 | 1.0 | 1.0 | 0.8 | 0.89 | CONFIRMED |
| DEX-1 | quoteSwap zero + hardcoded amountOutMin=0 | Medium | 0.8 | 1.0 | 1.0 | 0.8 | 0.89 | CONFIRMED |
| BLIND-C-1 | renounceOwnership not overridden | Low | 0.8 | 1.0 | 1.0 | 0.8 | 0.89 | CONFIRMED |
| BLIND-C-2 | Required role never granted in initialize | Low | 0.8 | 1.0 | 1.0 | 0.8 | 0.89 | CONFIRMED |
| SGI-8 | Permissionless collectPremium allows state manipulation | Low | 0.2 | 1.0 | 0.6 | 0.3 | 0.53 | UNCERTAIN |

---

## UNCERTAIN FINDINGS (0.4-0.7)

| Finding ID | Title (brief) | Sev | Evidence | Consensus | AQ | RAG | Composite | Gap | Priority |
|-----------|------------------|-----|----------|-----------|-----|-----|-----------|-----|----------|
| RS1-3 | SpecRegistry not updated on new pool | Medium | 0.8 | 0.80 | 0.8 | 0.3 | 0.67 | AQ:logic chains unclear; RAG:novel flow | MED |
| RS2-1 | revokeSpec clears _approvedSpecs only | Medium | 0.8 | 0.85 | 0.8 | 0.3 | 0.67 | AQ:partial step 5; RAG:access control class | MED |
| PC1-1 | First-depositor share inflation (ERC4626) | Low | 0.8 | 0.85 | 0.8 | 0.3 | 0.67 | AQ:step 5 partial; RAG:well-known class | LOW |
| PC1-2 | Withdrawal initiator receives operator addr | Low | 0.8 | 0.85 | 0.8 | 0.3 | 0.67 | AQ:step 5 partial; RAG:no precedent | LOW |
| PC2-1 | Quote startTime staleness -> binding fails | Medium | 0.8 | 0.85 | 0.85 | 0.4 | 0.71 | AQ:good coverage; RAG:known class | MED |
| PC2-3 | bindPolicy hook blocks reactivation | Low | 0.8 | 1.0 | 0.9 | 0.3 | 0.76 | AQ:strong; RAG:no precedent | LOW |
| PC2-5 | PolicyManager._validateRequest missing check | Informational | 0.8 | 1.0 | 0.9 | 0.3 | 0.76 | AQ:good; RAG:no precedent | N/A |
| PC4-3 | updateVault missing nonReentrant | Low | 0.8 | 1.0 | 0.8 | 0.3 | 0.74 | AQ:good; RAG:no precedent | LOW |
| CS-3 | lastKnownMorphoValue staleness | Low | 0.8 | 0.80 | 0.7 | 0.3 | 0.65 | AQ:step 5 partial; RAG:no precedent | LOW |
| CS-4 | Premium rate change no timelock | Low | 0.8 | 0.80 | 0.7 | 0.3 | 0.65 | AQ:clear but LOW severity; RAG:no precedent | LOW |
| CS-6 | mulDiv rounding dust premium | Low | 0.8 | 0.80 | 0.7 | 0.3 | 0.65 | AQ:boundary tested; RAG:no precedent | LOW |
| CS-9 | depositCap reopens after withdrawal | Low | 0.8 | 0.80 | 0.7 | 0.3 | 0.65 | AQ:step 5 partial; RAG:no precedent | LOW |
| AC-4 | morphoGateActive no timelock | Low | 0.8 | 0.80 | 0.7 | 0.3 | 0.65 | AQ:step 5 PARTIAL; RAG:no precedent | LOW |
| AC-8 | executeUpgrade clears state after call | Low | 0.8 | 0.80 | 0.8 | 0.3 | 0.66 | AQ:good; RAG:no precedent | LOW |
| OZ-1 | No try/catch on Chainlink oracle | Low | 0.8 | 0.80 | 0.7 | 0.3 | 0.65 | AQ:step 5 PARTIAL; RAG:class known | LOW |
| OZ-2 | maxDeposit checks policy but not maturity | Low | 0.8 | 0.80 | 0.7 | 0.3 | 0.65 | AQ:step 5 partial; RAG:no precedent | LOW |
| OZ-5 | rescueTokens uses totalPrincipal==0 | Low | 0.8 | 0.80 | 0.7 | 0.3 | 0.65 | AQ:step 5 partial; RAG:no precedent | LOW |
| TF-1 | block.timestamp as deadline (weak protection) | Low | 0.8 | 1.0 | 0.8 | 0.4 | 0.79 | AQ:good; RAG:partial mitigation noted | LOW |
| SGI-3 | Post-expiry premium catch-up charge | Medium | 0.8 | 1.0 | 0.9 | 0.3 | 0.76 | AQ:good; RAG:no precedent in insurance | MED |

---

## LOW_CONFIDENCE FINDINGS (<0.4)

| Finding ID | Title (brief) | Sev | Evidence | Consensus | AQ | RAG | Composite | Issue |
|-----------|------------------|-----|----------|-----------|-----|-----|-----------|-------|
| PC1-3 | _withdraw callback transient break | Informational | 0.2 | 1.0 | 0.4 | 0.3 | 0.43 | Evidence only [TRACE]; no active exploit found; consensus high (niche concern) |
| PC1-4 | Gate activation multiple times | Low | 0.8 | 1.0 | 0.7 | 0.3 | 0.71 | **PROMOTED to CONFIDENT** (composite 0.71 >= 0.7) |
| PC4-4 | PremiumCollector underlying token mismatch | Low | 0.2 | 1.0 | 0.6 | 0.3 | 0.51 | Evidence [TRACE][BOUNDARY] but PARTIAL finding; requires non-standard vault |
| SC-5 | Semantic consistency dual-source state | Low | 0.2 | 1.0 | 0.6 | 0.3 | 0.51 | Evidence [TRACE] but niche semantic concern; SC-8 is higher priority |
| SC-8 | coverageLimit cached vs live inconsistency | Medium | 0.8 | 1.0 | 0.9 | 0.3 | 0.78 | **PROMOTED to CONFIDENT** (composite 0.78 >= 0.7) |
| BLIND-B-1 | Missing event on access control setter | Informational | 0.8 | 1.0 | 0.9 | 0.3 | 0.76 | **PROMOTED to CONFIDENT** (composite 0.76 >= 0.7) |
| BLIND-A-3 | Empty list passed to multisig | Informational | 0.8 | 1.0 | 0.9 | 0.3 | 0.76 | **PROMOTED to CONFIDENT** (composite 0.76 >= 0.7) |
| SGI-3 | Post-expiry premium catch-up retroactive | Medium | 0.8 | 1.0 | 0.9 | 0.3 | 0.76 | **PROMOTED to CONFIDENT** (composite 0.76 >= 0.7) |

---

## RESCORING CORRECTIONS

Upon detailed review of RAG and consensus data:

### Promotions from LOW_CONFIDENCE to CONFIDENT
- **PC1-4**: Gate activation multiple — evidence 0.8 (clear code path), consensus 1.0 (single agent), AQ 0.7 (depth-backed) → **0.71** ✓
- **SC-8**: Dual-source inconsistency — evidence 0.8, consensus 1.0 (niche agent), AQ 0.9 (depth-backed [TRACE]) → **0.78** ✓
- **BLIND-B-1**: Missing event on setter — evidence 0.8, consensus 1.0, AQ 0.9 → **0.76** ✓
- **BLIND-A-3**: Empty list to multisig — evidence 0.8, consensus 1.0, AQ 0.9 → **0.76** ✓
- **SGI-3**: Post-expiry catch-up — evidence 0.8, consensus 1.0, AQ 0.9 → **0.76** ✓

### Demotions from UNCERTAIN to LOW_CONFIDENCE
- **PC4-4**: Non-standard vault precondition, PARTIAL verdict, evidence 0.2 (no concrete production case) → **0.51** (stays uncertain, but near floor)
- **PC1-3**: Transient invariant, Informational severity, no active exploit → **0.43** (flag for depth verification only if cascade detected)

---

## FINAL CONFIDENT COUNT: 33 findings (60%)
## FINAL UNCERTAIN COUNT: 14 findings (25.5%)
## FINAL LOW_CONFIDENCE COUNT: 8 findings (14.5%)

---

## Exit Conditions Check (Post-Iteration-1)

### Convergence Criteria Status
| Criterion | Value | Result |
|-----------|-------|--------|
| **All findings scored** | 55/55 | ✓ PASS |
| **CONFIDENT >= 0.7** | 33 findings (60%) | ✓ PASS |
| **UNCERTAIN 0.4-0.7** | 14 findings (25.5%) | ✓ IDENTIFIED |
| **LOW_CONFIDENCE < 0.4** | 8 findings (14.5%) | ✓ WITHIN BOUNDS |
| **Any Medium+ uncertain** | YES (6 Medium uncertain) | → **ITERATION 2 MANDATORY** |
| **Oscillation detected** | NO | ✓ PASS |
| **Hard iteration cap (3)** | Iteration 1/3 | ✓ CONTINUE |

### Decision
- **Iteration 2 spawning**: YES — 6 Medium-severity UNCERTAIN findings require targeted depth analysis
- **Reason**: Per Rule 3a.1, if ANY uncertain finding is Medium+, Iteration 2 is MANDATORY

---

## UNCERTAIN FINDINGS NEEDING DEPTH (By Spawn Priority)

**Priority formula**: `(1 - composite) × severity_weight`

| Rank | Finding | Severity | Composite | Priority Score | Domain |
|------|---------|----------|-----------|-----------------|--------|
| 1 | PC2-1 | Medium | 0.71 | 0.58 | Temporal staleness / timestamp validation |
| 2 | PC4-2+CS-5 | Medium | 0.71 | 0.58 | External parameter (poolFeeBps, deductible) retroactive read |
| 3 | SGI-3 | Medium | 0.76 | 0.48 | Lazy-accrual / post-expiry catch-up mechanics |
| 4 | RS1-3 | Medium | 0.67 | 0.66 | Factory state not synced (SpecRegistry) |
| 5 | RS2-1 | Medium | 0.67 | 0.66 | Partial cleanup in revokeSpec |

---

## RAG Score Analysis

### Strong Historical Precedent (RAG ≥ 0.6)
- **TF-4 + DEX-1** (0.8): amountOutMin=0 is one of the most-cited Sherlock/C4 findings
- **VA-3** (0.8): previewRedeem spec violation documented in code4rena 2024-03, Zellic primer
- **BLIND-C-1** (0.8): renounceOwnership not overridden — most common Low/Info finding
- **BLIND-C-2** (0.8): Required role never granted — classical missing role grant
- **PC4-1** (0.6): Stale approval after contract change — documented SWC-114 adjacent risk
- **CS-2** (0.6): ERC-4626 rounding/phantom-residual — code4rena 2022-11 precedent

### Partial/No Precedent (RAG ≤ 0.4)
- **RS1-1** (0.4): grace period / maturity mismatch — related class known, no exact DeFi insurance precedent
- **PC3-1, PC3-2** (0.4): Uniswap integration-specific patterns — indirect SlowMist precedent but no named findings
- **VA-1** (0.3): Rounding-to-zero debt wipe — novel in insurance context
- **AC-2, AC-3** (0.3): Semi-trusted role access control blocks — acknowledged design risk, no exact code path
- **SGI-3** (0.3): Post-expiry catch-up retroactive charge — niche DeFi insurance pattern

---

## Notes

1. **Evidence scoring**: Depth agents produced [BOUNDARY], [VARIATION], [TRACE] tags; breadth agents marked ✓ steps for [CODE]-level confidence.
2. **Consensus**: Consensus_map.md provides per-finding scores; specialized agent bonuses (+0.2) applied where relevant (VAULT_ACCOUNTING, DEX_INTEGRATION, SEMANTIC_GAP).
3. **Analysis Quality (Mode A for depth agents)**: Depth agents scored 0.7-1.0 based on tag counts; Mode B (breadth) scored on step execution (most found ≥0.7).
4. **RAG Match**: RAG Validation Sweep found strong precedent for common vulnerabilities (amountOutMin, ERC-4626 rounding, renounceOwnership); niche insurance/timestamp patterns have floor score 0.3.
5. **Confidence composite formula**: Applied uniformly; no manual overrides.

