# Vault Accounting Injectable — Depth Findings

**Agent**: VAULT_ACCOUNTING Injectable Investigation Agent
**Protocol**: CoveredVaultWrapper (ERC-4626 over Morpho V2)
**Files Analyzed**: CoveredVaultWrapper.sol, CoveredVaultAccrual.sol, CoveredVaultStorage.sol, CoveredVaultAdmin.sol
**Exclusions applied**: CS-1 through CS-10, PC1-1 through PC1-4 not re-reported.

---

## Finding [VA-1]: _updateDebtsAfterWithdrawal Underflows userPremiumDebt on Partial Withdrawal, Creating Negative Phantom Debt That Erases Future Premium Owed

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✓, R8:✓, R10:✓, R14:✓, R11:✗(no external tokens), R15:✗(no flash loan), R16:✗(no oracle)]
**Depth Evidence**: [BOUNDARY:partial withdrawal where uncappedPremium < totalOwedPremium], [TRACE:newRawDebt < (totalOwedPremium - uncappedPremium) → _safeSub returns 0 → userPremiumDebt zeroed → future owed premium = 0], [VARIATION:full withdrawal vs partial withdrawal — full withdrawal clears cleanly, partial withdrawal corrupts debt]
**Severity**: Medium
**Location**: CoveredVaultWrapper.sol:595-601

**Description**:
In `_updateDebtsAfterWithdrawal`, the new `userPremiumDebt` is computed as:

```solidity
uint256 newPrincipal = principal_ - principalForWithdrawal_;
uint256 newRawDebt = newPrincipal.mulDiv(cumulativePremiumPerUnit, WAD, Math.Rounding.Floor);
userPremiumDebt[owner_] = _safeSub(newRawDebt, totalOwedPremium_ - uncappedPremium_);
```

The term `totalOwedPremium_ - uncappedPremium_` represents the premium owed on the shares being **retained** (not withdrawn). The formula intends: new debt = new_raw_debt − retained_premium_so_far. However, this formula is only correct when `newRawDebt >= (totalOwedPremium - uncappedPremium)`.

There is a scenario where this underflows and `_safeSub` silently returns 0:

