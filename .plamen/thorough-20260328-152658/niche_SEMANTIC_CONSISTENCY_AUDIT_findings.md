# Semantic Consistency Audit Findings

**Agent**: Semantic Consistency Niche Agent
**Scope**: CoverPool, PolicyManager, ClaimManager, PremiumManager, CoveredVaultWrapper (+ storage/admin/accrual)
**Investigation Points**: Cross-contract parameter unit consistency, BPS scale agreement, deductibleBps vs maxCoverableLossBps semantics, gateGracePeriod units, coverageLimit flow, policyId off-by-one

---

## Finding [SC-1]: gateGracePeriod Is Time-Denominated but There Is No Unit Semantic Conflict — CONFIRMED Design Consistency

**Verdict**: REFUTED
**Step Execution**: ✓1,2,3 | ✗4(N/A)
**Rules Applied**: [R14:✗(single variable, no independent setter), R8:✗(single-source accumulator)]
**Severity**: Informational
**Location**: CoveredVaultAdmin.sol:181, CoveredVaultAccrual.sol:124,156, CoveredVaultStorage.sol:160

**Description**:
`gateGracePeriod` is accumulated as seconds (via `block.timestamp - gateActivatedAt`) in `setMorphoGateActive()`. It is consumed in `_activeElapsedFrom()` and `_isPolicyActive()` as a seconds offset on `meta.maturityTime` (also in seconds). Both producer and consumer agree on seconds as the unit.

No unit mismatch. This investigation point is cleared.

---

## Finding [SC-2]: ClaimManager Enforces Raw maturityTime While CoveredVaultWrapper Extends It by gateGracePeriod — ALREADY KNOWN

**Verdict**: REFUTED (already reported as RS1-1)
**Step Execution**: ✓1,2
**Rules Applied**: [R8:✓]
**Severity**: (Duplicate of RS1-1 — HIGH)
**Location**: ClaimManager.sol:307-308, CoveredVaultAccrual.sol:156

**Description**:
`ClaimManager._fileClaimWithMetadata` enforces `block.timestamp <= metadata.maturityTime` (raw), while `_isPolicyActive()` in CoveredVaultWrapper extends the window by `gateGracePeriod`. This is already captured as RS1-1 (CONFIRMED, High). Not re-reported here.

---

## Finding [SC-3]: coverageLimit Units Are Consistent Across CoverPool, PolicyManager, CoveredVaultWrapper, and ClaimManager

**Verdict**: REFUTED
**Step Execution**: ✓1,2,3
**Rules Applied**: [R8:✗(single read source through PolicyManager.policyMetadata)]
**Severity**: Informational
**Location**: CoverPool.sol:28-59, PolicyManager.sol:280-289, CoveredVaultWrapper.sol:302-306, ClaimManager.sol:259-260

**Description**:
`coverageLimit` originates in the EIP-712 `Quote` struct as a `uint256` denominated in payout-token asset units (raw token amounts, not BPS). The value flows: `Quote.coverageLimit` → `CoverPool.BoundPolicy.coverageLimit` → `PolicyManager._policies[].coverageLimit` → `onPolicyBound(_coverageLimit)` → `CoveredVaultWrapper.coverageLimit`.

All consumers (CoveredVaultWrapper residual-coverage check at L344-348, ClaimManager `remainingCoverage()` at L259-260, ClaimManager `_fileClaimWithMetadata()` at L300) read `metadata.coverageLimit` from the same PolicyManager source. Units are consistently payout-token denominated. No drift detected.

`depositCap = coverageLimit * BPS_DENOMINATOR / maxCoverableLossBps` uses raw-unit coverageLimit and BPS-unit maxCoverableLossBps to produce a raw-unit depositCap, which is correct.

---

## Finding [SC-4]: PremiumManager._BPS_DENOMINATOR vs CoveredVaultStorage.BPS_DENOMINATOR — Isolated Private Constants, No Shared Semantic

