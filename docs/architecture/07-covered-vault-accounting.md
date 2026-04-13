# CoveredVaultWrapper — Accounting & Liability Model

This document explains the premium liability, headroom cap, `totalAssets()` calculation, and insurance payout mechanics of the `CoveredVaultWrapper` contract.

---

## Architecture Overview

```
User → CoveredVaultWrapper (ERC-4626, UUPS)
         → Morpho V2 vault (fees=0, sole depositor=wrapper)
             → MorphoVaultV1Adapter (off-the-shelf)
                 → Underlying ERC-4626 yield source
```

The wrapper tracks per-user **principal** (cost basis) in `userPrincipal[user]`. Shares are non-transferable (soulbound) — only mints and burns are permitted.

---

## Premium Liability

The vault tracks one liability bucket: **`totalPremiumLiability`** — premiums owed to `premiumRecipient` for providing coverage.

Premium accrues continuously on **`totalPrincipal`** (cost basis of all depositors), intentionally excluding yield so users don't pay premium on their gains. The accrual uses a reward-per-token accumulator pattern (`cumulativePremiumPerUnit`) so each user's share of the liability is tracked precisely based on how long they've been in the vault.

The premium rate is set off-chain using an actuarial model that prices in both the expected underlying losses (smart contract risk, market risk, management fees, etc.) and a risk margin. There is no separate expected-loss accounting on-chain — it's all unified into the premium.

### Per-User Premium Tracking

On deposit, a user's `userPremiumDebt` is set so they don't inherit premium that accrued before they entered:

```solidity
userPremiumDebt[receiver] += assets.mulDiv(cumulativePremiumPerUnit, WAD);
```

On withdrawal, the user's owed premium is computed via the standard reward-per-token formula:

```
owedPremium = principal × cumulativePremiumPerUnit / WAD − userPremiumDebt
```

---

## Liability Headroom — The Safety Cap

```solidity
function _liabilityHeadroom(uint256 morphoVal) internal view returns (uint256) {
    return morphoVal > totalPremiumLiability ? morphoVal - totalPremiumLiability : 0;
}
```

This returns how much additional premium can accrue before liabilities equal the Morpho vault value.

During `_accruePremium()`, the new premium increment is capped against this headroom:

```solidity
uint256 maxNewLiability = _liabilityHeadroom(morphoValue);
if (accrued > maxNewLiability) accrued = maxNewLiability;
```

**Purpose:** Ensures `totalPremiumLiability` can never exceed `morphoValue`, which prevents `totalAssets()` from going negative. In a severe loss scenario where the Morpho vault value drops dramatically, the cap kicks in and premium simply stops accruing — the protocol absorbs the shortfall gracefully rather than reporting negative NAV.

---

## `totalAssets()` — Net Asset Value

```solidity
function totalAssets() public view override returns (uint256) {
    uint256 mv = _morphoValue();
    uint256 totalLiability = totalPremiumLiability + _accruedPremiumFor(mv);
    return mv > totalLiability ? mv - totalLiability : 0;
}
```

### Step by Step

1. **`mv`** = the wrapper's Morpho vault shares converted to underlying assets (gross value held)
2. **`totalLiability`** = checkpointed premium (stored in state) + uncheckpointed premium accrued since the last `_accruePremium()` call
3. **`totalAssets`** = `mv - totalLiability`, floored at 0

Including the uncheckpointed portion ensures NAV stays consistent between accrual events — the share price doesn't suddenly jump when `_accruePremium()` is called.

### Key Consequence

The share price already reflects the NAV *after* premium deductions. A new depositor buying shares at the current price is not subsidizing premiums that accumulated before they arrived — the liability is already priced into what they pay.

---

## Numerical Examples

All examples use realistic parameters:

| Parameter | Value |
|-----------|-------|
| Morpho underlying APY | 3% annually |
| Premium rate | 50 bps (0.5%) annually |
| `maxCoverableLossBps` | 1,000 (10%) |
| `deductibleBps` | 100 (1%) |

---

### Example 1: Normal Operation — Yield Exceeds Premium (1 year)

Alice deposits 100,000 USDC into the covered vault.

```
After 1 year:
morphoValue           = 100,000 × 1.03      = 103,000 USDC  (3% Morpho yield)
totalPremiumLiability = 100,000 × 0.50%      =     500 USDC  (50 bps premium)

_liabilityHeadroom    = 103,000 - 500        = 102,500       (cap not triggered)

totalAssets()         = 103,000 - 500        = 102,500 USDC
share price           = 102,500 / 100,000    = 1.025 USDC/share
```

Alice's effective yield = 3.0% Morpho yield - 0.5% premium = **2.5% net APY**. Premium is the cost of insurance coverage — a small drag on yield.

If Alice withdraws after 1 year:
```
assetsReceived       = 103,000 USDC
premiumForWithdrawal =     500 USDC
netAssetsReceived    = 102,500 USDC

insuredBasis = 100,000 - 500 = 99,500
netAssetsReceived (102,500) > insuredBasis (99,500) → no shortfall, no claim
```