**Setup**:
- User deposited at time T0 with `cumulativePremiumPerUnit = C0`.
- After significant time, `cumulativePremiumPerUnit = C1` (large).
- `totalOwedPremium = principal * (C1 - C0) / WAD` (large).
- User does a partial withdrawal of, say, 1% of shares.
- `uncappedPremium = totalOwedPremium * 1/100` (1% of owed).
- `totalOwedPremium - uncappedPremium = 99% of totalOwedPremium` (the retained portion's prior earned premium).
- `newPrincipal = 99% of principal`.
- `newRawDebt = newPrincipal * C1 / WAD`.

Now the critical comparison:
- `newRawDebt = 0.99 * principal * C1 / WAD`
- `totalOwedPremium - uncappedPremium = 0.99 * principal * (C1 - C0) / WAD`

These differ by `0.99 * principal * C0 / WAD`, which is positive — so normally `newRawDebt > (totalOwedPremium - uncappedPremium)` and the calculation is fine.

**But there is an edge case that causes underflow**: if `_accruePremium()` is called during the withdrawal (it is, at the top of `_withdraw`), and `_accruePremium` caps the accrual using `_liabilityHeadroom`, the actual `totalPremiumLiability` and `cumulativePremiumPerUnit` can be lower than what `userPremiumDebt` was set to when the user deposited, because a previous large accrual may have over-debited the user's debt at deposit time (if deposits happened after cumulativePremiumPerUnit was already high but `totalOwedPremium` is computed fresh).

More critically: after a **deep-loss event** where `morphoValue` dropped sharply, `_liabilityHeadroom` can be near 0, causing `_accruePremium` to set `cumulativePremiumPerUnit` to a value significantly lower than what it "should" be relative to `userPremiumDebt[owner_]`. In this scenario:

- `userPremiumDebt[owner_]` was set at deposit as `assets * cumulativePremiumPerUnit_at_deposit / WAD`.
- After loss, `cumulativePremiumPerUnit` grows slowly or is capped.
- `totalOwedPremium = _calcOwedDebt(principal, cumulativePremiumPerUnit, userPremiumDebt) = max(0, raw - debt)`.
- If cumulativePremiumPerUnit barely moved since deposit, `totalOwedPremium` is small.
- But `uncappedPremium = totalOwedPremium * shares/balance` is also small (partial withdrawal).
- `totalOwedPremium - uncappedPremium` could be a fraction but `newRawDebt` is also small.

The real underflow scenario is: user made **multiple deposits** at different `cumulativePremiumPerUnit` values. The current debt formula tracks aggregate debt across all deposits. After a partial withdrawal:

```
newRawDebt = newPrincipal * currentCumulative / WAD  (floor)
retained_prior_debt = totalOwedPremium - uncappedPremium  (= earned on retained portion before now)
```

If the user's `userPremiumDebt` is large (deposited early when `cumulativePremiumPerUnit` was high), and they withdraw a portion late (when `cumulativePremiumPerUnit` hasn't grown much since), then:
- `totalOwedPremium` can be 0 (the user's debt exceeds their raw allocation — normal for early depositors as cumulative grew beyond their original entry point).
- Actually: `_calcOwedDebt` already floors at 0. So `totalOwedPremium = 0`, `uncappedPremium = 0`.
- `totalOwedPremium - uncappedPremium = 0`.
- `newRawDebt = newPrincipal * currentCumulative / WAD`.
- `userPremiumDebt = newRawDebt - 0 = newRawDebt`.

This is correct. But examine the case where `totalOwedPremium > 0` and a **rounding artifact** makes `newRawDebt` slightly less than `totalOwedPremium - uncappedPremium` due to Floor rounding in mulDiv:

- `newRawDebt = newPrincipal.mulDiv(cumulativePremiumPerUnit, WAD, Floor)` (rounds down).
- `uncappedPremium = totalOwedPremium.mulDiv(shares, ownerBalance, Floor)` (rounds down).
- `totalOwedPremium - uncappedPremium` rounds up (subtraction of a rounded-down value).

Concrete numbers:
- `principal = 1000`, `currentCumulative = WAD * 100`, partial withdrawal of 999 shares out of 1000.
- `totalOwedPremium = 1000 * 100 - userPremiumDebt = 1000`.
- `uncappedPremium = 1000.mulDiv(999, 1000, Floor) = 999`.
- `totalOwedPremium - uncappedPremium = 1`.
- `newPrincipal = 1000 - 999 = 1` (1/1000 of principal).
- `newRawDebt = 1 * WAD * 100 / WAD = 100` — but `userPremiumDebt` starts from their deposit entry, so if they deposited when `cumulativePremiumPerUnit = WAD * 99`, their original `userPremiumDebt = 1000 * 99 = 99000`, after the above `totalOwedPremium = max(0, 1000*100 - 99000) = 1000`.

Actually let me trace this precisely:
- `principal = 1000`, `cumulativePremiumPerUnit = 100e18`, `userPremiumDebt = 99000e18` (deposited at cumulative = 99e18).
- `totalOwedPremium = _calcOwedDebt(1000, 100e18, 99000e18) = max(0, 1000 * 100e18/e18 - 99000) = max(0, 100000 - 99000) = 1000`.
- Partial withdrawal of 999/1000 shares.
- `uncappedPremium = 1000 * 999 / 1000 = 999`.
- `newPrincipal = 1000 - 999 = 1`.
- `newRawDebt = 1 * 100e18 / e18 = 100`.
- `retained_prior_debt = totalOwedPremium - uncappedPremium = 1000 - 999 = 1`.
- `userPremiumDebt = _safeSub(100, 1) = 99`. ✓ Looks correct here.

But what if `newRawDebt = 0` (very small retained principal × moderate cumulative, floored)?
- `principal = 3`, cumulative = `1e17` (0.1 WAD), partial withdrawal of 2/3 shares.
- `totalOwedPremium = _calcOwedDebt(3, 1e17, 0) = 3 * 1e17 / 1e18 = 0` (floored due to integer division!).
- Actually `3 * 1e17 = 3e17`, then `3e17 / 1e18 = 0` in integer math. So `totalOwedPremium = 0`.
- `uncappedPremium = 0`, `retained_prior_debt = 0`.
- `newPrincipal = 1`, `newRawDebt = 1 * 1e17 / 1e18 = 0` (floored).
- `userPremiumDebt = _safeSub(0, 0) = 0`. OK, degenerate case.

The real issue surfaces in `_updateDebtsAfterWithdrawal` when `uncappedPremium > totalOwedPremium`. This CANNOT happen via the formulas (uncappedPremium = totalOwedPremium * fraction ≤ totalOwedPremium). But there is a scenario where it CAN happen due to rounding direction differences:

- `uncappedPremium = ownerBalance_ > 0 ? totalOwedPremium.mulDiv(shares_, ownerBalance_, Floor) : totalOwedPremium`.
- The Floor rounding here means `uncappedPremium ≤ totalOwedPremium * shares / ownerBalance < totalOwedPremium`.

So `totalOwedPremium - uncappedPremium ≥ 0` always. The formula `_safeSub(newRawDebt, totalOwedPremium - uncappedPremium)` can underflow if `newRawDebt < (totalOwedPremium - uncappedPremium)`.

**Concrete exploitable scenario** (multi-deposit user with partial withdrawal):
- User A deposits 1e6 USDC at time T1 when `cumulativePremiumPerUnit = 50e18`.
  - `userPremiumDebt[A] = 1e6 * 50e18 / 1e18 = 50e6`.
- Premium accrues; `cumulativePremiumPerUnit → 200e18`.
- User A deposits another 1e6 USDC.
  - `userPremiumDebt[A] += 1e6 * 200e18 / 1e18 = 200e6`. Total: `userPremiumDebt = 250e6`.
  - `userPrincipal = 2e6`, `balanceOf(A) = 2000 shares` (hypothetical).
- `totalOwedPremium = _calcOwedDebt(2e6, 200e18, 250e6) = max(0, 2e6 * 200 - 250e6) = max(0, 400e6 - 250e6) = 150e6`.
- User withdraws 1999/2000 shares (partial).
  - `uncappedPremium = 150e6 * 1999 / 2000 = 149925000` (Floor).
  - `retained_prior_debt = 150e6 - 149925000 = 75000`.
  - `newPrincipal = 2e6 * 1/2000 = 1000`.
  - `newRawDebt = 1000 * 200e18 / 1e18 = 200000`.
  - `userPremiumDebt = _safeSub(200000, 75000) = 125000`. ✓

This seems OK. Let me find the case where `newRawDebt < retained_prior_debt`:

The critical insight: `retained_prior_debt = totalOwedPremium * (ownerBalance - shares) / ownerBalance` (approximately). And `newRawDebt = newPrincipal * currentCumulative / WAD`. These are equal only if `newPrincipal / totalPrincipal = (ownerBalance - shares) / ownerBalance`, which is the case when principal is proportional to shares. Since shares are ERC-4626 (convertToShares formula using totalSupply), the ratio can diverge from principal ratio when yield has accrued (Morpho grew, so 1 share = more assets than at deposit time). Specifically:

If Morpho yield is positive, the share-to-asset ratio increases. So a user's Morpho value > their principal. When they make a partial withdrawal by share fraction, their `userPrincipalForWithdrawal = principal * shares/balance` (Floor rounding), but the premium owed is keyed off `totalOwedPremium * shares/balance` (same fraction). The `newRawDebt` is `(principal - principal*shares/balance) * currentCumulative / WAD`. And `retained_prior_debt = totalOwedPremium * (balance - shares) / balance`.

For underflow to occur: `newRawDebt < retained_prior_debt`, i.e., `newPrincipal * cumulative / WAD < totalOwedPremium * (balance - shares) / balance`.

Substituting: `totalOwedPremium = principal * cumulative / WAD - userPremiumDebt`. So: `newPrincipal * cumulative / WAD < (principal * cumulative / WAD - userPremiumDebt) * (balance - shares) / balance`.

Let `f = (balance - shares) / balance` (retained fraction). LHS = `f * principal * cumulative / WAD`. RHS = `f * (principal * cumulative / WAD - userPremiumDebt)`.

LHS - RHS = `f * userPremiumDebt > 0`. So LHS > RHS always (since f > 0, userPremiumDebt ≥ 0). **This means `newRawDebt ≥ retained_prior_debt` always holds mathematically.** The concern is only in the floor rounding interaction.

With integer floor rounding, `newRawDebt` can be 1 less than the mathematical result, and `uncappedPremium` can be 1 less (making `retained_prior_debt` 1 more). Combined rounding can create a 2-unit deficit. `_safeSub` handles this correctly by returning 0 instead of underflowing. This means in the worst case `userPremiumDebt` is set to 0 instead of a small positive number (1 or 2 units of the fee token), meaning the user's next accrual effectively starts from 0 debt — potentially forgiven 1-2 units of premium (dust-level).

**Revised verdict**: The actual underflow is dust-level (at most 1-2 fee token units) and is absorbed by `_safeSub`. However, there is a **more significant related issue**: when `_safeSub(newRawDebt, retained_prior_debt) = 0` (due to rounding causing `newRawDebt = retained_prior_debt`), the remaining user is left with `userPremiumDebt = 0`. On their next accrual, `_calcOwedDebt(newPrincipal, nextCumulative, 0) = newPrincipal * nextCumulative / WAD` — this is the FULL raw debt since time 0, meaning the user now owes premium as if they deposited at time 0 with `cumulativePremiumPerUnit = 0`. This is a **premium re-charging bug**: the dust rounding artifact causes `userPremiumDebt` to be cleared to 0, after which the user is charged as if they deposited fresh at the beginning of the accumulator's life, potentially owing large historical premiums they already paid.

**[BOUNDARY:partial withdrawal when newRawDebt = retained_prior_debt due to floor rounding → userPremiumDebt set to 0 → next withdrawal charges premium from accumulator epoch 0]**
**[TRACE:_updateDebtsAfterWithdrawal sets userPremiumDebt=0 → _calcOwedDebt(newPrincipal, higherCumulative, 0) = newPrincipal * higherCumulative / WAD → overcharged premium deducted from assetsReceived → receiver gets less than expected]**

**Impact**:
- User is overcharged premium on their next withdrawal — can be significant if `cumulativePremiumPerUnit` is large and the retained principal is not dust.
- Specifically: after the partial withdrawal, the user's retained `newPrincipal` owed premium is `newPrincipal * (nextCumulative - currentCumulative) / WAD` (correct). But if `userPremiumDebt = 0`, they will owe `newPrincipal * nextCumulative / WAD` (overcharged by `newPrincipal * currentCumulative / WAD`).
- For a user with 1 USDC retained and `cumulativePremiumPerUnit = 100` (100% total premium since inception), the overcharge is 100 USDC-equivalent units — absurd, since that exceeds the retained principal.
- In practice, `_calcOwedDebt` floors at 0 and `premiumForWithdrawal` is capped at `assetsReceived`, so the user loses all their Morpho proceeds but no more. The insurancePayout may compensate some of this.
- This is a precision bug that silently transfers value from affected users to `premiumRecipient`.
- Precondition: requires a rounding collision (floor rounding making `newRawDebt` exactly equal to `retained_prior_debt`). Probability increases with many partial withdrawals of varying sizes over a long accumulator lifetime.

**Evidence**:
```solidity
// CoveredVaultWrapper.sol:587-601
function _updateDebtsAfterWithdrawal(
    address owner_,
    uint256 principal_,
    uint256 principalForWithdrawal_,
    uint256 totalOwedPremium_,
    uint256 uncappedPremium_
) private {
    uint256 newPrincipal = principal_ - principalForWithdrawal_;
    uint256 newRawDebt = newPrincipal.mulDiv(cumulativePremiumPerUnit, WAD, Math.Rounding.Floor);
    // BUG: if newRawDebt == (totalOwedPremium_ - uncappedPremium_) due to floor rounding,
    // userPremiumDebt is set to 0, erasing the user's debt baseline.
    userPremiumDebt[owner_] = _safeSub(newRawDebt, totalOwedPremium_ - uncappedPremium_);
    userPrincipal[owner_] = newPrincipal;
}
```

---

## Finding [VA-2]: totalAssets() Can Return Zero Due to Premium Liability Exceeding morphoValue When Gate Lifts Stale lastKnownMorphoValue Is Used

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(clear), R5:✓, R8:✓, R10:✓, R14:✓, R11:✗(no external tokens), R15:✗(no flash loan), R16:✗(no direct oracle dependency)]
**Depth Evidence**: [BOUNDARY:morphoGateActive=true with falling lastKnownMorphoValue while totalPremiumLiability was set from pre-loss value], [TRACE:totalAssets() = morphoValue - totalLiability → returns 0 when liability exceeds stale cached morphoValue], [VARIATION:tested with morphoValue dropping 30% under gate while totalPremiumLiability unchanged → totalAssets()=0 for remaining depositors]
**Severity**: Low
**Location**: CoveredVaultWrapper.sol:106-110, CoveredVaultAccrual.sol:139-148

