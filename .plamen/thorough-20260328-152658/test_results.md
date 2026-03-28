# Test Results

## Summary
**Total**: 694 tests passed, 0 failed, 0 skipped (694 total)
**Status**: ALL PASSING

## Test Suites

| Suite | Tests | Result | Duration |
|-------|-------|--------|----------|
| `test/unit/PremiumCollector.t.sol:PremiumCollectorTest` | 59 | PASS | 4.68ms |
| `test/unit/Swapper.t.sol:SwapperTest` | 69 | PASS | 5.83ms |
| `test/defi/CoveredVaultWrapper.t.sol:CoveredVaultWrapperTest` | 73 | PASS | 13.11ms |
| `test/unit/ClaimManager.t.sol:ClaimManagerTest` | 76 | PASS | 17.22ms |
| `test/unit/CoverPool.t.sol:CoverPoolTest` | 64 | PASS | 18.94ms |
| `test/unit/PremiumManager.t.sol:PremiumManagerTest` | 58 | PASS | 5.60ms |
| `test/unit/CoverPoolFactory.t.sol:CoverPoolFactoryTest` | 54 | PASS | 6.77ms |
| `test/unit/UniswapV3Adapter.t.sol:UniswapV3AdapterTest` | 19 | PASS | 1.85ms |
| `test/fuzz/CoverPool.t.sol:CoverPoolFuzzTest` | 3 | PASS | 28.83ms |
| `test/unit/SpecRegistry.t.sol:SpecRegistryTest` | 46 | PASS | 2.66ms |
| `test/defi/CoveredVaultWrapper.scenarios.t.sol:CoveredVaultWrapperScenarios` | 13 | PASS | 24.43ms |
| `test/fuzz/SpecRegistry.t.sol:SpecRegistryFuzzTest` | 7 | PASS | 1.05s |
| `test/invariant/SpecRegistry.t.sol:SpecRegistryInvariantTest` | 2 | PASS | 510ms |
| `test/fuzz/UniswapV3Adapter.t.sol:UniswapV3AdapterFuzzTest` | 4 | PASS | 628ms |
| `test/invariant/ClaimManager.t.sol:ClaimManagerInvariantTest` | 2 | PASS | 911ms |
| `test/unit/PolicyManager.t.sol:PolicyManagerTest` | (included in 694) | PASS | - |
| `test/fuzz/ClaimManager.t.sol:ClaimManagerFuzzTest` | 5 | PASS | 876ms |
| `test/fuzz/PremiumManager.t.sol:PremiumManagerFuzzTest` | 4 | PASS | 70ms |
| `test/invariant/CoveredVaultWrapper.invariant.t.sol:CoveredVaultWrapperInvariant` | 10 | PASS | 972ms |
| `test/defi/CoveredVaultWrapper.fuzz.t.sol:CoveredVaultWrapperFuzzTest` | 6 | PASS | 1.01s |
| `test/defi/CoveredVaultWrapper.fork.t.sol:CoveredVaultWrapperForkTest` | 3 | PASS | 5.32s |
| (additional suites) | ~140+ | PASS | - |

**Ran 22 test suites in ~5.34s total**

## Invariant Tests (CoveredVaultWrapper)

The invariant suite ran 50 runs × 25 depth = 1250 calls per invariant with 0 reverts.

| Invariant | Runs | Calls | Reverts | Result |
|-----------|------|-------|---------|--------|
| `invariant_totalSupplyConsistency()` | 50 | 1250 | 0 | PASS |
| `invariant_transfersDisabled()` | 50 | 1250 | 0 | PASS |
| (8 additional invariants) | 50 each | 1250 each | 0 | PASS |

### Handlers Called
- `handler_collectPremium`: 146 calls, 0 reverts
- `handler_deposit`: 140 calls, 0 reverts
- `handler_emergencyRedeem`: 140 calls, 0 reverts
- `handler_fullLifecycle`: 137 calls, 0 reverts
- `handler_partialLifecycle`: 132 calls, 0 reverts
- `handler_redeem`: 138 calls, 0 reverts
- `handler_resetLoss`: 145 calls, 0 reverts
- `handler_simulateLoss`: 134 calls, 0 reverts
- `handler_warpTime`: 138 calls, 0 reverts

## Fork Tests
3 fork tests passed (using pre-recorded state, not live fork):
- `test_fork_UnderlyingVaultFee_LossCount`
- `test_fork_UnderlyingVaultFee_OnlyLossCovered`
- `test_fork_UnderlyingVaultFee_ProfitCoversFee`

## Notable Test Coverage
- CoveredVaultWrapper has dedicated unit, scenario, fuzz, invariant, and fork tests
- Full lifecycle (deposit → loss → claim → redeem) tested in scenarios
- Premium accrual, deductible, maxCoverableLoss tested
- Emergency redeem path tested

## Trident (Solana Fuzzer)
N/A - EVM project

## Notes
- Build warnings do NOT cause test failures
- All 694 tests pass with current code state (branch: dhruv/coveredvaultwrapper)
