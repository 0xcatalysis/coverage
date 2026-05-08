# Coverage Smart Contracts Architecture

## Overview

Coverage contracts are the policy and payout application layer over Catalysis Core.
They are responsible for policy issuance semantics, premium collection/routing, and
claim execution, while Core handles committee stake and SSP-level execution.

## Contract Topology

```mermaid
graph LR
    CPF[CoverPoolFactory]
    CP[CoverPool]
    PM[PolicyManager]
    CM[ClaimManager]
    PRM[PremiumManager]
    SR[SpecRegistry]
    SW[Swapper]
    UV3[UniswapV3Adapter]
    CVW[CoveredVaultWrapper]
    PF[OraclePriceFeed]

    CPF --> CP
    PM --> CP
    CP --> PM
    CP --> SR
    CVW --> PRM
    CVW --> CM
    PRM --> CP
    CM --> SR
    CM --> SW
    CM --> PRM
    SW --> UV3
    PM --> PF
```

## Core Coverage Contracts

### 1) CoverPoolFactory

**Role:** Deploys and tracks `CoverPool` clones.

**Pattern and state:**

- UUPS upgradeable proxy.
- Deploys deterministic minimal proxy clones using `Clones.cloneDeterministic`.
- Maintains an internal pool set and pagination helpers.

**Key functions:**

- `createCoverPool(params)` creates and initializes a pool clone, grants curator ownership.
- `computeCoverPoolAddress(params)` predicts deterministic clone address. The salt combines all `CreateCoverPoolParams` fields with the factory's current `policyManager` address, so predictions change if `setPolicyManager` is called.
- `coverPoolExists(pool)` validates whether a pool is factory-created.
- `getCoverPools(offset, limit)`, `totalCoverPools()`, `coverPoolAt(index)` — pagination helpers over the internal pool set.
- `setCoverPoolImplementation`, `setPolicyManager`, `setStakeManager`, `setSpecRegistry` — dependency setters (`CREATOR_ROLE`).
- `pause` / `unpause` — emergency halt via `DEFAULT_ADMIN_ROLE` (not `CREATOR_ROLE`).

Note: On EigenLayer, duration vaults act as operators and are auto-deployed during committee creation.

**Key roles:**

- `CREATOR_ROLE` controls pool creation (`createCoverPool`) and major factory dependency setters.
- `DEFAULT_ADMIN_ROLE` controls `pause`/`unpause` and upgrades.

### 2) CoverPool

**Role:** Curator-owned underwriting pool for quote validation and policy binding.

**Pattern and state:**

- Intended for minimal-clone deployment.
- Uses `AccessControlDefaultAdminRulesUpgradeable` for admin transfer safety.
- Maintains bound policy commits and per-policy bound metadata.

**Key functions:**

- `bindPolicyForRequest(policyId, quote, spec, vaults, signature)` performs:
  - draft checks via `PolicyManager`,
  - EIP-712 quote signature verification (via `_verifyQuote` with the `validateQuote` modifier enforcing expiry),
  - local pool-side bind state persisted immediately after signature verification (`_recordBoundPolicy`),
  - spec registration in `SpecRegistry`,
  - committee vault binding in Core via `StakeManager`,
  - final policy bind callback into `PolicyManager`.
- `setPoolFeeBps(fee)` proposes a new pool fee and starts a **48-hour timelock** (`POOL_FEE_TIMELOCK`). The previous fee remains active until the timelock elapses. `finalizePoolFeeBps()` (callable by anyone) materialises the pending proposal once the timelock has passed. If a new proposal is submitted while a previous one is pending but not yet matured, the pending proposal is cancelled and replaced. `setFeeRecipient(...)` updates the fee recipient immediately.
- `setPremiumDefaulted(policyId, defaulted)` — forwarded to `PolicyManager`; callable only by the pool admin.
- `getBoundPolicy(policyId)` / `hasBoundPolicy(policyId)` — view helpers for bound policy state.
- `quoteDomainSeparator()` — returns the EIP-712 domain separator for off-chain quote construction.
- `pause` / `unpause` — emergency halt via `DEFAULT_ADMIN_ROLE`.

**Key role:**

- `QUOTE_SIGNER_ROLE` defines trusted quote signers.
- `DEFAULT_ADMIN_ROLE` (curator) controls all pool configuration, role grants, and pausing.

### 3) PolicyManager

**Role:** Policy draft and bound-policy authority.

**Pattern and state:**

- UUPS upgradeable proxy.
- Stores draft records (`PolicyDraft`) and canonical bound metadata (`PolicyMetadata`).
- Tracks next policy id and policy commit uniqueness.