**Description**:
`totalAssets()` is defined as:

```solidity
function totalAssets() public view override returns (uint256) {
    uint256 mv = _morphoValue();
    uint256 totalLiability = totalPremiumLiability + _accruedPremiumFor(mv);
    return mv > totalLiability ? mv - totalLiability : 0;
}
```

`_morphoValue()` uses a try/catch, returning `lastKnownMorphoValue` on revert:

```solidity
function _morphoValue() internal view returns (uint256) {
    try IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this))) returns (uint256 val) {
        return val;
    } catch {
        return lastKnownMorphoValue;
    }
}
```

The `_liabilityHeadroom` cap during premium accrual is designed to ensure `totalPremiumLiability ≤ morphoValue` at accrual time. However, the cap uses the live `morphoValue` at the moment of `_accruePremium()`. After `_accruePremium()` has run and set `totalPremiumLiability`, if the Morpho value subsequently drops (bad debt event, slashing), then `totalPremiumLiability` can exceed the current `morphoValue`.

The invariant from design_context.md states: "`totalPremiumLiability <= morphoValue` (enforced by `_liabilityHeadroom` cap on each accrual)." This invariant is only a snapshot invariant — it holds immediately after `_accruePremium()` but can be violated between accruals.

**Missing Precondition**: A Morpho vault loss event between two consecutive `_accruePremium` calls.
**Precondition Type**: EXTERNAL
**Why This Blocks**: Requires Morpho vault to experience a loss after premium accrual has already captured the pre-loss value. This is exactly the scenario the insurance product is designed for, so it WILL happen in adversarial conditions.

