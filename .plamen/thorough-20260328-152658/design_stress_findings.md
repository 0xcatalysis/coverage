# Design Stress Test Findings

Agent: Design Stress Testing Agent (Unconditional Slot)
Scope: CoveredVaultWrapper insurance protocol — systemic economic and architectural failure modes

---

## Finding [DST-1]: Premium Drain Spiral — No Circuit Breaker Against Protocol-Killing Rate

**Verdict**: CONFIRMED
**Severity**: Design Limit
**Location**: `CoveredVaultAccrual.sol:_accruePremium`, `CoveredVaultStorage.sol:MAX_PREMIUM_RATE_PER_SECOND`

### Stress Scenario

**Hypothesis**: If premiumRatePerSecond is set at or near `MAX_PREMIUM_RATE_PER_SECOND` (~50% APR), it can drain totalAssets faster than Morpho yield accrues, creating a structural premium-drain spiral.

**Quantitative Analysis**:

The protocol caps `premiumRatePerSecond` at `MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991` wei/second, which equals ~50% APR on principal.

For a Morpho vault earning a typical 5-10% APY:
- Premium drain rate at MAX: ~50% APR on principal
- Morpho yield: 5-10% APY on total assets (principal + accumulated yield)

At MAX_PREMIUM_RATE_PER_SECOND with totalPrincipal = depositCap = 1,000,000 USDC:
- Per-year premium: ~500,000 USDC
- Per-year Morpho yield (10% APY): ~100,000 USDC
- Net annual drain: ~400,000 USDC (40% of depositor principal per year)

`totalAssets()` formula: `morphoValue - totalPremiumLiability - accruedPremium`

After the liability cap (Invariant 1: `totalPremiumLiability <= morphoValue`) is hit, `_liabilityHeadroom()` returns 0 and further premium accrual pauses. At this point `totalAssets() = 0`, meaning all depositor assets are consumed by premium liability.

**Does the protocol survive the spiral?**

Partially. The liability headroom cap (`_liabilityHeadroom`) IS the circuit breaker for the accounting invariant, but it does NOT protect depositors from economic loss:

1. Once `totalPremiumLiability >= morphoValue`, share price → 0 (totalAssets = 0).
2. Depositors who exit during this state receive `assetsReceived - premiumForWithdrawal ≈ 0` with deep-loss guard in `_settleWithdrawalTransfer` capping premium at `assetsReceived`.
3. Insurance only triggers if `insuredBasis > netAssetsReceived`. If premium has consumed all assets AND there is no loss event (just premium drain), `insuredBasis = principal - premiumForWithdrawal ≈ 0` too — insurance does NOT trigger because it is not a "loss" in the Morpho loss sense, it is premium drain.

**Spiral Mechanism**:

1. Owner sets premium to near-MAX (2-hour timelock can be bypassed by a compromised or distressed operator)
2. Premium exceeds Morpho yield → `totalAssets()` declines → early depositors detect decline and rush to exit
3. Withdrawals trigger `_accruePremium()` → liability is checkpointed → premium is deducted from each withdrawing user
4. `depositCap` reopens as `totalPrincipal` drops (since `depositCap - totalPrincipal` is returned by `maxDeposit`)
5. New depositors can enter mid-drain because `policyBoundExecuted` is still true and `totalPrincipal < depositCap`
6. New entrants inherit the ongoing premium drain (though they get a fresh `userPremiumDebt` offset)

**Key asymmetry**: Premium-drained depositors receive approximately `(principal - owed_premium) + insurance_for_morpho_loss`. If Morpho has no loss but premium consumed 50% of principal, depositor receives 50% of deposit with NO insurance (no coverage for premium drain — only for Morpho loss shortfall).

**Circuit Breakers Present**:
- `MAX_PREMIUM_RATE_PER_SECOND` cap (50% APR) — exists but is extremely high for typical DeFi yields
- `_liabilityHeadroom` stops liability exceeding morphoValue — accounting protection only, not economic
- 2-hour timelock on rate changes — limits per-hour damage from a single rate change to ~0.0057% of principal

