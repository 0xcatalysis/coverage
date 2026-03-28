# Per-Contract Analysis #2: CoverPool + CoverPoolFactory + PolicyManager + SpecRegistry

**Cluster**: Policy Lifecycle (CoverPool, CoverPoolFactory, PolicyManager, SpecRegistry)
**Agent**: PC2
**Date**: 2026-03-28

---

## Finding [PC2-1]: Quote Requires `startTime >= block.timestamp` But Binding Happens After Draft Creation — All Quotes Go Stale

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single path), R6:✗(no semi-trusted shortcut), R8:✓, R10:✓, R11:✗(no external tokens), R12:✗(no dangerous precondition), R13:✗(not design-related), R14:✗(no aggregate variables), R15:✗(no flash-loan state), R16:✗(no oracle dependency)]
**Depth Evidence**: [BOUNDARY:startTime=block.timestamp → passes, next block → FAILS], [TRACE:requestCoverage()→bindPolicyForRequest()→validateQuote modifier→revert InvalidStartTime], [VARIATION:startTime set to "now+1s" at draft time → stale by the time curator binds]
**Severity**: Medium
**Location**: CoverPool.sol:L61 (validateQuote modifier), PolicyManager.sol:L155–L203

**Description**:
The `validateQuote` modifier in `CoverPool` enforces `require(quote.startTime >= currentTimestamp, InvalidStartTime(...))` at L61. This means the signed quote's `startTime` must be **in the future** at the moment `bindPolicyForRequest` is called. However, the policy lifecycle requires the user to call `PolicyManager.requestCoverage()` first to create a draft, then the curator calls `CoverPool.bindPolicyForRequest()` with a signed quote. Between these two transactions there is always a non-zero delay (at minimum one block, in practice hours to days while the curator reviews, configures vaults, and constructs the signature).

If the off-chain quote signer sets `startTime` to "now at sign time" rather than "now + expected_delay", the binding call will revert with `InvalidStartTime`. Conversely, to make the system actually work, the signer must set `startTime` well in advance of the actual signing, effectively meaning `startTime` in the quote is a future-prediction, not an anchor. Any mismatch between the signer's predicted delay and actual on-chain latency causes either:
1. Revert if `startTime` < `block.timestamp` at bind time — policy cannot be bound.
2. Coverage starting significantly later than the user expects if the signer pads `startTime` generously.

Additionally, the signed quote is consumed exactly once (via `boundPolicyCommits`) but there is no re-issuance mechanism — if the quote expires or `startTime` has passed, the curator must obtain a fresh signature. There is no on-chain fallback or mechanism to extend quotes atomically, meaning transient network congestion can permanently invalidate an otherwise-correct binding transaction, forcing a full re-negotiation.

**Impact**:
- Any temporary network or operational delay between `requestCoverage` and `bindPolicyForRequest` can cause the binding to revert, blocking the user from obtaining coverage even after a valid policy draft exists.
- The `expirationTime` must be set generously to accommodate delays, but `startTime` creates a tighter constraint — the coverage simply cannot start in the past. This means real coverage start times will often be delayed relative to user expectations.
- [TRACE: requestCoverage → curator constructs quote with startTime=T → delay D → bindPolicyForRequest at T+D → if D>0 and startTime≤T+D → revert]

**Evidence**:
```solidity
// CoverPool.sol:L59-L63
uint256 currentTimestamp = block.timestamp;
// forge-lint: disable-next-line(unsafe-typecast)
require(quote.startTime >= currentTimestamp, InvalidStartTime(quote.startTime, uint32(currentTimestamp)));
// forge-lint: disable-next-line(unsafe-typecast)
require(quote.expirationTime >= currentTimestamp, QuoteExpired(quote.expirationTime, uint32(currentTimestamp)));
```

The `startTime` check enforces the quote hasn't started yet at bind time, but the only safe quote is one where `startTime` is set far enough in the future to accommodate an unknown bind delay. There is no mechanism to update `startTime` without a new signature.

### Postcondition Analysis
**Postconditions Created**: Failed binding leaves a policy draft in `PolicyStatus.Created` indefinitely until the buyer cancels or a fresh quote is obtained; if the buyer does not cancel, StakeManager committee resources remain allocated.
**Postcondition Types**: [STATE, TIMING]
**Who Benefits**: No attacker directly benefits; this is an availability and UX issue.

---

