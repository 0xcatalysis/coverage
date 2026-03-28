# Verification Batch E

## Test File
`test/plamen/verify_batch_E.t.sol`

## Test Execution
All 12 tests PASS (0 failures).

```
Ran 12 tests for test/plamen/verify_batch_E.t.sol:VerifyBatchE
[PASS] testFuzz_H15_previewRedeem_overstates(uint256,uint256) (runs: 250)
[PASS] test_H14_maxWithdraw_underestimates()
[PASS] test_H15_previewRedeem_erc4626_compliant()
[PASS] test_H15_previewWithdraw_overstates()
[PASS] test_H16_creatorRole_instant_infra_change()
[PASS] test_H19_startTime_stale_on_bind()
[PASS] test_H20_stale_morphoValue_fallback()
[PASS] test_H22_operator_cannot_call_without_allowance()
[PASS] test_H22_owner_waives_insurance_via_emergency()
[PASS] test_H25_coverPool_retains_old_addresses_after_factory_rotation()
[PASS] test_H30_premiumDebt_rounding_zero()
[PASS] test_H39_post_expiry_accrual_capped_at_maturity()
Suite result: ok. 12 passed; 0 failed; 0 skipped
```

---

## H-14: maxWithdraw/maxRedeem Double-Deducts Premium

**Verdict**: CONFIRMED
**Severity**: Medium
**Evidence Tag**: [POC-PASS]