**Missing Mechanisms**:
- No maximum sustainable premium rate calculated as a function of Morpho's current yield
- No automatic rate ceiling tied to Morpho APY (e.g., rate <= morpho_apy / 2)
- No circuit breaker that pauses new deposits when `totalAssets() < X%` of `totalPrincipal`
- No user notification mechanism when premium exceeds yield (totalAssets declining)

**Impact**: At MAX_PREMIUM_RATE_PER_SECOND with 5% Morpho APY, depositors lose ~42% of principal per year to premium regardless of whether Morpho has any losses. This is economically indistinguishable from a slow rug. The 2-hour timelock limits rapid rate increases but a sustained high rate is fully within owner's rights.

**Severity Assessment**: Design Limit. The system does not fail mechanically (invariants hold), but the economic design allows a premium rate that can destroy depositor value independent of the insurance event it ostensibly covers. The 50% APR cap is a technical ceiling, not an economic ceiling calibrated to the yield source.

---

## Finding [DST-2]: Systemic Morpho Exploit — Single Policy Cannot Absorb Correlated Losses

**Verdict**: CONFIRMED
**Severity**: Design Limit
**Location**: `CoveredVaultWrapper.sol:_claimInsurance`, `ClaimManager.sol:_capAndExecutePayout`

### Stress Scenario

**Hypothesis**: The insurance model assumes approximately uncorrelated losses. What happens when ALL Morpho vaults using CoveredVaultWrapper experience simultaneous losses from a single Morpho exploit?

**Protocol Survival Analysis**:

Each CoveredVaultWrapper has exactly ONE policy with ONE `coverageLimit` backed by ONE restaker committee (EigenLayer/Symbiotic stake). The committee's slashable stake is validated at `bindPolicy()` time for USD equivalence with `coverageLimit`.

For systemic loss (e.g., Morpho exploit draining 30% of wrapped vault TVL across N wrappers):
- Each wrapper independently files claims against its own policy
- Each policy is backed by its own isolated committee stake
- No cross-contamination of coverage pools

**This is structurally sound for isolated losses. The systemic risk is real but bounded differently than assumed:**

The actual systemic risk is NOT that coverage pools share liabilities. The actual risk is:

1. **Slashing illiquidity**: All N committees receive simultaneous slash requests → `SlashingManager.executeSlashing()` must process N parallel slash transactions. If restakers have allocated the same EigenLayer strategy vault across multiple committees (a natural behavior to maximize yield on restaked assets), a single large slash event on that shared vault reduces available stake for all N committees simultaneously.

2. **Collateral swap failure**: `ClaimManager._processCollateral()` routes through Uniswap V3. A systemic crisis (e.g., Morpho exploit) will simultaneously stress DEX liquidity. All N claims trying to swap restaker collateral (ETH, BTC, staking tokens) to the vault's underlying asset (USDC) at the same time will experience slippage. The `maxSwapSlippageBps = 200` (2%) slippage cap means each swap gets `amountOutMin = quoted * 9800/10000`. In a crisis, quoted prices collapse → `amountOut` is less than `cappedClaim` → `totalPayout < cappedAmount` → `_policyClaims[policyId].totalPaidOut -= (cappedAmount - totalPayout)` (refund accounting) but the user receives less than the full insurance amount.

3. **Claim approval gate serialization**: After each successful claim, `_claimApprovalRequired[policyId] = true`. The curator must call `approveNextClaim()` to re-enable. For a systemic event where users withdraw en masse, only ONE withdrawal per block can succeed with insurance payout. All subsequent withdrawals in the same block that try to file claims will revert with `ClaimApprovalRequired` in the try/catch → they silently receive 0 insurance. **This is the critical finding**: the approval gate is per-policyId, but the vault has a single policyId. Under mass withdrawal after a Morpho loss event, only the FIRST withdrawer per curator approval cycle receives insurance.

**Protocol verdict for systemic Morpho exploit**:
- Coverage pools are isolated: SURVIVES systemic pooling
- Slippage during crisis: PARTIAL FAILURE (reduced payouts when markets are stressed, exactly when users need full coverage)
- Claim approval gate serialization: STRUCTURAL FAILURE for mass-withdrawal events

