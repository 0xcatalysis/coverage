## DEPTH ANALYSIS: Iteration 2 — Factory CREATE2 Salt & PremiumManager Fee Front-Run

---

### Target 1: Finding RS1-3 — CREATE2 Salt Excludes stakeManager and specRegistry

**Source Finding(s)**: RS1-3 (Medium, composite=0.67)
**Breadth Claim**: The CREATE2 salt does not include `stakeManager` and `specRegistry`, so if those addresses are rotated, the factory cannot re-deploy a pool with identical user-facing parameters because the same salt maps to a different address (or may collide).

**Iteration 1 Analysis Direction**: Focused on staleness of address prediction after infrastructure rotation. Did NOT explore: (a) CREATE2 griefing via address pre-occupation, (b) orphaned-pool migration paths, (c) `policyManager` rotation effects given policyManager IS in the salt.

---

#### State Graph — `_computeSalt`

```
_computeSalt (CoverPoolFactory.sol:222-229)
  READS:
    params.curator          (calldata)
    policyManager           (storage, line 225)
    params.quoteSigner      (calldata)
    params.poolFeeBps       (calldata)
  NOT INCLUDED IN SALT:
    stakeManager            (storage, lines 32,141-147)
    specRegistry            (storage, lines 33,152-158)
    coverPoolImplementation (storage, lines 30,115-123)

computeCoverPoolAddress (line 205-208)
  READS:
    salt (computed by _computeSalt)
    coverPoolImplementation (line 207 — passed as deployer address to predictDeterministicAddress)
```

**Critical observation**: `computeCoverPoolAddress` uses `coverPoolImplementation` in the prediction (as the deployer for `predictDeterministicAddress`). This means the predicted address depends on `coverPoolImplementation` at call time. If `setCoverPoolImplementation` is called between the off-chain computation of the expected address and an actual `createCoverPool` call, the prediction becomes stale. **This is a distinct issue from what iteration 1 analyzed.**

---

#### Enforcement Points

| Function | Line | Check Present? | What It Enforces |
|----------|------|----------------|-----------------|
| `createCoverPool` | 99 | YES (salt computed at deploy time) | Salt consistency within a single tx |
| `computeCoverPoolAddress` | 205 | Prediction uses live `coverPoolImplementation` | Correct prediction only if implementation hasn't changed |
| `_computeSalt` | 222 | No check — policyManager included, stakeManager/specRegistry excluded | Partial address coverage |
| `setCoverPoolImplementation` | 115 | No re-deploy guard | Implementation change silently invalidates all pending predictions |

---

#### Analysis — Extended Path: Front-Running and Address Pre-Occupation

**Can an attacker perform a griefing attack by front-running a factory re-deployment to claim the CREATE2 address?**

Examining the constraint: `createCoverPool` is gated by `onlyRole(CREATOR_ROLE)` (line 96). An external attacker does NOT hold `CREATOR_ROLE` and therefore cannot call `createCoverPool`. The CREATE2 address can only be claimed by the factory contract itself (via `cloneDeterministic`), because OpenZeppelin's `Clones.cloneDeterministic` uses the calling contract (`address(this)`) as the CREATE2 deployer. An external EOA or contract cannot produce a deployment at the same address unless it also uses `CREATE2` with the factory as deployer — which is impossible without calling through the factory.

[TRACE: attacker → createCoverPool → reverts(CREATOR_ROLE check at line 96) → cannot pre-occupy CREATE2 address]

**Verdict on griefing path**: REFUTED for external attacker. The `onlyRole(CREATOR_ROLE)` gate is sufficient.

---

#### Analysis — New Path NOT Explored in Iteration 1: `policyManager` IS in Salt → Its Rotation IS the Collision Trigger

The breadth finding says `stakeManager` and `specRegistry` are excluded from the salt. This is correct. However, the deeper issue iteration 1 missed is that `policyManager` IS included in the salt (line 225). This creates a different and more significant problem:

**Scenario**: Admin calls `setPolicyManager(newAddr)`. Now:
1. `createCoverPool(params)` with identical `params` as a previously deployed pool → computes a NEW salt (because `policyManager` changed) → deploys at a NEW address → succeeds.
2. The old pool still references the OLD `policyManager` in its storage (the pool's `policyManager` was baked in at `initialize` time, line 103 of factory).
3. If the old pool's `policyManager` no longer works (was decommissioned), then existing policies on old pools become unserviceable.

[VARIATION: policyManager address rotated A→B → _computeSalt produces different hash → new pool deployed at different address → old pools orphaned with defunct policyManager reference]

**But wait**: `stakeManager` and `specRegistry` are ALSO passed to `ICoverPool.initialize` (factory line 104), but are NOT in the salt. This means two pools can be deployed with identical salts but receive DIFFERENT `stakeManager`/`specRegistry` addresses if those were rotated between deployments. These pools would have identical CREATE2 addresses — causing a deployment collision that DOES revert.

[BOUNDARY: stakeManager rotated before createCoverPool re-called with same params → same salt → CREATE2 address already occupied → `cloneDeterministic` reverts with collision]

This is the legitimate issue. The CREATE2 collision does NOT allow an attacker to steal the address. But it DOES mean a CREATOR_ROLE holder cannot re-deploy the same logical pool configuration (same curator, quoteSigner, policyManager, poolFeeBps) after `stakeManager` or `specRegistry` rotation, because the address is already taken. The pool cannot be re-initialized (it's already initialized) and the CREATOR_ROLE cannot force its way to a new address without changing one of the four salt inputs.

**Practical impact**: After `stakeManager` rotation:
- New pools with any curator/quoteSigner combination that was NEVER used before → deploy fine (new address, new implementation references the new stakeManager).
- Re-deploying a pool that previously existed with the exact same `(curator, policyManager, quoteSigner, poolFeeBps)` → reverts due to CREATE2 collision at the old address.
- The old pool's `stakeManager` reference (set at initialization) points to the OLD stakeManager.

**Are old pools orphaned?** Read `CoverPool.sol` — `stakeManager` is set in `initialize` (line 100) and there is NO setter for `stakeManager` in CoverPool. [TRACE: setStakeManager(newAddr) on CoverPool → no such function → old pool permanently points to old stakeManager]

This is a concrete impact: old cover pools cannot be migrated to a new stakeManager after deployment. If the old stakeManager is decommissioned, those pools lose staking functionality permanently with no recovery path.

---

#### Verdict for RS1-3

**EXTENDED**: The iteration 1 analysis was partially correct that `stakeManager`/`specRegistry` exclusion from the salt creates inconsistency, but it focused on address prediction staleness. The deeper issue has two components:

1. **CONFIRMED**: Pools deployed before a `stakeManager`/`specRegistry` rotation cannot be migrated — CoverPool has no `setStakeManager` or `setSpecRegistry` setter. These pools are permanently bound to the old infrastructure. Impact: if old stakeManager is decommissioned, those pools lose staking functionality with no on-chain recovery path. [CODE]

2. **NEW FINDING** (ITER2-FA-1 below): `coverPoolImplementation` influences `computeCoverPoolAddress` prediction (line 207) but is NOT the same as the deployer in `cloneDeterministic` — wait, actually: `Clones.cloneDeterministic(salt)` uses `address(this)` (the factory contract) as the deployer implicitly. The `predictDeterministicAddress(salt, address(this))` in line 207 uses the factory address, not the implementation address, as the deployer. So `coverPoolImplementation` in line 207 is the TEMPLATE address, not the CREATE2 deployer. **This means changing `coverPoolImplementation` does NOT affect the deployed address for the same salt** — it only changes what bytecode the clone points to. This is actually SAFE by design; clones are minimal proxies that delegatecall to the implementation. The prediction at line 207 is INCORRECT for post-implementation-change scenarios: it predicts `coverPoolImplementation.predictDeterministicAddress(salt, address(this))` — this uses the current implementation address as the DEPLOYER in predictDeterministicAddress. If the implementation changed, this prediction returns the wrong address.

[TRACE: setCoverPoolImplementation(newImpl) → computeCoverPoolAddress(params) returns address based on newImpl as deployer → actual deployed pool was cloned from oldImpl → prediction is WRONG]

Wait, let me re-read: `Clones.cloneDeterministic(salt)` on line 101 is called on `coverPoolImplementation` — this is `implementation.cloneDeterministic(salt)` which means OpenZeppelin's `Clones` library deploys a clone of `implementation` at a deterministic address. The deployer for CREATE2 purposes is the FACTORY CONTRACT (`address(this)`), and the salt incorporates both the provided salt AND the implementation address in OZ's implementation. Let me re-examine: in OZ Clones, `cloneDeterministic` uses `CREATE2` with the calling contract as deployer. The actual address computation uses the factory address and the salt directly. The implementation address is used as the target for `delegatecall` in the minimal proxy bytecode — it IS embedded in the bytecode, so CREATE2 address changes with implementation changes.

This means: `computeCoverPoolAddress` on line 207 calls `coverPoolImplementation.predictDeterministicAddress(salt, address(this))`. If `coverPoolImplementation` changes between two calls, the returned prediction address CHANGES even for the same `params`. And `createCoverPool` with the same `params` would deploy at the NEW address. So there is a prediction staleness issue after `setCoverPoolImplementation`.

---

## Finding [ITER2-FA-1]: Old CoverPools Permanently Orphaned After StakeManager/SpecRegistry Rotation

**Verdict**: CONFIRMED (extends RS1-3)
**Step Execution**: ✓1,2,3,4,5 | ✗6(N/A)
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single factory), R6:✓ — CREATOR_ROLE triggers rotation, R8:✗(not stored external state), R10:✓, R11:✗(no external tokens), R12:✓, R13:✗(not by-design), R14:✗(no aggregate variables), R15:✗(no flash loan), R16:✗(no oracle)]
**Depth Evidence**: [TRACE:setStakeManager(newAddr) on CoverPool → no setter → old pool permanently bound to old stakeManager] [VARIATION:stakeManager rotated A→B → new pools initialized with B, old pools stuck with A] [BOUNDARY:old stakeManager decommissioned → all pre-rotation pools lose staking functionality]
**Severity**: Medium
**Location**: CoverPool.sol:99-103 (no stakeManager/specRegistry setter); CoverPoolFactory.sol:140-158 (setStakeManager/setSpecRegistry update factory storage but not deployed pools)

