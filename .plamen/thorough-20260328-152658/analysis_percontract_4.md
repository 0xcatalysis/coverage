# Per-Contract Analysis #4: PremiumCollector + PremiumManager + SpecRegistry

**Scope**: PremiumCollector.sol, PremiumManager.sol, SpecRegistry.sol
**Agent**: PC4
**Date**: 2026-03-28

---

## Finding [PC4-1]: Stale Approval Persists on Old RewardsManager After `setRewardsManager` Update

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5 | ✗6(no bidirectional role in this finding) | ✓7
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single entity flow), R6:✗(no bidirectional role), R8:✓, R10:✓, R11:✓, R12:✓, R13:✗(not design-related), R14:✗(no aggregate variables), R15:✗(no flash-loan-accessible state), R16:✗(no oracle dependency)]
**Depth Evidence**: [TRACE:setRewardsManager(newAddr)→old approval(type(uint256).max) NOT revoked→old addr retains pull access], [BOUNDARY:approval=type(uint256).max persists after setRewardsManager], [VARIATION:old rewardsManager changed→old unlimited allowance remains active]
**Severity**: Medium
**Location**: PremiumManager.sol:93-97, PremiumManager.sol:102-113

**Description**:
`PremiumManager.setRewardsManager()` replaces the `rewardsManager` address with no effect on the ERC20 token approval previously granted to the old address via `approveSpender()`. If the old `rewardsManager` was approved with `type(uint256).max` (unlimited allowance), it retains the ability to call `transferFrom(premiumManager, ..., any_amount)` on any approved tokens indefinitely after being replaced. Since `approveSpender` uses `forceApprove` which can set unlimited allowances, this creates a persistent token drain vector against the old address.

```solidity
// PremiumManager.sol:93-97
function setRewardsManager(address rewardsManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(rewardsManager_ != address(0), ZeroAddress());
    rewardsManager = rewardsManager_;
    emit RewardsManagerSet(rewardsManager_);
    // ❌ No revocation of approval granted to previous rewardsManager address
}

// PremiumManager.sol:102-113
function approveSpender(address token, address spender, uint256 amount) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(token != address(0) && spender != address(0), ZeroAddress());
    IERC20(token).forceApprove(spender, amount);   // can be type(uint256).max
    emit SpenderApproved(token, spender, amount);
}
```

The `distributeRewards` pull model requires that PremiumManager pre-approves RewardsManager via `approveSpender`. When `setRewardsManager` is called, no cleanup of the prior approval occurs. The old address retains its approved allowance until the admin manually calls `approveSpender(token, oldRewardsManager, 0)`.

**Impact**:
- If the old `rewardsManager` is a compromised or upgraded contract, it can drain all tokens currently held by PremiumManager (including `restakerSplit` amounts pending distribution) up to the approved allowance.
- In the common case where `type(uint256).max` was approved, the entire token balance of PremiumManager can be extracted by the old address.
- This applies to every token type ever approved — not limited to the most recent distribution token.

**Evidence**:
```solidity
// No approval revocation in setRewardsManager
function setRewardsManager(address rewardsManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(rewardsManager_ != address(0), ZeroAddress());
    rewardsManager = rewardsManager_;         // old approval silently persists
    emit RewardsManagerSet(rewardsManager_);
}
```

### Postcondition Analysis
**Postconditions Created**: Old rewardsManager address retains active ERC20 allowance for PremiumManager's token balances
**Postcondition Types**: [ACCESS, BALANCE]
**Who Benefits**: Attacker who controls the deprecated rewardsManager address

---