**Impact**: The claim approval gate is a correct mechanism to prevent rapid serial claiming, but it becomes a de-facto denial of insurance during the exact scenario insurance exists for: mass withdrawal after a Morpho loss event. The first user to withdraw post-loss gets full insurance; all subsequent users get nothing until the curator manually re-enables claims. In a panic scenario, the curator may be unavailable, delayed, or captured.

---

## Finding [DST-3]: Curator Incentive Misalignment — `setPremiumDefaulted` as Insurance Denial Weapon

**Verdict**: CONFIRMED
**Severity**: Structural
**Location**: `CoverPool.sol:setPremiumDefaulted`, `ClaimManager.sol:_fileClaimWithMetadata`

### Stress Scenario

**Hypothesis**: A curator controls both `setPremiumDefaulted` AND the `approveNextClaim` gate. Can a curator monetize insurance denial by timing parameter changes around large deposits?

**Attack Analysis**:

The curator (DEFAULT_ADMIN_ROLE on CoverPool) can call `setPremiumDefaulted(policyId, true)` at any time. This immediately sets `metadata.premiumDefaulted = true` in PolicyManager, causing ALL subsequent `fileClaim()` calls to revert with `PremiumDefaulted`.

The curator ALSO controls `approveNextClaim()` (required after each successful claim).

**Curator's combined controls over claim flow**:
1. **Pre-claim blocking**: Call `setPremiumDefaulted(policyId, true)` → all future claims revert
2. **Post-claim blocking**: Simply not call `approveNextClaim()` → second claim impossible

**Is this exploitable for profit?**

Unlike a typical rug scenario, the curator does NOT directly receive the insurance funds. Claim payments come from slashing the restaker committee — which the curator's operator's staked ETH/BTC backs. If the curator triggers a loss scenario AND blocks claims:
- Depositors don't get insurance → curator's restaked collateral is NOT slashed
- Depositors absorb the Morpho loss directly

**Economic value to curator**: A curator who also manages the Morpho vault (or has advance knowledge of an impending Morpho loss) could:
1. Allow deposits to accumulate (collecting premiums via premiumRecipient)
2. When Morpho loss is imminent, call `setPremiumDefaulted(true)`
3. Morpho suffers loss → depositors file claims → ALL REVERT with PremiumDefaulted
4. Curator's staked collateral is preserved

**Current protections**:
- `setPremiumDefaulted` can ALSO be set to `false` (curator can re-enable), so it's reversible
- The wrapper's `_claimInsurance` wraps `fileClaim` in try/catch — if ClaimManager reverts, it emits `ClaimManagerUnavailable` and the user receives 0 insurance (no revert)
- The 24-hour admin transfer delay on CoverPool provides some transition notice
- Timelock on CoveredVaultWrapper upgrade (7 days) but NOT on `setPremiumDefaulted`

**Critical gap**: There is NO timelock or delay on `setPremiumDefaulted`. The curator can call it in the same block as a Morpho loss event with zero on-chain warning. There is no event-based alerting that would trigger before `setPremiumDefaulted` executes (the transaction IS the event).

**What the curator must stake**: The curator's committee has staked assets (via EigenLayer/Symbiotic). The curator has skin in the game from slashing risk. However, if the curator is a separate entity from the restakers (the restakers fund the committee on behalf of the curator/operator), the curator's direct financial exposure to slashing may be limited.

**Impact**: Curator can unilaterally block all claims for a policy with zero notice and zero timelock. This is not a code bug — it is a deliberate design capability (defense against premium default). But it creates a principal-agent conflict where the curator's interest (preserving staked collateral) is directly opposed to the beneficiary's interest (receiving insurance on Morpho losses). The system has no mechanism to distinguish legitimate premium defaults from strategic claim denial.

---

## Finding [DST-4]: Policy Binding Lifecycle Gap — Deposits Accepted Before Coverage Window Opens