**Key functions:**

- `requestCoverage(...)`:
  - called by the wrapper **owner** (EOA/multisig) as `msg.sender`, recorded as `buyer`; the `CoveredVaultWrapper` contract itself is **not** the buyer,
  - commonly sets `claimer` to `CoveredVaultWrapper` (files claims atomically on withdrawal shortfall),
  - commonly sets `beneficiary` to `CoveredVaultWrapper` for atomic shortfall top-ups,
  - validates pool, payout token whitelist, hook, and duration,
  - creates policy draft,
  - creates Core committee with `committeeId = policyId` via `StakeManager.createCommittee(policyId, pool, duration)`,
  - then explicitly calls `StakeManager.addOperatorToCommittee(curator, policyId)` to register the pool curator as operator.
- `bindPolicy(request, boundPolicy)`:
  - callable by pool only,
  - validates request/draft/quote consistency,
  - verifies stake and vault readiness through Core,
  - stores canonical policy metadata,
  - calls `IBindPolicyHook.onPolicyBound(policyId, coverageLimit)`.
- `cancelPolicyDraft(policyId)` — buyer-only; cancels a `Created` draft and removes the curator from the committee via `StakeManager.removeOperatorFromCommittee`.
- `setPremiumDefaulted(policyId, defaulted)` — callable by the bound policy's pool (not admin).
- `setSupportedPayoutToken(token, supported)` — admin-managed payout token whitelist.
- `pause` / `unpause` — emergency halt via `DEFAULT_ADMIN_ROLE`.

Note: `PolicyManager` stores a `claimManager` address for reference but does **not** call `ClaimManager` at runtime.

### 4) PremiumManager

**Role:** Premium split and restaker reward routing bridge into Core.

**Pattern and state:**

- UUPS upgradeable proxy.
- Holds platform configuration: `platformTreasury`, `platformFeeBps`.
- Maintains an admin-controlled set of approved premium tokens; `distributePremium` reverts for any unapproved token.

**Key functions:**

- `distributePremium(pool, policyId, premiumToken, amount)`:
  - permissionless entrypoint — any caller (typically `CoveredVaultWrapper.collectPremium()`) may call it,
  - requires: `pool` has a bound policy for `policyId`, `premiumToken` is in the approved token set, `amount >= 1000`,
  - pulls `amount` from the caller via `safeTransferFrom`, so the caller must have approved `PremiumManager` first,
  - computes split: platform / pool / restaker,
  - transfers platform fee to `platformTreasury`,
  - transfers pool fee to pool `feeRecipient`,
  - for the restaker share: grants `RewardsManager` an **ephemeral per-call allowance** via `forceApprove(rewardsManager, restakerSplit)`, calls `RewardsManager.distributeRewards(policyId, curator, restakerSplit, token, taskId)` (where `taskId` is derived internally as `keccak256(abi.encodePacked(policyId, ++nonce))`), then zeroes the allowance with `forceApprove(rewardsManager, 0)`.
- `approveSpender(token, spender, amount)` grants an arbitrary spender a custom allowance from `PremiumManager`; this is a general admin utility and is **not** a prerequisite for `distributePremium` or `distributeSurplusAsRewards`, both of which manage their own ephemeral allowances internally.
- `addApprovedPremiumToken(token)` / `removeApprovedPremiumToken(token)` admin management of allowed premium tokens.
- `isApprovedPremiumToken(token)` / `approvedPremiumTokens()` view helpers.
- `getFeeSplits(...)` deterministic split helper.

- `distributeSurplusAsRewards(policyId, curator, amount, token, taskId)` — routes excess collateral from claim settlements to `RewardsManager`; requires `CLAIM_MANAGER_ROLE` (held by `ClaimManager`). Uses the same ephemeral `forceApprove` pattern as `distributePremium`.
- `setRewardsManager`, `setPlatformTreasury`, `setPlatformFeeBps` — admin setters.
- `pause` / `unpause` — emergency halt via `DEFAULT_ADMIN_ROLE`.

**Access control:** `DEFAULT_ADMIN_ROLE` for configuration; `distributePremium` has no role requirement; `distributeSurplusAsRewards` requires `CLAIM_MANAGER_ROLE`.

### 5) ClaimManager

**Role:** Claim execution engine from filing to payout.

**Pattern and state:**

- UUPS upgradeable proxy.
- Maintains per-policy claim counters, claim records, and cumulative paid-out amount.

**Key functions:**