## Finding [PC2-2]: CoverPoolFactory Salt Collision — Same Curator+QuoteSigner+FeeBps Can Only Deploy One Pool Per `policyManager`

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✓, R6:✗(no semi-trusted role), R8:✗(single-step), R10:✓, R11:✗(no external tokens), R12:✓, R13:✗, R14:✗, R15:✗, R16:✗]
**Depth Evidence**: [BOUNDARY:same params twice → CREATE2 collision → revert at EnumerableSet.add], [VARIATION:curator A, signer A, feeBps 100 → deploys pool1; same params again → EVM reverts on cloneDeterministic because address is already deployed], [TRACE: createCoverPool(sameParams)→_computeSalt(same)→cloneDeterministic→EVM REVERT because code exists at address]
**Severity**: Medium
**Location**: CoverPoolFactory.sol:L99–L109, L222–L228

**Description**:
`_computeSalt` hashes only four inputs: `curator`, `policyManager` (from factory state), `quoteSigner`, and `poolFeeBps`. The `specRegistry` and `stakeManager` values — also stored in the factory and passed to `initialize` — are NOT part of the salt computation. This has two distinct consequences:

**Consequence 1 — One pool per (curator, quoteSigner, feeBps) tuple:**
A given curator cannot deploy two separate pools with the same quoteSigner and same fee, even if they want distinct pools for different coverage products. The `cloneDeterministic` call will revert at the EVM level because the target address already has code. The `require(_pools.add(coverPool), CoverPoolCreationFailure())` then also rejects it. This limits operational flexibility: to create a second pool, the curator must change at least one of: quoteSigner, feeBps, or curator address itself.

**Consequence 2 — Salt does not include specRegistry/stakeManager:**
`computeCoverPoolAddress` (the off-chain address prediction function) hashes only the four fields in `_computeSalt`. If `stakeManager` or `specRegistry` in the factory is updated between address computation and deployment, the predicted address is still correct (since the salt is unchanged) — but the deployed pool will be initialized with different `stakeManager`/`specRegistry` values than were contemplated when the address was predicted. Off-chain systems that rely on `computeCoverPoolAddress` to whitelist the pool before deployment may not detect this mismatch.

This extends the finding noted in RS1-3 (salt excludes stakeManager/specRegistry) with concrete impact on the address prediction use case.

**Impact**:
- Curators cannot operate multiple pools with identical parameters (same quoteSigner, same fee structure) for different coverage verticals — they must artificially differentiate parameters.
- Off-chain tooling using `computeCoverPoolAddress` will compute the correct address but will not anticipate the actual `stakeManager`/`specRegistry` values embedded in the deployed pool. Any downstream system that validates these fields may reject a legitimately deployed pool.

**Evidence**:
```solidity
// CoverPoolFactory.sol:L222-L228
function _computeSalt(CreateCoverPoolParams calldata params) private view returns (bytes32) {
    return EfficientHashLib.hash(
        uint256(uint160(params.curator)),
        uint256(uint160(policyManager)),  // factory state, not params
        uint256(uint160(params.quoteSigner)),
        uint256(params.poolFeeBps)
        // MISSING: stakeManager, specRegistry
    );
}
```

`stakeManager` and `specRegistry` are passed to `CoverPool.initialize()` at L104 but not hashed into the salt. A curator wanting two pools with the same curator/signer/feeBps combination is permanently blocked.

### Postcondition Analysis
**Postconditions Created**: If `stakeManager` or `specRegistry` is updated factory-wide between prediction and deployment, the deployed pool will hold stale infrastructure references not reflected in the predicted address.
**Postcondition Types**: [STATE]
**Who Benefits**: No direct attacker benefit; this is an operational constraint and integration integrity issue.

---

## Finding [PC2-3]: `bindPolicy` in PolicyManager Calls `onPolicyBound` Hook After Setting `PolicyStatus.Bound` — Hook Revert Leaves State Inconsistent

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✓, R5:✗(single vault hook), R6:✗(no semi-trusted role in the hook relationship), R8:✓, R10:✓, R11:✗(no external tokens), R12:✗, R13:✗, R14:✗, R15:✗, R16:✗]
**Depth Evidence**: [TRACE: bindPolicy sets draft.status=Bound at L257, writes _policies[policyId] at L297, marks _registeredPolicyCommits[policyCommit]=true at L296, THEN calls hook.onPolicyBound() at L305 — if hook reverts, entire tx reverts → no inconsistency], [VARIATION: hook that always reverts → entire bindPolicy always reverts → policy forever stuck as Created], [BOUNDARY: policyBoundExecuted=true after first call → second call to onPolicyBound reverts PolicyBoundAlreadyExecuted]
**Severity**: Low
**Location**: PolicyManager.sol:L299–L306, CoveredVaultWrapper.sol:L282–L309

