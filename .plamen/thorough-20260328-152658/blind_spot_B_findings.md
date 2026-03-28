# Blind Spot Scanner B: Guards, Visibility & Inheritance
## CoveredVaultWrapper Protocol — In-Scope: CoverPool, CoverPoolFactory, PolicyManager, ClaimManager, SpecRegistry

> Scanner B checks: CHECK 3 (Admin Function Griefability), CHECK 4 (Permissionless Visibility), CHECK 5 (Inherited Capability Completeness), CHECK 5b (Override Safety)

---

## CHECK 3: Admin Function Griefability Analysis

| Admin Function | Preconditions | User-Manipulable? | Analyzed by Agent? | Finding ID |
|----------------|---------------|-------------------|-------------------|------------|
| CoverPool.bindPolicyForRequest | draft.status==Created, quote.startTime>=block.timestamp | Buyer can cancel draft (covered PC2-1) | YES | PC2-1 |
| CoverPool.setPremiumDefaulted | boundPolicies[policyId].policyId != 0 | No - policy existence not user-manipulable | YES | AC-2 |
| PolicyManager.requestCoverage | coverPoolExists(pool), supportedPayoutTokens[payoutToken] | No — whitelist admin-controlled | YES | — |
| ClaimManager.approveNextClaim | metadata.buyer != 0, msg.sender == pool.owner() | No — ownership check non-manipulable | NO | — |
| SpecRegistry.registerSpec | coverPoolFactory.coverPoolExists(msg.sender), whenNotPaused | SpecRegistry pause blocks registration | PARTIAL | BLIND-B-3 |

No new griefability findings beyond what is covered. The buyer's ability to cancel a draft (blocking bindPolicyForRequest) is covered by PC2-1.

---

## CHECK 4: Permissionless Function Visibility Audit

| Function | Contract | Emits Events? | Modifies State? | Should Be Internal? | Analyzed? |
|----------|----------|---------------|-----------------|---------------------|-----------|
| requestCoverage | PolicyManager | YES (CoverageRequested) | YES | NO — intended entrypoint | YES |
| cancelPolicyDraft | PolicyManager | YES (PolicyDraftCancelled) | YES | NO — buyer-restricted | YES |
| fileClaim | ClaimManager | YES (ClaimFiled/Approved/Rejected) | YES | NO — claimer-restricted | YES |
| approveNextClaim | ClaimManager | YES (NextClaimApproved) | YES | NO — pool owner only | YES (PC3-4) |
| registerSpec | SpecRegistry | YES (SpecRegistered) | YES | NO — CoverPool entrypoint | YES |
| distributeBatch | PremiumCollector | YES | YES | NO — permissionless distribution | YES |

No admin state-changing functions in scope emit NO events. All setters across CoverPool, CoverPoolFactory, PolicyManager, ClaimManager, and SpecRegistry emit events on every state change.

**CHECK 4 SPECIAL: `PolicyManager.setPremiumDefaulted` lacks `whenNotPaused`**

`PolicyManager.setPremiumDefaulted` (L333-340) is callable even when PolicyManager is paused, because it lacks a `whenNotPaused` modifier. The call originates from `CoverPool.setPremiumDefaulted` (onlyRole(DEFAULT_ADMIN_ROLE)), which also has no `whenNotPaused`. This means: during a PolicyManager pause intended to halt new operations, the curator can still mark premiums as defaulted, blocking future `fileClaim` calls (ClaimManager.fileClaim checks `metadata.premiumDefaulted`). This extends AC-2 but is a distinct guard gap. Note: this was already substantively covered by AC-2 (curator blocking claims) — the `whenNotPaused` absence does not create a NEW attack beyond AC-2's scope.

---

## CHECK 5: Inherited Capability Completeness

