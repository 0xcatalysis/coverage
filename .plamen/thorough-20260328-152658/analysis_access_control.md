# Access Control & Semi-Trusted Roles Analysis

> Agent: Analysis Agent #2 (Access Control)
> Scope: src/ directory — CoverPool, CoverPoolFactory, PolicyManager, ClaimManager, SpecRegistry, Swapper, PremiumManager, PremiumCollector, CoveredVaultAdmin, CoveredVaultWrapper

---

## Role Inventory & Capability Matrix

| Role | Contract | Trust Level | Capabilities | Fund Impact |
|------|----------|-------------|-------------|-------------|
| DEFAULT_ADMIN_ROLE | PolicyManager, ClaimManager, PremiumManager, PremiumCollector, SpecRegistry, Swapper, CoverPoolFactory | FULLY_TRUSTED | Upgrade, pause/unpause, set all dependency addresses, recover tokens | Direct: can redirect protocol addresses, recover tokens |
| DEFAULT_ADMIN_ROLE (CoverPool) | CoverPool (per clone) | SEMI_TRUSTED (pool-scoped) | Bind policies, set pool fee (max 20%), set fee recipient, grant/revoke roles, pause/unpause, setPremiumDefaulted | Indirect: blocks claims via defaulted flag, redirects pool fees |
| QUOTE_SIGNER_ROLE | CoverPool | SEMI_TRUSTED | Sign EIP-712 quotes | Indirect: can sign unfavorable quotes (bad premium, window) |
| CREATOR_ROLE | CoverPoolFactory | SEMI_TRUSTED | Create pools, **set coverPoolImplementation, setPolicyManager, setStakeManager, setSpecRegistry** | Direct: can change implementation and critical addresses |
| SWAP_MANAGER_ROLE | Swapper | SEMI_TRUSTED | Set swap routes, **only to whitelisted targets** | Indirect: malicious route config; mitigated by whitelist |
| SWAP_EXECUTOR_ROLE | Swapper | PRECONDITION (ClaimManager) | Execute swaps | Indirect: only ClaimManager should hold |
| PREMIUM_COLLECTOR_ROLE | PremiumManager | SEMI_TRUSTED | Trigger distributePremium | Low: triggers fee split of already-collected premiums |
| CoveredVaultWrapper Owner | CoveredVaultWrapper | SEMI_TRUSTED (timelocked) | Change rates/coverage params (timelocked), toggle Morpho gate (instant), rescue tokens, propose upgrades | Direct via morphoGateActive; indirect via timelocked params |

---

## Finding [AC-1]: CREATOR_ROLE Can Replace Critical Infrastructure Addresses Without Timelock

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5,6 | ✗6b(no Slither available)
**Rules Applied**: [R6:✓, R8:✗(single-step setter), R10:✓, R12:✓, R13:✗(not design-related), R14:✗(no aggregate variables)]
**Severity**: Medium
**Location**: CoverPoolFactory.sol:L115-L158

**Description**:
The `CREATOR_ROLE` in `CoverPoolFactory` has the ability to change critical infrastructure addresses: `coverPoolImplementation`, `policyManager`, `stakeManager`, and `specRegistry`. These setters have no timelock, no multi-sig requirement, and no pause guard. Notably, `setCoverPoolImplementation` allows CREATOR_ROLE to point to an arbitrary contract (with only a code-length check), which will be used as the template for all future CoverPool clones. `setPolicyManager`, `setStakeManager`, and `setSpecRegistry` change the addresses injected into all future pool clones created via `createCoverPool`.

```solidity
// CoverPoolFactory.sol L115-123
function setCoverPoolImplementation(address implementation_) external override onlyRole(CREATOR_ROLE) {
    require(implementation_ != address(0), ZeroAddress());
    require(implementation_.code.length != 0, InvalidImplementation());
    address previousImplementation = coverPoolImplementation;
    coverPoolImplementation = implementation_;
    emit CoverPoolImplementationSet(previousImplementation, implementation_);
}
```

While these changes only affect **future** pools (existing clones are not upgraded), CREATOR_ROLE is not documented as FULLY_TRUSTED in the trust model. The design_context.md classifies it under "Designated creator" without explicit trust bounds. Yet its capabilities extend far beyond pool creation -- it can control the implementation contract used for future pools and the core protocol addresses they integrate with.

