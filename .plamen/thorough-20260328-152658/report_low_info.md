## Low Findings

### [L-01] renounceOwnership Not Overridden in UniswapV3Adapter [VERIFIED]

**Severity**: Low
**Location**: `UniswapV3Adapter:L45-60`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`UniswapV3Adapter` inherits OpenZeppelin's `Ownable2Step` but does not override `renounceOwnership()`. Calling `renounceOwnership()` from the owner account succeeds, setting `owner()` to `address(0)` permanently. After this point, no account can call `setPairFee()` (gated by `onlyOwner`), bricking fee-tier configuration for all swap routes. The sister contract `CoveredVaultAdmin` correctly overrides this function to revert with a `RenounceDisabled()` error, but that protection was not applied to the adapter. A test confirmed that `renounceOwnership()` completes successfully and the owner address is set to zero.

**Impact**:
Fee-tier configuration becomes permanently inaccessible. Any future need to update or correct Uniswap V3 pool fee tiers via `setPairFee()` is blocked until a new adapter is deployed and all route configurations are migrated.

**Recommendation**:
Override `renounceOwnership()` in `UniswapV3Adapter` to revert unconditionally, mirroring the pattern already used in `CoveredVaultAdmin`:
```solidity
function renounceOwnership() public override onlyOwner {
    revert RenounceDisabled();
}
```

---

### [L-02] PREMIUM_COLLECTOR_ROLE Not Granted in PremiumManager.initialize() [UNVERIFIED]

**Severity**: Low
**Location**: `PremiumManager:L60-85`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`PremiumManager.initialize()` grants only `DEFAULT_ADMIN_ROLE` to the admin address. It does not grant `PREMIUM_COLLECTOR_ROLE` to the `PremiumCollector` contract address, even though `distributePremium()` requires `onlyRole(PREMIUM_COLLECTOR_ROLE)` to execute. A freshly deployed `PremiumManager` therefore has a non-functional premium distribution pipeline until an admin separately calls `grantRole(PREMIUM_COLLECTOR_ROLE, premiumCollector)` in a distinct post-deployment transaction. If this step is missed, all `distributeBatch` calls on `PremiumCollector` will silently fail because `_distribute()` will revert when it calls `distributePremium()`.

**Impact**:
Premium distribution is silently non-functional after deployment until the role is manually granted. There is no revert on deployment itself; the failure surfaces only when `distributePremium` is first called, making it easy to miss in post-deployment validation. Accrued premium will not flow to restakers and platform treasury until the role is configured.

**Recommendation**:
Add `_grantRole(PREMIUM_COLLECTOR_ROLE, premiumCollector_)` to `PremiumManager.initialize()`, passing the `PremiumCollector` address as a constructor/initializer parameter. Alternatively, add a deployment invariant test that asserts `hasRole(PREMIUM_COLLECTOR_ROLE, premiumCollector)` after deployment.

---

### [L-03] Pre-Policy Phantom Premium When Checkpoint Predates startTime [VERIFIED]

**Severity**: Low
**Location**: `CoveredVaultAccrual:L120-140`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`_activeElapsedFrom(checkpoint)` computes elapsed active time as `block.timestamp - checkpoint` when the policy is active, without clamping `checkpoint` to `max(checkpoint, startTime)`. A user who deposits before `startTime` (which is permitted, since the policy is bound but not yet started) sets `lastPremiumAccrualTime` to a timestamp earlier than `startTime`. When the policy activates, the first `_accruePremium()` call spans the full window from the pre-start deposit through the current block, including the pre-policy gap. A test demonstrated that with a 79,199-second pre-start window, `totalPremiumLiability` grew to over 1e15 when it should have been at most ~3e10 — roughly a 39,700× overcharge.

**Impact**:
Users who deposit before policy start are charged premium for a period during which they had no insurance coverage. The overcharge is proportional to how early they deposited relative to `startTime`, which can be substantial for policies with advance-deposit windows.

**Recommendation**:
In `_activeElapsedFrom`, clamp the effective start to `max(checkpoint, startTime)` in the active branch:
```solidity
uint256 activeStart = checkpoint < startTime ? startTime : checkpoint;
uint256 activeElapsed = block.timestamp - activeStart;
```

---

### [L-04] distributeBatch Reverts Entirely on Single Vault Failure [UNVERIFIED]

**Severity**: Low
**Location**: `PremiumCollector:L200-230`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`PremiumCollector.distributeBatch()` iterates over a caller-supplied list of vault addresses and calls `_distribute(vaults[i])` for each, with no try/catch around the inner call. `_distribute()` itself calls `IERC4626(vault).redeem(...)` externally. If any vault in the batch reverts — due to a paused state, reentrancy guard triggered by prior execution, an owner-only restriction, or any transient failure — the entire batch transaction reverts. All other vaults in the batch fail to receive their premium distribution, even those that would have succeeded independently.

**Impact**:
A single misconfigured or temporarily unavailable vault acts as a permanent blocker for batch premium distribution across all vaults registered in the same call. Keeper automation that relies on batch distribution will fail silently for all vaults whenever any one vault is unhealthy. This creates griefing opportunities and operational fragility.

**Recommendation**:
Wrap the `_distribute(vaults[i])` call in a try/catch and emit an error event on failure rather than reverting the entire batch:
```solidity
try this._distribute(vaults[i]) {} catch (bytes memory reason) {
    emit DistributeFailed(vaults[i], reason);
}
```

---

### [L-05] Oracle Revert in bindPolicy Blocks All Policy Binding [UNVERIFIED]

**Severity**: Low
**Location**: `PolicyManager:L270-290`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`PolicyManager.bindPolicy()` calls `IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue()` twice — once to aggregate staked token values and once to convert the coverage limit — without any try/catch. If Chainlink reverts for any reason (sequencer downtime on L2, stale answer, price out-of-range, zero-price guard), `bindPolicy()` propagates the revert. This makes all new policy binding globally unavailable for the duration of the oracle outage. Oracle outages on L2 networks are not uncommon, particularly during periods of network congestion or sequencer downtime.

**Impact**:
New policy onboarding is completely blocked during Chainlink oracle unavailability. Existing policies are unaffected, but no new CoveredVaultWrapper can become operational until the oracle recovers. During prolonged outages, vault operators may be unable to onboard new coverage capacity.

**Recommendation**:
Wrap the Chainlink calls in try/catch blocks with an appropriate fallback strategy (e.g., use a cached price or revert with a more informative error that distinguishes oracle failure from invalid parameters):
```solidity
try IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue(token, amount) returns (uint256 val) {
    totalStakeUSD += val;
} catch {
    revert OracleUnavailable();
}
```

