# Blind Spot Scanner C Findings

**Scanner**: Blind Spot Scanner C — Role Lifecycle, Capability Exposure & Reachability
**Scope**: PremiumCollector.sol, PremiumManager.sol, Swapper.sol, adapters/UniswapV3Adapter.sol
**Checks Run**: CHECK 6 (Role Lifecycle), CHECK 7 (Inherited Capability Exposure), CHECK 8 (Function Reachability)

---

## CHECK 6: Role Lifecycle Completeness

| Role | Contract | Grant Function | Revoke Function | Revoke Exists? | Circular Dependency? | Finding? |
|------|----------|----------------|-----------------|----------------|---------------------|----------|
| DEFAULT_ADMIN_ROLE | PremiumCollector | initialize (via _grantRole) | grantRole/revokeRole (OZ inherited) | YES | NO | None |
| DEFAULT_ADMIN_ROLE | PremiumManager | initialize (via _grantRole) | grantRole/revokeRole (OZ inherited) | YES | NO | None |
| PREMIUM_COLLECTOR_ROLE | PremiumManager | NOT granted in initialize — must be granted separately via grantRole() | revokeRole (OZ inherited) | YES | NO | **BLIND-C-2** (see below) |
| DEFAULT_ADMIN_ROLE | Swapper | initialize (via _grantRole) | grantRole/revokeRole (OZ inherited) | YES | NO | None |
| SWAP_MANAGER_ROLE | Swapper | initialize (via _grantRole) | revokeRole (OZ inherited) | YES | NO | None |
| SWAP_EXECUTOR_ROLE | Swapper | initialize (via _grantRole) | revokeRole (OZ inherited) | YES | NO | None |
| Owner | UniswapV3Adapter | constructor (Ownable2Step) | renounceOwnership() — NOT overridden | Via renounceOwnership — IRREVERSIBLE | NO | **BLIND-C-1** (see below) |

---

## CHECK 7: Inherited Capability Exposure Gaps

| Base Contract | Internal Function | Purpose | Called by Any In-Scope Function? | Externally Reachable? | Gap? |
|---------------|------------------|---------|----------------------------------|----------------------|------|
| Ownable (UniswapV3Adapter) | renounceOwnership() | Permanently surrender ownership | Not called internally | YES (public, onlyOwner) | YES — BLIND-C-1 |
| PausableUpgradeable (PremiumCollector) | _pause / _unpause | Pause state management | YES — exposed via pause()/unpause() | YES | None |
| PausableUpgradeable (PremiumManager) | _pause / _unpause | Pause state management | YES — exposed via pause()/unpause() | YES | None |
| AccessControlUpgradeable (PremiumManager) | grantRole/revokeRole | Role management | YES — inherited publicly | YES | PREMIUM_COLLECTOR_ROLE not set at init (BLIND-C-2) |
| UUPSUpgradeable (PremiumCollector, PremiumManager, Swapper) | _authorizeUpgrade | Upgrade gate | YES — exposed via _authorizeUpgrade override | YES (via upgradeToAndCall) | None |
| PremiumCollector | recoverTokens | Token recovery | NOT EXPOSED | NO | BLIND-C-4 (informational) |

---

## CHECK 8: Function Reachability Audit

| Function | Contract | Called By (internal) | Called By (external/test) | Reachable in Production? | Dead Code? |
|----------|----------|---------------------|--------------------------|-------------------------|------------|
| UniswapV3Adapter.swap() | UniswapV3Adapter | No | Swapper via low-level call() using stored calldata | YES — via Swapper._performSwap | No (but: SWAPPER immutable — see below) |
| UniswapV3Adapter.quote() | UniswapV3Adapter | No | Swapper.quoteSwap() or direct calls | YES | No |
| UniswapV3Adapter.setPairFee() | UniswapV3Adapter | No | Owner directly | YES — BUT permanently unreachable if owner calls renounceOwnership() | BLIND-C-1 |
| PremiumManager.distributePremium() | PremiumManager | No | PremiumCollector (requires PREMIUM_COLLECTOR_ROLE) | Only after admin grants PREMIUM_COLLECTOR_ROLE post-deploy | BLIND-C-2 |
| Swapper.setNativeWrapper() | Swapper | No | Admin (DEFAULT_ADMIN_ROLE) | YES — but old routes remain live post-change | BLIND-C-3 |
| PremiumCollector.getDistributableVaults() | PremiumCollector | No | Keeper bots (view) | YES | No |

---