| Contract | Inherited Base | Capability Provided | Exposure Function Exists? | Finding ID |
|----------|---------------|--------------------|--------------------------:|------------|
| CoverPool | AccessControlDefaultAdminRulesUpgradeable | 2-step admin transfer (beginDefaultAdminTransfer, acceptDefaultAdminTransfer, cancelDefaultAdminTransfer) | YES — inherited, not overridden | — |
| CoverPool | AccessControlDefaultAdminRulesUpgradeable | changeDefaultAdminDelay | YES — inherited, not overridden | — |
| CoverPool | PausableUpgradeable | pause/unpause | YES — exposed as external functions | — |
| CoverPool | EIP712Upgradeable | quoteDomainSeparator (domain separator query) | YES — exposed | — |
| CoverPoolFactory | UUPSUpgradeable | upgradeTo/upgradeToAndCall | YES — through _authorizeUpgrade override | — |
| CoverPoolFactory | AccessControlUpgradeable | grantRole/revokeRole/renounceRole | YES — inherited, no override | BLIND-B-1 |
| PolicyManager | UUPSUpgradeable | upgradeTo/upgradeToAndCall | YES — through _authorizeUpgrade override | — |
| ClaimManager | ReentrancyGuard | _nonReentrantBefore/_nonReentrantAfter (internal) | N/A — internal only | — |
| SpecRegistry | UUPSUpgradeable | upgradeTo/upgradeToAndCall | YES — through _authorizeUpgrade override | — |
| SpecRegistry | AccessControlUpgradeable | setCoverPoolFactory (one-time setter only) | PARTIAL — one-time setter, no update path | BLIND-B-2 |

---

## CHECK 5b: Upward Inheritance — Override Safety

| Base Contract | Virtual Function | Overridden By | Base Modifiers | Override Modifiers | Modifier Dropped? |
|---------------|-----------------|---------------|----------------|-------------------|-------------------|
| AccessControlDefaultAdminRulesUpgradeable | grantRole | CoverPool | _checkRoleAdmin (via AccessControl) | onlyRole(DEFAULT_ADMIN_ROLE) | NO — more restrictive |
| AccessControlDefaultAdminRulesUpgradeable | revokeRole | CoverPool | _checkRoleAdmin (via AccessControl) | onlyRole(DEFAULT_ADMIN_ROLE) | NO — more restrictive |
| PausableUpgradeable | _pause/_unpause | (internal, not overridden) | whenNotPaused/whenPaused | N/A | N/A |
| UUPSUpgradeable | _authorizeUpgrade | CoverPoolFactory, PolicyManager, ClaimManager, SpecRegistry | (none — internal) | onlyRole(DEFAULT_ADMIN_ROLE) | N/A |

No unsafe override patterns found. The CoverPool overrides of `grantRole`/`revokeRole` add a stricter `onlyRole(DEFAULT_ADMIN_ROLE)` requirement which is compatible with (and more explicit than) the base class's `_checkRoleAdmin` behavior.

---

## Findings

---

## Finding [BLIND-B-1]: CoverPoolFactory Uses AccessControlUpgradeable Without 2-Step Admin Transfer, Creating Asymmetric Security Guarantee vs CoverPools It Creates

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,5 | ✗4(N/A - no external price dependencies) | ✗7(N/A - no timing component)
**Rules Applied**: [R6:✓, R8:✗(single-step setter), R10:✓, R12:✗(no dangerous precondition state), R13:✓, R14:✗(no aggregate variables)]
**Severity**: Low
**Location**: `CoverPoolFactory.sol:L45-L73` (initialize), inherited `AccessControlUpgradeable`

**Description**:
`CoverPoolFactory` inherits `AccessControlUpgradeable` and grants `DEFAULT_ADMIN_ROLE` and `CREATOR_ROLE` at initialization. Because it uses `AccessControlUpgradeable` (not `AccessControlDefaultAdminRulesUpgradeable`), the `DEFAULT_ADMIN_ROLE` can be instantly transferred to a new address via `grantRole(DEFAULT_ADMIN_ROLE, newAdmin)` followed by `renounceRole(DEFAULT_ADMIN_ROLE, self)` — with NO delay and NO two-step confirmation.