### Bug Mechanism
`maxWithdraw` computes `grossAssets = _convertToAssets(shares)` using `totalAssets()` as the basis. `totalAssets()` already deducts `totalPremiumLiability + _accruedPremiumFor(mv)`. Then `maxWithdraw` ALSO subtracts `owedPremium` (which represents the user's share of that same liability). This is a double-deduction: the premium is subtracted twice, causing `maxWithdraw` to return a value smaller than what the user can actually withdraw.

### Key Evidence
| Metric | Value |
|--------|-------|
| maxWithdraw reported | 9,999,917,808,250,240,000,000 |
| previewRedeem(maxRedeem) | 9,999,958,904,125,120,000,000 |
| Difference | ~41,095,875,000 wei |
| Assertion | `assertLt(maxWithdraw, previewRedeem(maxRedeem))` PASSES |

The user can actually redeem more assets than `maxWithdraw` reports, confirming double-deduction.

### ERC-4626 Impact
`maxWithdraw` must return the "maximum assets that can be withdrawn" — understating it means integrators allocate less capital than available, and `withdraw(maxWithdraw)` succeeds while leaving shares behind.

---

## H-15: previewRedeem/previewWithdraw Overstates Proceeds

**Verdict**: FALSE_POSITIVE
**Severity**: Downgraded from Medium
**Evidence Tag**: [POC-FAIL]

### Why It Is Not a Bug
`previewRedeem(shares)` returns `_convertToAssets(shares)` which uses `totalAssets()` as the basis. `totalAssets() = morphoValue - totalPremiumLiability - _accruedPremiumFor(mv)`. The actual redeem path also deducts the user's `owedPremium`, which equals the user's proportional share of `totalPremiumLiability + accrued`. For a single user (100% of the vault), these are identical — `preview == actual`.

### Evidence
```
previewRedeem:  9,999,753,424,750,720,000,000
Actual out:     9,999,753,424,750,720,000,000
Difference:     0
```

### Fuzz Confirmation
`testFuzz_H15_previewRedeem_overstates` ran 250 iterations with random deposit amounts (1,000-50,000 ether) and time warps (30-180 days). The assertion `assertLe(preview, actualOut)` passed in all 250 runs — confirming ERC-4626 compliance holds in the tested scenarios.

### Evidence Audit
| Claim | Evidence Source | Tag | Valid for REFUTED? |
|-------|----------------|-----|-------------------|
| preview == actual | Protocol.sol (live execution) | [CODE] | YES |
| fuzz: preview <= actual (250 runs) | Foundry fuzz | [POC-PASS] | YES |

---

## H-16: CREATOR_ROLE Can Replace Infrastructure Addresses Without Timelock

**Verdict**: CONFIRMED
**Severity**: Medium
**Evidence Tag**: [POC-PASS]

### Bug Mechanism
`CoverPoolFactory.setStakeManager()`, `setSpecRegistry()`, and `setCoverPoolImplementation()` all check only `onlyRole(CREATOR_ROLE)` with no timelock. A single transaction from CREATOR_ROLE immediately rotates core infrastructure used by all future pool deployments and policy bindings.

### Key Evidence
```
StakeManager before: 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
StakeManager after:  0xD16d567549A2a2a2005aEACf7fB193851603dd70
-- Change was instant (same block, no delay)
assertEq(stakeManagerAfter, address(newStakeManager)) PASSES
assertEq(specRegistryAfter, address(newSpecRegistry)) PASSES
```

### Impact
Instant rotation of specRegistry, stakeManager, or coverPoolImplementation allows CREATOR_ROLE to immediately redirect all new pool creation to malicious/incompatible infrastructure without delay for users to respond. Combined with H-25 (orphaned CoverPools), this creates a two-step migration trap.

---

## H-19: Quote startTime Goes Stale Between Draft Creation and Policy Binding

**Verdict**: CONFIRMED
**Severity**: Medium
**Evidence Tag**: [POC-PASS]

### Bug Mechanism
`CoverPool.validateQuote` requires `quote.startTime >= block.timestamp`. If a quote is created with `startTime = block.timestamp` and then binding is delayed by even 1 second (e.g., front-run, busy block, MEV), the bind reverts with `InvalidStartTime`.

### Key Evidence
```
startTime:           1  (block.timestamp at quote creation)
block.timestamp:     1
After 1 second warp: 2
bindPolicyForRequest() -> vm.expectRevert() -> PASSES
H-19 CONFIRMED: bindPolicy reverts when startTime < block.timestamp
```

### Impact
Users who create quotes with `startTime = now` must rebind if there is any delay, causing failed transactions and poor UX. In adversarial conditions (frontrunning), binding can be consistently DoS'd.

---

## H-20: Stale lastKnownMorphoValue Inflates Premium Cap During Downtime

**Verdict**: CONFIRMED (Code-level)
**Severity**: Medium (PROVEN_ONLY cap: downgraded to Low)
**Evidence Tag**: [CODE-TRACE]

### Bug Mechanism (Code Evidence)
`_morphoValue()` in `CoveredVaultAccrual.sol:139-147`:
```solidity
function _morphoValue() internal view returns (uint256) {
    try IVaultV2(morphoVault).convertToAssets(...) returns (uint256 val) {
        return val;
    } catch {
        return lastKnownMorphoValue; // <-- STALE VALUE ON REVERT
    }
}
```

When Morpho is offline (`convertToAssets` reverts), `_liabilityHeadroom(morphoVal)` uses the stale high value, inflating the cap for new premium accrual. This can allow premium to accrue even when the vault has suffered a loss.

### Executed Evidence
```
Live morpho assets (after 50% loss): ~5,000 ether
lastKnownMorphoValue (cached pre-loss): ~10,000 ether
assertLt(liveMorphoAssets, cachedValue) PASSES
```

We verified the divergence is real — `lastKnownMorphoValue` can be significantly higher than live value after a loss event. The actual exploit requires Morpho to revert (not simulatable with MockVaultV2 without modification), hence [CODE-TRACE] tag. PROVEN_ONLY mode caps this at Low severity.

---

## H-22: Operator Can Waive Owner's Insurance via Emergency Exit

**Verdict**: CONFIRMED (Owner self-waive only) / FALSE_POSITIVE for unauthorized operator
**Severity**: Medium
**Evidence Tag**: [POC-PASS]

### Bug Mechanism
`emergencyRedeem` sets `SKIP_INSURANCE_SLOT = 1`, which causes `_computeInsurance` to return 0 (bypass insurance). The OWNER can call `emergencyRedeem` on their own position, explicitly waiving insurance coverage during a loss event.

A third-party "operator" without allowance CANNOT call `emergencyRedeem` (ERC-4626 allowance check blocks them).

### Key Evidence
```
=== H-22: Emergency exit bypasses insurance ===
Emergency redeem out: 8,499,958,904,125,120,000,000  (~8,500 ether)
depositAmount:        10,000 ether
15% Morpho loss: 8,500 ether received without insurance payout
assertLt(actualReceived, depositAmount) PASSES

test_H22_operator_cannot_call_without_allowance:
vm.expectRevert() -> PASSES (operator blocked by allowance check)
```

### Impact
Any user (as the owner of their own shares) can call `emergencyRedeem` and bypass insurance. This is by design but represents a usability risk: under time pressure, users may accidentally waive insurance on loss events. The hypothesis overstated the risk (operator cannot act without allowance), but owner self-waive is confirmed.

---

## H-25: Old CoverPools Permanently Orphaned After Infrastructure Rotation

**Verdict**: CONFIRMED
**Severity**: Medium
**Evidence Tag**: [POC-PASS]

### Bug Mechanism
`CoverPool.initialize()` sets `stakeManager` and `specRegistry` directly from constructor arguments at deployment time. After `CoverPoolFactory.setStakeManager()` or `setSpecRegistry()`, the factory's state changes but all existing `CoverPool` instances still reference the old addresses. There is no migration path for existing pools.

### Key Evidence
```
Pool stakeManager:   0xF62849F9A0B5Bf2913b396098F7c7019b51A820a (old)
Factory stakeManager after rotation: 0xD16d567549A2a2a2005aEACf7fB193851603dd70 (new)

assertEq(coverPool.stakeManager(), poolStakeManager) PASSES (pool unchanged)
assertNotEq(factory.stakeManager(), coverPool.stakeManager()) PASSES (diverged)
```

### Impact
After CREATOR_ROLE rotates infrastructure, existing CoverPools operate with stale `stakeManager` and `specRegistry`. Stake validation, committee management, and spec lookups all use the old addresses, creating a permanent split in the system.

---

## H-30: userPremiumDebt Zeroed by Floor Rounding After Partial Withdrawal

**Verdict**: PARTIAL (rounding present, magnitude small)
**Severity**: Medium (PROVEN_ONLY cap: downgraded to Low — no direct exploit demonstrated)
**Evidence Tag**: [CODE-TRACE]

### Analysis
`_updateDebtsAfterWithdrawal` computes:
```solidity
uint256 newRawDebt = newPrincipal.mulDiv(cumulativePremiumPerUnit, WAD, Math.Rounding.Floor);
userPremiumDebt[owner_] = _safeSub(newRawDebt, totalOwedPremium_ - uncappedPremium_);
```

The test showed that after a 1-share partial redemption:
- `debtAfter` > 0 (not zeroed for realistic parameters)
- `expectedMinDebt = 12,341,091,226,464,000` wei
- The rounding is present but does not zero the debt at typical scales (1,000+ ether deposits)

The zero-debt scenario requires very small principal values where `newRawDebt < (totalOwedPremium_ - uncappedPremium_)`. This is a precision edge case that requires tiny dust-level positions. No active exploit was demonstrated.

### Evidence Audit
| Claim | Evidence Source | Tag | Valid for REFUTED? |
|-------|----------------|-----|-------------------|
| Rounding formula present | CoveredVaultWrapper.sol:597 | [CODE] | YES |
| Debt not zeroed at 1000 ether | Live test execution | [POC-PASS] | YES |

PROVEN_ONLY mode caps at Low — no mechanical proof of zeroing under real conditions.

---

## H-39: Post-Expiry Premium Catch-Up Charges Full Lifetime Premium

**Verdict**: FALSE_POSITIVE
**Severity**: Downgraded from Medium
**Evidence Tag**: [POC-FAIL] (defense verified)

### Why It Is Not a Bug
`_activeElapsedFrom()` explicitly caps the catch-up window at `effectiveMaturity`:
```solidity
if (meta.buyer != address(0) && effectiveMaturity > checkpoint && block.timestamp >= startTime) {
    uint256 activeStart = checkpoint > meta.startTime ? checkpoint : meta.startTime;
    if (effectiveMaturity > activeStart) {
        return effectiveMaturity - activeStart; // CAPPED AT MATURITY, NOT block.timestamp
    }
}
```

### Key Evidence
```
=== H-39: Post-expiry premium catch-up ===
Policy maturity:    2505601 (30 days from start)
Checkpoint:         2505601 - 86400 (1 day before maturity)
Liability at check: 39,726,012,384,000,000 wei

[60 days after maturity]
Liability post-catch: 41,095,874,880,000,000 wei
Accrual delta:         1,369,862,496,000,000 wei

Expected (1 day):      1,369,862,496,000,000 wei
61-day (bug value):   83,561,612,256,000,000 wei

assertLt(delta, 61_day_premium / 2) PASSES (delta << bug value)
assertLt(delta, 1_day_premium * 5) PASSES (delta ~= 1 day, correct)
```

The catch-up accrual of 1,369,862,496,000 wei equals exactly 1 day of premium (maturity - lastCheckpoint), not 61 days. The hypothesis was incorrect about the accrual window.

---

## Summary

| H-ID | Title | Verdict | Severity | Evidence |
|------|-------|---------|----------|----------|
| H-14 | maxWithdraw Double-Deducts Premium | CONFIRMED | Medium | [POC-PASS] |
| H-15 | previewRedeem Overstates Proceeds | FALSE_POSITIVE | - | [POC-FAIL] |
| H-16 | CREATOR_ROLE Instant Infra Change | CONFIRMED | Medium | [POC-PASS] |
| H-19 | Quote startTime Staleness | CONFIRMED | Medium | [POC-PASS] |
| H-20 | Stale lastKnownMorphoValue | CONFIRMED (code) | Low (PROVEN_ONLY) | [CODE-TRACE] |
| H-22 | Emergency Exit Waives Insurance | CONFIRMED (owner) | Medium | [POC-PASS] |
| H-25 | Old CoverPools Orphaned | CONFIRMED | Medium | [POC-PASS] |
| H-30 | premiumDebt Zeroed by Rounding | PARTIAL | Low (PROVEN_ONLY) | [CODE-TRACE] |
| H-39 | Post-Expiry Premium Catch-Up | FALSE_POSITIVE | - | [POC-FAIL] |

**Result**: 5 CONFIRMED, 2 FALSE_POSITIVE, 2 PARTIAL/CONFIRMED-code
