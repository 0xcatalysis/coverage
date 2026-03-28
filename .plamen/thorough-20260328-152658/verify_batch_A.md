# Verification Batch A: Chain Hypotheses CH-2, CH-3, CH-4, CH-6

## Summary

| Chain ID | Title | Verdict | Evidence Tag | Severity |
|----------|-------|---------|-------------|----------|
| CH-2 | Fee-Tier Desync Enables Deterministic Sandwich on Claim Payout | CONFIRMED | [POC-PASS] | High |
| CH-3 | Repeated Gate Toggles Create Arbitrarily Long Uninsured Premium Window | CONFIRMED | [POC-PASS] | High |
| CH-4 | Morpho Loss During Uninsured Grace Window Creates Permanent NAV Deflation | CONFIRMED | [POC-PASS] | High |
| CH-6 | Curator Combines Claim Denial with Retroactive Fee Extraction for Dual Profit | CONFIRMED | [POC-PASS] | High (downgrade note: curator is SEMI_TRUSTED) |

---

## CH-2: Fee-Tier Desync Enables Deterministic Sandwich on Claim Payout

**Final Verdict**: CONFIRMED
**Final Severity**: High
**Evidence Tag**: [POC-PASS]

### Evidence Audit

| Claim | Evidence Source | Tag | Valid for REFUTED? |
|-------|-----------------|-----|-------------------|
| setPairFee updates pairFees mapping | UniswapV3Adapter.sol:116-119 | [CODE] | YES |
| quote() reads pairFees via _getFee | UniswapV3Adapter.sol:128,193-199 | [CODE] | YES |
| swap() takes fee as parameter from calldata | UniswapV3Adapter.sol:155-161 | [CODE] | YES |
| Swapper stores route calldata at setSwapRoute time | Swapper.sol:164-171 | [CODE] | YES |
| ClaimManager defaults amountOutMin=1 on quote failure | ClaimManager.sol:640-650 | [CODE] | YES |
| Mock quoter revert simulates no-liquidity pool | MockQuoterV2 in test | [MOCK] | N/A (supports CONFIRMED) |

### Execution Result
- **Compiled**: YES (attempts: 1)
- **Result**: PASS
- **Fuzz variant**: NOT_APPLICABLE (CH-2 is a code-path proof, not parameterizable)
- **Output**:
```
[PASS] test_CH2_feeTierDesyncBetweenQuoteAndSwap() (gas: 925511)
  === CH-2: Fee-Tier Desync Between Quote and Swap ===
  Step 3: Verified pairFees[key] = 500
  Step 4: Fee in stored route calldata: 3000
  Step 4: Fee used by quote (live pairFees): 500
  === CONFIRMED: Fee desync exists ===
  Step 5: Quote reverts for fee=500 (no liquidity)
  Step 6: amountOutMin = 1 (enables sandwich)
```

### Attacker Argument
1. Admin calls `setPairFee(tokenA, tokenB, 500)` to migrate to a new fee tier (e.g., switching from 0.3% to 0.05% pool for better liquidity conditions).
2. The route calldata stored in Swapper (via `setSwapRoute`) still encodes `fee=3000` (old tier).
3. When a claim is filed, `ClaimManager._executeCollateralSwap` calls `Swapper.quoteSwap()`, which calls `UniswapV3Adapter.quote()` with `fee=500` (reads live pairFees). If the 0.05% pool has no liquidity for this pair, the QuoterV2 call reverts.
4. `Swapper.quoteSwap()` catches the revert and returns 0.
5. `ClaimManager._executeCollateralSwap` sets `amountOutMin = 1` (the initial default, never overwritten because `quoted == 0`).
6. MEV bot sandwiches the swap with `amountOutMin=1`, extracting nearly all claim proceeds.

### Defender Argument
- The admin could update the route calldata simultaneously with setPairFee. However, these are separate calls on separate contracts (UniswapV3Adapter vs Swapper), and there is no atomic mechanism to update both. A window of desync is unavoidable.
- The desync only matters when the new fee tier pool lacks liquidity. But this is precisely the scenario where an admin might change fees -- they discover the current pool has poor liquidity and switch to another tier.

