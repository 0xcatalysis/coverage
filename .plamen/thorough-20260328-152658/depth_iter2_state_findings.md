# DEPTH ANALYSIS: State Trace — Iteration 2 (Devil's Advocate)

---

## Finding [ITER2-ST-1]: Quote Staleness Griefing is One-Sided — The Curator, Not the Buyer, Holds the Binding Trigger

**Verdict**: REFUTED (extends PC2-1 with a structural finding that inverts the victim)
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✓, R5:✗(single entity trigger), R6:✓, R8:✗(single-step), R10:✓, R13:✓]
**Depth Evidence**: [TRACE:requestCoverage→draft.status=Created; bindPolicyForRequest→msg.sender must be pool owner (admin)], [VARIATION:buyer calls cancelPolicyDraft→curator cannot bind], [BOUNDARY:quote.startTime >= block.timestamp check at bindPolicyForRequest→validateQuote modifier]
**Severity**: Low
**Location**: CoverPool.sol:L61, PolicyManager.sol:L155-L219, PolicyManager.sol:L209-L220

**Description**:
Iteration 1 explored whether a buyer can intentionally delay to force quote staleness and grief the curator. This analysis inverts the direction of that concern.

Examining `bindPolicyForRequest` at PolicyManager.sol:L225-L307: `require(draft.pool == msg.sender, UnauthorizedCaller())` — only the pool contract (i.e., only the curator via `CoverPool.bindPolicyForRequest` which is `onlyRole(DEFAULT_ADMIN_ROLE)`) can call `bindPolicy`. The buyer has no ability to trigger binding.

For the buyer to "grief" the curator via delay, the buyer would have to prevent the curator from binding in time. The buyer's only available action is `cancelPolicyDraft` (PolicyManager.sol:L209-L220), which requires `draft.status == PolicyStatus.Created` and `draft.buyer == msg.sender`. Cancellation is the buyer's legitimate right and causes no quote staleness — it simply terminates the draft.

The actual griefing direction is reversed: the **curator** controls all binding timing. If the curator delays calling `bindPolicyForRequest` past `quote.expirationTime` (line 63 of CoverPool.sol: `require(quote.expirationTime >= currentTimestamp`), the quote becomes stale and the buyer must request a new policy. Since `bindPolicyForRequest` is `onlyRole(DEFAULT_ADMIN_ROLE)` on the CoverPool, the curator is the only party who can cause staleness.

There is NO circumvention path for a stale quote: both the `startTime >= currentTimestamp` check (line 61) and the `expirationTime >= currentTimestamp` check (line 63) are inside the `validateQuote` modifier applied inside `_verifyQuote`, which is called unconditionally from `bindPolicyForRequest`. A stale quote cannot be bound regardless of who calls.

**Impact**: The iteration 1 concern (buyer griefing curator via delay) is structurally impossible. Only the curator can delay binding, and only the curator suffers from that delay. This is a design choice that creates lopsided timing risk on the curator.

**EXTENDS iteration 1**: Iteration 1 confirmed staleness is real. This analysis extends it by identifying that the griefing direction is inverted from what was suspected: it is a curator self-risk, not a buyer attack surface.

### Postcondition Analysis
**Postconditions Created**: Curator bears all quote timing risk — user has no leverage over binding timing.
**Postcondition Types**: TIMING
**Who Benefits**: Buyers are fully insulated from timing disputes; curators must ensure they bind before `expirationTime`.

---

## Finding [ITER2-ST-2]: Compound Deductible + Coverage Cap Change — Constraint Enforced at Execute-Time Against Current (Not Pending) Counterpart, Creating a Sequential Execution Window