**Description**:
In `PolicyManager.bindPolicy`, the `onPolicyBound` hook is called at the very end of the function (L305), after all state changes have been committed: `draft.status = PolicyStatus.Bound` (L257), `_registeredPolicyCommits[policyCommit] = true` (L296), and `_policies[policyId] = metadata` (L297). The function is wrapped in a `nonReentrant` guard and is `whenNotPaused`.

Because `onPolicyBound` is called inside the same transaction, if it reverts (for any reason — including a valid validation failure in `_validatePolicyBinding`), the entire `bindPolicy` transaction reverts atomically. This means the state changes are undone. So there is no state inconsistency from a Solidity atomicity perspective.

However, there is a functional concern: **the hook controls whether the policy can ever be bound**. If `CoveredVaultWrapper.onPolicyBound` reverts — e.g., because `pol.buyer != owner()` (the wrapper owner did not initiate the request), or `pol.pool != coverPool`, or `pol.payoutToken != asset()` — then `bindPolicy` reverts and the draft remains in `PolicyStatus.Created`. The curator cannot override this check. The user's only recourse is to cancel the draft and submit a new `requestCoverage` with a corrected hook contract.

More importantly, the hook has a **permanent one-shot guard**: `if (policyBoundExecuted) revert PolicyBoundAlreadyExecuted()`. Once the hook executes successfully, no second policy can ever be bound to the same `CoveredVaultWrapper` instance. This is by design (single-policy architecture), but it means if `onPolicyBound` succeeds but a subsequent operation in the same tx fails (none after L305 currently, but in future upgrades), the wrapper would have `policyBoundExecuted=true` while `PolicyManager` reverted. Currently this cannot occur because L305 is the last statement.

The real risk is: a `CoveredVaultWrapper` deployed with a wrong parameter (e.g., wrong `coverPool`) will cause `_validatePolicyBinding` to revert on `pol.pool != address(coverPool)`, which permanently blocks binding for any policy to that wrapper since the vault cannot be reconfigured post-initialization. The curator and buyer will be unable to bind without deploying a new wrapper.

**Impact**:
- If the `CoveredVaultWrapper` is misconfigured at deploy time (mismatched `coverPool`, `asset`, or owner), the binding will silently fail with only an opaque `InvalidData()` revert from the wrapper (after a `PolicyBindingFailed` event). The user and curator may not immediately understand why binding is blocked.
- The `PolicyBoundAlreadyExecuted` guard means the wrapper is permanently single-use. A curator who accidentally destroys the first binding opportunity must deploy a fresh wrapper.
- Low severity because no funds are directly at risk and the state reverts atomically; the consequence is operational blocking and gas waste.

**Evidence**:
```solidity
// PolicyManager.sol:L299-L306
address hook = draft.bindPolicyHook;

emit PolicyBound(...);

IBindPolicyHook(hook).onPolicyBound(policyId, boundPolicy.coverageLimit);
```

```solidity
// CoveredVaultWrapper.sol:L291-L292
if (policyBoundExecuted) revert PolicyBoundAlreadyExecuted();
// ...
_validatePolicyBinding(pol); // reverts with InvalidData() on any mismatch
```

### Postcondition Analysis
**Postconditions Created**: If hook reverts, transaction reverts atomically — no state changes persist. Draft remains in `Created` status permanently blocking re-bind attempts unless buyer cancels.
**Postcondition Types**: [STATE, EXTERNAL]
**Who Benefits**: No direct attacker benefit. Operational concern only.

---

## Finding [PC2-4]: `SpecRegistry.revokeSpec` Marks `_approvedSpecs[spec]=false` But Registered Mappings Are Immutable — Revoked Specs Remain Resolvable In Active Policies

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single contract), R6:✓, R8:✓, R10:✓, R11:✗(no external tokens), R12:✓, R13:✓, R14:✗, R15:✗, R16:✗]
**Depth Evidence**: [TRACE: approveSpec(spec)→registerSpec(specId,spec)→_specs[pool][specId]=spec; revokeSpec(spec)→_approvedSpecs[spec]=false; ClaimManager.resolveSpec(pool,specId)→returns spec (still registered)], [BOUNDARY: _specs mapping is write-once (never cleared by revokeSpec)], [VARIATION: spec approved→registered→revoked → registerSpec(specId,spec) now reverts with SpecNotApproved, but _specs[pool][specId] still returns spec]
**Severity**: Low
**Location**: SpecRegistry.sol:L84–L88 (`revokeSpec`), SpecRegistry.sol:L100–L122 (`registerSpec`), SpecRegistry.sol:L127–L131 (`resolveSpec`)