**Impact**:
- A compromised CREATOR_ROLE key can set a malicious `coverPoolImplementation` that steals funds when future pools are initialized (e.g., a backdoored CoverPool that grants the attacker QUOTE_SIGNER_ROLE or DEFAULT_ADMIN_ROLE).
- Setting a malicious `policyManager`/`stakeManager`/`specRegistry` means future pools would interact with attacker-controlled contracts.
- Existing pools are not affected (their addresses are set at initialization and immutable per pool), limiting blast radius.

**Evidence**:
[CODE] CoverPoolFactory.sol:L115 — `setCoverPoolImplementation` restricted to CREATOR_ROLE, no timelock.
[CODE] CoverPoolFactory.sol:L128 — `setPolicyManager` restricted to CREATOR_ROLE, no timelock.
[CODE] CoverPoolFactory.sol:L140 — `setStakeManager` restricted to CREATOR_ROLE, no timelock.
[CODE] CoverPoolFactory.sol:L152 — `setSpecRegistry` restricted to CREATOR_ROLE, no timelock.

### Postcondition Analysis
**Postconditions Created**: Future pool clones use attacker-controlled implementation or dependency addresses.
**Postcondition Types**: [STATE, ACCESS]
**Who Benefits**: Attacker with compromised CREATOR_ROLE key; social engineering vector against pool curators who trust factory-produced pools.

---

## Finding [AC-2]: CoverPool Curator Can Permanently Block Claims via setPremiumDefaulted

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5,6 | ✗6b(no Slither available)
**Rules Applied**: [R6:✓, R10:✓, R12:✓, R13:✓, R14:✗(no aggregate variables)]
**Severity**: Medium
**Location**: CoverPool.sol:L147-149, ClaimManager.sol:L297

**Description**:
The CoverPool curator (DEFAULT_ADMIN_ROLE on the pool clone) can call `setPremiumDefaulted(policyId, true)` to mark any bound policy as premium-defaulted. When a policy is marked as defaulted, `ClaimManager.fileClaim()` will revert at L297:

```solidity
// ClaimManager.sol L297
require(!metadata.premiumDefaulted, PremiumDefaulted(policyId));
```

The curator can set `premiumDefaulted = true` at any time after a policy is bound, even if the buyer has been faithfully paying premiums. There is no on-chain mechanism for the buyer/beneficiary to challenge or reverse this flag -- only the curator (via the same CoverPool) can set it back to `false`.

This is compounded by the CoveredVaultWrapper integration: when Morpho vault suffers a loss and users withdraw, `_claimInsurance()` calls `claimManager.fileClaim()`. If the curator has set premiumDefaulted, the fileClaim call will revert (not caught by try/catch because ClaimManager is available, the call just reverts with PremiumDefaulted). The try/catch in CoveredVaultWrapper L365-372 catches this scenario -- but the insurance payout is 0. Users lose insurance coverage they paid for.

```solidity
// CoveredVaultWrapper.sol L365-372
try claimManager.fileClaim(policyId, cappedClaim, evidenceHash, additionalData) {
    // success
} catch {
    _tstore(PENDING_CLAIM_AMOUNT_SLOT, 0);
    emit IE.ClaimManagerUnavailable(policyId);
    return 0;
}
```

**Impact**:
- Curator can deny insurance payouts for all users in a CoveredVaultWrapper by setting premiumDefaulted=true.
- Users have already paid premiums (per-second accrual) that cannot be recovered.
- This is a unilateral denial-of-service on insurance coverage without recourse.
- Severity assessed at: TVL up to depositCap (could be millions), premium already accrued and paid.

**Evidence**:
[CODE] CoverPool.sol:L147-149 — `setPremiumDefaulted` callable by curator, no timelock.
[CODE] ClaimManager.sol:L209 — `require(!_claimApprovalRequired[policyId], ...)` — approval gate.
[CODE] ClaimManager.sol:L297 (inside `_fileClaimWithMetadata`) — `require(!metadata.premiumDefaulted, PremiumDefaulted(policyId))` — blocks all claims.
[CODE] CoveredVaultWrapper.sol:L365-372 — try/catch catches the revert, returns 0 payout.

### Postcondition Analysis
**Postconditions Created**: All future claims for the policy are blocked; users who withdraw during a loss event receive zero insurance.
**Postcondition Types**: [STATE, ACCESS]
**Who Benefits**: A malicious curator who wants to avoid payouts; the protocol if premiums are genuinely defaulted (intended use).

---

## Finding [AC-3]: Claim Approval Gate Allows Curator to Permanently Block Multi-Claim Policies

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5,6 | ✗6b(no Slither available)
**Rules Applied**: [R6:✓, R10:✓, R12:✓, R13:✓, R14:✗(no aggregate variables)]
**Severity**: Medium
**Location**: ClaimManager.sol:L179-184, L209, L235