---

### [L-06] depositCap Reopens After Withdrawals During Loss Event [VERIFIED]

**Severity**: Low
**Location**: `CoveredVaultWrapper:L520-540`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`maxDeposit()` returns `depositCap - totalPrincipal` when a policy is bound, with no check for whether an active loss event is in progress. When a Morpho loss reduces vault assets below the coverage limit and existing depositors begin withdrawing, `totalPrincipal` falls below `depositCap`. This makes `maxDeposit()` return a non-zero value, allowing new depositors to enter the vault during an active loss event. A test confirmed that after a 50% Morpho loss where depositors have partially exited, `maxDeposit()` reports 500,000 units of available capacity while coverage is already being consumed.

**Impact**:
New depositors who enter during a loss event receive vault shares at a price that does not reflect the insurance coverage already being consumed. By the time they withdraw, the coverage limit may be exhausted by earlier claimants, leaving late entrants fully uninsured. This can mislead users who assume that entering a bound vault confers full coverage.

**Recommendation**:
Add a loss-event flag check to `maxDeposit()`. Return 0 when a loss event is active (i.e., when `morphoGateActive` is true or when `_morphoValue() < totalPrincipal`):
```solidity
if (!policyBoundExecuted || morphoGateActive) return 0;
```

---

### [L-07] Deposits Accepted After Policy Maturity Without Insurance [VERIFIED]

**Severity**: Low
**Location**: `CoveredVaultWrapper:L510-525`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`maxDeposit()` does not check `maturityTime`. After the policy expires (`block.timestamp > maturityTime`), `_isPolicyActive()` returns false and no insurance is provided, but the vault continues accepting deposits since `policyBoundExecuted` is still true and `totalPrincipal < depositCap`. A test confirmed that post-maturity deposits succeed: a user depositing after maturity receives vault shares with no premium accrual and no insurance coverage, which is not communicated by the ERC-4626 interface.

**Impact**:
Users who deposit after policy expiry receive uninsured exposure. The vault interface gives no indication that coverage has ended. Post-maturity depositors pay no premium (accrual is inactive), but they also receive no insurance against Morpho losses. Depending on UI presentation, this could mislead users into believing they are insured.

**Recommendation**:
Return 0 from `maxDeposit()` once the policy has matured:
```solidity
if (!policyBoundExecuted || block.timestamp >= maturityTime) return 0;
```
This signals to ERC-4626 integrators and frontends that the vault is no longer accepting deposits.

---

### [L-08] Fee-on-Transfer Collateral Tokens Cause Claim Revert [UNVERIFIED]

**Severity**: Low
**Location**: `ClaimManager:L620-650`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`ClaimManager._processCollateral()` passes the nominally slashed `collateralAmount` to `_executeCollateralSwap()`, which then approves and attempts to transfer exactly `collateralAmount` to the Swapper. For fee-on-transfer ERC-20 collateral tokens, the actual amount received by `ClaimManager` after the slashing transfer is `collateralAmount - fee`. When `_approveIfERC20()` approves the full nominal amount and the Swapper attempts `transferFrom(claimManager, ..., collateralAmount)`, the call reverts with `ERC20InsufficientBalance` because the ClaimManager holds less than the approved amount. The staking protocol permits validators to use various collateral tokens; if any token implements a transfer fee, affected claims will fail to execute.

**Impact**:
Any insurance claim involving a fee-on-transfer collateral token will revert at the swap stage, permanently blocking that claim's payout. The collateral has already been slashed from the vault at this point, so the loss is real but uncompensated. Claimants are denied their insurance payout and cannot retry with the same claim parameters.

**Recommendation**:
Use a balance-difference pattern in `_processCollateral` to determine the actual received amount:
```solidity
uint256 before = IERC20(collateralToken).balanceOf(address(this));
// ... slashing transfer occurs ...
uint256 actualReceived = IERC20(collateralToken).balanceOf(address(this)) - before;
```
Pass `actualReceived` instead of the nominal `collateralAmount` to `_executeCollateralSwap`.

---

### [L-09] amountOutMin Falls to 1 When QuoterV2 Reverts, Enabling Near-Total Sandwich [UNVERIFIED]

**Severity**: Low
**Location**: `Swapper:L280-310`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

> **Note**: This finding is capped at Low severity under proven-only mode. Evidence is code-level analysis only ([CODE-TRACE]); no end-to-end PoC execution was possible without live Uniswap infrastructure. Original suggested severity was High.

**Description**:
In `ClaimManager._executeCollateralSwap()`, `amountOutMin` is initialized to `1`. The code then attempts to obtain a quote via `ISwapper(swapper).quoteSwap()` inside a try/catch block. If `quoteSwap` reverts for any reason — including the fee-tier desync described in H-02 causing the wrong Uniswap pool to be queried — the empty `catch {}` block leaves `amountOutMin` at `1 wei`. The swap then proceeds with effectively no slippage protection. An MEV sandwich bot can profitably extract nearly the entire swap value, leaving the claimant with approximately 1 wei of payout instead of the expected amount.

**Impact**:
Near-total loss of claim payout to MEV whenever `quoteSwap` fails. The `quoteSwap` failure can be triggered by the fee-tier desync between `setPairFee` and stored route calldata (see H-02), or by any other condition that causes the Uniswap quoter to revert (gas exhaustion, pool state edge cases). In the worst case, a claimant who is owed a material insurance payout receives 1 wei.

**Recommendation**:
Replace the silent catch with a hard revert when no valid quote is obtained. Alternatively, implement a configurable minimum floor based on expected payout:
```solidity
} catch {
    revert QuoteUnavailable(collateralToken, payoutToken);
}
```

---

### [L-10] Curator Can Permanently Block Claims via setPremiumDefaulted [UNVERIFIED]

**Severity**: Low
**Location**: `CoverPool:L285-300`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

> **Note**: This finding is capped at Low severity under proven-only mode. Evidence for the full blocking mechanism is code-level analysis of the real `ClaimManager` ([CODE-TRACE]); the full claim flow was not executed in a live test environment. Original suggested severity was Medium.

**Description**:
A CoverPool curator (holding `DEFAULT_ADMIN_ROLE` on the pool) can call `setPremiumDefaulted(policyId, true)`, which writes `metadata.premiumDefaulted = true` to `PolicyManager`. When `CoveredVaultWrapper._claimInsurance()` subsequently calls `ClaimManager.fileClaim()`, the claim manager checks `require(!metadata.premiumDefaulted, PremiumDefaulted(policyId))` and reverts. The wrapper's `try/catch` silently absorbs the revert and returns 0 insurance payout. Depositors can still withdraw but receive no insurance coverage. There is no timelock on `setPremiumDefaulted`, no admin override, and no mechanism for depositors to challenge or reverse the decision.