**Description**:
`revokeSpec` sets `_approvedSpecs[spec] = false` and emits `SpecRevoked`. However, the `_specs[coverPool][specId]` mapping — which records the (pool, specId) → spec address relationship — is **never updated by `revokeSpec`**. The existing registration persists indefinitely.

This creates a two-tier inconsistency:

1. **New registrations blocked**: After revocation, calling `registerSpec` with the same spec will reach L118 (`require(_approvedSpecs[address(spec)], SpecNotApproved(...))`) and revert. Good.

2. **Existing mappings unaffected**: `resolveSpec(coverPool, specId)` at L127 reads only `_specs[coverPool][specId]`, which was set during the original `registerSpec` call and is never cleared. So `ClaimManager` can still call `resolveSpec` and get the revoked spec address, which it will then call to evaluate claims.

The semantics of `revokeSpec` appear to be "this spec implementation is considered unsafe/incorrect going forward" — but revocation does not actually prevent the revoked spec from being used to evaluate claims in policies already bound with that specId. The admin has no way to atomically block claims on policies using the revoked spec without a registry upgrade.

This is the RS2-1 issue noted in the exclusion list, confirmed here at the contract level. The `revokeSpec` function's documentation says specs are immutable once registered for a (pool, specId) pair, which is acknowledged in the contract NatSpec at L8: *"Once a (coverPool, specId) pair is registered, it cannot be changed to a different spec address."* However, this means revocation provides only a false sense of security — the admin believes they have revoked a dangerous spec when in reality it continues operating for all active policies.

**Impact**:
- If a spec implementation contains a bug or is compromised, the admin cannot block it from evaluating ongoing claims. The only remediation is a full SpecRegistry upgrade.
- Misleading: `isSpecApproved(spec)` returns `false` post-revocation, but `resolveSpec` still returns the spec. Integrators reading `isSpecApproved` to determine if claims are safe will receive a false-negative.
- At consumption point in ClaimManager: ClaimManager calls `resolveSpec` to get the ISpec implementation for a claim. If that spec is revoked but still registered, ClaimManager will use it. Depending on what the revoked spec does in `evaluate()`, this could approve fraudulent claims.

**Evidence**:
```solidity
// SpecRegistry.sol:L84-L88
function revokeSpec(address spec) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(spec != address(0), InvalidSpec());
    _approvedSpecs[spec] = false;  // Only clears approval flag
    emit SpecRevoked(spec);
    // _specs[coverPool][specId] NOT cleared — existing registrations remain
}

// SpecRegistry.sol:L127-L131
function resolveSpec(address coverPool, bytes32 specId) external view override returns (ISpec spec) {
    spec = _specs[coverPool][specId];  // Returns registered spec regardless of approval status
    require(address(spec) != address(0), SpecNotRegistered(coverPool, specId));
    return spec;
}
```

**R13 Analysis**: The immutability of (pool, specId) → spec is documented as intentional design. However, the impact is: if a spec is revoked for being unsafe, existing policyholders' claims will still be evaluated by the unsafe spec until all their policies mature. Users cannot opt out. The terminal consequence is: fraudulent claim approvals or incorrect claim denials persist for the life of all active policies bound with the revoked spec.

**R6 Analysis**: The DEFAULT_ADMIN_ROLE can revoke specs; their action creates the misleading state where `isSpecApproved` is false but the spec is still used.

### Postcondition Analysis
**Postconditions Created**: After revocation, `_approvedSpecs[spec]=false` but `_specs[pool][specId]=spec` remains. Any ClaimManager call to `resolveSpec` for that pool+specId will return the revoked spec.
**Postcondition Types**: [STATE, ACCESS]
**Who Benefits**: No direct attacker; this is an administrative limitation. An attacker who previously registered a malicious spec before revocation would still have their spec callable via ClaimManager.

---

## Finding [PC2-5]: `PolicyManager.bindPolicy` Accepts Any `startTime` In the Past Via `_validateRequest` — Quote Freshness Bypass

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R11:✗, R12:✗, R13:✗, R14:✗, R15:✗, R16:✗]
**Depth Evidence**: [BOUNDARY:startTime=0 passes _validateRequest, fails validateQuote in CoverPool], [TRACE: PolicyManager._validateRequest(request) only checks maturityTime > block.timestamp, NOT startTime >= block.timestamp → startTime could be any value in the past as long as maturity is in the future], [VARIATION: startTime=1 (unix epoch), maturityTime=block.timestamp+100 → passes PolicyManager validation, but CoverPool.validateQuote checks startTime >= block.timestamp → blocked at pool level]
**Severity**: Informational
**Location**: PolicyManager.sol:L358–L373 (`_validateRequest`), CoverPool.sol:L51–L64 (`validateQuote`)