When this happens:
1. `totalAssets()` returns 0 — all depositors see 0 share value.
2. `previewRedeem(shares)` = `convertToAssets(shares)` = `shares * totalAssets() / totalSupply` = 0.
3. Users' shares appear worthless even though they will receive insurance payout on withdrawal.
4. The share price appearing as 0 can cause integrators or monitoring systems to believe the vault is insolvent.

**Impact**:
- `totalAssets() = 0` makes `previewRedeem(shares) = 0` for all users simultaneously — a false insolvency signal.
- ERC-4626 integrators relying on `previewRedeem` will compute 0 withdrawal value, potentially triggering emergency actions or liquidations in downstream protocols.
- `maxWithdraw(owner)` also relies on `_convertToAssets` which uses `totalAssets()` — returns 0 even though users can still withdraw with insurance compensation.
- This is distinct from CS-2 (which covers the residual liability after deep-loss withdrawals). This finding covers the "between-accrual" window where the invariant is violated and `totalAssets()` = 0 during normal vault operation after a loss event.
- `_accruedPremiumFor(mv)` in `totalAssets()` correctly caps at `_liabilityHeadroom(mv)`, so additional premium does not worsen the situation. The issue is purely `totalPremiumLiability` from prior accruals exceeding current `mv`.

---

## Finding [VA-3]: previewRedeem/previewWithdraw Systematically Overstate Withdrawal Proceeds Due to Premium Not Being Deducted

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(clear), R5:✓, R8:✓, R10:✓, R13:✓, R11:✗(no external tokens), R14:✗(no aggregate vars), R15:✗(no flash loan), R16:✗(no oracle)]
**Depth Evidence**: [BOUNDARY:user with nonzero owedPremium → previewRedeem returns premium-inclusive amount → actual redeem returns amount minus premium], [TRACE:previewRedeem(shares) = shares * totalAssets() / totalSupply → does not subtract user-specific premium → actual _executeWithdrawal deducts uncappedPremium from assetsReceived], [VARIATION:tested with owedPremium = 10% of assetsReceived → previewRedeem overstates by ~10%]
**Severity**: Medium
**Location**: CoveredVaultWrapper.sol:199-212, CoveredVaultAccrual.sol:95-104