## Finding [PC4-2]: `poolFeeBps` Read Live at Distribution Time Enables Retroactive Fee Increase on Accrued Premium

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear, semi-trusted role behavior within permissions), R5:✗(single pool), R6:✓, R8:✓, R10:✓, R11:✗(no unsolicited transfers), R12:✓, R13:✓, R14:✗(no aggregate variables), R15:✗(no flash-loan state), R16:✗(no oracle)]
**Depth Evidence**: [TRACE:vault accrues 24h of shares→curator calls setPoolFeeBps(2000) before distributeBatch→poolSplit takes 20% of full 24h premium→restakerSplit reduced by ~20%], [VARIATION:poolFeeBps 0→2000 right before distribution→restakerSplit reduced by 2000bps on full period's premium], [BOUNDARY:poolFeeBps=2000(MAX)→restakerSplit = grossPremium*(10000-platformFeeBps-2000)/10000]
**Severity**: Medium
**Location**: PremiumManager.sol:154, CoverPool.sol:123-130

**Description**:
`PremiumManager.distributePremium()` fetches `poolFeeBps` live from the CoverPool at the moment of distribution (line 154: `uint16 poolFeeBps = ICoverPool(pool).poolFeeBps()`). However, premiums accumulate as ERC-4626 vault shares over the entire distribution interval (default 24 hours). The fee rate applicable to the accrued premium is the rate AT DISTRIBUTION TIME, not at accrual time.

A pool curator can call `CoverPool.setPoolFeeBps(2000)` (maximum 20%) just before `distributeBatch` is triggered, retroactively applying the increased fee to the full 24-hour premium that accrued during a period when a lower fee was in effect. After distribution completes, the curator can reduce the fee back to its original value.

```solidity
// PremiumManager.sol:154 — live read at distribution time
uint16 poolFeeBps = ICoverPool(pool).poolFeeBps();

// PremiumManager.sol:162-163 — computed on the full `amount` at current rate
(uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
    getFeeSplits(amount, platformFeeBps, poolFeeBps);

// CoverPool.sol:123-130 — curator can change fee any time, no delay
function setPoolFeeBps(uint16 poolFeeBps_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(poolFeeBps_ <= _MAX_POOL_FEE_BPS, InvalidFeeBps());
    poolFeeBps = poolFeeBps_;
    emit PoolFeeBpsSet(previousPoolFeeBps, poolFeeBps_);
}
```

The `_MAX_POOL_FEE_BPS = 2000` (20%) cap limits the maximum extraction per distribution to 20% of gross premium. For a vault generating $100k in premium per distribution period, a curator could extract up to $20k more than expected in a single distribution.

**Impact**:
- Restakers receive less premium than was implied by the fee rate during the accrual period.
- A curator operating in bad faith can consistently inflate their take-rate without protocol-level enforcement of fee stability across distribution windows.
- The fee is presented to restakers as a fixed or known rate, but the actual effective rate is determined unilaterally at distribution time with no lock-in period.
- Maximum additional extraction per distribution: `grossPremium × (maxPoolFeeBps - originalPoolFeeBps) / 10000`.

**Evidence**:
```solidity
// Attacker flow:
// T=0: vault registered, curator sets poolFeeBps=0 (attractive to restakers)
// T=0 to T=86399: premium accrues at implied 0% pool fee
// T=86399: curator calls setPoolFeeBps(2000)  — takes effect immediately, no timelock
// T=86400: keeper calls distributeBatch
// Result: distributeRewards receives 20% less than restakers expected
```

### Postcondition Analysis
**Postconditions Created**: Restaker split is systematically underpaid relative to the fee rate in effect during the accrual period
**Postcondition Types**: [STATE, BALANCE]
**Who Benefits**: Pool curator extracting excess pool fee from restakers

---

## Finding [PC4-3]: `updateVault` Missing `nonReentrant` While External Calls in `_distribute` Can Reach It

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4 | ✗5(N/A — requires malicious vault/premiumManager which is admin-controlled)
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single vault), R6:✓, R8:✓, R10:✓, R11:✗(no unsolicited tokens), R12:✗(no dangerous precondition), R13:✗(not design-related), R14:✗(no aggregate variables), R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [TRACE:distributeBatch→_distribute(vault)→IERC4626(vault).redeem()→vault.redeem re-enters→updateVault(vault, newPool, newPolicyId)→execution returns→distributePremium(newPool, newPolicyId, ...)], [BOUNDARY:vault.redeem() calls back updateVault before line 293→distributes to newPool/policyId instead of old config]
**Severity**: Low
**Location**: PremiumCollector.sol:147-158 (`updateVault`), PremiumCollector.sol:283, 293