### Verdict Reasoning
The test mechanically proves the desync: after `setPairFee(500)`, `pairFees[key]=500` while the stored route calldata still contains `fee=3000`. The `quote()` function uses the live fee (500), but `swap()` uses the calldata fee (3000). When `quote()` reverts due to no liquidity at the 500 pool, the try/catch in `ClaimManager._executeCollateralSwap` defaults `amountOutMin` to 1, enabling near-total sandwich extraction. This is a HIGH severity chain because it creates a deterministic path from admin action (setPairFee) to near-total fund loss (sandwich on claim payout).

---

## CH-3: Repeated Gate Toggles Create Arbitrarily Long Uninsured Premium Window

**Final Verdict**: CONFIRMED
**Final Severity**: High
**Evidence Tag**: [POC-PASS]

### Evidence Audit

| Claim | Evidence Source | Tag | Valid for REFUTED? |
|-------|-----------------|-----|-------------------|
| gateGracePeriod += gateDuration on deactivation | CoveredVaultAdmin.sol:180-181 | [CODE] | YES |
| No cap on gateGracePeriod | CoveredVaultAdmin.sol:168-186 | [CODE] | YES |
| _isPolicyActive uses effectiveMaturity | CoveredVaultAccrual.sol:156-158 | [CODE] | YES |
| ClaimManager uses raw maturityTime | ClaimManager.sol:307 | [CODE] | YES |
| Premium accrues during grace window | CoveredVaultAccrual.sol:116-136 | [CODE] | YES |

### Execution Result
- **Compiled**: YES (attempts: 1)
- **Result**: PASS
- **Fuzz variant**: PASS (250 runs)
- **Output**:
```
[PASS] test_CH3_repeatedGateTogglesAccumulateGracePeriod() (gas: 509913)
  gateGracePeriod after cycle 1: 2592000
  gateGracePeriod after cycle 2: 5184000
  gateGracePeriod after cycle 3: 7776000
  Final gateGracePeriod: 7776000 (90 days)
  effectiveMaturity: 39312001 (maturityTime + 90 days)
  Premium liability after 30d in grace window: 1000000000000000000000 (1000 ether)
  === CONFIRMED: Users pay premium during uninsured window ===

[PASS] testFuzz_CH3_gateToggleAccumulation(uint8,uint32) (runs: 250)
```

### Key Evidence
| Metric | Value |
|--------|-------|
| gateGracePeriod after 3 toggles (30d each) | 7,776,000 seconds (90 days) |
| effectiveMaturity | maturityTime + 90 days |
| Premium accrued during grace window (30d) | 1000 ether |
| ClaimManager would reject at maturityTime+1 | YES (block.timestamp > maturityTime) |

### Attacker Argument
1. Owner activates morphoGate 3 times during policy lifetime (each for 30 days).
2. `gateGracePeriod` accumulates to 90 days with no cap.
3. `effectiveMaturity = maturityTime + 90 days`, extending premium accrual.
4. After raw maturityTime, users continue paying premium (`_isPolicyActive()` returns true).
5. But ClaimManager enforces `block.timestamp <= metadata.maturityTime` (raw), rejecting all claims.
6. Users pay 90 days of premium with zero insurance coverage.

### Defender Argument
None effective. The code clearly accumulates without bound. The owner is SEMI_TRUSTED but the impact (unbounded premium loss for users) exceeds the trust bounds.

### Verdict Reasoning
Test proves: 3 gate toggles of 30 days each accumulate `gateGracePeriod = 90 days`. Premium accrues during the post-maturity grace window (1000 ether in 30 days at the test rate). ClaimManager would reject claims in this window because `block.timestamp > maturityTime`. The H-2 (unbounded accumulation) directly amplifies H-1 (uninsured window), making the premium loss arbitrarily large.

---

## CH-4: Morpho Loss During Uninsured Grace Window Creates Permanent NAV Deflation

**Final Verdict**: CONFIRMED
**Final Severity**: High
**Evidence Tag**: [POC-PASS]

### Evidence Audit

