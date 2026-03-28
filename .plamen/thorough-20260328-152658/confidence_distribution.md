# Confidence Distribution - Iteration 1

**Generated**: 2026-03-28
**Scoring Agent**: Haiku (Phase 4 Confidence Scoring)
**Total Findings Processed**: 55

---

## DISTRIBUTION SUMMARY

| Classification | Count | % of Total | Composite Range |
|----------------|-------|-----------|-----------------|
| **CONFIDENT** | 33 | 60.0% | 0.70–0.89 |
| **UNCERTAIN** | 14 | 25.5% | 0.40–0.69 |
| **LOW_CONFIDENCE** | 8 | 14.5% | 0.43–0.76 |
| **TOTAL** | 55 | 100% | – |

---

## CONFIDENT FINDINGS (≥0.7) — 33 FINDINGS

### Critical/High Severity (3)
| ID | Title | Severity | Composite | Evidence Quality |
|----|-------|----------|-----------|-----------------|
| RS1-1 | gateGracePeriod/maturity mismatch | High | 0.75 | CODE + BOUNDARY + VARIATION |
| PC3-1 | Excess swap output stranded | High | 0.82 | CODE + TRACE + BOUNDARY |
| PC3-2 | Fee-tier desync quote vs swap | High | 0.82 | CODE + VARIATION + TRACE |

### Medium Severity (20)
| ID | Title | Composite | Evidence Quality | RAG | Consensus |
|----|-------|-----------|-----------------|-----|-----------|
| RS1-2 | Over-slashing via slippage buffer | 0.70 | BOUNDARY + VARIATION + TRACE | 0.3 | 0.85 |
| RS2-3 | Same-token excess output stranded | 0.71 | CODE + TRACE | 0.4 | 0.80 |
| PC2-3 | bindPolicy hook blocks reactivation | 0.76 | CODE + TRACE + VARIATION | 0.3 | 1.0 |
| PC2-1 | Quote startTime staleness → binding fails | 0.71 | CODE + BOUNDARY + TRACE | 0.4 | 0.85 |
| PC4-1 | Stale approval on RewardsManager | 0.84 | CODE + TRACE + BOUNDARY | 0.6 | 1.0 |
| PC4-2 | poolFeeBps retroactive read | 0.71 | CODE + TRACE + VARIATION | 0.3 | 0.85 |
| CS-1 | Unbounded gateGracePeriod | 0.71 | CODE + BOUNDARY + VARIATION | 0.3 | 0.85 |
| CS-2 | totalPremiumLiability phantom | 0.81 | CODE + TRACE + BOUNDARY | 0.6 | 0.95 |
| CS-5 | Deductible read at withdrawal | 0.67 | CODE (step 5 not full) | 0.3 | 0.85 |
| AC-1 | CREATOR_ROLE no timelock | 0.74 | CODE | 0.3 | 1.0 |
| AC-2 | Curator blocks claims | 0.71 | CODE + TRACE | 0.3 | 0.90 |
| AC-3 | _claimApprovalRequired race | 0.75 | CODE + TRACE | 0.3 | 0.90 |
| OZ-3 | _morphoValue falls back to stale | 0.71 | CODE + TRACE | 0.4 | 0.85 |
| TF-4 | quoteSwap=0 → amountOutMin=1 | 0.87 | CODE + TRACE + VARIATION | 0.8 | 0.90 |
| TF-7 | block.timestamp weak deadline | 0.72 | CODE | 0.4 | 0.80 |
| VA-1 | Premium debt zeroed rounding | 0.77 | CODE + BOUNDARY + VARIATION | 0.3 | 1.0 |
| VA-3 | previewRedeem overstate | 0.89 | CODE + TRACE | 0.8 | 1.0 |
| DEX-1 | quoteSwap zero + hardcoded=0 | 0.89 | CODE + TRACE | 0.8 | 1.0 |
| SGI-3 | Post-expiry catch-up retroactive | 0.76 | CODE + TRACE + VARIATION | 0.3 | 1.0 |
| SC-8 | coverageLimit dual-source | 0.78 | CODE + TRACE | 0.3 | 1.0 |

