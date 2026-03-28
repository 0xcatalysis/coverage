# Breadth Re-Scan Agent #1 — Second Pass Findings

> Pass completed. Focused on cross-contract state inconsistencies, asymmetric operations,
> and specific areas highlighted in the task prompt.

---

## Finding [RS1-1]: gateGracePeriod Extension Renders Insurance Uncollectable During Grace Window

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✓, R6:✓, R8:✓, R10:✓, R11:✗(no external tokens), R12:✓, R13:✓, R14:✗(no aggregate variable mismatch), R15:✗(no flash loan), R16:✗(no oracle dependency)]
**Severity**: High
**Location**: `CoveredVaultAccrual.sol:116-136`, `CoveredVaultAccrual.sol:150-159`, `ClaimManager.sol:306-309`

**Description**:
The `gateGracePeriod` mechanism in `CoveredVaultWrapper` extends the vault's view of policy maturity to `meta.maturityTime + gateGracePeriod`, giving users who were locked behind a Morpho gate additional time to file insurance claims. However, `ClaimManager._fileClaimWithMetadata()` independently checks the raw `metadata.maturityTime` (line 307: `block.timestamp <= metadata.maturityTime`) with no knowledge of `gateGracePeriod`. This creates a permanent mismatch: the vault considers claims valid during the grace window, but the ClaimManager rejects every such claim with `ClaimOutsideCoverageWindow`.

The scenario is:
1. Morpho gate is activated (e.g., Morpho is paused/at risk) — gate activation time recorded
2. Policy expires (`block.timestamp > maturityTime`) while gate is still active
3. Gate is lifted: `gateGracePeriod += (liftTime - activateTime)`, `morphoGateActive = false`
4. `_isPolicyActive()` now returns `true` (vault sees `block.timestamp < maturityTime + gateGracePeriod`)
5. Premium accrual RESUMES during grace window (morphoGateActive is false, so _accruePremium collects)
6. A user suffers a loss and calls `redeem()` / `withdraw()`
7. Vault calls `_claimInsurance()` → `claimManager.fileClaim()` → **ClaimManager reverts** with `ClaimOutsideCoverageWindow` because `block.timestamp > maturityTime`
8. The `try/catch` catches the revert, emits `ClaimManagerUnavailable`, and returns **payout = 0**
9. User receives zero insurance despite the vault's accounting stating the policy is active

During this same grace window, premium continues to accrue and is deducted from users' withdrawals, meaning users both pay premium AND receive zero insurance — the worst possible outcome.

**Impact**:
- Users who suffered losses during the Morpho gate overlap period receive **zero insurance payout**, defeating the entire purpose of `gateGracePeriod`
- Premium is still collected during the grace period (vault's `totalPremiumLiability` grows, `totalAssets()` is deflated), causing remaining depositors to receive less value than expected
- The mechanism designed to protect users from Morpho downtime is silently broken — no on-chain indication that claims will fail; the vault shows `_isPolicyActive() == true` while insurance claims are guaranteed to fail

**Evidence**:

`CoveredVaultAccrual.sol:150-158` — vault uses `effectiveMaturity`:
```solidity
function _isPolicyActive() internal view returns (bool) {
    if (policyId == 0) return false;
    IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);
    uint256 effectiveMaturity = uint256(metadata.maturityTime) + gateGracePeriod;
    return
        metadata.buyer != address(0) && block.timestamp >= metadata.startTime && block.timestamp < effectiveMaturity;
}
```

`ClaimManager.sol:306-309` — ClaimManager uses raw `maturityTime`:
```solidity
require(
    block.timestamp >= metadata.startTime && block.timestamp <= metadata.maturityTime,
    ClaimOutsideCoverageWindow(policyId, metadata.startTime, metadata.maturityTime, uint32(block.timestamp))
);
```

`CoveredVaultWrapper.sol:365-372` — silent failure catches the ClaimManager revert:
```solidity
try claimManager.fileClaim(policyId, cappedClaim, evidenceHash, additionalData) {
    // success
} catch {
    _tstore(PENDING_CLAIM_AMOUNT_SLOT, 0);
    emit IE.ClaimManagerUnavailable(policyId);
    return 0;
}
```

There is no function in PolicyManager or ClaimManager to update `maturityTime` after binding.

### Postcondition Analysis
**Postconditions Created**: `gateGracePeriod > 0` after any gate toggle cycle; vault `_isPolicyActive()` returns true; ClaimManager returns `ClaimOutsideCoverageWindow` for all fileClaim calls
**Postcondition Types**: [STATE, EXTERNAL]
**Who Benefits**: The premium recipient collects premium from users who receive no insurance in return

---

## Finding [RS1-2]: Authorized Operators Can Waive Owner's Insurance by Calling emergencyRedeem/emergencyWithdraw

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single entity), R6:✓, R8:✗(single-step), R10:✓, R11:✗(no external tokens), R12:✓, R13:✓, R14:✗(no aggregate variables), R15:✗(no flash loan), R16:✗(no oracle dependency)]
**Severity**: Medium
**Location**: `CoveredVaultWrapper.sol:241-262`

**Description**:
`emergencyRedeem(uint256 shares, address receiver, address owner)` and `emergencyWithdraw(uint256 assets, address receiver, address owner)` are `external` functions with no `owner == msg.sender` access control. They are accessible to any account that holds an ERC-20 allowance from `owner` (via `_spendAllowance` in the underlying `_withdraw` call). When called, they set `SKIP_INSURANCE_SLOT = 1` before invoking `super.redeem/withdraw`, which causes `_computeInsurance()` to unconditionally return 0 — permanently waiving the insurance payout for that withdrawal.