In contrast, every `CoverPool` instance created by this factory uses `AccessControlDefaultAdminRulesUpgradeable` with a 24-hour admin transfer delay (initialized at `__AccessControlDefaultAdminRules_init(24 hours, curator_)` in `CoverPool.sol:L93`). This delay protects against rapid key compromise.

The factory has EQUAL OR GREATER privilege than any individual CoverPool:
- Factory admin can pause all new pool creation
- Factory admin (via CREATOR_ROLE assignment) can change `coverPoolImplementation` pointing all new pools to malicious code
- Factory admin can change `policyManager`, `stakeManager`, `specRegistry` for all future pools

Yet the factory admin role offers WEAKER key-compromise protection than individual pool admins, creating an inverted security posture: the root of the pool hierarchy is less protected than its leaves.

**Impact**:
- If the factory `DEFAULT_ADMIN_ROLE` key is compromised, attacker can instantly grant themselves the role permanently (before a multisig can react) with zero on-chain notice.
- No `_pending` admin transfer means no cancellation window.
- The factory admin can also grant `CREATOR_ROLE` to self immediately, enabling arbitrary pool creation (including pools with malicious implementation).
- Individual `CoverPool` curators benefit from 24h advance notice of admin changes; factory admin holders do not.

**Evidence**:
```solidity
// CoverPoolFactory.sol:L45-L73 — no 2-step protection
contract CoverPoolFactory is UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuard, ICoverPoolFactory {
    // ...
    _grantRole(DEFAULT_ADMIN_ROLE, admin_);  // instant, no delay
    _grantRole(CREATOR_ROLE, creator_);

// CoverPool.sol:L93 — 2-step, 24h delay
    __AccessControlDefaultAdminRules_init(24 hours, curator_);  // protected
```

**Why breadth agents likely missed this**: The finding requires comparing two separate inheritance hierarchies (factory vs. pool) to detect the security asymmetry. Per-contract breadth analysis would have noted the correct access control usage in each contract individually without comparing them.

---

## Finding [BLIND-B-2]: SpecRegistry.setCoverPoolFactory One-Time Write Creates Permanent Dependency Lock — Factory Re-Deployment Would Break Spec Registration

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3 | ✗4(N/A - no user-facing economic impact) | ✗5(N/A - no reentrancy path)
**Rules Applied**: [R6:✓, R8:✗(single-step), R10:✓, R12:✗(no dangerous precondition), R13:✓, R14:✗(no aggregate variables)]
**Severity**: Low
**Location**: `SpecRegistry.sol:L50-L56` (setCoverPoolFactory), `SpecRegistry.sol:L33-L43` (initialize)

**Description**:
`SpecRegistry.setCoverPoolFactory` can only be called when `address(coverPoolFactory) == address(0)` (L52). Once set (either via `initialize` with non-zero address or via `setCoverPoolFactory`), the factory address is permanently locked in the current implementation. No setter exists to update it.

```solidity
function setCoverPoolFactory(address coverPoolFactory_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(coverPoolFactory_ != address(0), ZeroAddress());
    require(address(coverPoolFactory) == address(0), "CoverPoolFactory already set");  // one-time only
    coverPoolFactory = ICoverPoolFactory(coverPoolFactory_);
    emit CoverPoolFactorySet(coverPoolFactory_);
}
```

`SpecRegistry.registerSpec` checks `coverPoolFactory.coverPoolExists(coverPool)` (L107). If the `CoverPoolFactory` is re-deployed at a new address (not an in-place UUPS upgrade), the SpecRegistry's `coverPoolFactory` reference becomes stale. `registerSpec` would then fail for ALL CoverPools created by the new factory address (since `coverPoolExists` on the old factory returns `false` for pools registered only with the new factory).