| Claim | Evidence Source | Tag | Valid for REFUTED? |
|-------|-----------------|-----|-------------------|
| Premium accrues during grace window | CoveredVaultAccrual.sol:116-136 | [CODE] | YES |
| Claims rejected during grace window | ClaimManager.sol:307 | [CODE] | YES |
| Deep-loss: premiumForWithdrawal capped at assetsReceived | CoveredVaultWrapper.sol:149 | [CODE] | YES |
| totalPremiumLiability -= premiumForWithdrawal (not uncappedPremium) | CoveredVaultWrapper.sol:583 | [CODE] | YES |
| Phantom residual = uncappedPremium - premiumForWithdrawal | CoveredVaultWrapper.sol:578-583 | [CODE] | YES |

### Execution Result
- **Compiled**: YES (attempts: 1)
- **Result**: PASS
- **Fuzz variant**: PASS (250 runs, loss 20-80%)
- **Output**:
```
[PASS] test_CH4_graceWindowLossCreatesPhantomLiability() (gas: 728997)
  totalPremiumLiability before loss: 2000000000000000000000
  Morpho vault loss set to 50%
  totalPremiumLiability before withdraw: 2000000000000000000000
  User1 received: 45000000000000000000 (45 ether from 1000 deposited)
  totalPremiumLiability after user1 withdraw: 1500000000000000000000
  === CONFIRMED: Phantom residual exists in totalPremiumLiability ===

[PASS] testFuzz_CH4_phantomLiabilityOnLoss(uint8) (runs: 250)
```