An authorized operator (e.g., a DeFi integration, a keeper bot with allowance, or a compromised integration contract) can call `emergencyRedeem(owner's_shares, receiver, owner)` on behalf of an owner who suffers a loss. The owner's insurance claim is silently skipped. The operator's intent to use the "no insurance" variant of the exit path directly controls whether the owner receives insurance proceeds.

The NatSpec states: "The user explicitly acknowledges they will NOT receive any insurance payout." However, the `user` in this context is the **operator** (`msg.sender`), not the **owner** (whose principal and shares are consumed). The acknowledgment is made by a party different from the one who bears the economic loss.

**Impact**:
- An adversarial or buggy operator with ERC-20 allowance can force the vault owner into the no-insurance exit path, causing the owner to lose their full insurance payout on a loss event
- In a protocol that issues vault shares as collateral (e.g., lending protocol), the lending protocol contract may call `emergencyRedeem` to liquidate a borrower's vault position, inadvertently waiving the borrower's insurance coverage
- Severity is Medium rather than High because: (a) requires the victim to have granted allowance, (b) the operator could have also called `redeem()` normally which would have claimed insurance

**Evidence**:

`CoveredVaultWrapper.sol:241-248`:
```solidity
function emergencyRedeem(uint256 shares, address receiver, address owner) external returns (uint256) {
    _tstore(SKIP_INSURANCE_SLOT, 1);
    super.redeem(shares, receiver, owner);  // if caller != owner, _spendAllowance is called
    _tstore(SKIP_INSURANCE_SLOT, 0);
    uint256 totalOut = _tload(ACTUAL_OUT_SLOT);
    emit IE.EmergencyExit(owner, receiver, shares, totalOut);
    return totalOut;
}
```

`CoveredVaultWrapper.sol:317-326` — insurance is unconditionally skipped when the flag is set:
```solidity
function _computeInsurance(...) internal returns (uint256 insurancePayout) {
    // Emergency exit: user explicitly waives insurance coverage.
    if (_tload(SKIP_INSURANCE_SLOT) != 0) return 0;
    ...
}
```

Compare with `_withdraw` in the OZ base (lines 308-310): any non-owner caller with sufficient allowance can trigger redemption, including the emergency path.

### Postcondition Analysis
**Postconditions Created**: Owner's shares burned, no insurance claim filed, assets transferred to receiver
**Postcondition Types**: [STATE, BALANCE]
**Who Benefits**: Adversarial operator; no economic benefit to attacker unless they control `receiver`

---

## Finding [RS1-3]: CoverPoolFactory Salt Excludes specRegistry and stakeManager — computeCoverPoolAddress Returns Stale Address After Infrastructure Rotation

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single entity), R6:✓, R8:✓, R10:✓, R11:✗(no external tokens), R12:✗(no dangerous precondition), R13:✗(not design-related), R14:✗(no aggregate variables), R15:✗(no flash loan), R16:✗(no oracle dependency)]
**Severity**: Low
**Location**: `CoverPoolFactory.sol:222-229`

**Description**:
The `_computeSalt` function in `CoverPoolFactory` uses only `(curator, policyManager, quoteSigner, poolFeeBps)` to derive the deterministic CREATE2 salt. It does NOT include `specRegistry` or `stakeManager`:

```solidity
function _computeSalt(CreateCoverPoolParams calldata params) private view returns (bytes32) {
    return EfficientHashLib.hash(
        uint256(uint160(params.curator)),
        uint256(uint160(policyManager)),
        uint256(uint160(params.quoteSigner)),
        uint256(params.poolFeeBps)
    );
}
```

`computeCoverPoolAddress()` (the public view function) calls `_computeSalt(params)` which reads the **current** `policyManager` from storage. After `setStakeManager()` or `setSpecRegistry()` is called on the factory, the salt does not change (these fields are not included). However, `computeCoverPoolAddress()` will still return the correct address since `stakeManager` and `specRegistry` are not part of the salt.

The more subtle issue is: `createCoverPool` calls `coverPoolImplementation.cloneDeterministic(salt)` with the current `stakeManager` and `specRegistry` values. If a CREATOR_ROLE holder calls `createCoverPool` with the same params after `setStakeManager`/`setSpecRegistry` was changed:
- The salt is identical (same curator, policyManager, quoteSigner, poolFeeBps)
- `cloneDeterministic` reverts because the address is already deployed
- There is no way to create a second pool with the same logical params but pointing to the updated `stakeManager`/`specRegistry`

This silently locks pools to the old `stakeManager`/`specRegistry` if infrastructure is rotated. Existing pools do not inherit the new addresses; there is no migration path.

**Impact**:
- After `setStakeManager()` or `setSpecRegistry()` is called on the factory, existing pools remain wired to the old contracts
- New pools with identical `(curator, quoteSigner, poolFeeBps)` cannot be created (CREATE2 collision)
- Infrastructure rotation intended to fix bugs or upgrade the system is incomplete for existing pools

**Evidence**:
`CoverPoolFactory.sol:103-105`:
```solidity
ICoverPool(coverPool).initialize(
    params.curator, params.quoteSigner, policyManager, stakeManager, specRegistry, params.poolFeeBps
);
```
The `stakeManager` and `specRegistry` here are whatever the factory's state is at deployment time, but the salt doesn't encode them, creating a "single deployment per logical params" constraint.

### Postcondition Analysis
**Postconditions Created**: Existing pools permanently wired to old infrastructure addresses
**Postcondition Types**: [STATE]
**Who Benefits**: N/A (design limitation, not an attack vector)