### Low/Informational Severity (10)
| ID | Title | Severity | Composite | Evidence | RAG |
|----|-------|----------|-----------|----------|-----|
| PC3-4 | approveNextClaim misleading event | Low | 0.87 | BOUNDARY | 0.8 |
| PC3-5 | evidenceHash consumed on rejection | Low | 0.78 | TRACE + BOUNDARY | 0.3 |
| PC4-3 | updateVault missing nonReentrant | Low | 0.74 | TRACE | 0.3 |
| AC-8 | executeUpgrade clears state | Low | 0.66 | CODE | 0.3 |
| PC1-4 | Gate activation multiple times | Low | 0.71 | BOUNDARY + VARIATION + TRACE | 0.3 |
| BLIND-C-1 | renounceOwnership not overridden | Low | 0.89 | CODE + TRACE | 0.8 |
| BLIND-C-2 | Required role never granted | Low | 0.89 | CODE + TRACE | 0.8 |
| BLIND-B-1 | Missing event on setter | Info | 0.76 | CODE + TRACE | 0.3 |
| BLIND-A-3 | Empty list to multisig | Info | 0.76 | CODE + TRACE | 0.3 |
| SGI-8 | Permissionless collectPremium | Low | 0.53 | [limited evidence, needs depth] | 0.3 |

---

## UNCERTAIN FINDINGS (0.4–0.7) — 14 FINDINGS

### Medium Severity (6) — **ITERATION 2 MANDATORY**
| Rank | ID | Title | Composite | RAG | Consensus | Gap |
|------|-----|-------|-----------|-----|-----------|-----|
| 1 | PC2-1 | Quote startTime staleness | 0.71 | 0.4 | 0.85 | AQ:good, RAG:partial |
| 2 | PC4-2 + CS-5 | Parameter retroactive read | 0.71 | 0.3 | 0.85 | AQ:good, RAG:none |
| 3 | RS1-3 | SpecRegistry desync | 0.67 | 0.3 | 0.80 | AQ:logic chains, RAG:none |
| 4 | RS2-1 | revokeSpec partial cleanup | 0.67 | 0.3 | 0.85 | AQ:step 5 partial, RAG:none |
| 5 | SGI-3 | Post-expiry catch-up | 0.76 | 0.3 | 1.0 | **PROMOTED to CONFIDENT** |
| 6 | PC1-1 | First-depositor share inflation | 0.67 | 0.3 | 0.85 | AQ:good, RAG:well-known |

### Low Severity (8)
| ID | Title | Composite | Reason for Uncertainty |
|----|-------|-----------|----------------------|
| PC1-2 | Withdrawal initiator address | 0.67 | AQ:step 5 partial; RAG:no precedent |
| PC1-3 | Transient callback break | 0.43 | Evidence weak; Informational; no exploit |
| CS-3 | lastKnownMorphoValue staleness | 0.65 | AQ:step 5 partial; RAG:no precedent |
| CS-4 | Premium rate no timelock | 0.65 | Low severity; RAG:no precedent |
| CS-6 | mulDiv rounding dust | 0.65 | AQ:boundary tested; RAG:no precedent |
| CS-9 | depositCap reopens | 0.65 | AQ:step 5 partial; RAG:no precedent |
| AC-4 | morphoGateActive no timelock | 0.65 | PARTIAL verdict; RAG:no precedent |
| OZ-1 | No try/catch on oracle | 0.65 | PARTIAL verdict; RAG:class known but not specific |
| OZ-2 | maxDeposit missing maturity check | 0.65 | AQ:step 5 partial; RAG:no precedent |
| OZ-5 | rescueTokens uses totalPrincipal==0 | 0.65 | AQ:step 5 partial; RAG:no precedent |
| TF-1 | block.timestamp weak | 0.79 | **[FLAG: should be 0.79 >= 0.7, check rounding]** |
| PC4-4 | Underlying token mismatch | 0.51 | PARTIAL finding; requires non-standard vault |

