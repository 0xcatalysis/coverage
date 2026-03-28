# Verification: Batch F (Low Severity Hypotheses)

**Hypotheses**: H-17, H-18, H-21, H-23, H-24, H-26, H-27, H-28, H-29, H-31
**Test file**: test/plamen/verify_batch_F.t.sol
**PROVEN_ONLY**: true (Low severity, code traces acceptable)

---

## H-17: renounceOwnership Not Overridden in UniswapV3Adapter

**Final Verdict**: CONFIRMED
**Final Severity**: Low
**Evidence Tag**: [POC-PASS]

### Evidence

Code trace:
- `UniswapV3Adapter` inherits `Ownable2Step` from OZ non-upgradeable (line 53)
- `Ownable2Step` inherits `Ownable` whose `renounceOwnership()` is NOT overridden in `UniswapV3Adapter`
- `CoveredVaultAdmin.sol:128` shows the correct mitigation: `function renounceOwnership() public override onlyOwner { revert RenounceDisabled(); }` - but this is in CoveredVaultAdmin, not in UniswapV3Adapter

Test output:
```
[PASS] test_H17_renounceOwnership_notBlocked() (gas: 24957)
Logs:
  === BEFORE ===
  Owner: 0x7364EC0c9AC408d0995605002d4d7423e3a8DBAA
  === ACTION: renounceOwnership ===
  === AFTER ===
  Owner after renounce: 0x0000000000000000000000000000000000000000
  BUG CONFIRMED: owner permanently cleared, setPairFee is bricked
```

### Evidence Audit
| Claim | Evidence Source | Tag | Valid for REFUTED? |
|-------|-----------------|-----|-------------------|
| renounceOwnership() succeeds on UniswapV3Adapter | Test execution | [POC-PASS] | YES |
| CoveredVaultAdmin overrides to revert | CoveredVaultAdmin.sol:128 | [CODE] | YES |
| UniswapV3Adapter has no override | UniswapV3Adapter.sol full source | [CODE] | YES |

### Verdict Reasoning
The test deploys `UniswapV3Adapter` and calls `renounceOwnership()` from the owner. The call succeeds, setting `owner()` to `address(0)`. After this, no one can call `setPairFee()` (onlyOwner), permanently bricking fee configuration. The sister contract `CoveredVaultWrapper` correctly overrides this via `CoveredVaultAdmin.renounceOwnership()` to revert with `RenounceDisabled()`, but `UniswapV3Adapter` lacks this protection.

---

## H-18: PREMIUM_COLLECTOR_ROLE Not Granted in PremiumManager.initialize()

**Final Verdict**: CONFIRMED
**Final Severity**: Low
**Evidence Tag**: [CODE-TRACE]

### Evidence

Code trace at `PremiumManager.sol` lines 54-74:
```solidity
function initialize(
    address admin_,
    address rewardsManager_,
    address platformTreasury_,
    uint16 platformFeeBps_
) external initializer {
    ...
    __AccessControl_init();
    __Pausable_init();
    _grantRole(DEFAULT_ADMIN_ROLE, admin_);  // only role granted
    // PREMIUM_COLLECTOR_ROLE never granted to any address here
    rewardsManager = rewardsManager_;
    platformTreasury = platformTreasury_;
    platformFeeBps = platformFeeBps_;
}
```

`distributePremium()` at line 147 requires `onlyRole(PREMIUM_COLLECTOR_ROLE)`. Therefore, freshly deployed `PremiumCollector` cannot call `distributePremium()` until a `DEFAULT_ADMIN_ROLE` holder manually calls `grantRole(PREMIUM_COLLECTOR_ROLE, premiumCollector)` in a separate transaction.

### Verdict Reasoning
The absence is unambiguous in source. This is a deployment configuration gap: any fresh deployment requires an additional post-deploy admin transaction to activate the premium distribution pipeline. Missing this step silently breaks all premium collection with no revert on the deployment transaction itself.

---

## H-21: Pre-Policy Phantom Premium When Checkpoint Predates startTime

**Final Verdict**: CONFIRMED
**Final Severity**: Low
**Evidence Tag**: [POC-PASS]

### Evidence

Bug mechanism:
- `_activeElapsedFrom(checkpoint)` at `CoveredVaultAccrual.sol:116-136`
- When `_isPolicyActive()` is true (line 117), returns `block.timestamp - checkpoint` with no lower-bound clamp to `startTime`
- If `lastPremiumAccrualTime` (the checkpoint) was set before `startTime`, the elapsed window includes pre-policy time