**Description**:
`PremiumCollector.registerVault` and `removeVault` are both guarded with `nonReentrant`, but `updateVault` is not:

```solidity
// registerVault: nonReentrant onlyRole(DEFAULT_ADMIN_ROLE)
// removeVault:   nonReentrant onlyRole(DEFAULT_ADMIN_ROLE)
// updateVault:   onlyRole(DEFAULT_ADMIN_ROLE)  — missing nonReentrant
function updateVault(address vault, address pool, uint96 policyId) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    // ... changes config.pool and config.policyId
}
```

`distributeBatch` is `nonReentrant`, which blocks re-entry into `distributeBatch` itself. However, `_distribute` makes external calls to:
1. L276: `IERC4626(vault).balanceOf(address(this))`
2. L283: `IERC4626(vault).redeem(shares, address(this), address(this))`
3. L290: `IERC20(config.underlying).safeTransfer(premiumManager, assets)`
4. L293: `IPremiumManager(premiumManager).distributePremium(...)`

Calls 2, 3, and 4 are external calls that could re-enter `updateVault` (since it lacks a reentrancy guard and the admin role could be granted to a smart contract). Specifically: if the vault's `redeem` implementation or the premiumManager's callback re-enters `updateVault`, it can change `config.pool` and `config.policyId` between the moment `lastDistributeTime` is written (L289) and the `distributePremium` call (L293).

The consequence is that the distribution at L293 uses the **new** `pool` and `policyId` values (read from `config` in L293 via `config.pool`, `config.policyId`), but the amount was determined based on the old vault state. The distribution is effectively redirected to a different pool mid-flight.

Note: This requires that the DEFAULT_ADMIN_ROLE is granted to a contract capable of performing the re-entry, or that the vault/premiumManager is a controlled malicious contract — both of which represent admin-level trust violations. Likelihood is low in practice.

**Impact**:
- Premium distribution for a vault can be redirected to an unintended pool/policyId within a single transaction.
- `lastDistributeTime` is permanently updated but the funds were distributed to a different destination than configured at the start of `_distribute`.
- The inconsistency is not detectable from the emitted `Distributed` event (which only logs vault, shares, and assets — not pool or policyId).

**Evidence**:
```solidity
function _distribute(address vault) private {
    VaultConfig storage config = _vaultConfigs[vault];
    // ...
    uint256 assets = IERC4626(vault).redeem(shares, address(this), address(this));
    // ↑ external call — vault can re-enter updateVault(vault, attackerPool, attackerPolicyId)

    config.lastDistributeTime = uint32(block.timestamp);
    IERC20(config.underlying).safeTransfer(premiumManager, assets);

    IPremiumManager(premiumManager).distributePremium(config.pool, config.policyId, ...);
    // ↑ config.pool and config.policyId now read AFTER possible re-entrant updateVault
}
```

### Postcondition Analysis
**Postconditions Created**: Distribution directed to attacker-controlled pool/policyId; `lastDistributeTime` updated with no record of redirection
**Postcondition Types**: [STATE, BALANCE]
**Who Benefits**: Attacker controlling a malicious vault or operating as admin

---