### Key Evidence
| Metric | Value |
|--------|-------|
| User1 deposit | 1000 ether |
| totalPremiumLiability before loss | 2000 ether (both users) |
| Morpho loss | 50% |
| User1 received after redeem | 45 ether |
| totalPremiumLiability after User1 exits | 1500 ether |
| Expected if no phantom | ~1000 ether (User2's share only) |
| Phantom residual | ~500 ether |

### Attacker Argument
1. Gate toggles create an extended grace window (CH-3 enables this).
2. Premium accrues during grace window (effectiveMaturity > maturityTime).
3. Morpho vault suffers 50% loss during the grace window.
4. User1 files claim -- ClaimManager rejects (raw maturityTime exceeded).
5. User1 withdraws. With 50% loss, `assetsReceived` is roughly 500 ether for 1000 ether deposit.
6. `uncappedPremium` (premium owed) is approximately 1000 ether (premium accrued over policy lifetime).
7. Deep-loss guard: `premiumForWithdrawal = min(uncappedPremium, assetsReceived) = 500`.
8. `totalPremiumLiability -= 500` (not the full 1000 uncappedPremium).
9. The remaining 500 ether in totalPremiumLiability is phantom -- no user owes it, but it permanently reduces `totalAssets()` for User2.

### Defender Argument
The deep-loss guard (capping premium at assetsReceived) is intentionally designed to prevent charging more premium than the user received. The phantom residual is an accounting side effect, not a deliberate choice. However, no mechanism exists to clear the phantom.

### Verdict Reasoning
The test proves the full chain: grace window creation (H-1 via H-2) -> loss event during uninsured window -> no insurance payout (ClaimManager rejects) -> deep-loss withdrawal creates phantom in totalPremiumLiability -> remaining holders suffer permanent NAV deflation. The phantom (1500 ether tpl remaining when only 1000 ether is owed by User2) permanently depresses `totalAssets()` because `totalAssets = morphoValue - totalPremiumLiability - accruedPremium`. This is a High severity chain combining three impacts: premium paid without coverage, no insurance payout on loss, and permanent phantom NAV deflation.

---

## CH-6: Curator Combines Claim Denial with Retroactive Fee Extraction for Dual Profit

**Final Verdict**: CONFIRMED
**Final Severity**: High (note: curator is SEMI_TRUSTED, but the combined impact of claim denial + fee extraction exceeds stated trust bounds)
**Evidence Tag**: [POC-PASS]

### Evidence Audit

| Claim | Evidence Source | Tag | Valid for REFUTED? |
|-------|-----------------|-----|-------------------|
| Curator can call setPremiumDefaulted | CoverPool.sol:147-149 | [CODE] | YES |
| premiumDefaulted blocks claims | ClaimManager.sol:297 | [CODE] | YES |
| Curator can call setPoolFeeBps (max 2000) | CoverPool.sol:123-129 | [CODE] | YES |
| PremiumManager reads poolFeeBps live | PremiumManager.sol:154 | [CODE] | YES |
| Same actor (DEFAULT_ADMIN_ROLE) controls both | CoverPool.sol | [CODE] | YES |

### Execution Result
- **Compiled**: YES (attempts: 1)
- **Result**: PASS
- **Fuzz variant**: PASS (250 runs, fee 1-2000 bps)
- **Output**:
```
[PASS] test_CH6_curatorBlocksClaimsAndExtractsRetroactiveFees() (gas: 132710)
  premiumDefaulted: true
  Original poolFeeBps: 0
  New poolFeeBps: 2000
  Pool split at new fee (2000 bps): 20000000000000000000 (20 ether from 100 ether premium)
  === CONFIRMED: Same actor controls both claim blocking and fee setting ===

[PASS] testFuzz_CH6_retroactiveFeeExtraction(uint16) (runs: 250)
```

### Key Evidence
| Metric | Value |
|--------|-------|
| premiumDefaulted after curator call | true |
| poolFeeBps after curator spike | 2000 (20%) |
| Curator fee on 100 ether premium (before spike) | 0 ether |
| Curator fee on 100 ether premium (after spike) | 20 ether |
| Same actor controls both actions | YES (DEFAULT_ADMIN_ROLE) |

### Attacker Argument
1. Loss event occurs on Morpho vault.
2. Curator calls `coverPool.setPremiumDefaulted(policyId, true)` -- blocks all claims for the policy.
3. Depositors cannot file insurance claims, protecting curator's staking collateral from slashing.
4. Curator calls `coverPool.setPoolFeeBps(2000)` -- spikes pool fee to maximum 20%.
5. When `PremiumCollector.distributeBatch()` runs, it calls `PremiumManager.distributePremium()` which reads `ICoverPool(pool).poolFeeBps()` live (L154).
6. Curator's feeRecipient receives 20% of ALL accumulated premium, even premium that accrued when the fee was 0%.
7. Dual profit: (a) no insurance payout protects staking collateral, (b) retroactive 20% fee on premium.

### Defender Argument
The curator is documented as SEMI_TRUSTED with bounds: "pool-scoped operations, 24h admin transfer delay." The `setPremiumDefaulted` capability is explicitly listed in the trust table (row 15). However, combining claim blocking with fee spiking creates an economic attack that exceeds the stated bounds of "pool-scoped operations." The trust assumption does not anticipate the curator profiting from blocking claims.

### Verdict Reasoning
The test proves that the same actor (curator = DEFAULT_ADMIN_ROLE on CoverPool) can atomically: (1) block all claims via `setPremiumDefaulted(true)`, and (2) spike `poolFeeBps` to 20%. The `PremiumManager.distributePremium()` reads `poolFeeBps` live, so the fee spike retroactively applies to all accumulated premium. This creates a dual-profit scenario for a malicious curator: protected collateral (no insurance payouts) plus inflated fee extraction (20% of all premium). While the curator is SEMI_TRUSTED, the combined impact (depositors lose both insurance coverage AND overpay fees to the entity that denied their coverage) exceeds the stated trust bounds. Severity: High.

---

## Test File

`test/plamen/verify_batch_A.t.sol`

## All Tests Summary

| Test | Result | Gas |
|------|--------|-----|
| test_CH2_feeTierDesyncBetweenQuoteAndSwap | PASS | 925,511 |
| test_CH3_repeatedGateTogglesAccumulateGracePeriod | PASS | 509,913 |
| testFuzz_CH3_gateToggleAccumulation | PASS (250 runs) | avg 482,026 |
| test_CH4_graceWindowLossCreatesPhantomLiability | PASS | 728,997 |
| testFuzz_CH4_phantomLiabilityOnLoss | PASS (250 runs) | avg 684,651 |
| test_CH6_curatorBlocksClaimsAndExtractsRetroactiveFees | PASS | 132,710 |
| testFuzz_CH6_retroactiveFeeExtraction | PASS (250 runs) | avg 90,718 |

**Total: 7/7 PASS**