Test output:
```
[PASS] test_H21_phantomPremiumBeforeStartTime() (gas: 8018418)
Logs:
  Checkpoint after pre-start deposit: 7202
  Policy startTime: 86401
  Total premium liability: 1255707288000000
  Max expected if bug-free (2s of accrual): 31709780000
  Phantom pre-startTime window (s): 79199
  Expected liability if bugged (phantom included): 1255691433110000
```

The liability is 1,255,707,288,000,000 (>1e15) when it should be at most 31,709,780,000 (about 3e10). The phantom window of 79,199 seconds before startTime is included in the accrual, producing ~39,700x excess premium.

### Evidence Audit
| Claim | Evidence Source | Tag | Valid for REFUTED? |
|-------|-----------------|-----|-------------------|
| _activeElapsedFrom does not clamp to startTime in active branch | CoveredVaultAccrual.sol:117-118 | [CODE] | YES |
| totalPremiumLiability >> expected when pre-start deposit exists | forge test execution | [POC-PASS] | YES |

### Verdict Reasoning
A user who deposits before `startTime` (allowed since policy is bound but not yet started) creates a scenario where `lastPremiumAccrualTime < startTime`. When the policy activates, the first `_accruePremium()` call uses `block.timestamp - checkpoint` which spans the pre-policy gap. Fix: clamp `activeStart = max(checkpoint, startTime)` in the active branch.

---

## H-23: distributeBatch Reverts Entirely on Single Vault Failure

**Final Verdict**: CONFIRMED
**Final Severity**: Low
**Evidence Tag**: [CODE-TRACE]

### Evidence

Code trace at `PremiumCollector.sol:163-168`:
```solidity
function distributeBatch(address[] calldata vaults) external override nonReentrant whenNotPaused {
    uint256 length = vaults.length;
    for (uint256 i = 0; i < length; ++i) {
        _distribute(vaults[i]);   // no try/catch
    }
}
```

`_distribute()` at line 283 calls `IERC4626(vault).redeem(shares, ...)` with no error handling. If any vault's `redeem()` reverts (paused vault, reentrancy guard, owner-only restriction), the entire batch fails.

### Verdict Reasoning
The absence of try/catch in the distribution loop means a single misbehaving or temporarily unavailable vault can block premium distribution for ALL registered vaults in a batch. This creates a griefing vector and operational fragility for keeper automation.

---

## H-24: Oracle Revert in bindPolicy Blocks All Policy Binding

**Final Verdict**: CONFIRMED
**Final Severity**: Low
**Evidence Tag**: [CODE-TRACE]

### Evidence

Code trace at `PolicyManager.sol:264-274`:
```solidity
for (uint256 i = 0; i < tokens.length; ++i) {
    if (tokenStakes[i] > 0) {
        totalStakeUSD +=
            IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue(tokens[i], tokenStakes[i]); // no try/catch
    }
}
uint256 coverageLimitUSD =
    IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue(request.payoutToken, boundPolicy.coverageLimit); // no try/catch
```

If `getUSDValue()` reverts (Chainlink sequencer down, answer out-of-date, zero-price revert, L2 sequencer uptime check), `bindPolicy()` propagates the revert. All new policy binding is blocked globally until the oracle recovers. This is classified PARTIAL in the hypothesis because it requires oracle failure precondition.

### Verdict Reasoning
No try/catch around oracle calls in `bindPolicy`. This is a liveness dependency: Chainlink oracle availability gates the ability to bind new policies. During oracle outages (not uncommon on L2s), the entire policy onboarding pipeline is paused.

---

## H-26: Premium Rate Change Retroactive to All Existing Positions

**Final Verdict**: FALSE_POSITIVE
**Final Severity**: N/A
**Evidence Tag**: [POC-PASS]

### Evidence

Test output:
```
[PASS] test_H26_rateChange_correctlyCheckpoints() (gas: 8039165)
Logs:
  Old rate: 1585489
  Liability after 30d at old rate: 0
  Liability at rate change (settles old rate): 41210045942890000
  Checkpoint after rate change: 2606403
  Liability after 30d at new rate: 123401795702890000
  Expected increment at old rate: 41095874880000000
  Expected increment at new rate (2x): 82191749760000000
  Actual new-rate contribution: 82191749760000000
```