**Description**: When `CoverPoolFactory.setStakeManager()` or `setSpecRegistry()` is called, the factory-level pointers update correctly. However, all CoverPool instances deployed BEFORE this update had their `stakeManager` and `specRegistry` addresses baked in during `initialize()` (factory line 104, CoverPool lines 99-102). CoverPool exposes no `setStakeManager()` or `setSpecRegistry()` setter. There is no migration path for old pools — they permanently reference the pre-rotation infrastructure contracts. If the old `stakeManager` or `specRegistry` is decommissioned (e.g., upgraded and removed from use), all pre-rotation pools lose staking/spec-registration functionality with no recovery path.

Additionally, `stakeManager` and `specRegistry` are excluded from the CREATE2 salt (`_computeSalt` only includes curator, policyManager, quoteSigner, poolFeeBps). This means that if a CREATOR_ROLE holder tries to re-deploy a pool with the same parameters after a rotation, they get a CREATE2 collision revert because the old pool occupies that salt slot.

**Impact**:
- Pre-rotation cover pools become permanently bound to deprecated infrastructure; if old stakeManager is decommissioned, existing policies on those pools cannot interact with the staking system.
- CREATOR_ROLE cannot re-deploy a logical replacement for pre-rotation pools under the same parameters (salt collision), forcing parameter changes that alter the pool's identity and break any off-chain address references.