Alice receives **102,500 USDC** — her full yield minus the premium. No insurance needed.

---

### Example 2: Loss Scenario — Insurance Payout Triggered (1 year)

Alice deposits 100,000 USDC. After 1 year, Morpho vault suffers a 5% loss (e.g., a smart contract exploit in an underlying market).

```
morphoValue           = 100,000 × 0.95      =  95,000 USDC  (5% loss, no yield)
totalPremiumLiability = 100,000 × 0.50%      =     500 USDC
```

Alice withdraws:

```
assetsReceived       = 95,000 USDC (from Morpho)
premiumForWithdrawal = min(500, 95,000) = 500 USDC
netAssetsReceived    = 95,000 - 500 = 94,500 USDC

insuredBasis = 100,000 - 500 = 99,500 USDC
shortfall    = 99,500 - 94,500 = 5,000 USDC → claim triggers
```

Apply cap and deductible:
```
maxInsurance   = 99,500 × 10% = 9,950 USDC   (5,000 is within cap)
capped         = 5,000 USDC
deductibleAmt  = 99,500 × 1% = 995 USDC      (traditional threshold on insured basis)
payout         = 5,000 - 995 = 4,005 USDC     (loss above deductible)
```

Total received by Alice:
```
netAssetsReceived  =  94,500 USDC
+ insurancePayout  =   4,005 USDC
──────────────────────────────────
Total              =  98,505 USDC
```

Alice deposited 100,000 and gets back **98,505 USDC**. The 1,495 gap = 500 premium + 995 deductible (1% of insured basis — the threshold she absorbs before insurance pays). Without insurance, she would have received only 94,500 — **the insurance recovered 4,005 of the 5,000 loss**.

---

### Example 3: Multi-User Scenario — Late Depositor Not Disadvantaged (6 months)

Alice deposits 100,000 USDC at day 0. Bob deposits 100,000 USDC at month 3.

```
Month 0-3: totalPrincipal = 100,000 (Alice only)
  Premium accrued = 100,000 × 0.50% × 0.25yr = 125 USDC
  cumulativePremiumPerUnit advances by 125/100,000 (WAD-scaled)

Month 3: Bob deposits 100,000 USDC
  Bob's userPremiumDebt = 100,000 × cumulativePremiumPerUnit / WAD
  This "debt" offsets the pre-existing premium so Bob owes nothing for months 0-3.

Month 3-6: totalPrincipal = 200,000 (Alice + Bob)
  Premium accrued = 200,000 × 0.50% × 0.25yr = 250 USDC
  cumulativePremiumPerUnit advances by 250/200,000
```

At month 6, total premium liability = 375 USDC. Morpho earned 3% APY:

```
morphoValue (month 6) ≈ 200,000 × 1.015    = 203,000 USDC  (approx, simplified)
totalAssets()         = 203,000 - 375       = 202,625 USDC
```

Each user's owed premium:
```
Alice: 6 months in vault → owes 125 + 125 = 250 USDC
Bob:   3 months in vault → owes 0   + 125 = 125 USDC
```

Bob does not pay for the 125 USDC that accrued before he deposited. The reward-per-token accumulator ensures fair pro-rata allocation.

---

### Example 4: Headroom Cap — Extreme Loss Scenario

Alice deposits 100,000 USDC. Six months of premium have accrued (250 USDC). Then the Morpho vault suffers a catastrophic 99.5% loss.

```
morphoValue           = 500 USDC             (99.5% loss)
totalPremiumLiability = 250 USDC             (already checkpointed)
New premium increment = 125 USDC             (natural accrual for next quarter)

_liabilityHeadroom    = 500 - 250 = 250 USDC
Premium increment (125) < headroom (250) → accrues fully
totalPremiumLiability = 250 + 125 = 375 USDC
totalAssets()         = 500 - 375 = 125 USDC
```

Now another quarter passes, natural increment would be 125 USDC again:

```
_liabilityHeadroom    = 500 - 375 = 125 USDC
Premium increment (125) = headroom (125) → accrues fully, headroom now 0
totalPremiumLiability = 375 + 125 = 500 USDC
totalAssets()         = 500 - 500 = 0 USDC
```

Any further premium accrual is capped at 0 — the headroom is exhausted. `totalAssets()` stays at 0 rather than going negative. If Alice withdraws, insurance covers the loss (minus cap and deductible).

---

### Example 5: Withdrawal with Yield Partially Offsetting Loss

Alice deposits 100,000 USDC. After 1 year, Morpho earned 3% yield but also suffered a 5% hack loss. Net Morpho value = 100,000 × 1.03 × 0.95 = 97,850 USDC.

```
assetsReceived       = 97,850 USDC
premiumForWithdrawal = 500 USDC (0.5% annual premium)
netAssetsReceived    = 97,350 USDC

insuredBasis = 100,000 - 500 = 99,500 USDC
shortfall    = 99,500 - 97,350 = 2,150 USDC → claim triggers
```

Apply cap and deductible:
```
maxInsurance   = 99,500 × 10% = 9,950 USDC   (2,150 is within cap)
capped         = 2,150 USDC
deductibleAmt  = 99,500 × 1% = 995 USDC      (traditional threshold)
payout         = 2,150 - 995 = 1,155 USDC     (loss above deductible)
```