In contrast, `PolicyManager` has a re-enterable `setCoverPoolFactory` (L128-131) with no one-time restriction.

**Asymmetry**: `PolicyManager` can update its factory reference in response to a factory re-deployment. `SpecRegistry` cannot — it would require a UUPS upgrade of `SpecRegistry` itself to update the factory reference.

**Impact**:
- If `CoverPoolFactory` is re-deployed (new address), new CoverPools cannot register specs (blocking policy binding via `CoverPool.bindPolicyForRequest` which calls `registerSpec`)
- The only recovery path is upgrading `SpecRegistry` via UUPS (`_authorizeUpgrade`), which requires the DEFAULT_ADMIN_ROLE and correct implementation — adding operational complexity under potential emergency
- Existing policies (already registered specs) are unaffected since `resolveSpec` only reads `_specs[coverPool][specId]`

**Evidence**:
```solidity
// SpecRegistry.sol:L50-L56 — one-time setter, no update path
function setCoverPoolFactory(address coverPoolFactory_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(coverPoolFactory_ != address(0), ZeroAddress());
    require(address(coverPoolFactory) == address(0), "CoverPoolFactory already set");

// PolicyManager.sol:L128-L131 — re-enterable setter, any admin can update
function setCoverPoolFactory(address coverPoolFactory_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(coverPoolFactory_ != address(0), ZeroAddress());
    coverPoolFactory = coverPoolFactory_;
    emit CoverPoolFactorySet(coverPoolFactory_);
}
```

**Why breadth agents likely missed this**: The one-time setter pattern in `SpecRegistry` vs. the updatable setter in `PolicyManager` requires comparing both contracts' factory reference management. Per-contract agents focus on correctness within a single contract and typically don't cross-reference setter flexibility between contracts.

---

## Finding [BLIND-B-3]: SpecRegistry Pause Blocks CoverPool Policy Binding Without User Notice — Undocumented Cross-Contract Pause Dependency

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,5 | ✗4(N/A) | ✗6(N/A - no role involved in the impact path)
**Rules Applied**: [R6:✗(no role in impact path), R8:✗(single-step dependency), R10:✓, R12:✗(no dangerous state), R13:✓, R14:✗(no aggregate variables)]
**Severity**: Low
**Location**: `CoverPool.sol:L180` (calls `registerSpec`), `SpecRegistry.sol:L100` (registerSpec with `whenNotPaused`)

**Description**:
`CoverPool.bindPolicyForRequest` calls `ISpecRegistry(specRegistry).registerSpec(quote.specId, ISpec(spec))` at line 180. `SpecRegistry.registerSpec` has a `whenNotPaused` guard (L100):

```solidity
// SpecRegistry.sol:L100
function registerSpec(bytes32 specId, ISpec spec) external override whenNotPaused {
```

```solidity
// CoverPool.sol:L180
ISpecRegistry(specRegistry).registerSpec(quote.specId, ISpec(spec));
```

If `SpecRegistry` is paused (by its `DEFAULT_ADMIN_ROLE`), ALL calls to `CoverPool.bindPolicyForRequest` will revert — even when `CoverPool` itself is unpaused. This creates a cross-contract pause dependency that is:
- NOT documented in `CoverPool.bindPolicyForRequest`
- NOT reflected in `CoverPool`'s own pause state
- Visible only to callers who observe the revert

A curator attempting to bind a policy while CoverPool is unpaused would receive an opaque revert from the SpecRegistry's `whenNotPaused` check, with no indication that SpecRegistry is the paused component.

Additionally, the `SpecRegistry` admin (`DEFAULT_ADMIN_ROLE`) is a distinct address from the `CoverPool` admin (`DEFAULT_ADMIN_ROLE` on each pool). These are different keys. The SpecRegistry admin can pause spec registration (blocking all pool binding) unilaterally without any coordination with pool curators.