**Impact**:
The curator can permanently deny all insurance claims for a policy, reducing the depositors' insurance to zero without any recourse mechanism. The curator's economic incentive to protect their staking position directly conflicts with depositors' right to receive insurance payout. When combined with retroactive fee extraction, the curator can simultaneously deny claims and extract maximum fees (see M-16).

**Recommendation**:
Add a timelock (minimum 48 hours) to `setPremiumDefaulted`, require a governance-level override path for depositors, or restrict `premiumDefaulted` to be set only after an explicit dispute-resolution process with neutral arbitration.

---

### [L-11] Claim Approval Gate Serializes Concurrent Claimants (First-Claimer Race) [UNVERIFIED]

**Severity**: Low
**Location**: `ClaimManager:L290-320`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

> **Note**: This finding is capped at Low severity under proven-only mode. The storage layout and code logic are confirmed, but the full multi-user serialization scenario was not executed end-to-end. Original suggested severity was Medium.

**Description**:
`ClaimManager._claimApprovalRequired` is a `mapping(uint96 policyId => bool)` — a single global flag per policy, not per user. After any successful claim is paid out on a policy (line 235), `_claimApprovalRequired[policyId]` is set to `true`, blocking all subsequent `fileClaim` calls for that policy with `ClaimApprovalRequired(policyId)`. The curator must then call `approveNextClaim(policyId)` to reset the flag before the next claimant can proceed. In a CoveredVaultWrapper with many depositors sharing a single policy, this creates a strict serialization: only one user can claim at a time, and each subsequent claimant must wait for the curator to manually gate their claim.

**Impact**:
During a large-scale Morpho loss event affecting all depositors, every claimant after the first must wait for curator approval. Curators can deliberately delay approvals, keeping depositors' funds illiquid. The race to be the first claimant creates an unfair advantage for technically sophisticated users and imposes material friction on the insurance claim process.

**Recommendation**:
Replace the global policy-level boolean with per-user claim tracking, or implement batch approval that covers all pending claims for a policy at once. If sequential approval is a design requirement, implement a maximum approval delay constraint.

---

### [L-12] Stale lastKnownMorphoValue During Morpho Downtime Inflates Premium Cap [UNVERIFIED]

**Severity**: Low
**Location**: `CoveredVaultWrapper:L140-160`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

> **Note**: This finding is capped at Low severity under proven-only mode. Evidence is code-level analysis; no live Morpho downtime scenario was executed. Original suggested severity was Medium.

**Description**:
When `IVaultV2(morphoVault).convertToAssets()` reverts, `_morphoValue()` falls back to `lastKnownMorphoValue` — the most recently cached Morpho vault value. This cached value is updated only when `convertToAssets` succeeds. If Morpho enters a maintenance window or experiences a revert-inducing condition after a period of losses (so the actual value is lower than the cached value), `_accruePremium()` uses the inflated cached value as the basis for premium calculation. Premium accrual is capped at `min(morphoValue, totalPrincipal)`, so an inflated Morpho value raises this cap, potentially over-collecting premium from users relative to their actual asset value.

**Impact**:
Users are charged premium based on a higher-than-actual Morpho value during downtime. The over-collection is proportional to the gap between `lastKnownMorphoValue` and the true current value. The risk is compounded if the vault owner does not promptly activate the morpho gate during downtime.

**Recommendation**:
When `convertToAssets` reverts, automatically activate the morpho gate (or use a zero fallback) rather than relying on the stale cache. Add an off-chain monitoring alert for Morpho revert conditions to trigger prompt gate activation.

---

### [L-13] userPremiumDebt Zeroed by Floor Rounding After Partial Withdrawal [UNVERIFIED]

**Severity**: Low
**Location**: `CoveredVaultWrapper:L400-420`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

> **Note**: This finding is capped at Low severity under proven-only mode. The rounding mechanism is confirmed by code analysis; the over-charge scenario was not executed end-to-end with live premium accrual. Original suggested severity was Medium.

**Description**:
When a user makes a small partial withdrawal, the per-user premium debt calculation uses integer floor division. If the withdrawal proportion is small enough that the calculated premium rounds to zero, `userPremiumDebt[user]` is set to the rounded value (zero), effectively wiping the user's accumulated premium debt. On the next withdrawal, premium is recalculated from the full accumulated `cumulativePremiumPerUnit` delta without any offset for the premium that was supposedly collected in the prior withdrawal. This results in the user being charged again for the premium period that was consumed but rounded to zero.

**Impact**:
Users making small partial withdrawals may find their subsequent withdrawals carry higher-than-expected premium charges equal to the amount that was previously rounded away. The overcharge is bounded by the precision lost in the rounding operation, which can be non-trivial at low premium rates or when `totalPrincipal` is large.

**Recommendation**:
Use ceiling (round-up) division for the premium debt calculation to ensure that any non-zero premium obligation is charged rather than rounded to zero:
```solidity
userPremiumDebt[user] = owedPremium.mulDiv(shares, userBalance, Math.Rounding.Ceil);
```

---

### [L-14] evidenceHash Permanently Consumed Even on Rejected Claims [VERIFIED]

**Severity**: Low
**Location**: `ClaimManager:L360-390`
**Confidence**: HIGH (PoC: PASS)

**Description**:
In `fileClaim()`, the call chain is: `_fileClaimWithMetadata()` marks `_usedEvidenceHashes[policyId][evidenceHash] = true` (line 311), then returns to `fileClaim()` which calls `_evaluateSpec()`. If the spec returns `isPayable = false`, the claim is rejected and the function returns — but the evidence hash is already permanently consumed. A subsequent attempt to re-file the same claim with the same evidence hash will revert with `DuplicateEvidenceHash`. This is particularly problematic when the evidence hash is derived from deterministic on-chain data (e.g., block hash, oracle reading) that cannot be varied, or when the same loss event requires re-submission after a temporary oracle condition clears.

**Impact**:
Claimants whose claims are rejected due to transient conditions (spec evaluation conditions temporarily unmet) cannot re-submit using the same evidence. They must construct a distinct evidence hash for each attempt, which may not be possible when the evidence is on-chain data. This effectively limits each claimant to one attempt per evidence hash, even for legitimate claims that were rejected due to timing.

**Recommendation**:
Move the `_usedEvidenceHashes[policyId][evidenceHash] = true` assignment to after `_evaluateSpec` returns with `isPayable = true`. The hash should be consumed only on successful claim acceptance, not on every submission attempt.