- `fileClaim(policyId, requestedAmount, evidenceHash, additionalData)`:
  - file-and-resolve entrypoint (single transaction),
  - requires `claimApprovalRequired[policyId] == false`; curator must call `approveNextClaim` between successive claims,
  - validates coverage window, remaining coverage, non-zero/unique evidence hash, and `!premiumDefaulted`,
  - requires caller equals policy `claimer`,
  - resolves spec and runs evaluation,
  - if payable, executes slashing and collateral processing, then sets `claimApprovalRequired[policyId] = true`,
  - transfers payout to beneficiary.
- `approveNextClaim(policyId)` — curator clears the per-policy approval gate between successive claims.
- `claimApprovalRequired(policyId)` / `remainingCoverage(policyId)` / `claimRecord(policyId, claimId)` — views.
- `recoverTokens(token, to, amount)` — admin utility to recover tokens left by failed surplus distributions.
- `setMaxSwapSlippageBps`, `setSpecRegistry`, `setSlashingManager`, `setSwapper`, `setPolicyManager`, `setPremiumManager` — admin dependency setters.
- `pause` / `unpause` — emergency halt via `DEFAULT_ADMIN_ROLE`.
- `receive()` — accepts native ETH for native-token payout flows.

**Slashing and payout mechanics (token-native, no oracle):**

1. `SlashingManager.previewSlashing(committeeId, operator)` returns per-vault collateral tokens and token-native stake amounts.
2. `_computeVaultSlashes` quotes each cross-token stake via `Swapper.quoteSwap` to determine payout-equivalent values, then computes proportional token-native slash amounts per vault; cross-token amounts are inflated by `1 / (1 - maxSwapSlippageBps)` to absorb worst-case swap slippage. If `quoteSwap` reverts or returns zero, or the computed slash rounds to zero, a `VaultExcludedFromSlashing` event is emitted and the vault is skipped.
3. `SlashingManager.executeSlashing(committeeId, operator, VaultSlash[], taskId)` executes slashing and returns seized collateral.
4. For each collateral token:
   - if it already equals `payoutToken`: transfer directly to beneficiary; surplus forwarded via `PremiumManager.distributeSurplusAsRewards` (skipped for native ETH surplus or if `premiumManager` is unset),
   - otherwise: swap through `Swapper` using `quoteSwap`-derived `amountOutMin`; surplus forwarded similarly.
   - Surplus routing is wrapped in a `try`/`catch`; failures emit `SwapSurplusDistributionFailed` and leave tokens in the contract for recovery via `recoverTokens`.

No USD conversion or `OraclePriceFeed` is used in the claim execution path.

### 6) SpecRegistry

**Role:** Immutable-style mapping of `(coverPool, specId)` to `ISpec`, with admin-controlled spec approval.

**Pattern and state:**

- UUPS upgradeable proxy.
- Registration is idempotent for the same target and rejects remapping to a different spec.
- Enforces caller is a factory-created pool.
- Maintains an admin-approved whitelist of `ISpec` implementation addresses. A spec must be approved before any pool can register it.

**Key functions:**

- `approveSpec(spec)` called by admin to whitelist a trusted `ISpec` implementation.
- `revokeSpec(spec)` called by admin to remove an `ISpec` from the whitelist.
- `isSpecApproved(spec)` view helper to check whether a spec is currently approved.
- `registerSpec(specId, spec)` called by pool during bind; reverts with `SpecNotApproved` if the spec is not on the whitelist.
- `resolveSpec(pool, specId)` called by `ClaimManager`; resolution **is** gated by approval status — if a spec is revoked via `revokeSpec`, both new registrations and claim resolution for any `(pool, specId)` pair using that spec address are blocked. Re-approving the spec via `approveSpec` restores resolution. Use revocation as a targeted kill switch for compromised spec implementations.

### 7) Swapper

**Role:** Controlled token conversion path for claim collateral.

**Pattern and state:**

- UUPS upgradeable proxy.
- Route registry keyed by `(tokenIn, tokenOut)`.
- Supports whitelisted swap targets and native wrapper semantics.

**Key functions:**

- `setSwapRoute(...)`, `setSwapTargetWhitelist(...)` for configuration.
- `executeSwap(params)` for authorized executors (typically `ClaimManager`).

**Key roles:**

- `DEFAULT_ADMIN_ROLE` whitelists swap targets via `setSwapTargetWhitelist`.
- `SWAP_MANAGER_ROLE` configures swap routes via `setSwapRoute`.
- `SWAP_EXECUTOR_ROLE` calls `executeSwap` (held by `ClaimManager`).