**Verdict**: REFUTED
**Step Execution**: ✓1,2,3
**Rules Applied**: [R14:✗(not independently settable — both hardcoded to 10_000)]
**Severity**: Informational
**Location**: PremiumManager.sol:32, CoveredVaultStorage.sol:30

**Description**:
PremiumManager uses `_BPS_DENOMINATOR = 10_000` (private constant) for its fee-split arithmetic. CoveredVaultStorage uses `BPS_DENOMINATOR = 10_000` (internal constant) for insurance arithmetic. Both are hardcoded to the same value. Neither is a parameter. There is no semantic drift — both mean "100% = 10,000 BPS".

The two contracts operate on completely separate domains (PremiumManager handles external premium flows; CoveredVaultWrapper handles internal insurance). They do not share the same BPS-scaled variables.

---

## Finding [SC-5]: poolFeeBps Maximum Limit Inconsistency Between CoverPool (20%) and PremiumManager Total-Fee Gate (100%)

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R14:✓, R5:✓, R10:✓]
**Depth Evidence**: [BOUNDARY:poolFeeBps=2000, platformFeeBps=2500 → totalFeeBps=4500 ≤ 10000, guard passes — 55% goes to restakers], [VARIATION:poolFeeBps 2000+platformFeeBps 2500 → 45% taken as fees, 55% to restakers — NOT a 100% exhaustion], [TRACE:_MAX_FEE_BPS=10_000 check in PremiumManager.distributePremium L160 never reverts for max-fee combo]
**Severity**: Low
**Location**: CoverPool.sol:36, PremiumManager.sol:33-34, PremiumManager.sol:159-160

**Description**:
`CoverPool._MAX_POOL_FEE_BPS = 2000` (20%) bounds the maximum pool fee a curator can set. `PremiumManager._MAX_PLATFORM_FEE_BPS = 2500` (25%) bounds the platform fee. `PremiumManager._MAX_FEE_BPS = 10_000` (100%) is the combined-fee guard: `require(totalFeeBps <= _MAX_FEE_BPS, ...)`.

The combined guard allows up to 100% combined fee (`platformFeeBps=2500 + poolFeeBps=2000 = 4500 < 10000`), meaning in the worst configured case, 45% of premiums are extracted as fees. This is intentional (the `_MAX_FEE_BPS` guard is a DOS-protection gate against integer underflow in `restakerSplit = grossPremium - platformSplit - poolSplit`, not a fairness cap).

However, the semantic inconsistency is that `_MAX_FEE_BPS = 10_000` creates a misleading guard name — `ExcessiveCombinedFees` is never reachable with legitimate fee parameters (max combined = 4500 bps), but a future change to either `_MAX_POOL_FEE_BPS` or `_MAX_PLATFORM_FEE_BPS` could silently push combined fees above 100% and cause `restakerSplit` underflow if the arithmetic is changed from subtraction to BPS multiplication. The guard is correct for now but relies on implicit coupling between two independently-settable limit constants across two separate contracts.

**Impact**:
Currently no exploitable harm — the arithmetic produces the correct `restakerSplit = amount - platformSplit - poolSplit` using subtraction, which floors at 0 for underflow protection only if Solidity's default overflow check fires at 100%. At max current fees (45%), restakers receive 55% of premiums. The semantic gap is a future regression risk: if `_MAX_POOL_FEE_BPS` is raised without corresponding update to `_MAX_FEE_BPS`, the guard will still pass while restakers are over-extracted.

**Evidence**:
```solidity
// CoverPool.sol:36
uint16 private constant _MAX_POOL_FEE_BPS = 2000; // 20%

// PremiumManager.sol:32-34
uint16 private constant _BPS_DENOMINATOR = 10_000;
uint16 private constant _MAX_FEE_BPS = 10_000;       // 100% — combined guard
uint16 private constant _MAX_PLATFORM_FEE_BPS = 2500; // 25%

// PremiumManager.sol:159-160 — passes for all legitimate combinations
uint16 totalFeeBps = platformFeeBps + poolFeeBps;
require(totalFeeBps <= _MAX_FEE_BPS, ExcessiveCombinedFees(...));
```