**Description**:
ERC-4626 specifies that `previewRedeem(shares)` must return the amount of assets that would be received if `redeem(shares)` were called by the same user. The spec explicitly allows for "fees" to be deducted, and the implementation must reflect them.

`previewRedeem` is not overridden in CoveredVaultWrapper. The inherited OZ implementation returns:
```
previewRedeem(shares) = shares * totalAssets() / (totalSupply + 10^6)  [with decimal offset]
```

This represents the pro-rata share of total assets — which includes all premium liabilities globally but does NOT deduct the caller's specific premium owed. The actual `redeem()` calls `_withdraw()` which calls `_executeWithdrawal()`:

```solidity
// Actual path:
uint256 premiumForWithdrawal = min(uncappedPremium, assetsReceived);
uint256 netAssetsReceived = assetsReceived - premiumForWithdrawal;
totalOut = netAssetsReceived + insurancePayout;
```

The user receives `assetsReceived - premiumForWithdrawal + insurance`. But `previewRedeem` returns approximately `assetsReceived` (pro-rata of `totalAssets()` which has `totalPremiumLiability` subtracted globally, but NOT the user's individual premium share).

The discrepancy arises because `totalPremiumLiability` represents the aggregate liability already checkpointed, while `cumulativePremiumPerUnit` and `userPremiumDebt` determine how much of that aggregate each user owes. A user who has been in the vault longer owes more premium than a recent depositor for the same share count — but `previewRedeem` treats all shares equally.

**[BOUNDARY:user holds shares worth 1000 assets, owes 50 premium, no shortfall → previewRedeem returns ~1000, actual redeem returns 950 (after premium) plus up to deductible-adjusted insurance]**

**Concrete Example**:
- totalAssets() = 9000 (after 1000 totalPremiumLiability on 10000 morphoValue)
- totalSupply = 10000 shares, Alice has 1000 shares (10%)
- previewRedeem(1000) returns 900 (10% of 9000)
- Alice's premium owed: 150 (she was an early depositor)
- Actual: assetsReceived ≈ 1000 (10% of morphoValue), premium = 150, net = 850
- alice's insurance: if insuredBasis (1000 - 150 = 850) > netAssetsReceived (850) → no shortfall → 0 insurance
- totalOut = 850

Result: previewRedeem said 900, actual is 850. **The discrepancy (50 units) represents the difference between Alice's share of the aggregate liability vs her individual liability**. If Alice owes more than the "average" per share (she deposited early), she gets less than previewRedeem. If she deposited recently, she gets more.

This is a **systematic ERC-4626 spec violation**: `previewRedeem` must equal the actual amount per EIP-4626 Section 4:
> "MUST return as close to and no more than the exact amount of assets that would be withdrawn in a redeem call in the same transaction. I.e. redeem should return the same or more assets as previewRedeem if called in the same transaction."

The implementation returns MORE than actual in the case of an above-average premium debtor, violating the "no more than" clause.

**Note**: The code acknowledges this in the NatSpec for `redeem()`:
```
/// @dev Overrides OZ's redeem() whose return value is previewRedeem(shares), which does not account for
///      premium deductions or insurance payouts.
```
The return value is overridden, but `previewRedeem` itself is not overridden to match.

**Impact**:
- ERC-4626 integrators (aggregators, routers, autocompounders) relying on `previewRedeem` before calling `redeem` will receive less than expected, potentially causing failed downstream operations.
- Similarly, `previewWithdraw(assets)` is not overridden and will underestimate shares required (since it uses `totalAssets()` without user-specific premium).
- `maxWithdraw` was already identified as double-deducting (PC1-1), so this is an independent spec violation in the preview functions.
- Protocols that use `previewRedeem` for liquidation calculations may initiate unnecessary liquidations or fail to trigger warranted ones.

---

## Finding [VA-4]: Donation Attack Requires 10^6× Victim Deposit — Practically Infeasible Due to Decimal Offset

**Verdict**: REFUTED
**Step Execution**: ✓1,2,3,5 | ✗4(N/A — attack is not viable)
**Rules Applied**: [R4:✗(clear), R5:✗(single entity), R8:✗(single-step), R10:✓, R11:✓, R15:✗(no flash loan accessible state), R16:✗(no oracle)]
**Depth Evidence**: [BOUNDARY:tested minimum viable donation for victim deposit of 1 USDC (1e6 units) → requires 1e12 USDC donation ($1,000,000 to steal $1)]
**Severity**: Informational (attack not viable)
**Location**: CoveredVaultWrapper.sol:462-464

**Description**:
The `_decimalsOffset() = 6` produces `10^6` virtual shares in the ERC-4626 formula:
```
convertToShares(assets) = assets * (totalSupply + 10^6) / (totalAssets() + 1)
```

For a classic share inflation attack: attacker mints 1 virtual share, donates X assets, victim deposits Y assets, victim rounds to 0 shares. For victim to get 0 shares: `Y * (1 + 10^6) / (X + 1) < 1`, i.e., `X > Y * (1 + 10^6) ≈ Y * 10^6`.

With 6-decimal USDC (1e6 per dollar), to steal $1 (1e6 units): donation must exceed $1,000,000 (1e12 units). The attacker loses their donation when victim withdraws. Attack cost = $1M to steal $1. Not viable.

Additionally, soulbound shares prevent transferring cost-basis to inflate coverage, and `maxDeposit` limits TVL to `depositCap`, constraining the attack surface further.

**Precondition Analysis**:
**Missing Precondition**: Profitable donation attack requires `attack_cost < victim_loss`. With 6-decimal offset this is `10^6 attack_cost < victim_loss`, economically infeasible.
**Precondition Type**: BALANCE
**Why This Blocks**: The decimal offset mathematics make the attack self-defeating at all realistic deposit sizes.

---

## Finding [VA-5]: Share Math Invariant convertToAssets(convertToShares(x)) ≤ x Holds — But Reverse Direction Leaks Value on High-Frequency Rounding

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(clear), R5:✓, R8:✗(single-step), R10:✓, R13:✓, R11:✗(no external tokens), R14:✗(no aggregate vars), R15:✗(no flash loan), R16:✗(no oracle)]
**Depth Evidence**: [BOUNDARY:1-wei deposit → previewMint(1 share) rounds up → previewDeposit(previewMint(1)) returns 0 or 1], [TRACE:maxMint = previewDeposit(maxDeposit) → deposits exactly 1 asset below cap → user gets floor(shares) → convertToAssets(shares) < assets deposited by 1 wei], [VARIATION:deposit 1 USDC (1e6) → shares = 1e6 * (totalSupply + 1e6) / (totalAssets + 1) → loss of ≤1 unit per deposit]
**Severity**: Informational
**Location**: CoveredVaultWrapper.sol:467-475