**Verdict**: CONFIRMED
**Severity**: Design Adequacy
**Location**: `CoveredVaultWrapper.sol:onPolicyBound`, `CoveredVaultAccrual.sol:_isPolicyActive`

### Stress Scenario

**Hypothesis**: Map the complete policy lifecycle and identify all periods where the vault accepts deposits but coverage is not active.

**Complete Lifecycle Map**:

```
State 0: Pre-binding
  - policyBoundExecuted = false
  - maxDeposit() = 0 → deposits BLOCKED
  - Coverage: NONE

State 1: Post-binding (policyBoundExecuted = true) but startTime NOT yet reached
  - depositCap set by onPolicyBound
  - maxDeposit() = depositCap - totalPrincipal → deposits OPEN
  - _isPolicyActive() = false (block.timestamp < startTime)
  - Insurance on withdrawal: _computeInsurance returns 0 (policy not active)
  - Premium accrual: _activeElapsedFrom returns 0 (because _isPolicyActive() = false
    and we're before startTime)
  - Coverage: NONE (deposits accepted, no insurance, no premium)

State 2: Active coverage window [startTime, maturityTime + gateGracePeriod]
  - Deposits OPEN (up to depositCap)
  - _isPolicyActive() = true
  - Insurance: ACTIVE
  - Premium: ACCRUING

State 3: Post-maturity
  - _isPolicyActive() = false
  - maxDeposit(): still returns depositCap - totalPrincipal (no check for policy expiry in maxDeposit())
  - Deposits OPEN even after policy expires
  - Premium: catch-up accrual for any gap between lastPremiumAccrualTime and effectiveMaturity
  - Insurance: NONE
```

**Uninsured Exposure Window — State 1**:

Between `onPolicyBound()` (which opens deposits) and `startTime` (when coverage begins), there is a structural gap. The length of this gap depends entirely on the quote's `startTime` parameter, which can be set as:
- `quote.startTime >= block.timestamp` (enforced in `CoverPool.validateQuote`)
- `quote.startTime > block.timestamp + X` where X can be arbitrarily large (e.g., days, weeks)

During State 1:
- Users CAN deposit (cap is open)
- Users will NOT receive insurance if they withdraw and Morpho has a loss
- Users are NOT paying premium (no accrual before startTime)

**Uninsured Exposure Window — State 3 (Post-Maturity)**:

`maxDeposit()` does NOT check `_isPolicyActive()`:
```solidity
function maxDeposit(address) public view override returns (uint256) {
    if (!policyBoundExecuted) return 0;
    return depositCap > totalPrincipal ? depositCap - totalPrincipal : 0;
}
```

After policy expiry, `policyBoundExecuted` remains `true` and `depositCap > totalPrincipal` may still be true. New deposits are accepted with ZERO insurance coverage.

**Quantification of Maximum Uninsured Exposure**:

State 1 gap: unbounded (startTime can be set far in future), but practically limited by the quote's `expirationTime`. The quote must not be expired, and `quote.startTime >= block.timestamp`, so the gap = `startTime - bindTime`. In a scenario where bind happens today and startTime = tomorrow: 24 hours of uninsured deposits possible.

State 3 gap: unbounded. After policy expires, deposits remain open indefinitely (until owner calls `rescueTokens` or manually manages). There is no cap-reset mechanism on policy expiry.

**Protocol Survival**: The protocol does NOT fully protect users entering during the uninsured windows. State 1 is a minor gap (usually short). State 3 is an unbounded ongoing risk if the operator fails to close the vault after policy expiry.

**Impact**: Deposits accepted post-maturity receive NO insurance but users may not know the policy has expired. The `maxDeposit()` function should return 0 when the policy has expired. A user depositing a day after policy expiry earns Morpho yield but has no insurance coverage — a silent miscommunication about the product's current state.

---

## Finding [DST-5]: Protocol Adequacy — `maxCoverableLossBps` and `deductibleBps` Leave Realistic Loss Scenarios Partially Uncovered