**Impact**:
- Any one SpecRegistry admin action (pause) blocks ALL CoverPool policy binding protocol-wide
- Policy buyers who requested coverage (`requestCoverage`) and have a pending draft cannot proceed to binding until SpecRegistry is unpaused
- Pending `requestCoverage` quotes expire (time-limited per `quote.expirationTime`), requiring re-quoting after SpecRegistry unpauses
- Curators who paid gas costs for infrastructure setup (committee vaults, stakes) cannot complete binding
- No on-chain indicator to distinguish "CoverPool paused" from "SpecRegistry paused" from callers' perspective

**Evidence**:
```solidity
// CoverPool.sol:L155-L198 — bindPolicyForRequest has its own whenNotPaused
function bindPolicyForRequest(...) external override onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
    // ...
    // This call will revert if SpecRegistry is paused — no try/catch, no documentation
    ISpecRegistry(specRegistry).registerSpec(quote.specId, ISpec(spec));  // L180
```

**Postcondition Analysis**:
**Postconditions Created**: SpecRegistry pause propagates as binding failure to all CoverPools
**Postcondition Types**: [STATE — protocol-wide binding freeze without CoverPool pause flag set]
**Who Benefits**: An actor who controls SpecRegistry admin key can halt all policy binding protocol-wide using just the SpecRegistry pause function

**Why breadth agents likely missed this**: Cross-contract dependency analysis requires tracing external call targets across contract boundaries and checking their independent pause states. Breadth agents analyzing CoverPool would note the `registerSpec` call but may not trace into SpecRegistry's internal guards. Breadth agents analyzing SpecRegistry would analyze its own pause logic without considering callers in other contracts.

---

## Findings Excluded (Verified as False Positives During This Scan)

1. **CoverPool.grantRole override adds redundant onlyRole(DEFAULT_ADMIN_ROLE)**: The override is stricter than base but functionally equivalent for the protocol's role structure. Not a finding.

2. **CoverPoolFactory DEFAULT_ADMIN_ROLE instant transfer**: While the factory uses `AccessControlUpgradeable` without 2-step protection, this is already captured in BLIND-B-1 with severity Low (same root cause).

3. **approveNextClaim missing whenNotPaused**: After careful analysis, this is intentional design — allowing curators to pre-approve claims during pause windows so they can proceed immediately after unpause. The approval is NOT consumed without a corresponding `fileClaim` execution.

4. **PolicyManager.setPremiumDefaulted missing whenNotPaused**: Substantively covered by AC-2 (curator blocking claims). The missing guard does not expand the attack surface beyond what AC-2 documents.

5. **SpecRegistry.resolveSpec not checking _approvedSpecs**: Already covered by RS2-1.

6. **CoverPool.bindPolicyForRequest → PolicyManager.bindPolicy → onPolicyBound reversion**: Already covered by PC2-3.

---

## Chain Summary

| Finding ID | Location | Root Cause (1-line) | Verdict | Severity | Precondition Type | Postcondition Type |
|------------|----------|---------------------|---------|----------|-------------------|-------------------|
| BLIND-B-1 | CoverPoolFactory.sol:45-73 | Factory uses AccessControlUpgradeable (instant admin transfer) while CoverPools it creates use AccessControlDefaultAdminRulesUpgradeable (24h delay) | CONFIRMED | Low | ACCESS | ACCESS |
| BLIND-B-2 | SpecRegistry.sol:50-56 | setCoverPoolFactory is one-time write with no update path; factory re-deployment would permanently break spec registration | CONFIRMED | Low | STATE | STATE, EXTERNAL |
| BLIND-B-3 | CoverPool.sol:180, SpecRegistry.sol:100 | SpecRegistry whenNotPaused propagates through CoverPool.bindPolicyForRequest as undocumented cross-contract pause dependency | CONFIRMED | Low | STATE | STATE, TIMING |