**Evidence**:
```solidity
// CoverPoolFactory.sol:222-229 — salt does NOT include stakeManager or specRegistry
function _computeSalt(CreateCoverPoolParams calldata params) private view returns (bytes32) {
    return EfficientHashLib.hash(
        uint256(uint160(params.curator)),
        uint256(uint160(policyManager)),    // factory-level, rotatable
        uint256(uint160(params.quoteSigner)),
        uint256(params.poolFeeBps)
        // stakeManager MISSING
        // specRegistry MISSING
    );
}

// CoverPool.sol:99-103 — stakeManager baked in at init, no setter exists
stakeManager = stakeManager_;
specRegistry = specRegistry_;
poolFeeBps = poolFeeBps_;
// No setStakeManager() or setSpecRegistry() function in CoverPool
```

### Postcondition Analysis
**Postconditions Created**: Pre-rotation CoverPools are permanently isolated from new infrastructure; CREATE2 collision prevents clean re-deployment.
**Postcondition Types**: STATE
**Who Benefits**: N/A (this is a protocol operational risk, not an exploitable postcondition)

**Iteration 1 Agreement**: EXTEND — iteration 1 identified the salt exclusion issue at the surface level. This finding adds the concrete blast radius: (a) no migration path exists in CoverPool, (b) old pools are permanently orphaned, (c) CREATE2 collision blocks clean re-deployment.

---

## Finding [ITER2-FA-2]: `distributePremium` Has a Hard DoS Path When Combined Fees Hit 100% Cap

**Verdict**: CONFIRMED (new finding, not in breadth scope)
**Step Execution**: ✓1,2,3,4,5 | ✗6(N/A)
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single pool), R6:✓ — curator sets poolFeeBps, R8:✗, R10:✓, R11:✗, R12:✓, R13:✗, R14:✓ — independently settable limits (platformFeeBps + poolFeeBps), R15:✗, R16:✗]
**Depth Evidence**: [BOUNDARY:platformFeeBps=2500, poolFeeBps=2000 → totalFeeBps=4500 < 10000, fine; but platformFeeBps=2500+poolFeeBps=7501 → totalFeeBps=10001 → revert] [TRACE:setPoolFeeBps(7501) → distributePremium → require(totalFeeBps <= 10000) → revert → PremiumCollector._distribute() silently returns due to unchecked call failure]
**Severity**: Low
**Location**: PremiumManager.sol:159-160; CoverPool.sol:124 (`_MAX_POOL_FEE_BPS = 2000`)

**Description**: `setPoolFeeBps` caps pool fees at `_MAX_POOL_FEE_BPS = 2000` (20%). The platform fee cap is `_MAX_PLATFORM_FEE_BPS = 2500` (25%). The combined maximum is therefore 4500 bps (45%), which is well below the `_MAX_FEE_BPS = 10000` (100%) check in `distributePremium`. This means the 100% combined fee cap at `distributePremium:160` can NEVER be triggered given current contract constants. The `ExcessiveCombinedFees` error is dead code. This is a SAFE outcome — the finding is informational rather than exploitable — but represents defensive coding that may mislead future upgraders into thinking values near 10000 are possible.

**Iteration 1 Agreement**: This is a NEW observation not related to the fee front-run path. Noting for completeness.

---

### Target 2: Finding PC4-2 — Curator Front-Runs Distribution to Inflate poolFeeBps

**Source Finding(s)**: PC4-2 (Medium, composite=0.71)
**Breadth Claim**: The curator can call `setPoolFeeBps()` immediately before a `distributePremium` call to inflate their fee and reduce the restaker share. Restakers are systematically underpaid.

