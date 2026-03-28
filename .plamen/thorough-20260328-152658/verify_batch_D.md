# Verification Batch D — Hypotheses H-2, H-6, H-8, H-10, H-11, H-12, H-13

**Test file**: `test/plamen/verify_batch_D.t.sol`
**Execution**: `forge test --match-contract VerifyBatchD`
**Results**: 8/8 tests PASS (7 finding tests + 1 fuzz variant for H-2)
**PROVEN_ONLY**: true — findings with only [CODE-TRACE] evidence capped at Low severity
**Evidence**: [POC-PASS] for H-2, H-6, H-8, H-11, H-12, H-13; [CODE-TRACE] for H-10

---

## Summary Table

| H-ID | Verdict | Evidence Tag | Test | Severity |
|------|---------|-------------|------|----------|
| H-2 | CONFIRMED | [POC-PASS] | `test_H2_unboundedGateGracePeriodAccumulation` + `testFuzz_H2` | Medium |
| H-6 | CONFIRMED | [POC-PASS] | `test_H6_staleApprovalPersistsOnOldRewardsManager` | Medium |
| H-8 | CONFIRMED | [POC-PASS] | `test_H8_retroactiveParamChangesReducePayout` | Medium |
| H-10 | CONFIRMED | [CODE-TRACE] | `test_H10_claimApprovalGateIsGlobalPerPolicy` | Low (PROVEN_ONLY downgrade) |
| H-11 | CONFIRMED | [POC-PASS] | `test_H11_isPolicyActiveBlocksWithdrawalOnPMRevert` | Medium |
| H-12 | CONFIRMED | [POC-PASS] | `test_H12_revokedSpecStillResolvable` | Medium |
| H-13 | CONFIRMED | [POC-PASS] | `test_H13_poolFeeBpsLiveReadEnablesRetroactiveFeeExtraction` | Medium |

---

## H-2: Unbounded gateGracePeriod Accumulation via Repeated Gate Toggles

**Verdict**: CONFIRMED
**Evidence Tag**: [POC-PASS]
**Severity**: Medium

### Bug Mechanism
`CoveredVaultAdmin.setMorphoGateActive` adds `block.timestamp - gateActivatedAt` to `gateGracePeriod` on every deactivation with no cap. Each `true → false` gate cycle accumulates unboundedly.

**Key code** (`CoveredVaultAdmin.sol:178-183`):
```solidity
} else if (!active && morphoGateActive && gateActivatedAt > 0) {
    uint256 gateDuration = block.timestamp - gateActivatedAt;
    gateGracePeriod += gateDuration;  // no cap
    gateActivatedAt = 0;
}
```

### Test Output
```
[PASS] test_H2_unboundedGateGracePeriodAccumulation() (gas: 168492)
Logs:
  gateGracePeriod after 3 x 1-day cycles: 259200

[PASS] testFuzz_H2_gracePeriodLinearlyAccumulates(uint8,uint32) (runs: 250)
```

### Key Evidence
- Before: `gateGracePeriod = 0`
- After 3 × 1-day cycles: `gateGracePeriod = 259200 = 3 * 86400`
- Fuzz confirms linear accumulation across 250 runs with 1-10 cycles and 1-604800 second durations
- `gateGracePeriod` is additive with no cap or reset mechanism

---

## H-6: Stale Unlimited Approval Persists on Old RewardsManager

**Verdict**: CONFIRMED
**Evidence Tag**: [POC-PASS]
**Severity**: Medium

### Bug Mechanism
`PremiumManager.setRewardsManager()` only updates the `rewardsManager` address pointer. It does NOT revoke the ERC-20 approvals previously granted to the old `rewardsManager` via `approveSpender()`. The old `rewardsManager` retains unlimited (`type(uint256).max`) approval to pull tokens from PremiumManager.

**Key code** (`PremiumManager.sol:93-97`):
```solidity
function setRewardsManager(address rewardsManager_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(rewardsManager_ != address(0), ZeroAddress());
    rewardsManager = rewardsManager_;  // no approval revocation
    emit RewardsManagerSet(rewardsManager_);
}
```

### Test Output
```
[PASS] test_H6_staleApprovalPersistsOnOldRewardsManager() (gas: 2258719)
Logs:
  Old RM allowance after setRewardsManager: 115792089237316195423570985008687907853269984665640564039457584007913129639935
```

### Key Evidence
- Before: `allowance(pm, oldRM) = type(uint256).max`
- After `setRewardsManager(newRM)`: `allowance(pm, oldRM) = type(uint256).max` (unchanged)
- `pm.rewardsManager() = address(newRM)` (correctly updated)
- The old RM can still drain all approved tokens despite being replaced

---

## H-8: Retroactive deductibleBps/maxCoverableLossBps Changes Reduce Insurance Payout

**Verdict**: CONFIRMED
**Evidence Tag**: [POC-PASS]
**Severity**: Medium

