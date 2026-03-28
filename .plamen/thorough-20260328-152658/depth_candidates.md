# Depth Candidates

## Domain Assignments

### Token Flow Domain
| Finding ID | Severity | Verdict | Priority |
|-----------|----------|---------|----------|
| TF-4 | Medium | CONFIRMED (CONTESTED adversarial) | HIGH — amountOutMin=1 fallback when QuoterV2 fails; near-total sandwich risk; depth to confirm QuoterV2 failure conditions and actual MEV extractability |
| TF-7 | Medium | PARTIAL | HIGH — all withdrawals blocked when PolicyManager down including emergency path via _accruePremium; depth to confirm morphoGateActive bypass |
| CS-2 | Medium | CONFIRMED | MEDIUM — phantom totalPremiumLiability after deep-loss; depth to trace exact delta accumulation and impact on last-user withdrawal |
| TF-1 | Low | CONFIRMED | LOW — block.timestamp deadline; depth to assess MEV extraction given amountOutMin constraint |
| TF-3 | Low | CONFIRMED | LOW — unsolicited Morpho share donation; no extraction vector but premium cap affected |
| TF-5 | Low | PARTIAL | LOW — fee-on-transfer collateral; depth to confirm whether protocol restricts collateral types in deployment |

### State Trace Domain
| Finding ID | Severity | Verdict | Priority |
|-----------|----------|---------|----------|
| CS-1 | Medium | CONFIRMED | HIGH — unbounded gateGracePeriod; depth to trace exact state transitions across multiple gate cycles and underwriter exposure |
| CS-5 | Medium | CONFIRMED | HIGH — retroactive deductibleBps/maxCoverableLossBps; depth to model worst-case scenario with users trapped in underwater positions |
| AC-2 | Medium | CONFIRMED | HIGH — premiumDefaulted blocks all claims; depth to confirm try/catch returns 0 and insurance is fully negated |
| AC-3 | Medium | CONFIRMED | HIGH — claim approval gate creates first-claimer race condition; depth to model multi-user scenario |
| AC-1 | Medium | CONFIRMED | MEDIUM — CREATOR_ROLE infrastructure replacement; depth to confirm future-pools-only blast radius and upgrade path exploitation |
| CS-4 | Low | CONFIRMED | MEDIUM — retroactive premium rate; bounded by MAX cap and 2h notice |
| AC-8 | Low | CONFIRMED | LOW — stale pending upgrade state after executeUpgrade |
| OZ-5 | Low | CONFIRMED | LOW — rescueTokens proxy check; owner sweeping dust |

### Edge Case Domain
| Finding ID | Severity | Verdict | Priority |
|-----------|----------|---------|----------|
| OZ-3 | Medium | PARTIAL | HIGH — stale Morpho fallback; depth to confirm over-accrual scenario when gate not activated promptly |
| CS-3 | Low | PARTIAL | MEDIUM — stale lastKnownMorphoValue during gate; depth to distinguish from OZ-3 (CS-3 is view-only; OZ-3 affects accrual) |
| OZ-2 | Low | CONFIRMED | LOW — deposits after maturity without insurance; simple design gap |
| CS-6 | Low | PARTIAL | LOW — precision rounding; bounded impact |
| AC-4 | Low | PARTIAL | LOW — morphoGateActive without timelock; within-bounds but stale value risk |
| OZ-1 | Low | PARTIAL | LOW — oracle revert DoS on bindPolicy; admin can replace oracle address |

### External Domain
| Finding ID | Severity | Verdict | Priority |
|-----------|----------|---------|----------|
| TF-7 | Medium | PARTIAL | HIGH — PolicyManager DoS affecting even emergency withdrawals (shared with Token Flow) |
| TF-4 | Medium | CONFIRMED | HIGH — QuoterV2 failure condition (shared with Token Flow) |
| OZ-1 | Low | PARTIAL | LOW — Chainlink oracle DoS on bindPolicy |
| TF-5 | Low | PARTIAL | LOW — fee-on-transfer collateral (shared with Token Flow) |