## Finding [BLIND-C-1]: UniswapV3Adapter Does Not Override renounceOwnership — Fee-Tier Configurability Can Be Permanently Destroyed

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3 | ✗4(N/A — no external actor involvement beyond owner) | ✗5(N/A — single entity)
**Rules Applied**: [R6:✓, R8:✗(single-step setter), R10:✓, R12:✓, R13:✓, R14:✗(no aggregate)]
**Depth Evidence**: [TRACE:owner calls renounceOwnership() → _owner=address(0) → setPairFee() reverts on onlyOwner → fee tiers permanently frozen]
**Severity**: Medium
**Location**: `adapters/UniswapV3Adapter.sol:116` (setPairFee), `lib/openzeppelin-contracts/contracts/access/Ownable.sol:76` (renounceOwnership)
**Description**: `UniswapV3Adapter` inherits `Ownable2Step → Ownable` and does NOT override `renounceOwnership()`. The inherited `renounceOwnership()` function (public, onlyOwner) sets `_owner = address(0)` irreversibly. After renouncement, the `onlyOwner` modifier on `setPairFee()` permanently reverts. Since `SWAP_ROUTER`, `SWAPPER`, and `QUOTER` are all immutable and the contract is not upgradeable, there is no recovery path — the adapter must be entirely redeployed and the Swapper route reconfigured.

The immediate consequence is that fee tiers become permanently frozen. Uniswap V3 has four fee tiers (0.01%, 0.05%, 0.3%, 1%). A misconfigured or frozen fee tier means swaps execute on the wrong pool, which can result in significantly worse execution for claim collateral swaps. This compounds the existing PC3-2 finding (fee-tier desync between `quote()` and `swap()` calldata) — renouncing ownership removes the admin's ability to correct that desync.

**Impact**:
- `setPairFee()` becomes permanently unreachable (function reachability destroyed)
- All future claim swaps through this adapter execute on the DEFAULT_FEE (3000 = 0.3%) pool regardless of market conditions or better-liquidity pool tiers
- Worsens PC3-2 impact: fee-tier desync between `pairFees` mapping (used by `quote`) and static calldata fee (used by `swap`) cannot be resolved after renouncement
- Must redeploy adapter + update Swapper route to restore functionality
**Evidence**:
```solidity
// UniswapV3Adapter.sol:116 — only protected function
function setPairFee(address tokenIn, address tokenOut, uint24 fee) external onlyOwner {
    bytes32 key = keccak256(abi.encodePacked(tokenIn, tokenOut));
    pairFees[key] = fee;
    emit PairFeeSet(tokenIn, tokenOut, fee);
}

// Ownable.sol:76 — inherited, NOT overridden in UniswapV3Adapter
function renounceOwnership() public virtual onlyOwner {
    _transferOwnership(address(0));  // irreversible
}

// UniswapV3Adapter.sol:57-65 — all immutable, no upgrade path
address public immutable SWAPPER;
IV3SwapRouter public immutable SWAP_ROUTER;
IQuoterV2 public immutable QUOTER;
```

### Postcondition Analysis (CONFIRMED)
**Postconditions Created**: After `renounceOwnership()` — `_owner = address(0)` state permanently set, `setPairFee()` permanently unreachable
**Postcondition Types**: STATE (immutable ownership null), ACCESS (onlyOwner permanently reverts)
**Who Benefits**: No one benefits — this is an admin error enabling class. A social engineering attack that convinces the owner to renounce would achieve this.

---

## Finding [BLIND-C-2]: PREMIUM_COLLECTOR_ROLE Not Granted During PremiumManager Initialization — Silent Distribution Failure on Deployment

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3 | ✗4(N/A — access control gap, not actor manipulation) | ✗5(N/A — single entity)
**Rules Applied**: [R6:✗(FULLY_TRUSTED deployer — oversight, not malice), R8:✗(single-step), R10:✓, R12:✗(no dangerous precondition), R13:✓]
**Severity**: Low
**Location**: `PremiumManager.sol:54-74` (initialize), `PremiumManager.sol:147` (distributePremium — PREMIUM_COLLECTOR_ROLE gate)
**Description**: `PremiumManager.initialize()` grants only `DEFAULT_ADMIN_ROLE` to the `admin_` parameter. `PREMIUM_COLLECTOR_ROLE`, which is required by `distributePremium()`, is never granted during initialization. The admin must separately call `grantRole(PREMIUM_COLLECTOR_ROLE, premiumCollector)` after deployment. If this step is omitted — a realistic deployment oversight — all premium distributions will silently fail with `AccessControlUnauthorizedAccount`, causing PremiumCollector to accumulate vault shares indefinitely.