Total received:
```
netAssetsReceived  =  97,350.00 USDC
+ insurancePayout  =   1,155.00 USDC
──────────────────────────────────────
Total              =  98,505.00 USDC
```

The 3% yield partially offset the 5% hack, reducing the shortfall from 5,000 to 2,150. The deductible threshold (995 USDC) absorbs the first portion of the loss. Alice recovers **98,505 out of 100,000**.

---

## Withdrawal Flow — Detailed

```
_withdraw()
  ├── _accruePremium()                    // checkpoint premium liability
  ├── compute userPrincipalForWithdrawal  // pro-rata share of owner's principal
  ├── _executeWithdrawal()
  │     ├── _computeOwedAmounts()         // reward-per-token formula for premium
  │     ├── Morpho.redeem()               // get underlying assets back
  │     ├── _updateDebtsAfterWithdrawal() // adjust remaining user's debt
  │     └── _settleWithdrawalTransfer()
  │           ├── cap premium at assetsReceived  // deep-loss guard
  │           ├── insuredBasis = principal - premiumForWithdrawal
  │           ├── _computeInsurance()
  │           │     ├── shortfall = insuredBasis - netAssetsReceived
  │           │     ├── _capAndApplyDeductible()
  │           │     └── _claimInsurance() → ClaimManager
  │           └── transfer(receiver, netAssets + insurancePayout)
  └── totalPrincipal -= userPrincipalForWithdrawal
```

### Deep-Loss Guard

In a catastrophic loss where Morpho returns very little:

```solidity
premiumForWithdrawal = uncappedPremium < assetsReceived ? uncappedPremium : assetsReceived;
```

Premium is capped at what Morpho actually returned. The uncollected premium is "forgiven" — it never reaches `pendingPremium` — and does not further reduce the user's insured basis.

### `_capAndApplyDeductible(shortfall, basis)`

```solidity
function _capAndApplyDeductible(uint256 shortfall, uint256 basis) private view returns (uint256) {
    uint256 maxInsurance = basis.mulDiv(maxCoverableLossBps, BPS_DENOMINATOR);
    uint256 capped = shortfall > maxInsurance ? maxInsurance : shortfall;
    uint256 deductibleAmt = basis.mulDiv(deductibleBps, BPS_DENOMINATOR);
    return capped > deductibleAmt ? capped - deductibleAmt : 0;
}
```

Two bounds applied sequentially (traditional insurance model):
1. **maxCoverableLossBps** — caps the claim at a percentage of the insured basis (policy limit)
2. **deductibleBps** — computes a fixed threshold (% of insured basis) that the policyholder absorbs before insurance pays. Losses at or below this threshold get $0 payout. Losses above it are paid out minus the threshold amount.

---

## Insurance Parameters

| Parameter | What it does | Timelock |
|-----------|-------------|----------|
| `premiumRatePerSecond` | WAD-scaled per-second premium rate applied to `totalPrincipal` | 2 hours (operational) |
| `maxCoverableLossBps` | Maximum insurance payout as % of insured basis; also drives `depositCap` | 2 days (standard) |
| `deductibleBps` | Copay percentage subtracted from every claim | 2 days (standard) |
| `premiumRecipient` | Address that receives collected premiums | 2 days (standard) |
| `depositCap` | Max TVL = `coverageLimit × 10,000 / maxCoverableLossBps` | Set by `onPolicyBound` |

### Deposit Cap Relationship

```
depositCap = coverageLimit × BPS_DENOMINATOR / maxCoverableLossBps
```

If the CoverPool has 1M USDC of coverage capacity and `maxCoverableLossBps = 1,000` (10%), then:
```
depositCap = 1,000,000 × 10,000 / 1,000 = 10,000,000 USDC
```

A 10% loss on 10M = 1M in claims, exactly exhausting the coverage.

---

## View Functions

| Function | Returns |
|----------|---------|
| `totalAssets()` | `morphoValue - totalPremiumLiability - accruedPremium` (floored at 0) |
| `calculateShortfall()` | Global insurable shortfall (capped + deductible applied) |
| `userShortfall(user)` | Per-user insurable shortfall |
| `maxWithdraw(owner)` | Maximum withdrawable assets accounting for premium deductions |
| `maxRedeem(owner)` | All shares (no restriction beyond balance) |

---

## Summary

| Concept | What it does | Where you see it |
|---------|-------------|-----------------|
| `totalPremiumLiability` | Premium owed to `premiumRecipient`, reduces NAV | `totalAssets()` deduction |
| `_liabilityHeadroom` | Prevents liabilities from exceeding `morphoValue` | Cap on each accrual increment |
| `insuredBasis` | Principal minus actually-collected premium | Lower bound for insurance trigger |
| `_capAndApplyDeductible` | Bounds claim at `maxCoverableLossBps`, then takes deductible | Final payout calculation |
| `depositCap` | Sizes the vault to its insurance capacity | `maxDeposit()` enforcement |