---

### [L-15] setNativeWrapper Does Not Disable Old WETH-Keyed Routes [UNVERIFIED]

**Severity**: Low
**Location**: `Swapper:L330-360`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
Swap routes in `Swapper` are stored in `_swapRoutes` keyed by `keccak256(abi.encodePacked(tokenIn, tokenOut))`, where `tokenIn`/`tokenOut` are always concrete ERC-20 addresses (not the `NATIVE_ETH` sentinel). When `setNativeWrapper` updates the `nativeWrapper` address from `WETH_OLD` to `WETH_NEW`, all previously configured routes that were keyed against `WETH_OLD` remain active and enabled in storage. Calls that resolve `NATIVE_ETH` to `WETH_NEW` will use a different route key and miss the old routes — but routes explicitly parameterized with `tokenIn = WETH_OLD` or `tokenOut = WETH_OLD` remain reachable by their concrete address and are never automatically invalidated.

**Impact**:
After a native wrapper migration, stale routes keyed by the old WETH address remain silently active. An operator with `SWAP_MANAGER_ROLE` must remember to manually disable each old route. Missing this cleanup step leaves unexpected route entries that may route through an outdated or deprecated WETH contract.

**Recommendation**:
Document the manual cleanup requirement prominently in `setNativeWrapper`'s NatSpec. Alternatively, emit an event listing the old wrapper address so that off-chain monitoring can detect stale routes. Consider adding an optional route invalidation parameter to `setNativeWrapper`.

---

### [L-16] approveNextClaim Emits Misleading Event on Non-Gated Policy [UNVERIFIED]

**Severity**: Low
**Location**: `ClaimManager:L400-420`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`approveNextClaim(policyId)` unconditionally sets `_claimApprovalRequired[policyId] = false` and emits `NextClaimApproved(policyId, msg.sender)` without first checking whether `_claimApprovalRequired[policyId]` was actually `true`. If the function is called on a policy that has no pending approval gate (the default is `false`), the write is a no-op but the event is still emitted. Off-chain systems and monitoring tools that parse `NextClaimApproved` events to track policy gating state will see a misleading event — indicating that an approval was granted when no gate was active.

**Impact**:
No on-chain fund loss. Off-chain indexers, audit trails, and monitoring dashboards may show spurious "claim approved" entries for policies that were never gated, complicating forensic analysis after claim disputes and introducing noise into event-driven automation.

**Recommendation**:
Add a guard to `approveNextClaim` that checks the current state before proceeding:
```solidity
require(_claimApprovalRequired[policyId], NoApprovalPending(policyId));
```

---

### [L-17] cumulativePremiumPerUnit Precision Loss With Small totalPrincipal [UNVERIFIED]

**Severity**: Low
**Location**: `CoveredVaultAccrual:L110-130`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
Premium accrual uses a two-step computation: first `accrued = totalPrincipal * premiumRatePerSecond * elapsed / WAD`, then `cumulativePremiumPerUnit += accrued * WAD / totalPrincipal`. When `totalPrincipal * premiumRatePerSecond * elapsed < WAD` (i.e., `1e18`), the first division truncates to zero and `_accruePremium` returns early with no accrual for that call. At maximum premium rate (`MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991`) with USDC-denominated principal below ~100 USDC (1e8 units), even a full second of elapsed time produces `accrued = 0`. These missed accrual windows accumulate silently.

**Impact**:
Users with very small deposits (below roughly 100 USDC at max premium rate) may accrue no premium per second, effectively receiving free insurance for small positions. The precision loss is bounded by one WAD unit per accrual call but accumulates across the policy lifetime for small depositors. At realistic TVLs this is negligible; it becomes material only at dust-level deposits.

**Recommendation**:
Consider using a higher-precision accumulator (e.g., 1e27 scaling) for `cumulativePremiumPerUnit`, or document the minimum viable deposit size below which precision guarantees do not hold.

---

### [L-18] updateVault Missing nonReentrant Guard [UNVERIFIED]

**Severity**: Low
**Location**: `PremiumCollector:L160-180`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`PremiumCollector.updateVault()` is gated by `onlyRole(DEFAULT_ADMIN_ROLE)` but has no `nonReentrant` modifier. `distributeBatch()` is guarded by `nonReentrant` and internally calls `_distribute()`, which makes two external calls: `IERC4626(vault).redeem()` and `IPremiumManager.distributePremium()`. If a malicious or compromised vault's callback re-enters `updateVault()` during the `vault.redeem()` call, it can mutate `_vaultConfigs[vault].pool` and `_vaultConfigs[vault].policyId` while `_distribute()` is mid-execution. The `config` reference in `_distribute` reads `pool` and `policyId` from storage after the redeem — if those values have been changed by the reentrant `updateVault`, premium will be distributed to the wrong pool or policy.

**Impact**:
A compromised vault or malicious vault admin with `DEFAULT_ADMIN_ROLE` could route premium distributions to an incorrect pool or policy by reentering `updateVault` during distribution. The impact is limited to misdirected premium distribution rather than fund loss, but can corrupt the premium accounting for affected vaults.

**Recommendation**:
Add `nonReentrant` to `updateVault` to prevent mid-distribution config mutations:
```solidity
function updateVault(address vault, address pool, uint96 policyId) external override nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
```

---

### [L-19] PremiumCollector Caches Vault Underlying at Registration [UNVERIFIED]

**Severity**: Low
**Location**: `PremiumCollector:L90-110`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`PremiumCollector.registerVault()` calls `IERC4626(vault).asset()` once and stores the result in `VaultConfig.underlying`. All subsequent `_distribute()` calls use this cached `config.underlying` for both the token transfer and the `distributePremium` call. The ERC-4626 standard treats `asset()` as immutable, so this pattern is correct for standard-compliant vaults. However, if a non-standard vault upgrades its underlying token — for example, via a proxy implementation change — the cached value becomes stale. `_distribute()` would attempt to transfer the old token and call `distributePremium` with the old token address, which could either fail silently (if old token balance is zero) or distribute incorrect token to the premium manager.

**Impact**:
Non-standard vaults that change their `asset()` return value after registration will cause premium distributions to use the wrong token. The likelihood is low given ERC-4626's immutability convention, but the impact is a misdirected premium distribution that may go undetected until balances are audited.

**Recommendation**:
Re-read `vault.asset()` at distribution time rather than using the cached value, or add a validation check that `IERC4626(vault).asset() == config.underlying` at the start of `_distribute`. The gas cost of one additional external call is minimal given the infrequency of distributions.

---

### [L-20] executeUpgrade Clears Pending State After upgradeToAndCall [UNVERIFIED]

