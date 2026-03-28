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
    PC[PremiumCollector]
    PRM[PremiumManager]
    SR[SpecRegistry]
    SW[Swapper]
    UV3[UniswapV3Adapter]

    CPF --> CP
    PM --> CP
    CP --> PM
    CP --> SR
    PM --> CM
    PC --> PRM
    CM --> SR
    CM --> SW
    SW --> UV3
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
- `computeCoverPoolAddress(params)` predicts deterministic clone address.
- `coverPoolExists(pool)` validates whether a pool is factory-created.

Note: On EigenLayer, duration vaults act as operators and are auto-deployed during committee creation.

**Key role:**

- `CREATOR_ROLE` controls pool creation and major factory settings.

### 2) CoverPool

**Role:** Curator-owned underwriting pool for quote validation and policy binding.

**Pattern and state:**

- Intended for minimal-clone deployment.
- Uses `AccessControlDefaultAdminRulesUpgradeable` for admin transfer safety.
- Maintains bound policy commits and per-policy bound metadata.

**Key functions:**

- `bindPolicyForRequest(policyId, quote, spec, vaults, signature)` performs:
  - draft checks via `PolicyManager`,
  - EIP-712 quote signature verification,
  - spec registration in `SpecRegistry`,
  - committee vault binding in Core via `StakeManager`,
  - final policy bind callback into `PolicyManager`.
- `setPoolFeeBps(...)`, `setFeeRecipient(...)` configure pool economics.

**Key role:**

- `QUOTE_SIGNER_ROLE` defines trusted quote signers.

### 3) PolicyManager

**Role:** Policy draft and bound-policy authority.

**Pattern and state:**

- UUPS upgradeable proxy.
- Stores draft records (`PolicyDraft`) and canonical bound metadata (`PolicyMetadata`).
- Tracks next policy id and policy commit uniqueness.

**Key functions:**

- `requestCoverage(...)`:
  - called by the covered vault (or its adapter) as the `buyer`,
  - commonly sets `claimer` to the cover adapter,
  - commonly sets `beneficiary` to the cover adapter for atomic shortfall top-ups,
  - validates pool and hook,
  - creates policy draft,
  - creates Core committee with `committeeId = policyId`
    (`createCommittee` auto-assigns the pool curator as committee operator).
- `bindPolicy(request, boundPolicy)`:
  - callable by pool only,
  - validates request/draft/quote consistency,
  - verifies stake and vault readiness through Core,
  - stores canonical policy metadata,
  - calls `IBindPolicyHook.onPolicyBound(policyId, coverageLimit)`.

### 4) PremiumCollector

**Role:** Collector of ERC-4626 vault shares and periodic redeemer/distributor.

**Pattern and state:**

- UUPS upgradeable proxy.
- Tracks registered vault configs: underlying token, pool, policyId, and distribution timestamp.
- Supports keeper-style public batch distribution.

**Key functions:**

- `registerVault(vault, pool, policyId)` maps a covered vault to routing metadata.
- `distributeBatch(vaults)` redeems shares to underlying and forwards assets to `PremiumManager`.
- `getDistributableVaults()` surfaces vaults eligible by interval and balance.

### 5) PremiumManager

**Role:** Premium split and restaker reward routing bridge into Core.

**Pattern and state:**

- UUPS upgradeable proxy.
- Holds platform configuration: `platformTreasury`, `platformFeeBps`.

**Key functions:**

- `distributePremium(pool, policyId, premiumToken, amount)`:
  - computes split: platform / pool / restaker,
  - transfers platform fee to treasury,
  - transfers pool fee to pool fee recipient,
  - retains restaker share (SSPRouter pulls it directly via allowance),
  - calls `RewardsManager.distributeRewards(policyId, operator, amount, token)`.
- `approveSpender(token, spender, amount)` grants SSPRouter an allowance to pull the restaker share.
- `getFeeSplits(...)` deterministic split helper.

**Key role:**