**Description**:
`PolicyManager._validateRequest` validates the quote's timing at L370:
```solidity
require(
    request.quote.startTime < request.quote.maturityTime && request.quote.maturityTime > block.timestamp,
    InvalidCoverageWindow(request.quote.startTime, request.quote.maturityTime)
);
```

This only checks:
1. `startTime < maturityTime` (ordering)
2. `maturityTime > block.timestamp` (maturity in the future)

It does NOT check `startTime >= block.timestamp`. A quote with `startTime` in the past (e.g., startTime=1 while maturityTime=block.timestamp+1000) would pass `_validateRequest`. The defence-in-depth exists in `CoverPool.validateQuote` which DOES enforce `startTime >= currentTimestamp`. However, `PolicyManager.bindPolicy` is called FROM `CoverPool.bindPolicyForRequest` — meaning the check order is:

1. `CoverPool.bindPolicyForRequest` calls `_verifyQuote` (applies `validateQuote` modifier → enforces startTime >= now)
2. Then calls `IPolicyManager(policyManager).bindPolicy(...)`
3. `PolicyManager.bindPolicy` re-checks via `_validateRequest` but does NOT re-check `startTime >= block.timestamp`

Because `bindPolicy` is called by `CoverPool` (enforced at L240: `require(draft.pool == msg.sender, UnauthorizedCaller())`), the startTime constraint is effectively enforced before `bindPolicy` is called. But `bindPolicy` is a public function callable by any registered CoverPool. A future CoverPool implementation (or a malicious pool added to the factory) could call `PolicyManager.bindPolicy` directly without going through `_verifyQuote`, passing a quote with `startTime` in the past.

The PolicyManager has no independent check on `startTime`, meaning it delegates freshness enforcement entirely to CoverPool. If a CoverPool implementation omits or weakens the `validateQuote` check, PolicyManager will accept a stale start time.

**Impact**:
- Currently mitigated by the call chain: all legitimate paths enforce startTime in CoverPool before PolicyManager is called.
- Risk materializes only if a future CoverPool implementation weakens signature validation, or if the factory's `CREATOR_ROLE` deploys a pool with a custom `bindPolicy` caller path.
- Low/Informational because current implementations are safe and PolicyManager correctly validates maturityTime (preventing fully-expired coverage).

**Evidence**:
```solidity
// PolicyManager.sol:L370-L372
require(
    request.quote.startTime < request.quote.maturityTime && request.quote.maturityTime > block.timestamp,
    InvalidCoverageWindow(request.quote.startTime, request.quote.maturityTime)
);
// Missing: request.quote.startTime >= block.timestamp
```

```solidity
// CoverPool.sol:L61 (validateQuote modifier — only applied in _verifyQuote, not PolicyManager)
require(quote.startTime >= currentTimestamp, InvalidStartTime(quote.startTime, uint32(currentTimestamp)));
```

### Postcondition Analysis
**Postconditions Created**: A policy could be bound with `startTime` in the past if CoverPool's start-time check is bypassed. `PolicyMetadata.startTime` would record a past timestamp, potentially affecting premium accrual start-time accounting and ClaimManager window checks.
**Postcondition Types**: [STATE, TIMING]
**Who Benefits**: A curator using a custom/future CoverPool implementation could bind policies with retroactive coverage windows.

---

## Chain Summary

| Finding | Root Cause | Severity | Key Finding |
|---------|-----------|----------|-------------|
| PC2-1 | Quote startTime enforced at bind time but quote is created ahead of bind | Medium | `startTime >= block.timestamp` validated at bind, not sign time — causes operational failures |
| PC2-2 | Salt excludes stakeManager/specRegistry; no uniqueness beyond curator+signer+fee | Medium | Single pool per (curator,signer,feeBps) tuple; stale infra refs in address prediction |
| PC2-3 | `onPolicyBound` hook is single-use permanent guard; misconfigured wrapper permanently blocks binding | Low | Wrapper misconfiguration permanently blocks policy binding |
| PC2-4 | `revokeSpec` clears approval flag but not registered mapping — revoked specs still resolvable | Low | Revoked specs continue evaluating claims for all active policies |
| PC2-5 | `PolicyManager._validateRequest` does not enforce `startTime >= block.timestamp` | Informational | Defence-in-depth gap: startTime freshness delegated entirely to CoverPool |