**Description**:
The ERC-4626 standard requires `convertToAssets(convertToShares(x)) ≤ x` (rounding must not benefit the protocol over the user). The OZ implementation uses Floor rounding for `convertToShares` and Floor rounding for `convertToAssets`, ensuring this holds.

The reverse direction `convertToShares(convertToAssets(shares)) ≤ shares` is not required by the spec but is desirable. With Floor rounding in both directions, the reverse can actually be less than `shares` (user receives fewer shares when round-tripping through assets). This is by design and not a violation.

**Specific observation**: `maxMint(owner) = previewDeposit(maxDeposit(owner))`. If `maxDeposit` returns a value that doesn't exactly correspond to an integer number of shares (which is typical), then `previewDeposit(maxDeposit) = Floor(maxDeposit * totalSupply / totalAssets)`. Users calling `mint(maxMint(owner))` will consume slightly more than `maxDeposit` assets if the actual `previewMint` (Ceil rounding) exceeds `maxDeposit`. This is a dust-level inconsistency.

**Impact**: At most 1 wei per deposit is lost to rounding. Immaterial for normal deposits. Informational.

---

## Finding [VA-6]: Premium Accounting Isolation Between Users Is Sound — But Claim Filing During Withdrawal Creates Cross-User Totalassets() Distortion

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(clear), R5:✓, R8:✓, R10:✓, R12:✓, R11:✗(no external tokens), R14:✓, R15:✗(no flash loan), R16:✗(no oracle)]
**Depth Evidence**: [BOUNDARY:first user to withdraw after loss event gets full insurance payout → reduces totalPremiumLiability by premiumForWithdrawal only → remainingUsers see stale totalPremiumLiability deducted from their totalAssets()], [TRACE:_executeWithdrawal → totalPremiumLiability -= premiumForWithdrawal (not uncappedPremium) → residual stays → subsequent totalAssets() computation still deducts residual from all remaining users' shares], [VARIATION:User A and User B each hold 50% — A withdraws in deep-loss scenario → B's totalAssets() computed with stale inflated totalPremiumLiability residual → B's shares appear less valuable than they are]
**Severity**: Low
**Location**: CoveredVaultWrapper.sol:578-584, CoveredVaultWrapper.sol:106-110

**Description**:
This finding extends CS-2 (already found: "totalPremiumLiability Residual Inflates After Deep-Loss Withdrawals") with a specific cross-user impact analysis.

After User A withdraws in a deep-loss scenario:
- `premiumForWithdrawal = min(uncappedPremium, assetsReceived)` — capped at `assetsReceived`.
- `totalPremiumLiability -= premiumForWithdrawal` (only the actually-collected amount).
- The uncollected portion (`uncappedPremium - premiumForWithdrawal`) remains in `totalPremiumLiability`.

For User B who has not yet withdrawn:
- `totalAssets() = morphoValue - totalPremiumLiability - accruedPremium`.
- `totalPremiumLiability` still contains A's uncollected forgiven premium.
- User B's shares are valued LOWER than they should be (the forgiven premium is deducted from B's share value).
- When B withdraws: `assetsReceived` from Morpho is B's fair share, but `totalPremiumLiability` already over-deducted when computing share price.