### Bug Mechanism
`CoveredVaultWrapper._capAndApplyDeductible` reads `maxCoverableLossBps` and `deductibleBps` directly from live storage at withdrawal time. Owner can change these parameters (with 2-day timelock) after a loss event has occurred but before the user withdraws, retroactively reducing the insurance payout the user is entitled to.

**Key code** (`CoveredVaultWrapper.sol:630-635`):
```solidity
function _capAndApplyDeductible(uint256 shortfall, uint256 basis) private view returns (uint256) {
    uint256 maxInsurance = basis.mulDiv(maxCoverableLossBps, BPS_DENOMINATOR, ...);  // live read
    uint256 capped = shortfall > maxInsurance ? maxInsurance : shortfall;
    uint256 deductibleAmt = basis.mulDiv(deductibleBps, BPS_DENOMINATOR, ...);  // live read
    return capped > deductibleAmt ? capped - deductibleAmt : 0;
}
```

### Test Output
```
[PASS] test_H8_retroactiveParamChangesReducePayout() (gas: 530442)
Logs:
  Assets received: 807207550990000000000
  H-8 CONFIRMED: live param read enables retroactive payout reduction (9%->1%)
```

### Key Evidence
- Scenario: 20% Morpho loss. Original params: max=10%, ded=1% → net insurance = 9% of insuredBasis
- Owner changes (after loss): max=4%, ded=3% → net insurance = 1% of insuredBasis
- Both `maxCoverableLossBps = 400` and `deductibleBps = 300` are applied at withdrawal time
- User receives only ~807 ether instead of expected payout under original terms

---

## H-10: Claim Approval Gate Serializes Concurrent Claimants (First-Claimer Race)

**Verdict**: CONFIRMED
**Evidence Tag**: [CODE-TRACE]
**Severity**: Low (PROVEN_ONLY downgrade from Medium — no live execution of full claim flow)

### Bug Mechanism
`ClaimManager._claimApprovalRequired[policyId]` is a `mapping(uint96 policyId => bool)` — a GLOBAL flag per policy, NOT per user. After any successful claim on a policy, `_claimApprovalRequired[policyId] = true` is set (line 235), blocking ALL subsequent claimants for that policy until the curator calls `approveNextClaim(policyId)`. In a multi-depositor vault with a shared policy, the first successful withdrawal claim blocks all concurrent claimants.

**Key code** (`ClaimManager.sol:209`):
```solidity
require(!_claimApprovalRequired[policyId], ClaimApprovalRequired(policyId));
```
**Key code** (`ClaimManager.sol:235`):
```solidity
_claimApprovalRequired[policyId] = true;
```

### Test Output
```
[PASS] test_H10_claimApprovalGateIsGlobalPerPolicy() (gas: 3575943)
Logs:
  H-10 CODE-TRACE: _claimApprovalRequired is mapping(uint96=>bool), not per-user
```

### Key Evidence
- `claimApprovalRequired(1) == false` on fresh deployment (confirmed by test)
- [CODE-TRACE] Storage layout: `mapping(uint96 => bool)` keyed on `policyId`, not `(policyId, user)`
- After one successful claim: all subsequent `fileClaim` calls for same policyId revert until curator approves
- In CoveredVaultWrapper: the policy is shared across all depositors; first claimer blocks all others
- Note: PROVEN_ONLY downgrade applies — no POC-PASS for the full serialization scenario

---

## H-11: _isPolicyActive External Call Blocks All Withdrawals During PolicyManager Downtime

**Verdict**: CONFIRMED
**Evidence Tag**: [POC-PASS]
**Severity**: Medium

### Bug Mechanism
`CoveredVaultAccrual._isPolicyActive()` calls `_policyManager.policyMetadata(policyId)` with no try/catch. If PolicyManager is unavailable (paused, upgraded to broken impl, or network partition), this external call reverts, which propagates through `_activeElapsedFrom` → `_accruePremium` → `_withdraw`, blocking ALL vault withdrawals.

**Key code** (`CoveredVaultAccrual.sol:155-159`):
```solidity
function _isPolicyActive() internal view returns (bool) {
    if (policyId == 0) return false;
    IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);  // NO try/catch
    uint256 effectiveMaturity = uint256(metadata.maturityTime) + gateGracePeriod;
    return metadata.buyer != address(0) && block.timestamp >= metadata.startTime && block.timestamp < effectiveMaturity;
}
```

### Test Output
```
[PASS] test_H11_isPolicyActiveBlocksWithdrawalOnPMRevert() (gas: 7642584)
Logs:
  Replaced _policyManager at slot: 1
  H-11 CONFIRMED: withdrawal reverts on PolicyManager downtime
```

