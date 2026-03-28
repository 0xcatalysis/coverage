# Verification Batch B: H-1, H-4, H-5

## H-1: gateGracePeriod Renders Grace Window Fully Uninsured While Premium Accrues
**Final Verdict**: CONFIRMED
**Final Severity**: High (PROVEN_ONLY demotion does NOT apply -- [POC-PASS])
**Evidence Tag**: [POC-PASS]

### Evidence Audit
| Claim | Evidence Source | Tag | Valid for REFUTED? |
|-------|-----------------|-----|-------------------|
| _isPolicyActive uses effectiveMaturity | CoveredVaultAccrual.sol:156-158 | [CODE] | YES |
| ClaimManager uses raw maturityTime | ClaimManager.sol:307 | [CODE] | YES |
| Premium accrues during grace window | CoveredVaultAccrual.sol:117-118 (calls _isPolicyActive) | [CODE] | YES |
| Desync proven by executed test | test/plamen/verify_batch_B.t.sol:Test_H1 | [POC-PASS] | YES |

### Execution Result
- **Compiled**: YES (attempts: 1)
- **Result**: PASS
- **Fuzz variant**: NOT_APPLICABLE (logic check, not value-dependent)
- **Output**:
```
[PASS] test_H1_gracePeriodInsuranceGap() (gas: 227795)
  === H-1: Grace Period Insurance Gap ===
  Raw maturityTime: 3592000
  effectiveMaturity: 4196800
  Current time: 3678400
  _isPolicyActive (vault logic): true
  ClaimManager window check: false
  === VERIFICATION ===
  Premium accruing: true
  Claims accepted: false
```

### Attacker Argument
When the Morpho gate is activated and later deactivated, `gateGracePeriod` accumulates time (CoveredVaultAdmin.sol:181). This extends `effectiveMaturity` in `_isPolicyActive()` (CoveredVaultAccrual.sol:156-157), causing premium to continue accruing past the raw `maturityTime`. However, `ClaimManager._fileClaimWithMetadata()` at line 307 checks `block.timestamp <= metadata.maturityTime` (the raw value from PolicyManager, which does NOT include gateGracePeriod). Users in the grace window pay premium but cannot file claims. This is a direct user-harming desync -- users pay for insurance coverage they cannot use.

### Defender Argument
The grace window mechanism was intended to extend the policy window to compensate users for time lost during the Morpho gate. However, the ClaimManager was not updated to recognize the extended maturity. This is a cross-contract integration gap, not a design choice. No defense mechanism prevents this.

### Verdict Reasoning
The test mechanically proves the logical desync: `_isPolicyActive()` returns true (premium accrues) while `ClaimManager`'s window check returns false (claims rejected) during the grace period. The code evidence is unambiguous -- CoveredVaultAccrual.sol:156 adds `gateGracePeriod` to maturity, but ClaimManager.sol:307 does not. This is a High severity finding because users lose premium payments without corresponding insurance coverage, and the duration can be significant (especially with H-2's unbounded accumulation).

---

## H-4: Excess Swap Output Permanently Stranded in ClaimManager
**Final Verdict**: CONFIRMED
**Final Severity**: Medium (downgraded from High -- admin can recover via recoverTokens)
**Evidence Tag**: [POC-PASS]

### Evidence Audit
| Claim | Evidence Source | Tag | Valid for REFUTED? |
|-------|-----------------|-----|-------------------|
| amountOut capped at remainingPayout | ClaimManager.sol:666 | [CODE] | YES |
| Surplus stays in ClaimManager | test/plamen/verify_batch_B.t.sol:Test_H4 | [POC-PASS] | YES |
| recoverTokens exists for admin | ClaimManager.sol:169-174 | [CODE] | YES |
| No automatic surplus routing mechanism | ClaimManager.sol (full review) | [CODE] | YES |

### Execution Result
- **Compiled**: YES (attempts: 1)
- **Result**: PASS
- **Fuzz variant**: NOT_APPLICABLE (threshold behavior, clearly demonstrated)
- **Output**:
```
[PASS] test_H4_excessSwapOutputStranded() (gas: 680387)
  === H-4: Excess Swap Output ===
  Requested payout: 100000000000000000000
  Swap output: 150 ether
  Beneficiary received: 100000000000000000000
  Stranded in ClaimManager: 50000000000000000000
  === VERIFICATION ===
  Expected surplus: 50000000000000000000
  Actual surplus in ClaimManager: 50000000000000000000
  Surplus is stranded: true
```

### Attacker Argument
When a collateral swap produces more payout tokens than `remainingPayout`, the excess (50 ether in the test, i.e., 150 - 100) remains in ClaimManager. This means vault stakers were over-slashed: they gave up 200 ether of collateral that produced 150 ether of payout tokens, but only 100 was needed. The extra 50 ether equivalent is extracted from stakers with no automatic return mechanism. Over multiple claims with favorable price movements, material value accumulates in ClaimManager.