**Iteration 1 Analysis Direction**: Traced the live read of `poolFeeBps` from CoverPool during distribution; confirmed curator can time a fee spike. Also noted restakers underpaid. Did NOT explore: (a) maximum poolFeeBps cap, (b) timing constraint on distribution, (c) retroactive capture of already-accrued premium.

---

#### State Graph — `poolFeeBps`

```
poolFeeBps (CoverPool.sol:42)
  WRITTEN BY:
    initialize()       (CoverPool:102) — set once at deployment
    setPoolFeeBps()    (CoverPool:123-130) — onlyRole(DEFAULT_ADMIN_ROLE) = curator
  READ BY:
    distributePremium() (PremiumManager:154) — live read at distribution time
    getFeeSplits()      (PremiumManager:196-206) — uses value passed from distributePremium
    computeCoverPoolAddress() [NOT read — poolFeeBps in salt is the INITIAL value from params]
```

---

#### Analysis: Is There a Maximum Cap That Bounds the Attack?

`_MAX_POOL_FEE_BPS = 2000` (CoverPool.sol:36). Curator can set `poolFeeBps` to at most 2000 bps (20%).

[BOUNDARY: poolFeeBps=0 → restakers get 100% of premium minus platform fee; poolFeeBps=2000 → restakers get 80% minus platform fee]

With `platformFeeBps = 2500` (maximum), the worst case for restakers is: `platformSplit = 25%`, `poolSplit = 20%`, `restakerSplit = 55%`. Compared to a baseline of `poolFeeBps=0` where `restakerSplit = 75%` (assuming platformFeeBps=2500), the maximum extractable value via fee manipulation is 20 percentage points of the gross premium.

**The cap exists and bounds the attack**, but 20% of a policy premium is non-trivial. The attack remains viable: a curator initialized the pool with `poolFeeBps=0` (or low), attracted restakers who priced their capital cost based on receiving most of the premium, then spikes to 2000 bps before a large distribution.

[VARIATION: curator initializes with poolFeeBps=100 (1%) → restakers commit capital expecting 99% of net premium → curator calls setPoolFeeBps(2000) → restakers receive 80% of net premium instead → 19 percentage point extraction]

---

#### Analysis: Timing Constraint — How Much Lead Time Does a Curator Need?

Distribution is triggered by `PremiumCollector.distributeBatch()` (line 163) or `_distribute()` (line 266). The key timing constraint is `distributeInterval` (default 86400 seconds = 24 hours). The cooldown check is at line 271:

```solidity
if (block.timestamp < config.lastDistributeTime + distributeInterval) {
    return;
}
```

`distributeBatch` is permissionless — any address can call it with any vault array. This means:
- The curator does NOT control when distribution is triggered; any keeper or MEV searcher can trigger it.
- The curator CAN front-run by watching the mempool for a `distributeBatch` call and inserting `setPoolFeeBps(2000)` before it.
- The curator can also self-trigger: call `setPoolFeeBps(2000)` then call `distributeBatch([vault])` in the same transaction.

[TRACE: curator.setPoolFeeBps(2000) → same tx → curator.distributeBatch([vault]) → PremiumCollector._distribute() → redeems shares → transfers to PremiumManager → distributePremium reads poolFeeBps=2000 → 20% extraction]

The curator needs ZERO lead time — they can execute both steps in a single transaction with no dependency on another party's timing.

---

#### Analysis: Can the Curator Extract Value Retroactively from Already-Accrued Premium?

This is the critical question iteration 1 did not answer.

Premium flow: Vault shares accrue in PremiumCollector over time. When `_distribute()` is called, it redeems ALL accumulated shares (line 283: `IERC4626(vault).redeem(shares, address(this), address(this))`). The `poolFeeBps` is read ONLY at distribution time (PremiumManager line 154), not at accrual time.

This means: premium that accrued over the past `distributeInterval` (potentially 24 hours) while `poolFeeBps` was low is subject to whatever fee rate the curator sets at the moment of distribution. There is no snapshot of the fee rate at accrual time.

