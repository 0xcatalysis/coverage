# Semantic Invariant Pass 2 Flags (for Depth Agent Routing)

sync_gaps = 5
accumulation_exposures = 4
conditional_writes = 9
cluster_gaps = 3

## Priority Gaps for Depth Loop (sorted by severity)

### HIGH Priority (confirmed findings in inventory requiring depth)

1. **RS1-1 / gateGracePeriod insurance coverage gap** — HIGH
   - CoveredVaultAccrual.sol:116-136, ClaimManager.sol:306-309
   - gateGracePeriod extends vault's `_isPolicyActive()` effective maturity window past raw maturityTime. ClaimManager enforces raw maturityTime and rejects claims filed after it. Users pay premium through the grace window but receive zero coverage. Level 3 trace: terminal impact = permanent loss of insurance payout for all users during grace window.

2. **CS-2 / totalPremiumLiability deep-loss phantom liability** — MEDIUM
   - CoveredVaultWrapper.sol:574-583
   - After deep-loss withdrawal, `totalPremiumLiability` is not decremented by the forgiven premium delta. Inflated liability → depressed `totalAssets()` → all remaining depositors see lower NAV. Level 3 trace: PERMANENT state corruption until the protocol is fully wound down. Depth should verify whether a deliberate deep-loss withdrawal sequence can systematically harm other depositors.

3. **CS-5 / deductibleBps and maxCoverableLossBps retroactive** — MEDIUM
   - CoveredVaultAdmin.sol:57-89
   - Parameters read at withdrawal time, not at loss-event time. Admin can reduce payout retroactively after a loss event. Depth should verify whether the 2-day STANDARD_DELAY provides sufficient protection.

4. **AC-3 / _claimApprovalRequired permanent block** — MEDIUM
   - ClaimManager.sol:179-235
   - After each successful payout, _claimApprovalRequired is set true. All subsequent withdrawers with losses receive $0 insurance silently until curator calls approveNextClaim(). Level 3 trace: all users during the approval-pending window lose their insurance without notification.

5. **PC3-1 / excess swap output stranded in ClaimManager** — HIGH
   - ClaimManager.sol:663-669
   - Surplus swap output locked in ClaimManager; vault stakers over-slashed. Level 3: permanent fund loss for vault stakers.

6. **PC3-2 / UniswapV3Adapter fee-tier mismatch** — HIGH
   - UniswapV3Adapter.sol:127-135, 155-188
   - pairFees (quote) vs stored calldata fee (swap) desync after fee migration. Scenario A: claim DoS. Scenario B: weakened slippage protection. Level 3: users lose insurance payouts or receive reduced amounts.

### MEDIUM Priority (conditional / partial findings needing depth)

7. **OZ-3 / _morphoValue stale fallback** — MEDIUM
   - CoveredVaultAccrual.sol:139-147
   - Fallback to stale `lastKnownMorphoValue` when convertToAssets reverts. Depth: trace full premium over-accrual impact when gate is lifted but Morpho still returning stale data.

8. **TF-7 / _isPolicyActive external call blocks withdrawals** — MEDIUM
   - CoveredVaultAccrual.sol:153-159
   - External call to PolicyManager propagates through `_accruePremium()` and blocks ALL withdrawals. Depth: verify whether emergency paths (emergencyRedeem/emergencyWithdraw) also hit this call.

9. **CS-3 / lastKnownMorphoValue stale after gate deactivation** — LOW
   - CoveredVaultAccrual.sol:39-47, CoveredVaultAdmin.sol:170-177
   - Pass 2 confirmed: `_accruePremium()` called during gate deactivation returns early (morphoGateActive still true at time of call), so lastKnownMorphoValue is NOT refreshed. Stale window exists until next deposit/withdrawal.

### LOW Priority (informational / edge cases)

10. **C2c (NEW conditional) / totalPremiumLiability phantom when redeemShares == 0** — Very Low
    - CoveredVaultWrapper.sol:557-583
    - Edge case: `userMorphoShares[user] == 0 && userPrincipal[user] > 0` leads to `premiumForWithdrawal = 0` but `uncappedPremium > 0`, leaving phantom in `totalPremiumLiability`. Requires abnormal precondition state. Not a new finding to add to inventory — variant of CS-2 edge case only exploitable if state corruption occurred previously.

11. **PC1-3 / totalPrincipal stale during evaluate() callback** — INFORMATIONAL
    - CoveredVaultWrapper.sol:186-195
    - Pass 2 Level 3 trace: evaluate() does NOT read totalPrincipal. Cannot be weaponized. Confirmed safe under current code.

## Flags Summary

| Flag | Total (Pass 1 + Pass 2) | New in Pass 2 |
|------|------------------------|---------------|
| sync_gaps | 5 | 0 |
| accumulation_exposures | 4 | 0 |
| conditional_writes | 9 | 1 (C2c edge case) |
| cluster_gaps | 3 | 0 |

## Depth Agent Trigger Recommendation

The following niche agent should be triggered:
- **SEMANTIC_GAP_INVESTIGATOR**: YES — sync_gaps=5, accumulation_exposures=4, conditional_writes=9, cluster_gaps=3 all exceed trigger thresholds.

Priority depth domains for SEMANTIC_GAP_INVESTIGATOR:
1. CS-2 deep-loss phantom totalPremiumLiability (SYNC_GAP 2) — permanent state corruption
2. RS1-1 gateGracePeriod / ClaimManager maturityTime mismatch (SYNC_GAP 5 cascade) — HIGH severity confirmed
3. totalPremiumLiability headroom accumulation (ACCUMULATION_EXPOSURE 2) — self-limiting but interaction with deep-loss is novel