### Defender Argument
ClaimManager has a `recoverTokens` function (line 169) that allows `DEFAULT_ADMIN_ROLE` holders to extract stranded tokens. The funds are NOT permanently locked -- admin can recover and redistribute them. However, this requires manual admin intervention and there is no mechanism to ensure the recovered funds are returned to the correct slashed vaults pro-rata.

### Verdict Reasoning
The bug is confirmed -- surplus swap output is silently retained in ClaimManager instead of being routed to beneficiary or returned to slashed vaults. However, the original severity assessment of "permanently stranded" is overstated because `recoverTokens` exists as an admin recovery mechanism (ClaimManager.sol:169-174). The real issue is (a) vault stakers are over-slashed without compensation, (b) admin must manually intervene to recover and redistribute, and (c) the surplus rightfully belongs to the slashed vaults, not the admin. Downgrading from High to Medium because the funds are recoverable (not permanently lost), but the misallocation and lack of automatic routing is still a meaningful deficiency.

---

## H-5: UniswapV3Adapter Fee-Tier Desync Between Quote and Swap
**Final Verdict**: CONFIRMED
**Final Severity**: High (PROVEN_ONLY demotion does NOT apply -- [POC-PASS])
**Evidence Tag**: [POC-PASS]

### Evidence Audit
| Claim | Evidence Source | Tag | Valid for REFUTED? |
|-------|-----------------|-----|-------------------|
| quote() reads pairFees mapping via _getFee | UniswapV3Adapter.sol:128, 193-199 | [CODE] | YES |
| swap() takes fee as calldata parameter | UniswapV3Adapter.sol:155-188 | [CODE] | YES |
| Swapper stores calldata at setSwapRoute time | Swapper.sol:170 | [CODE] | YES |
| Swapper uses stored calldata in executeSwap | Swapper.sol:240-241, 311 | [CODE] | YES |
| setPairFee updates mapping but not stored route | UniswapV3Adapter.sol:116-120 | [CODE] | YES |
| Desync proven by executed test | test/plamen/verify_batch_B.t.sol:Test_H5 | [POC-PASS] | YES |

### Execution Result
- **Compiled**: YES (attempts: 1)
- **Result**: PASS
- **Fuzz variant**: NOT_APPLICABLE (deterministic desync, not value-dependent)
- **Output**:
```
[PASS] test_H5_feeTierDesync() (gas: 375624)
  === H-5: Fee-Tier Desync ===
  Initial quote result: 1000
  Swap 1 fee used: 3000
  Fee changed to: 500
  === VERIFICATION ===
  Quote uses fee from pairFees: 500
  Swap uses fee from calldata: 3000
  Fee in pairFees (quote path): 500
  Fee in swap execution: 3000
  Desync confirmed: true
```

### Attacker Argument
After admin calls `setPairFee(tokenA, tokenB, 500)` to migrate from the 0.3% pool to the 0.05% pool:
1. `quote()` calls `_getFee()` which reads `pairFees` mapping and returns 500 (new fee).
2. `swap()` is called by Swapper with stored calldata that still encodes `fee=3000` (old fee).
3. Two attack scenarios:
   - **DoS**: If the old pool (3000) has been drained of liquidity after migration, swaps revert, blocking all claims.
   - **Slippage**: If the old pool (3000) has poor liquidity, swap execution is significantly worse than the quote predicted. The `amountOutMin` is computed from the quote (which used the correct new pool), but the swap executes against the wrong pool, potentially enabling MEV extraction.

### Defender Argument
The admin could update the swap route (calling `Swapper.setSwapRoute` with new calldata encoding the new fee) at the same time as calling `setPairFee`. However, there is no atomic mechanism to ensure both are updated together, and `setPairFee` is on UniswapV3Adapter while `setSwapRoute` is on Swapper (potentially different admin roles). The architecture has an inherent consistency gap.

### Verdict Reasoning
The test mechanically proves the desync: after `setPairFee`, `pairFees[key]` returns 500 (used by `quote()`) while the swap still executes with fee=3000 (from stored calldata). This is confirmed by the router mock recording `lastFee=3000` on the second swap. The architecture fundamentally separates the fee source for quoting (live mapping read) from swapping (frozen calldata), creating an unavoidable desync window. This is High severity because it affects the critical claim payout path -- either causing claim DoS or enabling sandwich attacks on claim settlements.

---

## Summary

| Hypothesis | Verdict | Evidence | Final Severity |
|-----------|---------|----------|---------------|
| H-1 | CONFIRMED | [POC-PASS] | High |
| H-4 | CONFIRMED | [POC-PASS] | Medium (downgraded from High - admin recovery exists) |
| H-5 | CONFIRMED | [POC-PASS] | High |