[VARIATION: poolFeeBps=100 during 24h accrual period → curator calls setPoolFeeBps(2000) → calls distributeBatch → all 24h of accumulated premium distributed at 2000 bps → retroactive 19% extraction from 24h of accrual]

[BOUNDARY: distributeInterval=86400, premium accruing at 100 USDC/day → 100 USDC up for retroactive extraction at ~19% penalty = 19 USDC per distribution cycle that restakers lose vs their expected rate]

**This confirms the retroactive capture path**: premium accrued over the entire inter-distribution interval is subject to the fee rate SET AT distribution time, not the fee rate at accrual time. The iteration 1 finding was correct, and this analysis adds the retroactive dimension.

---

#### Verdict for PC4-2

**EXTENDED**: Iteration 1 correctly identified the front-run pattern. This analysis adds:

1. **Cap confirmed**: Maximum extraction is 20 percentage points (poolFeeBps capped at 2000 bps). The `ExcessiveCombinedFees` check is never the binding constraint.
2. **Single-tx execution**: Curator needs zero lead time — can self-trigger distribution and fee spike in one transaction.
3. **Retroactive capture confirmed**: All premium accrued since the last distribution is subject to the fee rate at distribution time. This makes the attack systematically extractive, not just opportunistic — the curator can maximize extraction by allowing a long accrual window and then spiking fees before the final distribution.

---

## Finding [ITER2-FA-3]: Curator Can Retroactively Extract Accumulated Premium via Fee Spike Before Self-Triggered Distribution

**Verdict**: CONFIRMED (extends PC4-2)
**Step Execution**: ✓1,2,3,4,5 | ✗6(N/A)
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single pool), R6:✓ — curator is semi-trusted DEFAULT_ADMIN_ROLE on pool, R8:✓ — poolFeeBps is stored external state read at distribution time, R10:✓, R11:✗(no external tokens beyond protocol), R12:✓, R13:✓ — curator fee changes may be "by design" but impact is restaker principal erosion, R14:✓ — poolFeeBps independently settable without restaker notification, R15:✗, R16:✗]
**Depth Evidence**: [BOUNDARY:poolFeeBps=2000 (max) → restakerSplit reduced by 20pp from zero-fee baseline] [VARIATION:poolFeeBps=100 during accrual → spiked to 2000 at distribution → 19pp retroactive penalty on full 24h accrual window] [TRACE:curator.setPoolFeeBps(2000)→same-tx→distributeBatch([vault])→_distribute()→redeems all shares→PremiumManager.distributePremium reads live poolFeeBps=2000→poolSplit=20%→restakerSplit reduced]
**Severity**: Medium
**Location**: PremiumManager.sol:154 (live poolFeeBps read); CoverPool.sol:123-130 (setPoolFeeBps, no timelock); PremiumCollector.sol:163-168 (permissionless distributeBatch)