**Verdict**: CONFIRMED (extends CS-5 with new compound-change path)
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✓, R5:✗(single actor), R6:✓, R8:✓, R10:✓, R14:✓]
**Depth Evidence**: [TRACE:executeMaxCoverableLossBps checks newBps > deductibleBps(current)→NOT pendingDeductibleBps], [TRACE:executeDeductibleBps checks newBps < maxCoverableLossBps(current)→NOT pendingMaxCoverableLossBps], [VARIATION:simultaneous pending A=5% and B=4% → execution order determines whether invariant deductible<max is momentarily consistent]
**Severity**: Low
**Location**: CoveredVaultAdmin.sol:L57-L89

**Description**:
Iteration 1 focused on admin front-running: reading `maxCoverableLossBps` and `deductibleBps` at withdrawal time vs. loss-event time. This analysis explores the compound effect when BOTH parameters change simultaneously.

The invariant `deductibleBps < maxCoverableLossBps` is checked at execute-time against the **current live value** of the counterpart, not against the pending value. Specifically:
- `executeMaxCoverableLossBps` (line 60): `require(newBps > deductibleBps)` — reads current `deductibleBps`
- `executeDeductibleBps` (line 84): `require(newBps < maxCoverableLossBps)` — reads current `maxCoverableLossBps`

Consider this sequence: owner proposes `maxCoverableLossBps → 3%` and `deductibleBps → 2%` simultaneously (both use `STANDARD_DELAY = 2 days`). After 2 days, the owner executes them in a specific order:

1. **Execute `executeMaxCoverableLossBps(3%)`**: Check is `3% > deductibleBps(current=5%)` — this FAILS and reverts.
2. **Execute `executeDeductibleBps(2%)`**: Check is `2% < maxCoverableLossBps(current=10%)` — passes. Now `deductibleBps = 2%`.
3. **Execute `executeMaxCoverableLossBps(3%)`**: Check is `3% > deductibleBps(current=2%)` — passes. Now `maxCoverableLossBps = 3%`.

The constraint IS maintained end-to-end, but the owner must execute in the correct order (deductible first, then max-coverable). If they execute in the wrong order, `executeMaxCoverableLossBps` reverts and must be retried after step 2. This is a UX friction issue, not a security vulnerability.

However, there is a genuine compound impact on coverage payout that iteration 1 did not explore: when both parameters change, the combined effect on `_capAndApplyDeductible(shortfall, basis)` is non-linear. At `maxCoverableLossBps=10%, deductibleBps=1%`, a 5% loss yields: `capped=5%, deductible=1%, payout=4%`. At `maxCoverableLossBps=3%, deductibleBps=2%`, the same 5% loss yields: `capped=3%, deductible=2%, payout=1%`. The payout drops 75% (from 4% to 1% of basis). This can be executed with a 2-day timelock window.

**ClaimManager interaction (new finding)**: The `_capAndApplyDeductible` function in CoveredVaultWrapper is called at the vault level when the user withdraws. `ClaimManager.fileClaim` independently resolves the spec and slashes stakers. The deductible and max-coverable parameters affect the vault's internal `_claimInsurance` call path (CoveredVaultWrapper.sol:L329, L419, L436), NOT anything in ClaimManager itself. ClaimManager has no visibility into these parameters. Therefore, changing these parameters does NOT affect claims already submitted to ClaimManager — those claims are denominated in the policy's `coverageLimit` and processed by ClaimManager without referencing vault-local `deductibleBps`/`maxCoverableLossBps`.

**Impact**: The compound simultaneous reduction of `maxCoverableLossBps` and increase of `deductibleBps` amplifies the coverage reduction effect nonlinearly. A user who relies on `calculateShortfall()` or `userShortfall()` view functions to understand their coverage exposure may receive a materially lower payout than expected if the owner executes both changes close to a loss event. The 2-day timelock provides notice but users must monitor pending parameter changes actively.