- `PREMIUM_COLLECTOR_ROLE` gates premium distribution entrypoint.

### 6) ClaimManager

**Role:** Claim execution engine from filing to payout.

**Pattern and state:**

- UUPS upgradeable proxy.
- Maintains per-policy claim counters, claim records, and cumulative paid-out amount.

**Key functions:**

- `fileClaim(policyId, requestedAmount, evidenceHash, additionalData)`:
  - acts as a file-and-resolve entrypoint (single transaction),
  - validates coverage window and remaining coverage,
  - requires caller equals policy `claimer`,
  - resolves spec and runs evaluation,
  - if payable, executes slashing and collateral processing,
  - transfers payout to beneficiary.
- `remainingCoverage(policyId)` and read models for claims.

**Slashing and payout mechanics:**

- Converts requested payout token amount to USD via Core `ChainlinkPriceFeed`.
- Calls Core `SlashingManager.executeSlashing(committeeId, operator, slashAmountUSD)`.
- Processes returned collateral token arrays:
  - direct transfer if already payout token,
  - otherwise swap through `Swapper`.

### 7) SpecRegistry

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
- `resolveSpec(pool, specId)` called by `ClaimManager`; resolution is not gated by approval status so in-flight claims on existing policies are unaffected by revocations.

### 8) Swapper

**Role:** Controlled token conversion path for claim collateral.

**Pattern and state:**

- UUPS upgradeable proxy.
- Route registry keyed by `(tokenIn, tokenOut)`.
- Supports whitelisted swap targets and native wrapper semantics.

**Key functions:**

- `setSwapRoute(...)`, `setSwapTargetWhitelist(...)` for configuration.
- `executeSwap(params)` for authorized executors (typically `ClaimManager`).

**Key roles:**

- `SWAP_MANAGER_ROLE` configures routes and whitelisted targets.
- `SWAP_EXECUTOR_ROLE` calls `executeSwap` (held by `ClaimManager`).

### 9) UniswapV3Adapter

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

These components typically live outside this repository but are first-class architecture actors.

### Covered Vault (Morpho V2)

- user-facing insured vault,
- sets management-fee style premium parameters (via curator controls),
- allocates/deallocates through the adapter.

### CoveredVaultWrapper

- ERC-4626 wrapper around a Morpho vault,
- accrues and collects premiums from depositors,
- tracks reference accounting for shortfall detection,
- calls Coverage claim entrypoints (`fileClaim`) on shortfall,
- receives claim payout and tops up withdrawals to make depositors whole.

### Base Vault (Morpho V1/V2)

- underlying yield venue where adapter actually places capital,
- can be shared with uninsured users outside the covered vault.

## Upgrade and Access-Control Model

All major contracts are UUPS upgradeable (except CoverPool clones, which are minimal proxies).

Typical control planes:

- `DEFAULT_ADMIN_ROLE` for contract-wide configuration and upgrades.
- specialized roles for restricted entrypoints:
  - `CREATOR_ROLE` on factory,
  - `QUOTE_SIGNER_ROLE` on pools,
  - `PREMIUM_COLLECTOR_ROLE` on premium manager,
  - `SWAP_MANAGER_ROLE` / `SWAP_EXECUTOR_ROLE` on swapper.
- On `SpecRegistry`, `DEFAULT_ADMIN_ROLE` additionally controls the spec approval whitelist
  (`approveSpec` / `revokeSpec`). Only admin-approved `ISpec` implementations may be registered
  by cover pool curators.

## Integration Dependencies

Coverage contracts rely on Core interfaces:

- `IStakeManager` for committee create/operator/vault and stake reads,
- `IRewardsManager` for reward fan-out trigger,
- `ISlashingManager` for committee slashing execution,
- `IChainlinkPriceFeed` for payout-to-USD conversion.

## Next Steps

- [Core Integration](./03-core-integration.md)
- [Policy Lifecycle](./05-policy-lifecycle.md)
- [Premiums and Claims](./06-premiums-claims.md)