**Description**:
After each successful claim payout, `_claimApprovalRequired[policyId]` is set to `true` (L235). This means the next claim for the same policy will revert at L209 unless the CoverPool curator calls `approveNextClaim(policyId)` (L179-184).

```solidity
// ClaimManager.sol L235
_claimApprovalRequired[policyId] = true;

// ClaimManager.sol L179-184
function approveNextClaim(uint96 policyId) external override {
    IPolicyManager.PolicyMetadata memory metadata = IPolicyManager(policyManager).policyMetadata(policyId);
    require(metadata.buyer != address(0), PolicyNotFound(policyId));
    require(msg.sender == ICoverPool(metadata.pool).owner(), UnauthorizedApprover());
    _claimApprovalRequired[policyId] = false;
    emit NextClaimApproved(policyId, msg.sender);
}
```

The curator acts as a gatekeeper for all claims beyond the first. If the curator becomes unavailable (key loss, going offline) or maliciously withholds approval, no further claims can be filed for that policy. For CoveredVaultWrapper, this means only one user withdrawal can receive insurance. All subsequent withdrawals during the same loss event get zero insurance.

The design intent is to prevent "rapid serial claiming" (as noted in design_context.md). However, the mitigation is asymmetric: it has no timeout/fallback. There is no mechanism by which approval is automatically restored after a delay.

**Impact**:
- After one successful claim, curator inaction permanently blocks further claims.
- In a multi-user CoveredVaultWrapper scenario: the first user to withdraw during a loss event gets insurance; all subsequent users do not. This is a race condition for insurance payouts.
- Users have paid the same premium rate but receive unequal coverage.
- No on-chain fallback: unlike the Morpho gate (which has a grace period mechanism), the claim approval gate has no auto-reset.

**Evidence**:
[CODE] ClaimManager.sol:L235 — `_claimApprovalRequired[policyId] = true` set after every successful claim.
[CODE] ClaimManager.sol:L209 — `require(!_claimApprovalRequired[policyId], ...)` blocks next claim.
[CODE] ClaimManager.sol:L179-184 — `approveNextClaim` requires `msg.sender == ICoverPool(metadata.pool).owner()` (curator only).

### Postcondition Analysis
**Postconditions Created**: After first successful claim, all subsequent claims blocked until curator acts.
**Postcondition Types**: [STATE, ACCESS]
**Who Benefits**: First user to withdraw in a loss event; curator who may want to control claim flow.

---

## Finding [AC-4]: CoveredVaultWrapper Owner morphoGateActive Toggle Has No Timelock and Can Block Withdrawals

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3,4,5,6 | ✗6b(no Slither available)
**Rules Applied**: [R6:✓, R8:✗(single-step), R10:✓, R12:✓, R13:✓, R14:✗(no aggregate variables)]
**Severity**: Low
**Location**: CoveredVaultAdmin.sol:L168-186

**Description**:
The `setMorphoGateActive(bool active)` function is the only owner operation without a timelock. When set to `true`:
1. Premium accrual pauses (users stop paying premium -- this is beneficial to users).
2. `_morphoValue()` falls back to `lastKnownMorphoValue` (cached value may be stale).
3. Withdrawals are NOT directly blocked by the gate (the gate only pauses accrual and caches Morpho value). Morpho redemption itself may or may not work depending on the actual Morpho vault state.

When deactivated, `gateGracePeriod += gateDuration` extends the policy maturity window, which is favorable to users (extends insurance coverage).

The risk is limited because:
- Activating the gate pauses premium (beneficial to users).
- Deactivating restores normal operation with extended coverage.
- The gate is designed for genuine Morpho emergencies where the vault blocks redemptions.

However, if the owner activates the gate when Morpho is functioning normally, `_morphoValue()` will use the cached value instead of the live value. If the real Morpho value subsequently drops significantly, `totalAssets()` would show an inflated value (based on the stale cache), and users who deposit during this period would receive shares at an artificially high conversion rate. When the gate is deactivated and the real value is read, existing users' positions would be diluted.