**Evidence**:
```solidity
// CoveredVaultAdmin.sol:60 — checks current deductibleBps, NOT pendingDeductibleBps
require(newBps > deductibleBps, IA.InvalidMaxCoverableLoss());

// CoveredVaultAdmin.sol:84 — checks current maxCoverableLossBps, NOT pendingMaxCoverableLossBps
require(newBps < maxCoverableLossBps, IA.InvalidParameters());

// CoveredVaultWrapper.sol:630-634 — both parameters read at call-time
uint256 maxInsurance = basis.mulDiv(maxCoverableLossBps, BPS_DENOMINATOR, Math.Rounding.Floor);
uint256 capped = shortfall > maxInsurance ? maxInsurance : shortfall;
uint256 deductibleAmt = basis.mulDiv(deductibleBps, BPS_DENOMINATOR, Math.Rounding.Floor);
return capped > deductibleAmt ? capped - deductibleAmt : 0;
```

**EXTENDS iteration 1**: Iteration 1 focused on admin front-running individual changes. This analysis adds: (a) the compound nonlinear effect of simultaneous changes; (b) confirms ClaimManager is NOT affected by these parameters; (c) shows the constraint check uses current (not pending) counterpart values, creating a required execution ordering.

---

## Finding [ITER2-ST-3]: Revoked Spec Remains Permanently Callable via resolveSpec — No Defense for Claims Against Revoked Specs

**Verdict**: CONFIRMED (extends RS2-1 with concrete operator exploit path)
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✓, R5:✗(single actor path), R6:✓, R8:✓, R10:✓, R13:✓]
**Depth Evidence**: [TRACE:revokeSpec→_approvedSpecs[spec]=false; resolveSpec reads _specs→always returns registered address regardless of approval], [TRACE:fileClaim→_evaluateSpec→ISpecRegistry.resolveSpec→returns spec→spec.evaluate(context)], [VARIATION:spec.evaluate() behavior can differ between approved and revoked spec—controlled by spec implementation]]
**Severity**: Medium
**Location**: SpecRegistry.sol:L84-L88, SpecRegistry.sol:L127-L130, ClaimManager.sol:L711

**Description**:
Iteration 1 identified that `revokeSpec` clears `_approvedSpecs[spec]` but not `_specs[coverPool][specId]`, and that `resolveSpec` reads only `_specs`. This analysis traces the concrete operator exploit path and the claim lifecycle when a spec is revoked mid-claim.

**State graph**:
```
_approvedSpecs[spec]
  WRITTEN BY: approveSpec (L75-L78), revokeSpec (L84-L88)
  READ BY: registerSpec (L118) — approval check ONLY at registration time

_specs[coverPool][specId]
  WRITTEN BY: registerSpec (L120) — only if _approvedSpecs[spec] == true at registration
  READ BY: resolveSpec (L128) — no approval check at resolution time
```

The approval check at `registerSpec` (line 118: `require(_approvedSpecs[address(spec)], SpecNotApproved(address(spec)))`) fires ONLY once, at the moment of registration. Once registered, `_specs[coverPool][specId]` is immutable (line 110-115: if the spec address matches the existing entry, it simply returns; only new registrations with different addresses fail). Revocation via `revokeSpec` sets `_approvedSpecs[spec] = false` but does nothing to `_specs`.

**Claim lifecycle when spec is revoked mid-claim**:
1. Policy is bound with `specId = X`, spec address `S` registered for that (pool, specId) pair.
2. A loss event occurs; claimer calls `fileClaim`.
3. Admin revokes spec `S` (via `revokeSpec`).
4. `fileClaim` still calls `_evaluateSpec` → `resolveSpec(pool, specId)` → returns `S` (no approval check) → `S.evaluate(context)`.