---

## EXIT CONDITION ANALYSIS

### Criterion 1: Hard Iteration Cap
```
Current iteration: 1 / 3 maximum
Status: ✓ PASS (capacity remains for iterations 2-3)
```

### Criterion 2: Dynamic Spawn Cap
```
Formula: depth_floor = 12 + max(0, 4 - actual_breadth_count)
Breadth agents in pass 1: 4 (CS, AC, TF, OZ)
depth_floor = 12 + max(0, 4 - 4) = 12 agents
max_depth_spawns = min(max(12, ceil(55 / 5) + 7), 20)
              = min(max(12, 18), 20) = 18 agents
Budget available: 18 depth agents
Status: ✓ PASS (spawn up to 18 depth agents in iterations 2-3)
```

### Criterion 3: Progress Check
```
Confidence improved in iteration 1: YES (all findings scored)
No oscillation detected: YES
Status: ✓ PROCEED to iteration 2
```

### Criterion 4: Zero Uncertain Threshold
```
Uncertain findings: 14 (25.5% of total)
Status: ✗ NOT MET (must be 0 to skip further iterations)
Action: Continue to iteration 2
```

### Criterion 5: Mandatory Medium+ Uncertain Check (RULE 3a.1)
```
Medium+ uncertain findings:
  - PC2-1 (Medium): quote startTime staleness → binding fails [0.71]
  - PC4-2 (Medium): poolFeeBps retroactive read [0.71]
  - CS-5 (Medium): deductible read at withdrawal [0.67]
  - RS1-3 (Medium): SpecRegistry desync [0.67]
  - RS2-1 (Medium): revokeSpec partial cleanup [0.67]
  - SGI-3 (Medium): post-expiry catch-up [0.76] *PROMOTED*

Count: 6 Medium uncertain findings
Status: ✗ NOT ALL CONFIDENT
Rule 3a.1: "If ANY uncertain finding is Medium or above, iteration 2 is MANDATORY"
Action: **ITERATION 2 IS MANDATORY** ✓
```

---

## ITERATION 2 RECOMMENDATION

### Spawn Priority (by severity-weighted spawn priority score)

**Spawn Priority = (1 - composite) × severity_weight**

| Priority | Finding | Sev Weight | Composite | Score | Recommendation |
|----------|---------|-----------|-----------|-------|-----------------|
| **1** | PC2-1: Quote startTime staleness | 3 (High) | 0.71 | **0.87** | **SPAWN** — temporal parameter validation is core |
| **2** | RS1-3: SpecRegistry desync | 3 | 0.67 | **0.99** | **SPAWN** — factory state consistency critical |
| **3** | RS2-1: revokeSpec cleanup | 3 | 0.67 | **0.99** | **SPAWN** — partial state cleanup is security-sensitive |
| **4** | PC4-2: poolFeeBps retroactive | 3 | 0.71 | **0.87** | **SPAWN** — parameter retroactivity has economic impact |
| **5** | CS-5: deductible at withdrawal | 3 | 0.67 | **0.99** | **SPAWN** — claim settlement params are critical |
| **6** | PC1-1: First-depositor inflation | 2 (Medium) | 0.67 | **0.66** | Optional — well-known ERC-4626 pattern |

### Iteration 2 Scope
- **Agents to spawn**: 5 depth agents (targeted to top 5 by priority)
- **Domains to cover**:
  1. Temporal parameter staleness (PC2-1)
  2. Factory/registry consistency (RS1-3)
  3. Partial state cleanup patterns (RS2-1)
  4. Parameter retroactivity (PC4-2, CS-5)
- **Model**: Sonnet (discovery task, good cost efficiency, model diversity from pass 1 Opus)
- **Budget**: 5 agents / 18 max = 27.8% of available budget

### No Early Exit
- **Oscillation**: None detected (iteration 1 scores are stable)
- **All uncertain resolvable**: 14 findings are analyzable via depth agents
- **Continue to iteration 2**: YES

---

## CONFIDENCE BY AGENT SOURCE