```solidity
// CoveredVaultAdmin.sol L168-186
function setMorphoGateActive(bool active) external override onlyOwner {
    _accruePremium();
    if (active && !morphoGateActive) {
        gateActivatedAt = block.timestamp;
        try IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this))) returns (uint256 val) {
            lastKnownMorphoValue = val;
        } catch {}
    } else if (!active && morphoGateActive && gateActivatedAt > 0) {
        uint256 gateDuration = block.timestamp - gateActivatedAt;
        gateGracePeriod += gateDuration;
        gateActivatedAt = 0;
    }
    morphoGateActive = active;
    emit IE.MorphoGateStatusUpdated(active);
}
```

### Precondition Analysis
**Missing Precondition**: Owner must act maliciously by activating gate when Morpho is functioning normally.
**Precondition Type**: ACCESS
**Why This Blocks**: Owner is timelocked for other operations and trusted to some degree; malicious gate activation during normal operation is detectable off-chain.

### Postcondition Analysis
**Postconditions Created**: Stale Morpho value used for totalAssets(); premium accrual paused; gateGracePeriod extended on deactivation.
**Postcondition Types**: [STATE, TIMING]
**Who Benefits**: Depositors during gate period (if value drops); owner (premium pauses, coverage extends).

---

## Finding [AC-5]: SWAP_MANAGER_ROLE Route Configuration Constrained by Whitelist

**Verdict**: REFUTED
**Step Execution**: ✓1,2,3,4,5,6 | ✗6b(no Slither available)
**Rules Applied**: [R6:✓, R8:✗(single-step), R10:✓, R12:✗(no dangerous precondition from this role alone)]
**Severity**: Informational
**Location**: Swapper.sol:L146-173

**Description**:
SWAP_MANAGER_ROLE can call `setSwapRoute(tokenIn, tokenOut, swapTarget, enabled, swapCalldata)` to configure swap routes. The `swapTarget` must be in `whitelistedTargets` (L161), which is controlled by DEFAULT_ADMIN_ROLE (L114). The route stores arbitrary `swapCalldata` which is used when the executor calls `executeSwap`.

The whitelist check at route creation time AND at execution time (L363: `require(whitelistedTargets[swapTarget], ...)`) provides a double-gate. Even if SWAP_MANAGER configures a malicious route, the target must remain whitelisted at execution time. The DEFAULT_ADMIN can de-whitelist at any time.

Additionally, `executeSwap` verifies `amountOut >= params.amountOutMin` (L243), providing slippage protection.

**Evidence**:
[CODE] Swapper.sol:L161 — `require(whitelistedTargets[swapTarget], ...)` at route setting.
[CODE] Swapper.sol:L363 — `require(whitelistedTargets[swapTarget], ...)` at execution.
[CODE] Swapper.sol:L243 — `require(amountOut >= params.amountOutMin, ...)` slippage check.
[CODE] Swapper.sol:L240 — `effectiveCalldata = params.swapCalldata.length > 0 ? params.swapCalldata : routeCalldata` — executor can override with own calldata.

Cross-validation: The stored `swapCalldata` in the route can be overridden by the executor (ClaimManager) via `params.swapCalldata` at execution time. However, in practice ClaimManager passes empty swapCalldata (L660: `swapCalldata: ""`), so the stored route calldata is used. A malicious SWAP_MANAGER could set calldata that routes through a sandwich contract, but the amountOutMin check and the whitelist constraint limit damage.

---

## Finding [AC-6]: CoverPool Curator 24-Hour Admin Transfer Delay is Short for Pool-Scoped Trust

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3,4,5,6 | ✗6b(no Slither available)
**Rules Applied**: [R6:✓, R10:✓, R12:✗(no dangerous precondition), R13:✓, R14:✗(no aggregate variables)]
**Severity**: Informational
**Location**: CoverPool.sol:L93

**Description**:
CoverPool uses `AccessControlDefaultAdminRulesUpgradeable` with a 24-hour delay for admin transfers (L93: `__AccessControlDefaultAdminRules_init(24 hours, curator_)`). This is a two-step process (propose + accept) with a 24-hour delay.

While 24 hours gives some notice for admin transfer, the curator has significant capabilities: binding policies, setting premiumDefaulted (AC-2), and managing the claim approval gate (AC-3). For a pool managing significant TVL, 24 hours may be insufficient for depositors to react.