**Recommendation**: Replace `_MAX_FEE_BPS = 10_000` with `_MAX_FEE_BPS = _MAX_PLATFORM_FEE_BPS + _MAX_POOL_FEE_BPS` (4500) to make the guard semantically meaningful. Alternatively, document that `_MAX_FEE_BPS` is an underflow guard, not a fairness constraint.

---

## Finding [SC-6]: deductibleBps and maxCoverableLossBps Are Semantically Consistent Between ClaimManager's View and CoveredVaultWrapper's Internal Computation

**Verdict**: REFUTED
**Step Execution**: ✓1,2,3
**Rules Applied**: [R8:✗(deductibleBps/maxCoverableLossBps not read by ClaimManager — ClaimManager is unaware of them)]
**Severity**: Informational
**Location**: CoveredVaultWrapper.sol:627-635, ClaimManager.sol:196-238

**Description**:
`deductibleBps` and `maxCoverableLossBps` exist only in `CoveredVaultWrapper` (CoveredVaultStorage). `ClaimManager` is entirely unaware of these parameters — it simply processes a `requestedAmount` that the wrapper has already computed post-cap, post-deductible.

The cap and deductible logic is implemented in `_capAndApplyDeductible()` (CoveredVaultWrapper.sol:630-635). Both parameters are in BPS with denominator 10_000, consistently matching `BPS_DENOMINATOR`. ClaimManager's `requestedAmount` is denominated in payout-token units, which matches the wrapper's `claimAmount` output from `_capAndApplyDeductible`.

No semantic inconsistency between contracts.

---

## Finding [SC-7]: policyId Is Assigned via ++_nextPolicyId (Pre-Increment) Starting at 1 — CoveredVaultWrapper Guard policyId != 0 Is Correctly Calibrated

**Verdict**: REFUTED
**Step Execution**: ✓1,2,3
**Rules Applied**: [R8:✗(single increment source)]
**Severity**: Informational
**Location**: PolicyManager.sol:184, CoveredVaultAccrual.sol:120,154

**Description**:
`PolicyManager._nextPolicyId` starts at 0. First assigned policyId is `++_nextPolicyId = 1`. `CoveredVaultWrapper` uses `policyId == 0` / `policyId != 0` to guard "no policy bound yet" state. Since PolicyManager never issues policyId=0, the guard is correctly calibrated — no off-by-one.

`onPolicyBound` also guards: `if (_policyId == 0) revert InvalidPolicyId()` which is redundant but harmless.

---

## Finding [SC-8]: CoveredVaultWrapper.coverageLimit vs ClaimManager's remainingCoverage Read — Dual-Source Tracking Risk

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R8:✓, R14:✓, R5:✓, R10:✓]
**Depth Evidence**: [TRACE:_claimInsurance L344-348 reads coverageLimit from local state; ClaimManager.remainingCoverage L259-260 reads from PolicyManager.policyMetadata — same underlying value, different read paths], [VARIATION:if PolicyManager.policyMetadata.coverageLimit changes (upgradeable proxy) → CoveredVaultWrapper.coverageLimit and ClaimManager would diverge], [BOUNDARY:if remainingCoverage in ClaimManager reaches 0 while CoveredVaultWrapper.coverageLimit > 0, wrapper still files cappedClaim > 0 which then returns payout=0 silently via balanceBefore==balanceAfter]
**Severity**: Low
**Location**: CoveredVaultWrapper.sol:344-351, CoveredVaultWrapper.sol:302, ClaimManager.sol:259-260