This is a deployment lifecycle gap: the role that connects the two contracts (PremiumCollector → PremiumManager) has no on-chain initialization path. There is no deployment-time assertion that PREMIUM_COLLECTOR_ROLE is set correctly, no event from `initialize()` that could alert monitoring systems, and the symptom (accumulated shares, no distribution) may not be caught immediately in production.

**Impact**:
- If `PREMIUM_COLLECTOR_ROLE` not granted: `distributePremium()` reverts for ALL calls from PremiumCollector
- PremiumCollector accumulates vault shares indefinitely — shares not redeemed, premiums not distributed to platform/pool/restakers
- Restakers receive zero premium payments for active policies
- No on-chain indication of the missing grant — operational monitoring required
**Evidence**:
```solidity
// PremiumManager.sol:54-74 — initialize grants DEFAULT_ADMIN_ROLE only
function initialize(address admin_, address rewardsManager_, address platformTreasury_, uint16 platformFeeBps_)
    external initializer
{
    // ...
    _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    // PREMIUM_COLLECTOR_ROLE is NEVER granted here
}

// PremiumManager.sol:144-148 — distributePremium requires PREMIUM_COLLECTOR_ROLE
function distributePremium(...) external override nonReentrant whenNotPaused onlyRole(PREMIUM_COLLECTOR_ROLE) {
    // ...
}

// Role defined but no grant path in initialize
bytes32 public constant override PREMIUM_COLLECTOR_ROLE = keccak256("PREMIUM_COLLECTOR_ROLE");
```

### Postcondition Analysis (CONFIRMED)
**Postconditions Created**: Until role is granted — all `distributePremium()` calls from PremiumCollector revert; vault shares accumulate
**Postcondition Types**: ACCESS (missing role), STATE (accumulated shares), TIMING (delayed premium flow)
**Who Benefits**: No actor — this is an operational failure mode

---

## Finding [BLIND-C-3]: Swapper.setNativeWrapper Does Not Disable Old Native Routes — Stale ERC20 Routes Remain Executable After Wrapper Change

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3 | ✗4(N/A — role-constrained executor) | ✓5
**Rules Applied**: [R6:✓, R8:✓, R10:✓, R12:✗(no dangerous precondition for attacker), R13:✓, R14:✗(no aggregate)]
**Depth Evidence**: [TRACE:setNativeWrapper(newWETH) → old routes key(oldWETH,tokenOut) still enabled → executeSwap(oldWETH,tokenOut) uses stale route with old wrapper context] [VARIATION:tokenIn=oldWETH (ERC20 path) vs tokenIn=NATIVE_ETH → different route lookup → stale route reachable via ERC20 path]
**Severity**: Low
**Location**: `Swapper.sol:123-127` (setNativeWrapper), `Swapper.sol:231-240` (executeSwap route resolution)
**Description**: `Swapper.setNativeWrapper()` requires `whenPaused` (to give the admin time to reconfigure routes), but it does NOT disable or invalidate routes that were configured using the old `nativeWrapper` address. Routes are stored keyed by `keccak256(tokenIn, tokenOut)` where `tokenIn` for native ETH swaps is the old WETH address. After changing `nativeWrapper`:

1. `executeSwap(tokenIn=NATIVE_ETH, ...)` resolves `actualTokenIn = newWETH`, looks up key(newWETH, tokenOut) — fails with `SwapRouteNotEnabled` if no new route exists. Safe.
2. `executeSwap(tokenIn=oldWETH, ...)` (using old WETH address directly as ERC20 input) resolves `actualTokenIn = oldWETH` (not NATIVE_ETH, so no resolution), looks up key(oldWETH, tokenOut) — **the old route is still enabled** and will execute.

Since `SWAP_EXECUTOR_ROLE` is held by ClaimManager, and ClaimManager may internally reference stale WETH addresses when processing slashed collateral from SlashingManager, this creates a realistic path where swaps are executed through stale routes after a nativeWrapper migration.

The documentation acknowledges the need to reconfigure routes post-change, but provides no on-chain mechanism to prevent use of old routes. The `whenPaused` requirement only creates an opportunity window — it does not enforce route hygiene.