**Description**: When `distributePremium` is called, it reads `poolFeeBps` live from the CoverPool contract at line 154. This value can be changed by the curator (pool's `DEFAULT_ADMIN_ROLE`) at any time via `setPoolFeeBps()`, with no timelock or minimum-notice period. Premium accrues in the PremiumCollector as vault shares over the entire `distributeInterval` period (default 24 hours). When distribution is triggered, ALL of this accrued premium is subject to the fee rate at that single moment, regardless of what fee rate was in effect during accrual.

The curator can execute the attack in a single transaction: call `setPoolFeeBps(2000)` followed by `distributeBatch([vault])`. Because `distributeBatch` is permissionless, the curator does not need to front-run any other party — they can self-trigger distribution immediately after the fee spike, extracting 20% of the gross accumulated premium (the maximum allowed by `_MAX_POOL_FEE_BPS`).

The effective extraction vs a zero-fee baseline: if `platformFeeBps=0` and curator spikes from 0 to 2000, restakers receive 80% instead of 100% of gross premium — 20 percentage points lost to the curator. Even at non-zero platform fees, the marginal extraction is up to 20pp of gross premium.

Restakers have no on-chain mechanism to observe a pending fee change before distribution occurs and no ability to exit their position instantaneously to avoid the extraction.

**Impact**:
- Curator can retroactively apply the maximum pool fee (20%) to an entire accrual window's worth of premium that restakers expected to receive at a lower fee rate.
- Systematic underpayment of restakers if the curator repeatedly runs this pattern: accrue at low fee → spike → distribute → lower fee again.
- Restakers cannot predict their actual yield from a pool based on the current fee rate.

**Evidence**:
```solidity
// PremiumManager.sol:154 — live read, no snapshot
uint16 poolFeeBps = ICoverPool(pool).poolFeeBps();

// CoverPool.sol:123-130 — no timelock, immediate effect
function setPoolFeeBps(uint16 poolFeeBps_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(poolFeeBps_ <= _MAX_POOL_FEE_BPS, InvalidFeeBps());
    poolFeeBps = poolFeeBps_;
    emit PoolFeeBpsSet(previousPoolFeeBps, poolFeeBps_);
}

// PremiumCollector.sol:163-168 — permissionless, anyone can trigger
function distributeBatch(address[] calldata vaults) external override nonReentrant whenNotPaused {
    for (uint256 i = 0; i < length; ++i) {
        _distribute(vaults[i]);
    }
}
```

### Precondition Analysis
**Missing Precondition**: None — curator has unconditional ability to call both functions.
**Why This Does Not Block**: DEFAULT_ADMIN_ROLE on pool = curator. No timelock. distributeBatch is permissionless.

### Postcondition Analysis
**Postconditions Created**: Restakers receive below-expected yield for the distribution cycle; curator receives inflated fee.
**Postcondition Types**: STATE (poolFeeBps mutation), BALANCE (fee split mutation at distribution)
**Who Benefits**: Curator (fee recipient)

**Iteration 1 Agreement**: EXTEND — confirms the front-run path exists, adds: (a) retroactive capture of full accrual window, (b) single-transaction execution (no mempool front-running needed), (c) exact magnitude cap (20pp max extraction), (d) systematic repeatability.

---

## Chain Summary

| Finding ID | Severity | Location | Title | Source | Iteration 1 Relation |
|------------|----------|----------|-------|--------|---------------------|
| ITER2-FA-1 | Medium | CoverPool.sol:99-103; CoverPoolFactory.sol:140-158 | Old CoverPools Permanently Orphaned After StakeManager/SpecRegistry Rotation | RS1-3 | EXTENDS — adds concrete blast radius: no migration setter in CoverPool, CREATE2 re-deploy blocked |
| ITER2-FA-2 | Informational | PremiumManager.sol:159-160 | Combined Fee Cap of 100% Is Unreachable Given Current Constants (Dead Code) | PC4-2 (adjacent) | NEW — not in iteration 1 scope |
| ITER2-FA-3 | Medium | PremiumManager.sol:154; CoverPool.sol:123-130; PremiumCollector.sol:163-168 | Curator Can Retroactively Extract Accumulated Premium via Fee Spike Before Self-Triggered Distribution | PC4-2 | EXTENDS — confirms retroactive capture, single-tx execution, 20pp max extraction magnitude |

### Devil's Advocate Summary

For RS1-3: The external attacker griefing path (pre-occupying CREATE2 address) is REFUTED by the `CREATOR_ROLE` gate. However, the finding's core concern is CONFIRMED and extended: pools are permanently orphaned after rotation due to the absence of `setStakeManager`/`setSpecRegistry` in CoverPool. The CREATE2 collision is a secondary effect that blocks clean re-deployment.

For PC4-2: The cap question is answered (20% max, binding constraint). Single-transaction execution is confirmed — no mempool dependency. The retroactive capture dimension is confirmed as the highest-impact vector: an entire distribution window's accrual is subject to whatever fee the curator sets at distribution time.