**Description**:
`CoveredVaultWrapper` caches `coverageLimit` in local state (set once by `onPolicyBound` at L302). It uses this cached value to compute `remainingCoverage` locally (L344-348: `policyCoverageLimit > paidOut ? policyCoverageLimit - paidOut : 0`) via `_getPaidCover(policyId)` (reads ClaimManager's `policyClaim.totalPaidOut`).

`ClaimManager.remainingCoverage()` reads the same `metadata.coverageLimit` from PolicyManager. These two sources are currently identical — both trace back to `boundPolicy.coverageLimit` from CoverPool's `BoundPolicy`.

**The risk**: `PolicyManager` is a UUPS upgradeable proxy. If an upgrade changes how `policyMetadata()` returns `coverageLimit`, or if `coverageLimit` in `_policies` mapping is mutated by a new admin function, `CoveredVaultWrapper.coverageLimit` (cached) would diverge from `ClaimManager`'s live PolicyManager read. In that scenario, the wrapper would believe more coverage is available than ClaimManager grants, causing `cappedClaim` to be sent to ClaimManager, which then returns 0 payout (because `_fileClaimWithMetadata` caps at true remaining). The user gets no insurance payout on a legitimate loss.

Additionally, `CoveredVaultWrapper._claimInsurance()` checks `remainingCoverage = policyCoverageLimit - paidOut` locally but then calls `claimManager.fileClaim(policyId, cappedClaim, ...)`, which performs its own `remaining` check. The wrapper's local capping at L350 and ClaimManager's internal capping at L300 are duplicate guards operating on different reads of `coverageLimit`.

**Impact**:
In the current codebase (no upgrade path that mutates policyMetadata.coverageLimit), this is harmless. On a PolicyManager upgrade that modifies coverage semantics, the wrapper would silently under-pay insurance claims. Low severity given PolicyManager upgrade is an admin action under DEFAULT_ADMIN_ROLE.

**Evidence**:
```solidity
// CoveredVaultWrapper.sol:344-350 — reads local cached state
uint256 policyCoverageLimit = coverageLimit;  // cached at onPolicyBound
uint256 paidOut = _getPaidCover(policyId);    // reads ClaimManager.totalPaidOut
uint256 remainingCoverage = policyCoverageLimit > paidOut ? policyCoverageLimit - paidOut : 0;
uint256 cappedClaim = claimAmount > remainingCoverage ? remainingCoverage : claimAmount;

// ClaimManager.sol:259-260 — reads live PolicyManager state
IPolicyManager.PolicyMetadata memory metadata = IPolicyManager(policyManager).policyMetadata(policyId);
return totalPaidOut >= metadata.coverageLimit ? 0 : metadata.coverageLimit - totalPaidOut;
```

**Recommendation**: Document that `CoveredVaultWrapper.coverageLimit` is a cache of the policy-bound value and must not be mutated independently. Add an assertion in ClaimManager's `fileClaim` that `metadata.coverageLimit` equals the `requestedAmount`'s logical cap as a sanity check.

---

## Finding [SC-9]: premiumRatePerSecond Unit Mismatch Risk — WAD-Scaled Rate Applied to BPS-Denominated Principal

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R14:✓, R8:✗(single-pass arithmetic, no stored external state), R10:✓]
**Depth Evidence**: [BOUNDARY:premiumRatePerSecond=MAX(15_854_895_991 wei/sec), totalPrincipal=depositCap=MAX_UINT256/maxCoverableLossBps → overflow risk in mulDiv], [VARIATION:premiumRatePerSecond denominated as WAD(1e18)-scaled while totalPrincipal is raw-token denominated — cross-unit multiply requires WAD divisor], [TRACE:_accruePremium L54: totalPrincipal.mulDiv(premiumRatePerSecond * elapsed, WAD) — units: [token] * [WAD/sec * sec] / WAD = [token] ✓]]
**Severity**: Informational
**Location**: CoveredVaultAccrual.sol:53-54, CoveredVaultStorage.sol:50-54

**Description**:
`premiumRatePerSecond` is WAD-scaled (1e18 denominator), representing tokens per unit of principal per second. `totalPrincipal` is raw token units. The product `premiumRatePerSecond * elapsed` has units `[WAD / sec * sec] = [WAD]`, and dividing by `WAD` gives `[dimensionless ratio * totalPrincipal tokens] = [tokens accrued]`.

The dimensional analysis is correct. The comment at CoveredVaultStorage.sol:54 (`MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991`) represents WAD * 50% / (365 * 24 * 3600) = ~50% APR.