`executePremiumRate()` at `CoveredVaultAdmin.sol:34-45`:
1. Calls `_accruePremium()` first (settles all pending accrual at old rate)
2. Sets `lastPremiumAccrualTime = block.timestamp` (checkpoint sealed at execution time)
3. Then updates `premiumRatePerSecond = newRate`

The test confirms: the 30-day period after rate change accrues at exactly 2x the old rate (new rate), NOT retroactively at the new rate for the old period.

### Why It's Not a Bug
The `executePremiumRate()` function explicitly checkpoints before switching rates. The 2-hour operational delay (OPERATIONAL_DELAY) means users have advance notice. The `setPremiumRate()` is only a proposal; the actual change requires `executePremiumRate()` which includes the mandatory checkpoint. Retroactivity does not occur.

---

## H-27: depositCap Reopens After Withdrawals During Loss Event

**Final Verdict**: CONFIRMED
**Final Severity**: Low
**Evidence Tag**: [POC-PASS]

### Evidence

Test output:
```
[PASS] test_H27_depositCapReopensAfterWithdrawal() (gas: 8118045)
Logs:
  depositCap: 1000000000000000000000000
  totalPrincipal after fill: 1000000000000000000000000
  maxDeposit after fill: 0
  totalPrincipal after partial withdrawal: 500000000000000000000000
  maxDeposit after withdrawal (should be 0 during loss): 500000000000000000000000
```

`maxDeposit()` at `CoveredVaultWrapper.sol:467-469`:
```solidity
function maxDeposit(address) public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
    if (!policyBoundExecuted) return 0;
    return depositCap > totalPrincipal ? depositCap - totalPrincipal : 0;
}
```

No check for active loss events. When 50% Morpho loss occurs and depositors withdraw, `totalPrincipal` drops below `depositCap`, reopening the cap. New depositors can enter a pool with already-depleted coverage.

### Verdict Reasoning
The deposit cap mechanism is purely based on `totalPrincipal` relative to `depositCap`. During an active loss event (Morpho value < principal), the coverage is already being consumed. New depositors who enter during the loss event will find the coverage limit partially or fully exhausted, yet `maxDeposit` shows available capacity. This is particularly harmful if the coverage limit is consumed by the time they withdraw.

---

## H-28: Deposits Accepted After Policy Maturity Without Insurance

**Final Verdict**: CONFIRMED
**Final Severity**: Low
**Evidence Tag**: [POC-PASS]

### Evidence

Test output:
```
[PASS] test_H28_depositsAcceptedAfterMaturity() (gas: 8193610)
Logs:
  block.timestamp: 2678401 maturity: 2592001
  Policy active: false
  maxDeposit after maturity: 990000000000000000000000
  Late user deposited post-maturity with 1000004098187176780306588874 shares - no insurance
```

`maxDeposit()` at `CoveredVaultWrapper.sol:467-469` does not check `maturityTime`:
```solidity
function maxDeposit(address) public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
    if (!policyBoundExecuted) return 0;
    return depositCap > totalPrincipal ? depositCap - totalPrincipal : 0;
}
```

After policy maturity, `_isPolicyActive()` returns false so no insurance is available, yet the vault continues accepting deposits. Post-maturity depositors pay no premium (accrual is inactive) but also receive no insurance.

### Verdict Reasoning
Post-maturity deposits get silently uninsured positions. While no premium accrues (which is not harmful), the user interface/documentation might lead depositors to believe they are covered. The vault should return `maxDeposit() = 0` after `block.timestamp > maturityTime` to signal that the coverage period has ended.

---

## H-29: Fee-on-Transfer Collateral Tokens Cause Claim Revert

**Final Verdict**: CONFIRMED
**Final Severity**: Low
**Evidence Tag**: [CODE-TRACE]

### Evidence

Code trace at `ClaimManager.sol:587-620`:
```solidity
function _processCollateral(
    uint96 policyId, uint256 claimId,
    address collateralToken, uint256 collateralAmount,  // nominal slashed amount
    address payoutToken, address beneficiary, uint256 remainingPayout
) private returns (uint256 amountOut) {
    ...
    } else {
        amountOut = _executeCollateralSwap(
            collateralToken, collateralAmount,  // passes nominal amount
            payoutToken, beneficiary, remainingPayout
        );
    }
}
```