The revoked spec `S` is still called. Whether the outcome differs from a non-revoked spec depends entirely on the spec implementation — `evaluate()` is an arbitrary external contract. An operator (who knows the spec's internal logic) can:
- **If the spec has any admin-controlled override**: After revocation (which may signal the admin intends to disable spec S), an operator who controls or understands spec S may be able to call spec S's admin functions before `fileClaim` to alter `evaluate()` behavior — making claims that should fail pass, or claims that should pass fail.
- **More concretely**: If the spec was revoked because it was found to produce incorrect results, all in-flight claims still use the buggy spec. There is no mechanism to block a `fileClaim` against a policy whose spec has been revoked.

**Concrete harm from an operator perspective**: A dishonest operator (the pool curator) who controls a spec contract and wants to deny a valid claim can:
1. Deploy a spec that returns `isPayable = false` for specific conditions.
2. Register it for their pool.
3. When a valid claim is about to be filed, trigger `revokeSpec` via the admin (or convince admin to revoke) as a smoke screen — this has no effect on the claim outcome since `resolveSpec` still returns the spec.
4. Simultaneously, if the spec has any backdoor (even a seemingly benign governance function), alter it to return `false` for the specific `evidenceHash`.

The key asymmetry: **revocation does not protect claimants from a malicious or buggy spec**. The claim lifecycle offers no exit after the spec is bound to the policy (the `specId` is stored in `PolicyMetadata` at binding time and is immutable).

**CONTRADICTS iteration 1**: Iteration 1's framing was "operator can use revoked spec to file claims against a revoked spec that the coverage provider intended to be invalidated." The actual harm direction is the opposite: a revoked spec can deny valid claims, not enable invalid ones. The `fileClaim` restriction is that it must be called by `metadata.claimer` (ClaimManager.sol:L214) — so an attacker cannot file fake claims against a revoked spec. But a colluding curator+spec-admin pair CAN manipulate the spec's evaluate logic after revocation since the spec remains callable.

**Evidence**:
```solidity
// SpecRegistry.sol:84-88 — revoke only clears approval, not registration
function revokeSpec(address spec) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(spec != address(0), InvalidSpec());
    _approvedSpecs[spec] = false;
    emit SpecRevoked(spec);
}

// SpecRegistry.sol:127-130 — resolveSpec has no approval check
function resolveSpec(address coverPool, bytes32 specId) external view override returns (ISpec spec) {
    spec = _specs[coverPool][specId];
    require(address(spec) != address(0), SpecNotRegistered(coverPool, specId));
    return spec;  // no _approvedSpecs check
}

// ClaimManager.sol:711 — resolveSpec called directly, no approval validation
ISpec spec = ISpecRegistry(specRegistry).resolveSpec(metadata.pool, metadata.specId);
```

**Impact**: Spec revocation provides no protection to claimants with active policies. If a spec is revoked due to a bug or malicious behavior, all in-flight claims for policies using that spec continue to use the revoked spec implementation. A colluding pool curator and spec administrator can deny valid claims by modifying the spec contract after revocation (since revocation does not prevent spec execution). Severity is Medium because: (a) it requires DEFAULT_ADMIN_ROLE to revoke AND spec controller to manipulate, and (b) the curator is semi-trusted but the combination is adversarial.

**Recommendation**: `resolveSpec` should also check `_approvedSpecs[address(spec)]` before returning, or the claim manager should refuse to evaluate claims against revoked specs. Alternatively, spec implementations should be immutable (no admin functions post-deployment).

---

## Chain Summary

| Finding | Source Finding(s) | Agreement | Key Extension |
|---------|------------------|-----------|---------------|
| ITER2-ST-1 | PC2-1 | REFUTES buyer-griefer concern | Binding is `onlyRole(DEFAULT_ADMIN_ROLE)` on CoverPool — buyer cannot trigger or delay it; curator holds all timing risk |
| ITER2-ST-2 | CS-5 | EXTENDS with compound path | Simultaneous maxCoverableLossBps + deductibleBps changes create nonlinear payout reduction; confirmed ClaimManager is NOT affected by vault deductible params |
| ITER2-ST-3 | RS2-1 | CONTRADICTS iteration 1's attack direction | Revocation cannot enable false claims (claimer restricted); instead it fails to block manipulated spec evaluations that deny valid claims |