---

## REFUTED Findings for Second Opinion

| Finding ID | Agent | REFUTED Reason | Second Opinion Priority |
|-----------|-------|----------------|------------------------|
| AC-5 | Access Control (#2) | SWAP_MANAGER_ROLE mitigated by whitelist double-gate | LOW — whitelist is robust; executor can override calldata, but amountOutMin protection remains. Confirmatory depth only. |
| OZ-4 | Oracle/Zero-State (#4) | EfficientHashLib 11-param overload confirmed; address casts zero-extend | NONE — technical proof, no depth needed |
| TF-2 | Token Flow/External (#3) | totalPrincipal==0 with userMorphoShares>0 requires atomic deposit/withdraw break | LOW — OZ-5 covers same location with slightly different attack vector. OZ-5 is CONFIRMED; TF-2 refutation stands. |

---

## Depth Priority Order (Spawn Sequence)

### MANDATORY Depth (Medium severity CONFIRMED/PARTIAL/CONTESTED)
1. **CS-1** [State Trace] — Unbounded gateGracePeriod → underwriter exposure modeling
2. **CS-2** [Token Flow] — totalPremiumLiability phantom delta → last-user impact
3. **CS-5** [State Trace] — Retroactive insurance parameters → trapped user worst-case
4. **AC-2** [State Trace] — premiumDefaulted claim block → insurance nullification
5. **AC-3** [State Trace] — Claim approval race condition → multi-user scenario
6. **TF-4** [Token Flow] — amountOutMin=1 fallback → sandwich extraction proof
7. **TF-7** [External] — PolicyManager DoS → emergency path verification
8. **OZ-3** [Edge Case] — Stale Morpho fallback + no gate → accrual over-payment

### RECOMMENDED Depth (Low severity with depth evidence potential)
9. **AC-1** [State Trace] — CREATOR_ROLE blast radius scoping
10. **OZ-5** [Edge Case] — rescueTokens dust sweep confirmation
11. **CS-4** [State Trace] — Retroactive rate scenario modeling
12. **OZ-2** [Edge Case] — Post-maturity deposit design gap

### OPTIONAL Depth (Informational / positive findings)
- CS-7, CS-8, CS-10, AC-7, AC-9, OZ-6, TF-6, TF-8 — No depth needed

---

---

## Phase 3b/3c New Depth Candidates

### HIGH Priority (High severity CONFIRMED — must verify before reporting)

| Finding ID | Agent | Severity | Verdict | Domain | Priority Notes |
|-----------|-------|----------|---------|--------|---------------|
| RS1-1 | Re-Scan #1 | High | CONFIRMED | State Trace + External | gateGracePeriod/ClaimManager maturityTime mismatch — users pay premium and receive zero insurance. Compound with PC1-4 (unbounded accumulation). Verify whether grace-window claim failures are truly silent and whether ClaimManager can be updated to match. |
| PC3-1 | Per-Contract #3 | High | CONFIRMED | Token Flow | Surplus swap output stranded in ClaimManager — vault stakers over-slashed. Quantify expected stranding per claim scenario. Verify recoverTokens is the only path and whether this is exploitable via intentional slippage inflation. |
| PC3-2 | Per-Contract #3 | High | CONFIRMED | External + Token Flow | UniswapV3Adapter fee-tier mismatch — quote uses pairFees, swap uses stored calldata. DoS or weakened slippage depending on direction. Verify: can an admin atomically update both pairFees and stored calldata? How common is fee-tier migration? |

### MEDIUM Priority (Medium severity CONFIRMED — depth to confirm worst-case)

| Finding ID | Agent | Severity | Verdict | Domain | Priority Notes |
|-----------|-------|----------|---------|--------|---------------|
| RS1-2 | Re-Scan #1 | Medium | CONFIRMED | Edge Case + Access Control | Operator can call emergencyRedeem to waive owner's insurance. Verify: does the operator gain any direct benefit (if receiver == operator address)? What integrations realistically hold allowances (lending protocols, aggregators)? |
| RS2-1 | Re-Scan #2 | Medium | CONFIRMED | State Trace | revokeSpec is a no-op for active policies — admin has false confidence. Depth: what is the worst-case impact if a buggy spec evaluates claims? Can admin pause ClaimManager as partial mitigation? |
| PC2-1 | Per-Contract #2 | Medium | CONFIRMED | External + State Trace | Quote startTime staleness causes binding failures on any non-zero delay. Depth: is there an off-chain retry mechanism? How large must the startTime buffer be in practice? |
| PC4-1 | Per-Contract #4 | Medium | CONFIRMED | Token Flow + Access Control | Stale unlimited approval persists after setRewardsManager. Depth: confirm admin workflow for setRewardsManager; is approveSpender(token, old, 0) standard practice? What is the expected time window for approval to be exploited? |
| PC4-2 | Per-Contract #4 | Medium | CONFIRMED | State Trace | poolFeeBps live read enables retroactive fee spike at distribution time. Depth: confirm no timelock on setPoolFeeBps; quantify maximum extraction per period at maxPoolFeeBps=2000; is this within SEMI_TRUSTED_ROLE bounds for curator? |

### SECOND OPINION Required

| Finding ID | Agent | Severity | Verdict | Reason |
|-----------|-------|----------|---------|--------|
| RS3-2 | Re-Scan #3 | Low | PARTIAL | Requires same-block same-user identical cappedClaim collision; verify whether rounding in _capAndApplyDeductible can realistically produce identical values after sequential principal reduction |
| PC1-4 | Per-Contract #1 | Low | CONFIRMED | Overlaps with CS-1 (existing Medium) but adds unbounded cap dimension + RS1-1 compound; chain agent should assess whether CS-1 + PC1-4 + RS1-1 form a severity-upgrade chain |

---

## Chain Pre-Scan: Low Findings with Postconditions vs Medium+ Preconditions

| Low Finding | Postcondition | Matching Medium+ Finding | Missing Precondition | CHAIN_ESCALATED? |
|------------|--------------|------------------------|---------------------|-----------------|
| CS-9 (Low) | "Deposit capacity reopens after withdrawals; coverage pool exposure increases" (STATE) | CS-1 (Medium) — "effectiveMaturity unbounded via gateGracePeriod" | No direct linkage — separate mechanisms | NO |
| OZ-2 (Low) | "Uninsured deposits after maturity" (STATE, TIMING) | AC-3 (Medium) — "first-claimer race condition" | AC-3 requires active policy; OZ-2 is post-maturity → no chain | NO |
| AC-4 (Low) | "Stale Morpho value cached; premium paused; gateGracePeriod extended on deactivation" (STATE, TIMING) | CS-1 (Medium) — "gateGracePeriod unbounded extension" | AC-4's gateGracePeriod extension IS the postcondition feeding CS-1. CHAIN: AC-4 → CS-1 | **CHAIN_ESCALATED** |
| CS-3 (Low) | "Stale morpho value used for totalAssets() during gate" (STATE) | OZ-3 (Medium) — "stale fallback affects premium accrual + totalAssets()" | CS-3 and OZ-3 share the same root cause; CS-3 is the view-only dimension of OZ-3 | Not escalation — same finding |
| TF-3 (Low) | "Inflated _morphoValue affecting premium accrual cap" (STATE) | TF-4 (Medium) — "amountOutMin=1 enables near-total sandwich" | No causal link — different mechanisms | NO |

**CHAIN_ESCALATED identified: 1**
- **AC-4 → CS-1**: Owner toggling gate accumulates gateGracePeriod (AC-4 postcondition: gateGracePeriod extended), which is the root cause of CS-1 (unbounded gateGracePeriod). Together, these form a continuous chain. However, this is not a new finding — AC-4 is already noted as PARTIAL and CS-1 addresses the unbounded accumulation. Tagging as chain context for depth agents.