**Verdict**: CONFIRMED (partial adequacy gap)
**Severity**: Design Adequacy
**Location**: `CoveredVaultWrapper.sol:_capAndApplyDeductible`, `CoveredVaultWrapper.sol:onPolicyBound`

### Stress Scenario

**Hypothesis**: If a Morpho loss of 30% occurs, what percentage of depositors are covered? Is the relationship between `maxCoverableLossBps`, `deductibleBps`, and `depositCap` formula correct?

**Coverage Formula Analysis**:

For a user with `principal = P`:
- `insuredBasis = P - premiumForWithdrawal` ≈ P (ignoring premium for simplicity)
- `shortfall = insuredBasis - netAssetsReceived`
- Insurance payout formula: `min(shortfall, maxCoverableLossBps * insuredBasis / BPS) - deductibleBps * insuredBasis / BPS`

For a 30% Morpho loss (`assetsReceived = 0.7 * P`):
- `shortfall = P - 0.7P = 0.3P`
- With `maxCoverableLossBps = 1000` (10%): `max_insurance = 0.1 * P`
- With `deductibleBps = 100` (1%): `deductible = 0.01 * P`
- **Actual payout**: `min(0.3P, 0.1P) - 0.01P = 0.1P - 0.01P = 0.09P`
- **User receives**: `0.7P (from Morpho) + 0.09P (insurance) = 0.79P`
- **Net loss to user at 30% Morpho loss**: 21% of principal

The insurance covers only 9% of a 30% loss (30% coverage). The user absorbs the remaining 21%.

**Is the depositCap formula correct?**

`depositCap = coverageLimit * BPS_DENOMINATOR / maxCoverableLossBps`

With `coverageLimit = 100,000 USDC` and `maxCoverableLossBps = 1000` (10%):
- `depositCap = 100,000 * 10,000 / 1000 = 1,000,000 USDC`

This means: if ALL depositors simultaneously claim `maxCoverableLossBps` of their principal, total claims = `depositCap * maxCoverableLossBps / BPS = 1,000,000 * 10% = 100,000 = coverageLimit`. ✓

The formula is mathematically consistent — the coverage pool is exactly sized to cover `maxCoverableLossBps` of all depositor principal simultaneously. However:

**Structural gap 1 — Loss exceeds maxCoverableLossBps**:

For any Morpho loss > `maxCoverableLossBps + deductibleBps`, users absorb losses beyond the cap regardless of how large the loss is. A 50% Morpho loss with `maxCoverableLossBps = 1000` leaves users with `50% Morpho loss + 9% insurance = 41% net loss`. The insurance is calibrated for small, bounded losses, not existential Morpho events.

**Structural gap 2 — Deductible erodes coverage for small losses**:

For a Morpho loss of exactly `deductibleBps` (1%), insurance payout = `min(0.01P, 0.1P) - 0.01P = 0`. The deductible completely cancels the insurance for losses at or below `deductibleBps`.

For a Morpho loss between `deductibleBps` and `maxCoverableLossBps`:
- 5% loss: payout = `5% - 1% = 4%` of principal
- 10% loss: payout = `10% - 1% = 9%` of principal (capped at max)
- 30% loss: payout = `10% - 1% = 9%` of principal (capped at max)

This is a normal deductible structure, but combined with the small `maxCoverableLossBps` defaults, the protocol covers a narrow band of losses. A rational depositor needs to understand that:
- Losses ≤ 1% (deductibleBps): no payout
- Losses 1-10%: partial coverage (loss - deductible)
- Losses > 10%: fixed 9% payout regardless of actual loss magnitude

**Structural gap 3 — `depositCap` does not account for deductible in premium accounting**:

When `maxCoverableLossBps` is changed via `executeMaxCoverableLossBps()`, `depositCap` is recalculated:
```solidity
depositCap = (coverageLimit * BPS_DENOMINATOR) / uint256(newBps);
```

If `maxCoverableLossBps` is DECREASED after deposits exist (e.g., from 1000 to 500), the new `depositCap` doubles but `totalPrincipal` stays fixed. The coverage pool must now back potentially more deposit TVL per unit of coverage — but the coverage pool (restaker stake) was sized for the OLD `maxCoverableLossBps`. This creates a window where `totalPrincipal > old_depositCap` but `totalPrincipal < new_depositCap` AND the coverage pool has not been resized to match.