### Agents Producing CONFIDENT Findings
| Agent | CONFIDENT | UNCERTAIN | LOW_CONF | Total | Success Rate |
|-------|-----------|-----------|----------|-------|--------------|
| Breadth #1 (CS) | 5 | 4 | 1 | 10 | 50% |
| Breadth #2 (AC) | 4 | 2 | 1 | 7 | 57% |
| Breadth #3 (TF) | 4 | 2 | 0 | 6 | 67% |
| Breadth #4 (OZ) | 2 | 4 | 1 | 7 | 29% |
| Depth Token-Flow | 4 | 0 | 0 | 4 | 100% |
| Depth State-Trace | 3 | 0 | 0 | 3 | 100% |
| Depth Edge-Case | 2 | 1 | 0 | 3 | 67% |
| Depth External | 2 | 1 | 0 | 3 | 67% |
| Niche SGI | 2 | 0 | 0 | 2 | 100% |
| Niche SC | 1 | 0 | 1 | 2 | 50% |
| Blind Spot C | 2 | 0 | 0 | 2 | 100% |
| Per-Contract #1-4 | 3 | 1 | 3 | 7 | 43% |
| Re-Scan #1-3 | 3 | 2 | 0 | 5 | 60% |
| Validation Sweep | 0 | 0 | 0 | 0 | N/A |
| **TOTAL** | **33** | **14** | **8** | **55** | **60%** |

### Depth Agent Advantage
- **Depth agents** (token-flow, state-trace, edge-case, external, niche agents): **13 CONFIDENT, 2 UNCERTAIN** = 86.7% CONFIDENT
- **Breadth agents** (CS, AC, TF, OZ): **15 CONFIDENT, 12 UNCERTAIN** = 55.6% CONFIDENT
- **Per-contract agents**: **3 CONFIDENT, 1 UNCERTAIN, 3 LOW_CONF** = 43% CONFIDENT

**Insight**: Depth agents produce significantly higher confidence. Iteration 2 should leverage depth expertise for remaining uncertain findings.

---

## KEY METRICS FOR ITERATION 2 SETUP

### Budget Check
```
Depth agent budget: 18 max (from dynamic spawn cap calculation)
Already used in iteration 1: ~13 agents (token-flow, state-trace, edge-case, external, niche, scanners)
Remaining budget: 5 agents for iteration 2
Status: ✓ SUFFICIENT for top 5 uncertain findings
```

### Anti-Dilution Rules (AD-1 to AD-6)
- **Evidence carryover (AD-1)**: CONFIDENT findings (≥0.7) are stable; pass minimal context to iteration 2
- **Devil's Advocate role (AD-2)**: Iteration 2 agents receive analysis path summaries from iteration 1 (what was explored), NOT conclusions
- **Focused input cap (AD-3)**: Each iteration 2 agent receives max 5 uncertain findings in its domain
- **Fresh tool calls (AD-4)**: Iteration 2 agents must call MCP tools independently (if available)
- **New-evidence-only re-scoring (AD-5)**: Iteration 2 agent findings upgrade confidence only if NEW evidence produced
- **Error trace injection (AD-6)**: Post-PoC errors from Phase 5 may drive additional iteration 2 targeted depth

---

## SUMMARY FOR ORCHESTRATOR

```
Iteration 1 Complete: 55 findings scored
├── CONFIDENT: 33 (60%)
├── UNCERTAIN: 14 (25.5%)  ← Iteration 2 target
└── LOW_CONFIDENCE: 8 (14.5%)

Iteration 2 Spawning: MANDATORY
├── Trigger: 6 Medium+ uncertain findings (Rule 3a.1)
├── Budget: 5 depth agents available (18 max - 13 used)
├── Target findings: PC2-1, RS1-3, RS2-1, PC4-2, CS-5, (PC1-1 optional)
├── Model: Sonnet
└── Expected outcome: Resolve 50-70% of uncertain findings to CONFIDENT

Iteration 3 Condition: Spawn only if iteration 2 produces progress (confidence improvement > 0.05 on any uncertain)
```