## Finding [PC4-4]: `PremiumCollector` Caches Vault Underlying at Registration — Mismatch Causes Wrong Token Transfer

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3 | ✗4(N/A for standard ERC-4626 vaults) | ✓5
**Rules Applied**: [R4:✗(evidence clear for non-compliant path), R5:✗(single vault), R6:✗(no bidirectional role), R8:✓, R10:✓, R11:✓, R12:✓, R13:✗(not design-related), R14:✗(no aggregate variables), R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [TRACE:registerVault(vault,pool,policyId)→underlying=vault.asset() cached→vault.asset() changes→_distribute→redeem sends new_token to PremiumCollector→safeTransfer(old_underlying, premiumManager, assets)→wrong token drained from PremiumCollector], [BOUNDARY:config.underlying=tokenA, vault.asset()=tokenB after change→PremiumCollector sends tokenA (which it may not have) to PremiumManager]
**Severity**: Low
**Location**: PremiumCollector.sol:105-108 (registration), PremiumCollector.sol:283-290 (distribution)

**Description**:
`registerVault` caches `underlying = IERC4626(vault).asset()` at registration time and stores it in `VaultConfig.underlying`. During distribution in `_distribute`, the redeemed assets arrive at `address(this)` from `IERC4626(vault).redeem(...)`, but the subsequent transfer uses the **cached** `config.underlying` rather than re-querying the vault:

```solidity
// Registration (line 105-108):
address underlying = IERC4626(vault).asset();
_vaultConfigs[vault] = VaultConfig({
    underlying: underlying, ...
});

// Distribution (lines 283-290):
uint256 assets = IERC4626(vault).redeem(shares, address(this), address(this));
// ↑ Vault sends tokens of vault.asset() (current) to address(this)

config.lastDistributeTime = uint32(block.timestamp);
IERC20(config.underlying).safeTransfer(premiumManager, assets);
// ↑ Sends config.underlying (CACHED) — not necessarily current vault.asset()
```

If the vault's `asset()` return value changes (possible for non-standard or upgradeable vaults, or vaults with asset migration logic), the two token addresses diverge:
- `redeem` sends `newToken` to PremiumCollector
- `safeTransfer` attempts to send `oldToken` (cached `config.underlying`) with `assets` amount

This would send `oldToken` from PremiumCollector's balance to PremiumManager (potentially draining another vault's accumulated tokens), while `newToken` accumulates indefinitely in PremiumCollector with no distribution path.

For standard ERC-4626 vaults with immutable `asset()`, this path is not reachable. However, PremiumCollector's `registerVault` accepts any address that returns a non-zero `asset()` — there is no validation that the vault is a legitimate or immutable-asset ERC-4626.

**Impact**:
- Tokens from one vault's distribution are incorrectly sent to PremiumManager as another vault's premium.
- `newToken` accumulates in PremiumCollector with no withdrawal path (no `rescueToken` or sweep function exists).
- Cross-contamination between vault distributions in a multi-vault `distributeBatch` call.

### Precondition Analysis
**Missing Precondition**: Vault's `asset()` must change after registration (requires non-standard vault)
**Precondition Type**: EXTERNAL
**Why This Blocks**: Standard ERC-4626 vaults have an immutable asset; this path only triggers for upgradeable or non-compliant vaults registered by admin

### Postcondition Analysis
**Postconditions Created**: Wrong token transferred to PremiumManager; new asset token stranded in PremiumCollector
**Postcondition Types**: [BALANCE, STATE]
**Who Benefits**: No clear beneficiary; results in accounting corruption

---

## Chain Summary

| Finding | Severity | Verdict | Can Enable Another Finding? | Postcondition Type |
|---------|----------|---------|-----------------------------|--------------------|
| PC4-1 | Medium | CONFIRMED | YES — old rewardsManager allowance enables token drain | BALANCE, ACCESS |
| PC4-2 | Medium | CONFIRMED | YES — curator can reduce restakerSplit right before distribution | BALANCE, STATE |
| PC4-3 | Low | CONFIRMED | YES — misdirected distribution (admin-controlled precondition) | STATE, BALANCE |
| PC4-4 | Low | PARTIAL | YES — cross-vault token contamination (non-standard vault precondition) | BALANCE, STATE |