**The `deductibleBps` does not affect `depositCap`**: The `depositCap` formula assumes ALL losses up to `maxCoverableLossBps` are paid. But since `deductibleBps` reduces every payout, the ACTUAL maximum claimable amount per user is `(maxCoverableLossBps - deductibleBps) * principal / BPS`, not `maxCoverableLossBps * principal / BPS`. This means the coverage pool is modestly over-sized relative to actual maximum payouts — a conservative direction, but a misalignment between the formula and the actual payout math.

**Protocol Survival**:

For a 30% Morpho loss with default parameters:
- SURVIVES mechanically (invariants hold, accounting is correct)
- Insurance payout = 9% of each user's principal
- Total claims = 9% * totalPrincipal, must be <= coverageLimit (satisfied since totalPrincipal <= depositCap = coverageLimit * BPS/maxCoverableLossBps, and 9% * totalPrincipal ≤ 10% * totalPrincipal ≤ coverageLimit by formula)
- Users absorb 21% net loss on a 30% Morpho event

**Impact**: The protocol adequately covers losses within `[deductibleBps, maxCoverableLossBps]`. For systemic Morpho losses exceeding `maxCoverableLossBps`, coverage is fixed at `maxCoverableLossBps - deductibleBps` percent of principal — a small fraction of large losses. This is a design tradeoff, not a bug, but deployers and users should be clearly informed that this product is not full-coverage insurance.

---

## Chain Summary

| Finding | Dimension | Verdict | Severity | Mechanism | Existential? |
|---------|-----------|---------|----------|-----------|--------------|
| DST-1 | Premium Drain Spiral | CONFIRMED | Design Limit | MAX_PREMIUM_RATE = 50% APR; no yield-floor circuit breaker; depositors can lose 40%+ per year to premium without a Morpho loss event | No — accounting holds, but economically damaging |
| DST-2 | Systemic Morpho Exploit | CONFIRMED | Design Limit | Claim approval gate serializes insurance: only 1st withdrawer gets insurance per curator approval cycle; claim approval gate is per-policyId | Partial failure under mass-withdrawal |
| DST-3 | Curator Claim Denial | CONFIRMED | Structural | setPremiumDefaulted has no timelock; curator can block all claims in same block as Morpho loss with zero notice; direct misalignment between curator's incentive (preserve stake) and depositor's interest (receive insurance) | No — but represents a critical trust assumption violation risk |
| DST-4 | Lifecycle Uninsured Windows | CONFIRMED | Design Adequacy | Deposits open before startTime (State 1 gap) and after maturity (State 3: maxDeposit() doesn't check policy expiry) | No — bounded short-term, but ongoing post-maturity |
| DST-5 | Coverage Adequacy | CONFIRMED | Design Adequacy | Insurance covers losses only in [deductibleBps, maxCoverableLossBps] band; 30% Morpho loss → 9% payout, 21% user loss; formula structurally consistent but narrow coverage window | No — design tradeoff, not a bug |

### Priority for Attention

1. **DST-2** (Claim gate serialization) — Highest impact: directly prevents insurance payouts during the exact scenario the protocol is designed for. A simple fix (increase claim approval granularity or add a cooldown instead of a binary gate) would significantly improve robustness.

2. **DST-3** (Curator setPremiumDefaulted timelockless) — A timelock (even 1 hour) on `setPremiumDefaulted` would prevent same-block weaponization while preserving the legitimate use case.

3. **DST-4** (Post-maturity deposits) — Adding `_isPolicyActive()` check to `maxDeposit()` would close the State 3 gap with minimal change.

4. **DST-1** (Premium rate spiral) — The 2-hour timelock and 50% APR cap are present but may be insufficient economic guardrails. Consider adding an advisory maximum rate linked to Morpho's observable yield.

5. **DST-5** (Coverage adequacy) — Design tradeoff that requires disclosure, not a code fix.