### 8) UniswapV3Adapter

**Role:** Bridges the Swapper's static-calldata pattern to Uniswap V3 `SwapRouter02`.

**Why it exists:** The Swapper stores one static calldata blob per `(tokenIn, tokenOut)` route and
replays it verbatim on every swap. Uniswap V3's `exactInputSingle` requires the `amountIn` to be
encoded in each call, making a direct route impossible. The adapter resolves `amountIn` dynamically
from the allowance the Swapper grants it.

**Integration pattern** (called by `Swapper._performSwap`):

1. Swapper approves adapter for `amountIn` of `tokenIn`.
2. Swapper calls `adapter.swap(tokenIn, tokenOut, fee, amountOutMinimum)` via stored static calldata.
3. Adapter reads `allowance(Swapper, adapter)` to obtain `amountIn`.
4. Adapter pulls `tokenIn` from Swapper via `transferFrom`.
5. Adapter calls `SwapRouter02.exactInputSingle` forwarding `amountOutMinimum` for router-level slippage enforcement.
6. Router delivers `tokenOut` directly to Swapper.
7. Adapter clears residual approval to the router.

**Slippage protection:** The `amountOutMinimum` parameter is forwarded directly to the Uniswap V3
router, enabling defense-in-depth slippage protection at the adapter level.

**Access control:** `swap()` is restricted to the `SWAPPER` address recorded at construction time.
Only the authorized Swapper contract may invoke the adapter, enforcing the principle of least
privilege. Any third-party call is rejected with `UnauthorizedCaller()`.

**Deployment:** `script/DeployUniswapV3Adapter.s.sol` deploys the adapter (passing the `SWAPPER`
address as a constructor argument), whitelists it in `Swapper`, and configures the route in one
transaction. Since `UniswapV3Adapter` is an immutable contract, any change to the adapter requires
deploying a new instance and reconfiguring the Swapper route via `setSwapTargetWhitelist` +
`setSwapRoute`.

| Network | SwapRouter02 |
|---------|-------------|
| Sepolia | `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E` |
| Mainnet | `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` |

## Covered Vault Integration Components (Morpho)

These components live in `src/defi/` and are first-class architecture actors.

### CoveredVaultWrapper

- UUPS-upgradeable ERC-4626 vault that wraps a Morpho V2 vault,
- shares are **non-transferable** between external accounts,
- accrues premiums continuously against depositor principal via a reward-per-token accumulator,
- exposes `collectPremium()` (permissionless) which flushes accrued premium to `PremiumManager.distributePremium()` when a policy is bound; falls back to a direct `safeTransfer` to `premiumRecipient` when `policyId == 0`,
- detects shortfall on withdrawal by comparing `insuredBasis` (principal minus paid premium) against proceeds from the Morpho vault,
- calls `ClaimManager.fileClaim(...)` atomically during withdrawal when a shortfall exists,
- receives claim payout and tops up the user's withdrawal to make them whole,
- exposes `emergencyRedeem` / `emergencyWithdraw` for users to exit without insurance by setting a transient skip-insurance flag.

## Upgrade and Access-Control Model

All major contracts are UUPS upgradeable (except CoverPool clones, which are minimal proxies).

Typical control planes:

- `DEFAULT_ADMIN_ROLE` for contract-wide configuration and upgrades.
- specialized roles for restricted entrypoints:
  - `CREATOR_ROLE` on factory,
  - `QUOTE_SIGNER_ROLE` on pools,
  - `SWAP_MANAGER_ROLE` (route config) and `SWAP_EXECUTOR_ROLE` (execute swap) on swapper; swap target whitelisting requires `DEFAULT_ADMIN_ROLE` on swapper.
- On `SpecRegistry`, `DEFAULT_ADMIN_ROLE` additionally controls the spec approval whitelist
  (`approveSpec` / `revokeSpec`). Only admin-approved `ISpec` implementations may be registered
  by cover pool curators.

## Integration Dependencies

Coverage contracts rely on Core interfaces:

- `IStakeManager` for committee create/operator/vault and stake reads,
- `IRewardsManager` for reward fan-out trigger,
- `ISlashingManager` for committee slashing execution,
- `IOraclePriceFeed` for stake-to-USD conversion at bind time (stake sufficiency check in `PolicyManager`).

## Next Steps

- [Core Integration](./03-core-integration.md)
- [Policy Lifecycle](./05-policy-lifecycle.md)
- [Premiums and Claims](./06-premiums-claims.md)
- [CoveredVaultWrapper Accounting](./07-covered-vault-accounting.md)