No unit mismatch. The semantic naming (`premiumRatePerSecond`) could be more explicit — it should be called `premiumRatePerSecondWAD` or `premiumRatePerSecondScaled` to signal the WAD scaling to future developers who may confuse it with a raw bps rate. This is an informational naming inconsistency.

**Evidence**:
```solidity
// CoveredVaultStorage.sol:50-54
uint256 internal constant WAD = 1e18;
/// @notice Maximum allowed premium rate: ~50% per year (WAD-scaled per second)
uint256 internal constant MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991;

// CoveredVaultAccrual.sol:53-54
uint256 accrued = _totalPrincipal > 0
    ? _totalPrincipal.mulDiv(premiumRatePerSecond * activeElapsed, WAD, Math.Rounding.Floor)
    : 0;
```

The variable name omits the WAD-scaled qualifier, creating a semantic ambiguity for integrators reading the interface `premiumRatePerSecond()` — it appears to be a per-second raw amount but is actually WAD-scaled.

---

## Finding [SC-10]: BPS Scale Agreement — All BPS Parameters Use 10_000 as 100% Consistently

**Verdict**: REFUTED
**Step Execution**: ✓1,2,3
**Rules Applied**: [R14:✗(hardcoded, not settable)]
**Severity**: Informational
**Location**: Multiple

**Description**:
Verified that all BPS-denominated parameters across the codebase use `10_000 = 100%`:
- `CoverPool._MAX_POOL_FEE_BPS = 2000` → 20% max pool fee ✓
- `PremiumManager._BPS_DENOMINATOR = 10_000` → 100% ✓
- `PremiumManager._MAX_PLATFORM_FEE_BPS = 2500` → 25% ✓
- `CoveredVaultStorage.BPS_DENOMINATOR = 10_000` → 100% ✓
- `maxCoverableLossBps` range: (0, 10_000] → (0%, 100%] ✓
- `deductibleBps` range: [0, maxCoverableLossBps) → uncapped above ✓

No WAD vs BPS confusion exists between contracts. No 10_000 vs 1e18 mixing detected.

---

## Chain Summary

| Finding ID | Title | Severity | Verdict | Potential Chain With |
|------------|-------|----------|---------|---------------------|
| SC-5 | _MAX_FEE_BPS=100% guard semantically misleading; no reachable underflow today but future regression risk if fee caps raised | Low | CONFIRMED | PC4-2 (poolFeeBps live-read front-run) |
| SC-8 | CoveredVaultWrapper caches coverageLimit locally; ClaimManager reads live from PolicyManager — dual-source divergence on upgrade | Low | CONFIRMED | RS1-1 (ClaimManager maturityTime vs wrapper effectiveMaturity) |
| SC-9 | premiumRatePerSecond missing WAD-scaled qualifier in name; naming inconsistency not exploitable but ambiguous for integrators | Informational | CONFIRMED | None |
| SC-1 | gateGracePeriod seconds unit consistent between producer (setMorphoGateActive) and consumer (_activeElapsedFrom, _isPolicyActive) | Informational | REFUTED | N/A |
| SC-2 | ClaimManager raw maturityTime vs wrapper effectiveMaturity — duplicate of RS1-1 | (Duplicate) | REFUTED | N/A |
| SC-3 | coverageLimit units consistent (payout-token raw amount) across all contracts | Informational | REFUTED | N/A |
| SC-4 | _BPS_DENOMINATOR naming isolated per-contract, both 10_000, no shared semantic | Informational | REFUTED | N/A |
| SC-6 | deductibleBps/maxCoverableLossBps invisible to ClaimManager (wrapper handles pre-computation) | Informational | REFUTED | N/A |
| SC-7 | policyId starts at 1 (pre-increment), wrapper guard policyId != 0 correctly calibrated | Informational | REFUTED | N/A |
| SC-10 | All BPS parameters consistently use 10_000 = 100% across all contracts | Informational | REFUTED | N/A |