**Impact**:
- After `setNativeWrapper(newWETH)`, old WETH-keyed routes remain enabled
- If ClaimManager still holds/processes old WETH during migration, it can call `executeSwap(oldWETH, ...)` through the stale route
- The stale route may point to a swap adapter configured for the old WETH context (e.g., fee tier, route calldata encoded with old WETH address) — causing potentially incorrect swaps or failed adapter calls
- Risk is bounded by `SWAP_EXECUTOR_ROLE` restriction (only ClaimManager) and the `whenPaused` requirement giving admin an intervention window
**Evidence**:
```solidity
// Swapper.sol:123-127 — requires whenPaused, but does NOT disable old routes
function setNativeWrapper(address wrapper) external override onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
    require(wrapper != address(0), ZeroAddress());
    nativeWrapper = wrapper;
    emit NativeWrapperSet(wrapper);
    // No route invalidation — old routes keyed by old WETH address remain enabled
}

// Swapper.sol:231-234 — NATIVE_ETH resolves to current nativeWrapper, but ERC20 path bypasses resolution
address actualTokenIn = params.tokenIn == NATIVE_ETH ? nativeWrapper : params.tokenIn;
// If tokenIn = oldWETH (ERC20 path), actualTokenIn = oldWETH — old route is still found
```

### Postcondition Analysis (CONFIRMED)
**Postconditions Created**: After `setNativeWrapper()` — new wrapper resolves for NATIVE_ETH path; old routes remain enabled for direct ERC20 path using old WETH address
**Postcondition Types**: STATE (stale routes persist), TIMING (active during migration window)
**Who Benefits**: Only an actor with SWAP_EXECUTOR_ROLE can exploit this — constrained to ClaimManager under normal operation

---

## Finding [BLIND-C-4]: PremiumCollector Has No Token Recovery Function — Stranded Tokens Are Unrecoverable

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3 | ✗4(N/A — no actor manipulation needed) | ✗5(N/A)
**Rules Applied**: [R6:✗(FULLY_TRUSTED admin circumstance), R8:✗(single-step), R10:✓, R12:✗, R13:✓]
**Severity**: Informational
**Location**: `PremiumCollector.sol` (entire contract — missing function)
**Description**: `PremiumCollector` is the only UUPS proxy contract in the system that does not expose a `recoverTokens()` function. All other UUPS contracts in scope (`ClaimManager`, `Swapper`) implement token recovery. PremiumCollector regularly holds ERC-4626 vault shares (accrued between collection cycles) and transiently holds underlying ERC-20 tokens during the `_distribute()` execution path (between `vault.redeem()` and `safeTransfer(premiumManager, assets)`).

If underlying tokens are accidentally sent to PremiumCollector, or if a partial state occurs where tokens arrive but cannot be forwarded (e.g., due to PremiumManager being paused at an inopportune moment — though this is mitigated by reverting the whole tx), they cannot be recovered by admin.

Breadth agents likely missed this because `PremiumCollector` does hold vault shares (which are expected to accumulate) and the recovery gap only manifests with direct/accidental token sends, not during normal operation.

**Impact**:
- Underlying ERC-20 tokens accidentally sent to PremiumCollector cannot be recovered by any role
- Vault shares that exceed the `shares == 0` removal guard (removeVault) could be stranded if a vault is deregistered with non-zero balances — but this is already blocked by `VaultHasShares` error
- Protocol inconsistency: all sibling UUPS contracts expose recovery; PremiumCollector does not
**Evidence**:
```solidity
// PremiumCollector.sol — no recoverTokens or rescue function anywhere
// Compare with Swapper.sol:132-141 which provides:
function recoverTokens(address token, address to, uint256 amount) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(token != address(0) && to != address(0), ZeroAddress());
    require(amount != 0, ZeroAmount());
    if (token == NATIVE_ETH) {
        payable(to).sendValue(amount);
    } else {
        IERC20(token).safeTransfer(to, amount);
    }
}
```

---

## Chain Summary

| Finding ID | Location | Root Cause (1-line) | Verdict | Severity | Precondition Type | Postcondition Type |
|------------|----------|---------------------|---------|----------|-------------------|-------------------|
| BLIND-C-1 | UniswapV3Adapter.sol:116, Ownable.sol:76 | renounceOwnership() not overridden in UniswapV3Adapter; owner can permanently destroy setPairFee() reachability | CONFIRMED | Medium | ACCESS | STATE, ACCESS |
| BLIND-C-2 | PremiumManager.sol:54-74, 147 | PREMIUM_COLLECTOR_ROLE not granted in PremiumManager.initialize(); admin must grant it separately or all distributions silently fail | CONFIRMED | Low | ACCESS | STATE, TIMING |
| BLIND-C-3 | Swapper.sol:123-127, 231-234 | setNativeWrapper() changes wrapper but does not disable old WETH-keyed routes; stale routes remain executable via ERC20 path | CONFIRMED | Low | STATE | STATE, EXTERNAL |
| BLIND-C-4 | PremiumCollector.sol (missing) | No recoverTokens() on PremiumCollector despite all sibling UUPS contracts having one; stranded tokens unrecoverable | CONFIRMED | Informational | EXTERNAL | BALANCE |