### Key Evidence
- Storage slot scan found `_policyManager` at slot 1 of the UUPS proxy
- After replacing slot 1 with `RevertingPolicyManager` (which reverts on `policyMetadata`):
- `vm.expectRevert()` is satisfied — `localWrapper.redeem(shares, user, user)` reverts
- Method: `vm.warp(+1 second)` ensures `_accruePremium` calls `_activeElapsedFrom` → `_isPolicyActive`

---

## H-12: Revoked Spec Still Callable by ClaimManager for Existing Policies

**Verdict**: CONFIRMED
**Evidence Tag**: [POC-PASS]
**Severity**: Medium

### Bug Mechanism
`SpecRegistry.resolveSpec()` returns a registered spec without checking `_approvedSpecs[address(spec)]`. When admin calls `revokeSpec(spec)`, the spec is removed from `_approvedSpecs` but NOT from `_specs[pool][specId]`. Subsequent `resolveSpec` calls return the revoked spec, allowing ClaimManager to still call `evaluate()` on a spec that was intentionally revoked due to security concerns.

**Key code** (`SpecRegistry.sol:127-130`):
```solidity
function resolveSpec(address pool, bytes32 specId) external view override returns (ISpec) {
    ISpec spec = _specs[pool][specId];
    if (address(spec) == address(0)) revert SpecNotRegistered(pool, specId);
    return spec;  // no check against _approvedSpecs
}
```

### Test Output
```
[PASS] test_H12_revokedSpecStillResolvable() (gas: 1541402)
Logs:
  H-12 CONFIRMED: resolveSpec() ignores revocation - returns revoked spec
```

### Key Evidence
- Before revoke: `resolveSpec(pool, specId) == address(fakeSpec)` [confirmed]
- `isSpecApproved(fakeSpec) == false` after `revokeSpec(fakeSpec)` [confirmed]
- After revoke: `resolveSpec(pool, specId) == address(fakeSpec)` [STILL returns revoked spec]
- `revokeSpec` only sets `_approvedSpecs[spec] = false`, does not clear `_specs` mapping

---

## H-13: poolFeeBps Read Live at Distribution Enables Retroactive Fee Extraction

**Verdict**: CONFIRMED
**Evidence Tag**: [POC-PASS]
**Severity**: Medium

### Bug Mechanism
`PremiumManager.distributePremium()` reads `poolFeeBps` live from the CoverPool at distribution time via `ICoverPool(pool).poolFeeBps()`. A curator can change `poolFeeBps` (up to 20%) immediately before `distributePremium` is called, retroactively applying a higher fee rate to premium that was accrued at a lower rate. No snapshot of the fee at accrual time is maintained.

**Key code** (`PremiumManager.sol:154`):
```solidity
uint16 poolFeeBps = ICoverPool(pool).poolFeeBps();  // live read at distribution time
```

### Test Output
```
[PASS] test_H13_poolFeeBpsLiveReadEnablesRetroactiveFeeExtraction() (gas: 2504768)
Logs:
  Pool fee paid: 200000000000000000000
  Expected at original 5%: 50000000000000000000
  Expected at new 20%: 200000000000000000000
  H-13 CONFIRMED: poolFeeBps live read enables retroactive fee extraction
```

### Key Evidence
- 1000 ether premium accumulated under 5% pool fee → expected fee = 50 ether
- Curator changes poolFeeBps to 20% before distribution
- Actual fee extracted = 200 ether (4× expected)
- `poolFeePaid (200 ether) == expectedAtNewFee (200 ether)` [assertion passes]
- `poolFeePaid (200 ether) > expectedAtOrigFee (50 ether)` [assertion passes]

---

## Execution Results

```
Ran 8 tests for test/plamen/verify_batch_D.t.sol:VerifyBatchD
[PASS] testFuzz_H2_gracePeriodLinearlyAccumulates(uint8,uint32) (runs: 250)
[PASS] test_H10_claimApprovalGateIsGlobalPerPolicy() (gas: 3575943)
[PASS] test_H11_isPolicyActiveBlocksWithdrawalOnPMRevert() (gas: 7642584)
[PASS] test_H12_revokedSpecStillResolvable() (gas: 1541402)
[PASS] test_H13_poolFeeBpsLiveReadEnablesRetroactiveFeeExtraction() (gas: 2504768)
[PASS] test_H2_unboundedGateGracePeriodAccumulation() (gas: 168492)
[PASS] test_H6_staleApprovalPersistsOnOldRewardsManager() (gas: 2258719)
[PASS] test_H8_retroactiveParamChangesReducePayout() (gas: 530442)

Suite result: ok. 8 passed; 0 failed; 0 skipped; finished in 33.48ms
```

---

## PROVEN_ONLY Severity Adjustments

| H-ID | Original Severity | Adjusted Severity | Reason |
|------|------------------|-------------------|--------|
| H-10 | Medium | Low | Best evidence is [CODE-TRACE] — no full execution of multi-user serialization scenario |

All other findings have [POC-PASS] and retain their original severity.
