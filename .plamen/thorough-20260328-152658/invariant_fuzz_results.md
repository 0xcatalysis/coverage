# Invariant Fuzz Campaign Results

## Test File: test/plamen/InvariantFuzz.t.sol

## Prior Art: Existing Invariant Suite

Before writing new tests, the existing 10-invariant stateful suite was executed:
- **File**: `test/invariant/CoveredVaultWrapper.invariant.t.sol`
- **Result**: ALL 10 PASS (50 runs × 25 calls = 1,250 calls per invariant)
- **Invariants covered by existing suite**:
  - INV-1: totalPrincipal == sum(userPrincipal)
  - INV-2: totalPremiumLiability <= morphoValue
  - INV-3: duplicate of INV-2 (combined liability bounded)
  - INV-4: totalAssets() >= 0
  - INV-5: Soulbound transfers disabled
  - INV-6: userPrincipal == 0 iff balanceOf == 0
  - INV-7: sum(userMorphoShares) <= morphoVault.balanceOf(wrapper)
  - INV-8: totalSupply() == sum(balanceOf(u))
  - INV-9: pendingPremium collectable after collectPremium()
  - INV-10: totalPrincipal == 0 iff totalSupply() == 0

## Compilation Status
- **Compiled**: YES (attempts: 1)
- **Errors**: None

## Test Results

| Test | Runs | Result | Finding |
|------|------|--------|---------|
| testFuzz_cumulativePremiumMonotonic | 250 | PASS | - |
| testFuzz_erc4626RoundTrip | 250 | PASS | - |
| testFuzz_premiumLiabilityCapUnderLoss | 250 | PASS | - |
| testFuzz_totalAssetsNeverReverts | 250 | PASS | - |
| testFuzz_depositCapEnforced | 250 | PASS | - |
| testFuzz_userPremiumSumVsLiability | 250 | PASS | - |
| testFuzz_depositWithdrawRoundTrip | 250 | PASS | - |
| testFuzz_maxWithdrawBoundedByGrossAssets | 250 | PASS | - |

**Total fuzz runs: 2,000**
**Total test time: ~81ms execution, ~41s wall clock (including compilation)**

## Violations Found

None. All 8 fuzz tests passed with 250 runs each, and all 10 pre-existing invariant tests also pass.

## Evidence Tags

- testFuzz_cumulativePremiumMonotonic: [POC-PASS]
- testFuzz_erc4626RoundTrip: [POC-PASS]
- testFuzz_premiumLiabilityCapUnderLoss: [POC-PASS]
- testFuzz_totalAssetsNeverReverts: [POC-PASS]
- testFuzz_depositCapEnforced: [POC-PASS]
- testFuzz_userPremiumSumVsLiability: [POC-PASS]
- testFuzz_depositWithdrawRoundTrip: [POC-PASS]
- testFuzz_maxWithdrawBoundedByGrossAssets: [POC-PASS]

## Invariants Tested (supplementary — gaps vs existing suite)

| ID | Invariant | Coverage |
|----|-----------|----------|
| FUZZ-A | cumulativePremiumPerUnit is monotonically non-decreasing | [POC-PASS] 250 runs |
| FUZZ-B | ERC-4626 round-trip: convertToShares(convertToAssets(s)) <= s | [POC-PASS] 250 runs |
| FUZZ-C | totalPremiumLiability <= morphoValue after Morpho loss (1-50%) | [POC-PASS] 250 runs |
| FUZZ-D | totalAssets() saturates at 0 — never reverts under any input | [POC-PASS] 250 runs |
| FUZZ-E | totalPrincipal never exceeds depositCap (multi-user deposits) | [POC-PASS] 250 runs |
| FUZZ-F | sum(userOwedPremium) <= totalPremiumLiability + 2 (rounding dust) | [POC-PASS] 250 runs |
| FUZZ-G | Same-block deposit+redeem: assetsReceived <= deposited (no extraction) | [POC-PASS] 250 runs |
| FUZZ-H | maxWithdraw(user) <= convertToAssets(balanceOf(user)) | [POC-PASS] 250 runs |

## Summary
- Tests written: 8
- Tests executed: 8 (all 2,000 fuzz runs)
- Violations: 0
- Highest severity: None
- Pre-existing invariant suite: 10 PASS

## Notes

The protocol's invariants hold robustly across all fuzz dimensions tested. The key observations:

1. **Premium accumulator (cumulativePremiumPerUnit)**: Correctly monotonic — the `_liabilityHeadroom` cap prevents runaway accrual when Morpho values drop, and the cap itself is enforced correctly.

2. **ERC-4626 round-trip**: Shares-to-assets-to-shares is correctly non-expansionary. The 10^6 virtual share decimals offset (`_decimalsOffset() = 6`) provides inflation-attack protection without breaking the round-trip invariant.

3. **Deep-loss premium cap**: `_liabilityHeadroom()` correctly prevents `totalPremiumLiability` from exceeding `morphoValue` even when Morpho reports up to 50% loss. The saturating subtraction in `totalAssets()` correctly returns 0 in extreme cases.

4. **depositCap enforcement**: `maxDeposit()` correctly returns `depositCap - totalPrincipal`, capping individual user deposits and preventing aggregate TVL from exceeding the policy-derived cap.

5. **Per-user premium sum**: The reward-per-token accumulator produces per-user owed amounts that sum to at most `totalPremiumLiability` (within 2-unit rounding dust), confirming no overcounting.