`_executeCollateralSwap()` at line 639:
```solidity
_approveIfERC20(collateralToken, swapper, collateralAmount);  // approves nominal amount
```

For fee-on-transfer tokens, `ClaimManager` receives `collateralAmount - fee` from the slashing transfer, but approves and attempts to spend `collateralAmount`. The Swapper's `transferFrom` will revert with `ERC20InsufficientBalance` since the ClaimManager holds less than approved.

This hypothesis is PARTIAL in the pipeline because it requires fee-on-transfer collateral tokens. The fix is a balance-diff pattern: measure balance before/after the slashing transfer and use the actual received amount.

### Verdict Reasoning
The trusted amount pattern in `_processCollateral` is incorrect for fee-on-transfer ERC-20s. While major staking tokens (ETH, WBTC, USDC) are not fee-on-transfer, the protocol's permissionless collateral token acceptance (determined by what validators stake) could include such tokens.

---

## H-31: evidenceHash Permanently Consumed Even on Rejected Claims

**Final Verdict**: CONFIRMED
**Final Severity**: Low
**Evidence Tag**: [POC-PASS]

### Evidence

Code trace at `ClaimManager.sol:283-324` (`_fileClaimWithMetadata`):
```solidity
// Line 293: Guard against duplicate BEFORE marking used
require(!_usedEvidenceHashes[policyId][evidenceHash], DuplicateEvidenceHash(policyId, evidenceHash));
...
// Line 311: Hash consumed HERE, before returning to fileClaim
_usedEvidenceHashes[policyId][evidenceHash] = true;
```

Then in `fileClaim()` at lines 213-225:
```solidity
(claimId, metadata) = _fileClaimWithMetadata(policyId, requestedAmount, evidenceHash);
// evidenceHash ALREADY consumed at this point

ISpec.EvaluationResult memory result = _evaluateSpec(policyId, metadata, evidenceHash, additionalData);

if (!result.isPayable) {
    claim.status = ClaimStatus.Rejected;
    emit ClaimRejected(policyId, claimId, "Spec evaluation failed", block.timestamp);
    return claimId;  // hash consumed but claim rejected - no re-submission possible
}
```

Test output:
```
[PASS] test_H31_demonstrateConsumeBeforeEval() (gas: 930627)
Logs:
  H-31 CONFIRMED: same evidence hash cannot be re-submitted after rejection

[PASS] test_H31_evidenceHashConsumedOnRejection() (gas: 267)
```

### Verdict Reasoning
The evidenceHash is consumed in `_fileClaimWithMetadata` before the spec evaluation in `fileClaim`. If the spec rejects the claim (e.g., oracle condition not met at claim time, parameter mismatch), the same evidence hash cannot be re-submitted. This forces claimants to use a new hash for each attempt, which may be impossible if the evidence is deterministic on-chain data (same block hash, same oracle reading). The fix is to move `_usedEvidenceHashes[policyId][evidenceHash] = true` to after `_evaluateSpec` returns `isPayable = true`.

---

## Summary

| H-ID | Title | Verdict | Severity | Evidence |
|------|-------|---------|----------|----------|
| H-17 | renounceOwnership Not Overridden in UniswapV3Adapter | CONFIRMED | Low | [POC-PASS] |
| H-18 | PREMIUM_COLLECTOR_ROLE Not Granted in initialize() | CONFIRMED | Low | [CODE-TRACE] |
| H-21 | Pre-Policy Phantom Premium When Checkpoint Predates startTime | CONFIRMED | Low | [POC-PASS] |
| H-23 | distributeBatch Reverts Entirely on Single Vault Failure | CONFIRMED | Low | [CODE-TRACE] |
| H-24 | Oracle Revert in bindPolicy Blocks All Policy Binding | CONFIRMED | Low | [CODE-TRACE] |
| H-26 | Premium Rate Change Retroactive to All Existing Positions | FALSE_POSITIVE | N/A | [POC-PASS] |
| H-27 | depositCap Reopens After Withdrawals During Loss Event | CONFIRMED | Low | [POC-PASS] |
| H-28 | Deposits Accepted After Policy Maturity Without Insurance | CONFIRMED | Low | [POC-PASS] |
| H-29 | Fee-on-Transfer Collateral Tokens Cause Claim Revert | CONFIRMED | Low | [CODE-TRACE] |
| H-31 | evidenceHash Permanently Consumed Even on Rejected Claims | CONFIRMED | Low | [POC-PASS] |