**Severity**: Low
**Location**: `CoveredVaultAdmin:L190-210`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`CoveredVaultAdmin.executeUpgrade()` calls `upgradeToAndCall(impl, "")` before clearing `pendingUpgradeTimestamp` and `pendingImplementation`. The ordering is intentional — `_authorizeUpgrade()` reads `pendingImplementation` to validate the target, so it must be non-zero during the call. However, if `upgradeToAndCall` reverts (e.g., the new implementation's initializer reverts), the pending state is not cleared. The owner can retry without re-proposing since the timelock is already satisfied — this is arguably the intended behavior. The cleaner pattern would use a local variable for the implementation address and clear storage before the external call to prevent stale state on partial failures.

**Impact**:
A failed upgrade leaves `pendingUpgradeTimestamp` and `pendingImplementation` in an active state. While the owner can simply retry `executeUpgrade`, the stale pending state is observable and could confuse monitoring systems that track pending upgrade proposals. No fund loss; the recovery path (retry or re-propose) is straightforward.

**Recommendation**:
Use a local variable to capture the pending implementation address, clear the pending state before calling `upgradeToAndCall`, and pass the address as an argument to `_authorizeUpgrade` rather than reading from storage:
```solidity
address impl = pendingImplementation;
pendingUpgradeTimestamp = 0;
pendingImplementation = address(0);
upgradeToAndCall(impl, "");
```
This requires adjusting `_authorizeUpgrade` to accept the implementation as a parameter rather than re-reading storage.

---

### [L-21] rescueTokens Uses totalPrincipal>0 as Proxy for Tracked Shares [UNVERIFIED]

**Severity**: Low
**Location**: `CoveredVaultWrapper:L635-650`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`CoveredVaultAdmin.rescueTokens()` handles the Morpho vault token specially: when `totalPrincipal > 0`, it treats the entire Morpho share balance as tracked (i.e., user-owned) and blocks sweeping any shares. The actual tracked share obligation is the sum of `userMorphoShares[user]` across all depositors, which may be less than the full Morpho balance if surplus shares exist (e.g., from rounding residuals or direct share donations). The `totalPrincipal > 0` proxy is overly conservative — it prevents the admin from recovering any legitimately surplus shares while users are deposited, even when the surplus is clearly not user-owned.

**Impact**:
The admin cannot rescue accidentally-donated Morpho shares or rounding residuals while any user has a deposit. No user funds are at risk (the guard is conservative in the safe direction), but surplus value is permanently locked in the vault until all users exit.

**Recommendation**:
Track the exact number of Morpho shares attributed to users in a separate `totalMorphoShares` accumulator (incremented on deposit, decremented on withdrawal). Use this as the guard in `rescueTokens` instead of the `totalPrincipal > 0` proxy:
```solidity
uint256 trackedShares = totalMorphoShares; // exact tracked amount
require(amount <= balance - trackedShares, InvalidParameters());
```

---

### [L-22] Stale Evidence Hash From block.timestamp Causes Same-Block Claim Denial [UNVERIFIED]

**Severity**: Low
**Location**: `ClaimManager:L360-390`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`CoveredVaultWrapper._claimInsurance()` constructs an evidence hash as `keccak256(abi.encodePacked(user, policyId, cappedClaim, block.timestamp))`. If two claims are filed in the same block for the same user, policy, and capped amount — which can occur during a bundled multi-operation transaction or when a user retries within the same block — the hash is identical. The second claim attempt will revert with `DuplicateEvidenceHash` because the first call already consumed the hash. Combined with the finding that evidence hashes are consumed even on rejected claims (see L-14), a claim rejected in the same block cannot be retried until the next block.

**Impact**:
Same-block retry attempts for identical claim parameters are blocked. While same-block duplicates are rare in normal operation, they can occur in batched transaction scenarios or if a wrapper makes multiple claim attempts within one transaction. The result is a stuck claim that requires waiting for the next block.

**Recommendation**:
Include a per-call nonce or the calling contract address in the evidence hash to ensure uniqueness across same-block attempts:
```solidity
bytes32 evidenceHash = keccak256(abi.encodePacked(user, policyId, cappedClaim, block.timestamp, claimNonce++));
```

---

### [L-23] bindPolicy Hook Single-Use Guard Permanently Blocks Re-Binding [UNVERIFIED]

**Severity**: Low
**Location**: `CoveredVaultWrapper:L595-610`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`CoveredVaultWrapper.onPolicyBound()` sets `policyBoundExecuted = true` on first successful invocation and reverts with `PolicyBoundAlreadyExecuted()` on any subsequent call. The flag is never reset anywhere in the codebase. While the single-policy-per-vault architecture makes this the intended behavior, it means that if infrastructure is rotated after binding (such as a `specRegistry` or `stakeManager` replacement as described in M-13), the vault cannot bind a new policy under the updated infrastructure. An expired-policy vault that has served its term is also permanently unable to bind a new policy for a continuation term.

**Impact**:
Vaults are permanently limited to a single policy binding. After the policy expires, the vault can no longer serve as an active insurance vehicle without deploying a new vault contract. In infrastructure rotation scenarios, existing vaults may become permanently orphaned with no path to bind under the new infrastructure.

**Recommendation**:
Add a privileged reset mechanism (e.g., `resetPolicyBinding()` callable by the vault owner) that clears `policyBoundExecuted`, `policyId`, `coverageLimit`, and related state to allow re-binding. Alternatively, document the single-use design constraint prominently so operators plan vault lifecycles accordingly.

---

### [L-24] block.timestamp as Swap Deadline (No MEV Time Protection) [UNVERIFIED]

**Severity**: Low
**Location**: `Swapper:L250-280`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`ClaimManager._executeCollateralSwap()` sets `deadline = block.timestamp` in the `SwapParams` struct passed to `Swapper.executeSwap()`. The Swapper validates `block.timestamp <= params.deadline`, which trivially passes since both values are the same block's timestamp. The deadline check therefore provides no temporal constraint: a validator can include the transaction at any point during the block's validity window without the deadline adding any additional protection. The intended MEV mitigation effect of a deadline — preventing a stale transaction from executing in a future block after conditions have changed — is absent.

**Impact**:
The swap deadline provides no actual protection against delayed or griefed execution. A transaction that was submitted with the intent to execute immediately can be held and included in a later block without the deadline causing a revert. This is a standard pattern in Solidity and has limited practical impact in most contexts; the more significant slippage risk is addressed separately (see L-09).

**Recommendation**:
Use a configurable deadline offset to allow swaps to survive brief congestion while providing meaningful time-based protection:
```solidity
deadline: block.timestamp + deadlineBuffer  // e.g., deadlineBuffer = 300 seconds
```
The `deadlineBuffer` should be a governance-configurable parameter.

---

### [L-25] Unsolicited Morpho Share Donation (No Attacker Profit) [UNVERIFIED]

**Severity**: Low
**Location**: `CoveredVaultWrapper:L475-490`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`CoveredVaultWrapper.totalAssets()` computes Morpho value as `IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this)))`. Any party can directly transfer Morpho vault shares to the wrapper address, increasing `balanceOf(address(this))` without going through the deposit flow. This inflates `totalAssets()`, which inflates the share price for all existing depositors — the donation is a gift to depositors at the attacker's expense. No attacker profit is possible; the donated value is permanently absorbed by existing depositors. However, `rescueTokens` is blocked from recovering donated Morpho shares while `totalPrincipal > 0` (see L-21), so the donated shares cannot be swept by the admin.

**Impact**:
No direct harm to the protocol or users. The donation benefits existing depositors and costs the attacker. The donated shares are irrecoverable by the admin while users are deposited, making this a one-way economic gift to the vault. Informational in nature but reported at Low given the interaction with the `rescueTokens` limitation.

**Recommendation**:
No fix required for the donation mechanism itself. For completeness, document in the contract NatSpec that externally donated Morpho shares are permanently absorbed into the vault's NAV and cannot be separated.

---

### [L-26] SpecRegistry whenNotPaused Cross-Contract Pause Dependency [UNVERIFIED]

**Severity**: Low
**Location**: `SpecRegistry:L70-85`, `ClaimManager:L565-580`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`SpecRegistry.registerSpec()` is gated by `whenNotPaused`, meaning that pausing the SpecRegistry (for example, to block registration of a malicious spec) also prevents all CoverPools from registering new specs. All CoverPools share the same singleton `SpecRegistry`. Since `resolveSpec()` is not gated by pause, existing policies continue to resolve their specs during a pause — but no new spec registrations are possible across the entire protocol. A localized incident affecting one pool (e.g., a malicious spec attempt) that triggers a registry pause creates protocol-wide friction for all other pools.

**Impact**:
Pausing the SpecRegistry to address a localized security incident prevents all new policy binding that requires spec registration across all CoverPools. Existing policies and their claims are unaffected. The impact is operational friction rather than fund loss.

**Recommendation**:
Consider per-pool pause granularity for `registerSpec`, or separate the emergency pause (blocking registration globally) from a per-pool suspension mechanism. At minimum, document the cross-pool pause dependency so operators understand the blast radius of a registry pause.

---

### [L-27] Factory Uses Instant Admin Transfer While CoverPools Use 24h Delay [UNVERIFIED]

**Severity**: Low
**Location**: `CoverPoolFactory:L140-160`, `CoverPool:L50-70`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`CoverPool` is initialized with `AccessControlDefaultAdminRulesUpgradeable` configured for a 24-hour admin transfer delay (`__AccessControlDefaultAdminRules_init(24 hours, curator_)`). This means compromising the CoverPool admin requires at least a 24-hour window before a malicious transfer completes, providing time for detection and response. `CoverPoolFactory`, by contrast, uses `AccessControlUpgradeable` with no delay — admin transfers complete instantly. Since the factory controls which implementations are used for new pool deployments and which infrastructure addresses (specRegistry, stakeManager) are referenced, a compromised factory admin can instantly redirect all future pool deployments to malicious implementations.

**Impact**:
A compromised `CoverPoolFactory` admin can atomically transfer ownership and deploy malicious pool implementations in a single block, with no grace period for detection. The asymmetry between pool-level protection (24h delay) and factory-level protection (instant) means the higher-impact operation has weaker protection.

**Recommendation**:
Apply `AccessControlDefaultAdminRulesUpgradeable` with at least a 24-hour delay to `CoverPoolFactory`, consistent with the protection applied to individual CoverPools.

---

### [L-28] coverageLimit Cached Locally vs Live Read in ClaimManager [UNVERIFIED]

**Severity**: Low
**Location**: `ClaimManager:L180-210`, `CoverPool:L225-245`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`CoveredVaultWrapper` stores `coverageLimit` as a local state variable set at `onPolicyBound` time and never subsequently updated. `ClaimManager.remainingCoverage()` reads `coverageLimit` directly from `PolicyManager.PolicyMetadata`, which is the authoritative source written at `bindPolicy` time. In the current codebase, both sources are identical since `PolicyMetadata.coverageLimit` is immutable after binding. However, the local cache creates a forward-compatibility risk: if a future protocol upgrade allows `coverageLimit` to be modified after binding (e.g., as part of a coverage limit increase feature), the wrapper's local copy would silently diverge from the authoritative value, causing the wrapper to use a stale limit when computing insurance claim amounts.

**Impact**:
No impact in the current implementation — both values are always equal. The risk is forward-looking: future upgrades that allow `coverageLimit` mutation after binding would create silent divergence between the wrapper's local copy and the authoritative `PolicyManager` value, causing incorrect claim caps without any revert or warning.

**Recommendation**:
Remove the local `coverageLimit` storage variable and read directly from `ClaimManager.remainingCoverage()` at claim time, which already provides the authoritative remaining coverage after accounting for prior payouts. This also eliminates the gas-optimization rationale for the local copy.

---

### [L-29] _MAX_FEE_BPS Guard Semantically Misleading [UNVERIFIED]

**Severity**: Low
**Location**: `CoverPool:L30-45`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`PremiumManager.distributePremium()` checks `require(totalFeeBps <= _MAX_FEE_BPS)` where `_MAX_FEE_BPS = 10_000` (100%). The guard implies a meaningful combined fee cap. However, `platformFeeBps` is independently capped at `_MAX_PLATFORM_FEE_BPS = 2500` (25%) by its setter, and `poolFeeBps` is independently capped at `_MAX_POOL_FEE_BPS = 2000` (20%) by CoverPool's setter. The maximum achievable combined fee is therefore 4,500 bps (45%), making the 10,000 bps guard permanently unreachable. The `ExcessiveCombinedFees` error can never be triggered through normal protocol operation, and the guard provides no additional protection beyond the individual caps.

**Impact**:
No direct security impact. The dead-code guard creates a false sense of combined fee protection and may mislead auditors or integrators into believing the combined cap is meaningful. Any tooling that checks for the `ExcessiveCombinedFees` event will never observe it.

**Recommendation**:
Either set `_MAX_FEE_BPS` to the actual maximum achievable value (`_MAX_PLATFORM_FEE_BPS + _MAX_POOL_FEE_BPS = 4500`) to make the guard meaningful, or remove the combined check entirely and rely solely on the individual caps enforced by each setter.

---

## Informational Findings

### [I-01] PolicyManager._validateRequest Missing startTime Check (Defence-in-Depth)

**Severity**: Informational
**Location**: `PolicyManager:L200-220`

**Description**:
`PolicyManager._validateRequest()` checks that `startTime < maturityTime` and `maturityTime > block.timestamp`, but does not verify `startTime >= block.timestamp`. A caller can supply a `startTime` in the past and pass validation. The validated `startTime` is stored verbatim in `PolicyMetadata.startTime` and is used by `_activeElapsedFrom` in `CoveredVaultAccrual` when computing pre-policy phantom premium windows. A stale `startTime` accepted here compounds the precision issue described in L-03. While the primary guard against stale startTime is expected to be enforced upstream (quote validation logic), the absence of a floor check in `_validateRequest` is a defence-in-depth gap.

**Recommendation**:
Add `require(request.quote.startTime >= block.timestamp, InvalidStartTime())` to `_validateRequest` as an additional layer of defence.

---

### [I-02] PremiumCollector Missing recoverTokens Function

**Severity**: Informational
**Location**: `PremiumCollector:L290-297`

**Description**:
`ClaimManager` and `Swapper` both implement a `recoverTokens(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE)` function for recovering accidentally-sent tokens. `PremiumCollector` is the only UUPS proxy contract in the protocol that lacks this function and does not include it in `IPremiumCollector`. Tokens inadvertently transferred to `PremiumCollector` — for example, by a misconfigured vault or keeper automation — cannot be recovered by the admin.

**Recommendation**:
Add a `recoverTokens` function to `PremiumCollector` and its interface, consistent with sibling contracts. Ensure it includes appropriate guards to prevent recovering tokens that are legitimately managed by the contract (e.g., any ERC-4626 vault shares currently tracked in `_vaultConfigs`).

---

### [I-03] _withdraw Decrements totalPrincipal After External Interactions

**Severity**: Informational
**Location**: `CoveredVaultWrapper:L625-640`

**Description**:
`CoveredVaultWrapper._withdraw()` decrements `totalPrincipal` at line 189 after `_executeWithdrawal()` has already made two external calls: `IVaultV2(morphoVault).redeem()` and `ClaimManager.fileClaim()`. This is a Checks-Effects-Interactions pattern violation. The `nonReentrant` modifier on `_withdraw` prevents exploitation, making this informational in practice. Note that `userPrincipal[owner]` is correctly decremented inside `_updateDebtsAfterWithdrawal` (called within `_executeWithdrawal`), so partial CEI compliance exists; only the aggregate `totalPrincipal` counter follows the incorrect ordering.

**Recommendation**:
Move `totalPrincipal -= userPrincipalForWithdrawal` to before the `_executeWithdrawal` call to fully comply with the CEI pattern, eliminating any theoretical reentrancy surface even if the `nonReentrant` guard were removed in a future refactor.

---

### [I-04] acceptOwnership Clears Timestamps But Not Pending Values

**Severity**: Informational
**Location**: `CoveredVaultAdmin:L220-230`

**Description**:
`CoveredVaultAdmin.acceptOwnership()` correctly zeros all six `*Timestamp` fields and `pendingImplementation`, but does not clear the corresponding pending value fields: `pendingPremiumRate`, `pendingMaxCoverableLossBps`, `pendingDeductibleBps`, and `pendingPremiumRecipient`. After an ownership transfer, the new owner inherits stale pending values with zeroed timestamps. While `_requireTimelockReady(0)` will revert with `NoPendingChange()` (preventing accidental execution of the stale values), the inconsistent state — non-zero values with zero timestamps — is a code quality concern that could confuse tooling or operators inspecting contract state.

**Recommendation**:
Clear all pending value fields in `acceptOwnership()` alongside the timestamp fields:
```solidity
pendingPremiumRate = 0;
pendingMaxCoverableLossBps = 0;
pendingDeductibleBps = 0;
pendingPremiumRecipient = address(0);
```

---

### [I-05] Swapper Stored Route Calldata May Become Stale

**Severity**: Informational
**Location**: `Swapper:L150-175`

**Description**:
`Swapper.setSwapRoute()` stores arbitrary `bytes calldata swapCalldata` into `_swapRoutes[routeKey].swapCalldata` with no expiry timestamp, version nonce, or staleness detection mechanism. When `executeSwap` falls back to stored calldata (`params.swapCalldata.length == 0`), it uses whatever was stored at configuration time. If the DEX route configuration changes after storage — for example, due to a Uniswap pool fee-tier migration, a liquidity pool deprecation, or a path restructuring — the stored calldata silently becomes stale. A `SWAP_MANAGER_ROLE` holder must proactively update routes when underlying DEX configurations change; there is no automatic detection of divergence.

**Recommendation**:
Document the route staleness risk prominently in `setSwapRoute`'s NatSpec. Consider adding a `routeExpiry` timestamp field to the `RouteConfig` struct that can be checked at execution time, forcing manual renewal of routes that have not been refreshed recently.

---

### [I-06] PremiumManager approveSpender Allows Arbitrary ERC-20 Approvals

**Severity**: Informational
**Location**: `PremiumManager:L185-200`

> **Note**: Impact is conditional on the `DEFAULT_ADMIN_ROLE` holder acting maliciously. The `DEFAULT_ADMIN_ROLE` is classified as fully trusted in the protocol's stated trust assumption model.

**Description**:
`PremiumManager.approveSpender(address token, address spender, uint256 amount)` allows the `DEFAULT_ADMIN_ROLE` holder to grant any ERC-20 approval of any amount to any spender address. This capability is intentional — it is used to pre-authorize the SSPRouter to pull restaker shares — but its breadth is notable. A compromised or malicious `DEFAULT_ADMIN_ROLE` holder could use this function to approve an attacker-controlled address to drain any ERC-20 token held by `PremiumManager`.

**Recommendation**:
No code change required given the fully-trusted classification of `DEFAULT_ADMIN_ROLE`. For documentation purposes, enumerate the specific approvals that are expected (e.g., SSPRouter approval) and consider adding an allowlist of permitted spenders to reduce the blast radius of a compromised admin key.

---

### [I-07] premiumRatePerSecond Missing WAD-Scaled Qualifier

**Severity**: Informational
**Location**: `CoveredVaultStorage:L50-65`

**Description**:
The state variable `premiumRatePerSecond` is WAD-scaled (divided by `1e18` in the accrual formula at `CoveredVaultAccrual.sol:54`), but the variable name does not convey this unit information. The NatSpec comment says "WAD-scaled" which partially mitigates the concern, but an integrator reading only the variable name would interpret it as a raw `wei/second` rate rather than a `wei/second * 1e18` value. The constant `MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991` also lacks a unit qualifier, making the maximum rate opaque to integrators without reading the NatSpec.

**Recommendation**:
Rename to `premiumRatePerSecondWad` or add a unit comment directly in the variable declaration: `uint256 public override premiumRatePerSecond; // WAD-scaled: divide by 1e18 to get rate`. Similarly qualify `MAX_PREMIUM_RATE_PER_SECOND`.

---

### [I-08] Combined Fee Cap Dead Code (100% Unreachable)

**Severity**: Informational
**Location**: `CoverPool:L35-45`

**Description**:
`PremiumManager.distributePremium()` includes the check `require(totalFeeBps <= _MAX_FEE_BPS)` where `_MAX_FEE_BPS = 10_000` (100%). Since `platformFeeBps` is capped at 2,500 bps and `poolFeeBps` is capped at 2,000 bps by their respective setters, the combined total can never exceed 4,500 bps. The 10,000 bps guard is unreachable dead code. The `ExcessiveCombinedFees(platformFeeBps, poolFeeBps, totalFeeBps)` custom error can never be emitted in normal protocol operation, making it a misleading artefact in the ABI. (This finding describes the same constant as L-29 but focuses on the dead-code aspect rather than the semantic naming.)

**Recommendation**:
Remove the redundant combined fee guard, or update `_MAX_FEE_BPS` to `_MAX_PLATFORM_FEE_BPS + _MAX_POOL_FEE_BPS` (4,500 bps) so that the guard is meaningful and the `ExcessiveCombinedFees` error is reachable.

---

### [I-09] _accruePremium Advances Timestamp When Rate is Zero

**Severity**: Informational
**Location**: `CoveredVaultAccrual:L85-100`

**Description**:
`_accruePremium()` unconditionally sets `lastPremiumAccrualTime = block.timestamp` at line 32 before any other checks. When `premiumRatePerSecond == 0`, the subsequent multiplication yields `accrued = 0` and the function returns early at line 56 — but the timestamp has already been advanced. This means that when the rate is later set to a non-zero value, there is no catch-up accrual for the elapsed zero-rate period; the consumed time window is silently discarded. The NatSpec at lines 30-32 documents this as intentional design: "Always advance the timestamp unconditionally so that when a new policy is later bound, there is no catch-up accrual for the inactive gap period." The same logic applies to zero-rate periods.

**Recommendation**:
No code change required — this is documented intentional behavior. Add a comment specifically calling out the zero-rate case alongside the existing NatSpec, as this invariant is non-obvious and integrators who set `premiumRatePerSecond = 0` temporarily may not anticipate that elapsed time during the zero-rate period will not be recovered when the rate is restored.

---

### [I-10] Fee Split Rounding Favors Restakers (2 wei dust)

**Severity**: Informational
**Location**: `PremiumManager:L125-140`

**Description**:
`PremiumManager.getFeeSplits()` computes platform and pool splits using integer floor division, then assigns the remainder to restakers: `restakerSplit = grossPremium - platformSplit - poolSplit`. Each floor division truncates up to 1 wei, so restakers receive up to 2 wei of dust per distribution call that would otherwise accrue to the platform or pool. At maximum fee rates (platformFeeBps = 2500, poolFeeBps = 2000), the maximum dust per call is 2 wei. At any realistic distribution frequency and premium scale, the cumulative dust is negligible.

**Recommendation**:
No fix required — the rounding direction (favoring restakers over platform/pool) is a reasonable design choice. Document the rounding behavior in the NatSpec for `getFeeSplits` to make the intent explicit.

---

### [I-11] PremiumCollector._distribute Truncates to uint32

**Severity**: Informational
**Location**: `PremiumCollector:L220-235`

**Description**:
`PremiumCollector._distribute()` stores the distribution timestamp as `config.lastDistributeTime = uint32(block.timestamp)`. The `uint32` type overflows at Unix timestamp 4,294,967,295 (February 7, 2106). After this date, `lastDistributeTime` wraps to 0, which would allow immediate re-distribution regardless of `distributeInterval`. This is a well-known year-2106 timestamp issue present in many Solidity codebases. No immediate action is required for the protocol's current deployment horizon.

**Recommendation**:
No immediate fix required. For long-term maintenance, migrate `VaultConfig.lastDistributeTime` to `uint64` (which overflows around year 584 billion) and update all related logic. Flag this for review in any protocol version intended to operate past 2100.

---

### [I-12] _isPolicyActive External Call on Every Deposit/Withdraw (Gas)

**Severity**: Informational
**Location**: `CoveredVaultAccrual:L65-95`

**Description**:
`_isPolicyActive()` makes an external call to `PolicyManager.policyMetadata(policyId)` on every invocation. Within a single withdrawal transaction, `_isPolicyActive` is called at minimum twice: once via `_accruePremium → _activeElapsedFrom → _isPolicyActive`, and once via `_executeWithdrawal → _settleWithdrawalTransfer → _computeInsurance → _isPolicyActive`. Each invocation is a cold external call that cannot be collapsed by the EVM. No within-transaction caching of the `PolicyMetadata` struct is performed. This represents two cross-contract calls per withdrawal where one would suffice.

**Recommendation**:
Cache the `PolicyMetadata` result at the start of `_withdraw` and `_deposit` and pass it through the internal call chain as a memory argument. This reduces external calls per withdrawal from 2+ to 1, saving approximately 2,000–5,000 gas per operation depending on whether the PolicyManager storage is warm.

---

### [I-13] CoverPool Curator 24-Hour Admin Transfer Delay

**Severity**: Informational
**Location**: `CoverPool:L50-70`

> **Note**: This is documented design behavior. The 24-hour admin transfer delay is explicitly stated in the protocol's trust assumption model for CoverPool curators.

**Description**:
`CoverPool` is initialized with `AccessControlDefaultAdminRulesUpgradeable` configured for a 24-hour admin transfer delay. This means any transfer of the `DEFAULT_ADMIN_ROLE` (curator) on a CoverPool requires a 24-hour pending period before the transfer completes. The delay is a deliberate security measure — it provides a window for depositors and protocol operators to detect and respond to an unauthorized admin transfer attempt. This finding documents the design for completeness and for contrast with `CoverPoolFactory`, which uses instant admin transfer (see L-27).

**Recommendation**:
No change required. Document the 24-hour delay in user-facing documentation so that CoverPool operators are aware of the transfer latency when performing legitimate curator rotation.