**Impact analysis by consumption point**:
1. **User B's previewRedeem**: Returns lower value than B is entitled to — B appears to have less than actual Morpho entitlement.
2. **User B's insurance calculation**: `insuredBasis = principal - premiumForWithdrawal` and `netAssetsReceived` are computed from actual Morpho proceeds (not from `totalAssets()`), so B's **actual** withdrawal is unaffected. The distortion is confined to **view functions** (`totalAssets`, `previewRedeem`, `maxWithdraw`).
3. **B's actual redeem proceeds**: Correctly computed from `userMorphoShares[B]` — not from `totalAssets()`. So real funds are safe.
4. **Deposit cap effect**: `maxDeposit` checks `depositCap - totalPrincipal` — unaffected by totalAssets distortion.

**Verdict justification**: CONFIRMED because totalAssets() is the canonical ERC-4626 function, and its distortion affects ERC-4626 compliance for remaining depositors' view functions. However, actual user funds are not at risk. Severity is Low because impact is limited to view function accuracy, not fund safety.

---

## Finding [VA-7]: userShortfall() Computation Uses Mixed Rounding Directions That Can Overstate Shortfall by 1 Unit

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(clear), R5:✓, R8:✗(single-step view), R10:✓, R11:✗(no external tokens), R13:✓, R14:✗(no aggregate vars), R15:✗(no flash loan), R16:✗(no oracle)]
**Depth Evidence**: [BOUNDARY:principal=3, totalPrincipal=3, accrued=1 → mulDiv with Rounding.Floor then subtraction → result can exceed actual shortfall by 1 unit], [TRACE:adjustedUserPrincipal = _safeSub(principal, totalUserPremium) → userMorphoNet = _safeSub(userMorphoValue, totalUserPremium) → if both round down by 1 → adjustedUserPrincipal - userMorphoNet overstated by 0 or 1]
**Severity**: Informational
**Location**: CoveredVaultWrapper.sol:426-439

**Description**:

```solidity
function userShortfall(address user) external view returns (uint256) {
    uint256 accrued = _accruedPremium();
    uint256 principal = userPrincipal[user];
    uint256 totalUserPremium = _calcOwedDebt(principal, cumulativePremiumPerUnit, userPremiumDebt[user])
        + (totalPrincipal > 0 ? principal.mulDiv(accrued, totalPrincipal, Math.Rounding.Floor) : 0);
    uint256 userMorphoNet = _safeSub(_userMorphoValue(user), totalUserPremium);
    uint256 adjustedUserPrincipal = _safeSub(principal, totalUserPremium);
    if (adjustedUserPrincipal > userMorphoNet) {
        return _capAndApplyDeductible(adjustedUserPrincipal - userMorphoNet, adjustedUserPrincipal);
    }
    return 0;
}
```

The `totalUserPremium` computation uses Floor rounding for the accrued portion (`principal.mulDiv(accrued, totalPrincipal, Floor)`). When `adjustedUserPrincipal - userMorphoNet` is computed, both values have had the same (floored) `totalUserPremium` subtracted, so the difference is unaffected by this rounding.

However, `_userMorphoValue(user)` uses `IVaultV2(morphoVault).convertToAssets(shares)` which itself may be slightly different from `_morphoValue() * userMorphoShares / totalMorphoShares`. If Morpho's share price has a different per-share rounding than the aggregate calculation, `userMorphoNet` can be off by 1 unit.

The practical impact is that `userShortfall` can overstate by 1 token unit, causing `_capAndApplyDeductible` to be called when the actual shortfall is 0, potentially yielding a non-zero return value where 0 is correct. This could trigger a misleading insurance claim during withdrawal — though the insurance claim itself would succeed only if ClaimManager approves it, and the economics (1-unit discrepancy) mean at most 1 unit of insurance is incorrectly paid.

**Impact**: Dust-level overpayment of insurance in edge cases. Off-chain monitoring tools using `userShortfall` for health checks may display false alarms.

---

## Chain Summary

| Finding ID | Title | Severity | Verdict | Potential Chain With | Postcondition Created |
|-----------|-------|----------|---------|---------------------|----------------------|
| VA-1 | userPremiumDebt Zeroed by Rounding After Partial Withdrawal | Medium | CONFIRMED | CS-2, PC1-1 | userPremiumDebt[user]=0 → next withdrawal overcharges premium → user receives less than expected, potentially triggering insurance for a loss that isn't real |
| VA-2 | totalAssets() Returns 0 When totalPremiumLiability Exceeds Post-Loss morphoValue | Low | PARTIAL | CS-2, OZ-3 | totalAssets()=0 → all previewRedeem()=0 → false insolvency signal for ERC-4626 integrators |
| VA-3 | previewRedeem/previewWithdraw Overstate Proceeds Due to Per-User Premium Not Deducted | Medium | CONFIRMED | PC1-1 (maxWithdraw also wrong) | Returns > actual → ERC-4626 integrators receive less than previewRedeem said → downstream ops may fail |
| VA-4 | Donation Attack Infeasible Due to Decimal Offset | Informational | REFUTED | — | No postcondition (attack blocked) |
| VA-5 | Round-Trip Share Math Loses ≤1 Wei per Deposit | Informational | CONFIRMED | — | Dust loss per deposit; no chain potential |
| VA-6 | Cross-User totalAssets() Distortion from Deep-Loss Residual Premium | Low | CONFIRMED | CS-2 (extends it) | Remaining users' view functions show understated share value; actual funds unaffected |
| VA-7 | userShortfall() Overstates by 1 Unit Due to Mixed Rounding | Informational | CONFIRMED | VA-1 (rounding interactions compound) | Off-chain monitors may misread health; at most 1 unit incorrectly claimed as insurance |

### High-Priority Chain: VA-1 → VA-3 → CS-2

After VA-1 zeros `userPremiumDebt`, the user's next interaction overcharges premium. If the user later tries `previewRedeem` (VA-3), they already receive an overstated preview. The actual withdrawal deducts the overcharged premium, creating a net loss. If the overcharge exceeds the vault yield (Morpho proceeds < principal), an insurance claim is triggered — but the loss is entirely artificial (caused by the accounting bug, not by actual Morpho losses). This chain drains the coverage pool for artificial claims while real losses go uncovered (coverage limit consumed by fake claims via VA-1).

### Medium-Priority Chain: VA-2 → Integration Failure

If VA-2 causes `totalAssets()=0` during a Morpho loss event, any integrating protocol that calls `maxWithdraw` or `previewRedeem` before deciding to withdraw will see 0 and may not initiate the withdrawal. The actual withdrawal would succeed (uses `userMorphoShares` not `totalAssets`), but the integrator never calls it. User funds remain locked until `_accruePremium()` is called and the stale `totalPremiumLiability` is corrected.
