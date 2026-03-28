# Breadth Re-Scan Agent 3 — Third Pass Analysis

## Finding [RS3-1]: Gate Grace Extension Renders Insurance Uncollectable — ClaimManager Enforces Raw maturityTime

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear, no externals), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R11:✗(no external tokens), R12:✓, R13:✓, R14:✗(no aggregate variables), R15:✗(no flash-loan), R16:✗(no oracle)]
**Severity**: High
**Location**: CoveredVaultAccrual.sol:153-158 (`_isPolicyActive()`), CoveredVaultWrapper.sol:328-333 (`_computeInsurance`), ClaimManager.sol:307-308 (`_fileClaimWithMetadata`)
**Description**:
The `gateGracePeriod` mechanism is designed to extend insurance eligibility for users who were unable to withdraw during a Morpho gate event. When the gate is lifted, `gateGracePeriod += gateDuration` (CoveredVaultAdmin.sol:181). Both `_isPolicyActive()` and `_activeElapsedFrom()` use `effectiveMaturity = maturityTime + gateGracePeriod`, causing the wrapper to treat the policy as active during the extension window.

However, `ClaimManager._fileClaimWithMetadata` enforces:
```solidity
// ClaimManager.sol:307-308
require(
    block.timestamp >= metadata.startTime && block.timestamp <= metadata.maturityTime,
    ClaimOutsideCoverageWindow(...)
);
```

The ClaimManager uses the raw `maturityTime` from `PolicyManager` with no knowledge of the wrapper's `gateGracePeriod`. When a user withdraws during the grace extension (i.e., `maturityTime < block.timestamp < maturityTime + gateGracePeriod`):

1. `_computeInsurance` calls `_isPolicyActive()` → returns `true` (within effectiveMaturity)
2. `_claimInsurance` calls `claimManager.fileClaim()`
3. `fileClaim` reverts with `ClaimOutsideCoverageWindow` (block.timestamp > maturityTime)
4. The try/catch in `_claimInsurance` catches this → emits `ClaimManagerUnavailable` → returns 0

The user receives zero insurance payout. The misleading `ClaimManagerUnavailable` event makes the failure look like a ClaimManager outage rather than the actual cause (window mismatch). Additionally, premium continues to accrue during the grace window (`_accruedPremiumFor` also uses effectiveMaturity), so users pay premiums for a window in which they receive no insurance coverage.

**Impact**:
- Users who suffered losses during a Morpho gate event and withdraw during the grace extension window receive zero insurance payout, despite `_isPolicyActive()` confirming eligibility.
- This defeats the primary purpose of the `gateGracePeriod` mechanism: granting insurance eligibility for losses that occurred while users were gate-locked.
- Premiums continue to be deducted from withdrawals in the grace window (via `_accruedPremiumFor`), creating a double-harm: users pay for coverage they cannot receive.
- The `ClaimManagerUnavailable` event misattributes the cause, making off-chain monitoring misleading.

**Evidence**:
```solidity
// CoveredVaultAccrual.sol:153-158
function _isPolicyActive() internal view returns (bool) {
    if (policyId == 0) return false;
    IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);
    uint256 effectiveMaturity = uint256(metadata.maturityTime) + gateGracePeriod;
    return metadata.buyer != address(0) && block.timestamp >= metadata.startTime
           && block.timestamp < effectiveMaturity; // Extends beyond raw maturityTime
}

// CoveredVaultWrapper.sol:328-333
if (insuredBasis > netAssetsReceived && _isPolicyActive()) {
    uint256 claimAmount = _capAndApplyDeductible(insuredBasis - netAssetsReceived, insuredBasis);
    if (claimAmount > 0) {
        insurancePayout = _claimInsurance(claimAmount, owner); // Will return 0 in grace window
    }
}

// ClaimManager.sol:307-308 — enforces raw maturityTime, not effectiveMaturity
require(
    block.timestamp >= metadata.startTime && block.timestamp <= metadata.maturityTime,
    ClaimOutsideCoverageWindow(...)
);
```

### Postcondition Analysis
**Postconditions Created**: Insurance is silently denied for all withdrawals during the grace extension window; `ClaimManagerUnavailable` events emitted even though ClaimManager is functioning correctly.
**Postcondition Types**: STATE, TIMING
**Who Benefits**: No party; this is a protocol inconsistency that harms users.

---

## Finding [RS3-2]: Stale Evidenced Hash from `block.timestamp` Can Cause Second Same-Block Claim Denial

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3 | ✗4(very narrow conditions) | ✓5
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R11:✗(no external tokens), R12:✗(no dangerous precondition), R13:✗(not design-related), R14:✗(no aggregate variables), R15:✗(no flash-loan), R16:✗(no oracle)]
**Severity**: Low
**Location**: CoveredVaultWrapper.sol:358 (`_claimInsurance`), ClaimManager.sol:293 (`_fileClaimWithMetadata`)
**Description**:
The evidence hash for insurance claims is constructed as:
```solidity
// CoveredVaultWrapper.sol:358
bytes32 evidenceHash = keccak256(abi.encodePacked(user, policyId, cappedClaim, block.timestamp));
```

`ClaimManager._fileClaimWithMetadata` marks this hash as used for the policyId:
```solidity
// ClaimManager.sol:293
require(!_usedEvidenceHashes[policyId][evidenceHash], DuplicateEvidenceHash(policyId, evidenceHash));
_usedEvidenceHashes[policyId][evidenceHash] = true;
```

If the same user, same policy, same `cappedClaim` amount, and same `block.timestamp` produce the same hash across two transactions in the same block, the second claim is rejected as a duplicate. While different principal amounts at different states produce different `cappedClaim` values (because principal is reduced after the first withdrawal), rounding effects in `_capAndApplyDeductible` can yield identical `cappedClaim` for two sequential withdrawals of very small amounts.

The second claim's `try/catch` catches the `DuplicateEvidenceHash` revert → emits `ClaimManagerUnavailable` → returns 0. Again, the event misattributes the cause.

**Impact**:
- In a narrow scenario involving same-block same-user withdrawals with identical computed `cappedClaim` values (possible due to rounding at small scales), the second withdrawal receives no insurance payout.
- The `ClaimManagerUnavailable` event obscures the true cause.
- Practical exploitation requires specific timing and amounts; not a general attack vector.

**Evidence**:
```solidity
// Same evidenceHash if all four inputs are identical in same block:
bytes32 evidenceHash = keccak256(abi.encodePacked(user, policyId, cappedClaim, block.timestamp));
```

### Precondition Analysis
**Missing Precondition**: Two same-block same-user withdrawals must compute identical `cappedClaim` (requires rounding to produce the same result after `mulDiv` in `_capAndApplyDeductible` for sequential principal reductions)
**Precondition Type**: TIMING, STATE
**Why This Blocks**: Sequential principal reductions after tx1 change the numerator for tx2's computation, typically yielding different `cappedClaim`; collision is only possible with very specific amounts at rounding boundaries.

---

DONE: 2 new findings identified