However, this is an informational observation because:
- The two-step pattern itself is sound (OpenZeppelin's battle-tested implementation).
- Depositors can monitor the `DefaultAdminTransferScheduled` event.
- CoveredVaultWrapper shares are soulbound; users can still withdraw before a malicious new curator acts.

**Evidence**:
[CODE] CoverPool.sol:L93 — `__AccessControlDefaultAdminRules_init(24 hours, curator_)`.

### Precondition Analysis
**Missing Precondition**: Requires the current curator to initiate the transfer to a malicious party.
**Precondition Type**: ACCESS
**Why This Blocks**: Curator must already be compromised or malicious.

---

## Finding [AC-7]: CoveredVaultWrapper Ownership Uses Ownable2Step but Pending Timelocks Cleared on Transfer

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5,6 | ✗6b(no Slither available)
**Rules Applied**: [R6:✓, R8:✓, R10:✓, R12:✗(no dangerous precondition), R13:✗(not design-related)]
**Severity**: Informational
**Location**: CoveredVaultAdmin.sol:L116-124

**Description**:
The `acceptOwnership()` override in CoveredVaultAdmin properly clears all pending timelocked proposals when ownership transfers:

```solidity
function acceptOwnership() public override {
    super.acceptOwnership();
    pendingPremiumRateTimestamp = 0;
    pendingDeductibleTimestamp = 0;
    pendingMaxCoverableLossTimestamp = 0;
    pendingUpgradeTimestamp = 0;
    pendingImplementation = address(0);
    pendingPremiumRecipientTimestamp = 0;
}
```

This is good defensive design -- prevents the old owner from "planting" a proposal that the new owner unknowingly executes. Combined with `renounceOwnership()` being disabled (L128-129), the ownership model is sound.

Noted as informational positive finding: the design correctly handles the ownership transfer edge case.

**Evidence**:
[CODE] CoveredVaultAdmin.sol:L116-124 — All pending proposals cleared on ownership acceptance.
[CODE] CoveredVaultAdmin.sol:L128-129 — `renounceOwnership()` reverts with `RenounceDisabled()`.

---

## Finding [AC-8]: Pending Upgrade State Not Cleared Before upgradeToAndCall in executeUpgrade

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5,6 | ✗6b(no Slither available)
**Rules Applied**: [R6:✓, R8:✓, R10:✓, R12:✗(no dangerous precondition), R13:✗(not design-related)]
**Severity**: Low
**Location**: CoveredVaultAdmin.sol:L141-149

**Description**:
In `executeUpgrade()`, the `pendingUpgradeTimestamp` and `pendingImplementation` are cleared AFTER the `upgradeToAndCall(impl, "")` call:

```solidity
function executeUpgrade() external override onlyOwner {
    _requireTimelockReady(pendingUpgradeTimestamp);
    address impl = pendingImplementation;
    emit IE.UpgradeExecuted(impl);
    // upgradeToAndCall -> _authorizeUpgrade reads pendingImplementation, so clear AFTER the call.
    upgradeToAndCall(impl, "");
    pendingUpgradeTimestamp = 0;
    pendingImplementation = address(0);
}
```

The comment explains this is intentional: `_authorizeUpgrade` reads `pendingImplementation` for validation, so it must be set during the call. After `upgradeToAndCall` completes, the implementation has changed but the proxy's storage still holds the old `pendingImplementation` and `pendingUpgradeTimestamp` values.

If the new implementation's `executeUpgrade` or `_authorizeUpgrade` logic differs (e.g., does not check `pendingImplementation`), those stale storage values could be misinterpreted. However, `upgradeToAndCall(impl, "")` passes empty calldata, so no initialization runs in the new implementation context within this call. The lines after `upgradeToAndCall` execute in the NEW implementation's code context (since the proxy now points to the new implementation). If the new implementation removed those storage variables or changed their meaning, the cleanup lines could write to unexpected slots.

In practice this is low risk because:
1. The new implementation must be proposed 7 days in advance.
2. Both old and new implementations should maintain the same storage layout (UUPS requirement).
3. The comment indicates awareness of the ordering constraint.

**Impact**:
- If a new implementation does not preserve the storage layout for `pendingUpgradeTimestamp` and `pendingImplementation`, the cleanup writes could corrupt storage.
- If the new implementation has a different `_authorizeUpgrade` that doesn't check `pendingImplementation`, a direct call to `upgradeToAndCall` could bypass the timelock.

**Evidence**:
[CODE] CoveredVaultAdmin.sol:L141-149 — Cleanup lines execute after proxy implementation has changed.
[CODE] CoveredVaultAdmin.sol:L153-159 — `_authorizeUpgrade` validates `newImplementation == pendingImplementation`.

### Postcondition Analysis
**Postconditions Created**: After upgrade, new implementation code runs but stale pending state may remain if cleanup fails.
**Postcondition Types**: [STATE]
**Who Benefits**: Attacker if new implementation has weaker upgrade auth; otherwise benign.

---

## Finding [AC-9]: PremiumManager approveSpender Allows Arbitrary ERC-20 Approvals

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5,6 | ✗6b(no Slither available)
**Rules Applied**: [R6:✗(FULLY_TRUSTED role), R10:✓, R12:✗(no dangerous precondition), R13:✗(not design-related)]
**Severity**: Informational
**Location**: PremiumManager.sol:L102-114

**Description**:
The `approveSpender` function in PremiumManager allows DEFAULT_ADMIN_ROLE to approve any ERC-20 token held by PremiumManager to any spender for any amount. This is a wide-open approval function:

```solidity
function approveSpender(address token, address spender, uint256 amount)
    external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(token != address(0) && spender != address(0), ZeroAddress());
    IERC20(token).forceApprove(spender, amount);
    emit SpenderApproved(token, spender, amount);
}
```

While this is restricted to DEFAULT_ADMIN_ROLE (FULLY_TRUSTED), it enables the admin to grant unlimited approvals on any tokens held by PremiumManager. The intended use is for SSPRouter integration (per design_context.md: "SSPRouter pulls restaker share from PremiumManager via pre-set approval"). However, the function is not scoped to SSPRouter specifically.

This is informational because DEFAULT_ADMIN_ROLE is FULLY_TRUSTED and already has upgrade capability.

**Evidence**:
[CODE] PremiumManager.sol:L102-114 — Unrestricted approval function.

---

## Step Execution Checklist

| Step | Required | Completed? | Notes |
|------|----------|------------|-------|
| 1. Inventory Role Permissions | YES | ✓ | Full capability matrix above |
| 2. Analyze Within-Scope Abuse | YES | ✓ | Curator setPremiumDefaulted, claim approval gate, morphoGateActive |
| 3. Model Attack Scenarios (A,B,C) | YES | ✓ | Scenarios modeled in AC-2, AC-3, AC-4 |
| 4. Assess Mitigations | YES | ✓ | Timelocks, whitelist, two-step transfers assessed |
| 5. Model User-Side Exploitation (D,E,F) | YES | ✓ | Users cannot exploit roles; roles are admin-only, no predictable timing |
| 6. Precondition Griefability Check | YES | ✓ | Assessed per finding |
| 6b. Admin Function Griefability | YES | Partial | No Slither available; manual enumeration performed |

### User-Side Exploitation Assessment (Step 5)

For the semi-trusted roles in this protocol, user-side exploitation is limited because:

1. **No predictable keeper actions**: Unlike protocols with periodic keeper operations (harvesting, rebalancing), the roles in Coverage are primarily administrative (setters, approvals). There are no time-predictable keeper actions for users to front-run.

2. **distributeBatch is permissionless**: Premium distribution via PremiumCollector is permissionless (anyone can call). This removes the keeper timing attack vector -- there is no role action to front-run.

3. **collectPremium is permissionless**: CoveredVaultWrapper premium collection is also permissionless. No timing exploitation possible.

4. **Griefability of admin functions**: Users cannot manipulate preconditions for most admin functions because they are pure state setters (no balance/threshold preconditions). The exception is `removeVault` in PremiumCollector which requires `shares == 0` -- but this is by design (don't remove vaults with funds).

---

## Chain Summary

| Finding ID | Verdict | Postconditions Created | Postcondition Type | Who Benefits |
|------------|---------|----------------------|-------------------|-------------|
| AC-1 | CONFIRMED | Future pool clones use attacker-controlled implementation/addresses | STATE, ACCESS | Compromised CREATOR_ROLE holder |
| AC-2 | CONFIRMED | All claims blocked for policy; users lose insurance | STATE, ACCESS | Malicious curator |
| AC-3 | CONFIRMED | Claims beyond first blocked until curator acts; race condition for insurance | STATE, ACCESS | First withdrawing user; malicious curator |
| AC-4 | PARTIAL | Stale Morpho value; premium paused; grace period extended | STATE, TIMING | Depositors during gate; owner |
| AC-5 | REFUTED | N/A | N/A | N/A |
| AC-6 | PARTIAL | 24h admin transfer window | ACCESS | N/A |
| AC-7 | CONFIRMED | Pending proposals cleared on transfer (positive) | STATE | Users (defensive design) |
| AC-8 | CONFIRMED | Post-upgrade stale pending state | STATE | Attacker if new impl has weaker auth |
| AC-9 | CONFIRMED | Arbitrary ERC-20 approvals by admin | ACCESS | Compromised admin |
