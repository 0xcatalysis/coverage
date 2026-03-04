# Coverage to Core Integration

## Overview

Coverage uses Core as the execution and accounting substrate for restaked security.
The boundary is strict:

- Coverage defines underwriting, policy semantics, premium routing, and claim intent.
- Core executes committee-level stake, reward distribution, and slashing on SSP adapters.

This separation keeps restaking platform complexity out of Coverage contracts.

## Integration Matrix

| Coverage Contract | Core Contract | Function | Purpose |
|---|---|---|---|
| `PolicyManager` | `StakeManager` | `createCommittee(policyId, coverageAmount, pool, duration)` | Create policy-scoped committee; auto-assigns pool curator as operator |
| `CoverPool` | `StakeManager` | `addCommitteeVaults(policyId, vaults[])` | Bind selected vaults/strategies backing policy; triggers internal stake sufficiency check |
| `PolicyManager` | `StakeManager` | `getCommitteeVaults(policyId)` | Verify vault backing exists before bind finalization |
| `PremiumManager` | `RewardsManager` | `distributeRewards(policyId, operator, amount, token, taskId)` | Trigger Core reward fan-out; SSPRouter pulls restaker share from PremiumManager |
| `ClaimManager` | `ChainlinkPriceFeed` | `getUSDValue(token, amount)` | Normalize requested payout to USD slash target |
| `ClaimManager` | `ChainlinkPriceFeed` | `getTokenAmount(token, usdAmount)` | Convert USD amounts back to token amounts for slippage preview |
| `ClaimManager` | `SlashingManager` | `previewSlashing(policyId, operator, slashAmountUSD)` | Preview per-vault collateral distribution without executing; used to compute real-time swap slippage before inflating slash target |
| `ClaimManager` | `SlashingManager` | `executeSlashing(policyId, operator, slashAmountUSD, taskId)` | Execute policy-scoped slashing and retrieve collateral |

> **Note:** EigenLayer operator setup (depositing stake, allocating magnitude, and registering to the
> committee's operator set) is performed off-chain by the restaker before bind. See
> [Restaker Setup](./04-restaker-setup.md) for the full sequence.

## Committee and Policy Identity

Coverage enforces `policyId == committeeId` across all cross-layer calls.

Implications:

- Capacity is set once at policy request (`coverageAmount`).
- Vault assignment is attached to the same id at bind time.
- Rewards and slashing are naturally scoped to the policy's committee.

Typical covered-vault actor mapping:

- `buyer`: covered vault or cover adapter.
- `claimer`: cover adapter (withdrawal-triggered claim path).
- `beneficiary`: cover adapter for atomic shortfall make-whole, then forwarded to covered vault/user path.

## Flow-by-Flow Integration

### 1) Pool Creation

Sequence:

1. Curator invokes `CoverPoolFactory.createCoverPool(params)`.
2. Factory deploys and initializes a pool clone with curator as owner.

Outcome:

- Curator is pool owner and holds `DEFAULT_ADMIN_ROLE` on the pool.
- Pool is tracked in factory for `coverPoolExists()` validation.

### 2) Coverage Request and Committee Creation

Sequence:

1. Covered vault (or its adapter acting as buyer) calls `PolicyManager.requestCoverage(...)`.
2. Manager creates draft and increments `policyId`.
3. Manager calls `StakeManager.createCommittee(policyId, coverageAmount, pool, duration)`.
   `createCommittee` auto-assigns the pool's curator as the committee operator internally.

Outcome:

- Draft exists in Coverage.
- Committee scaffold exists in Core with policy-aligned id and curator as operator.

### 3) Vault Binding and Policy Activation

Sequence:

1. Curator calls `CoverPool.bindPolicyForRequest(...)` with quote and vaults.
2. Pool calls `StakeManager.addCommitteeVaults(policyId, vaults)`.
   - `SSPRouter._checkDelegation` runs internally and reverts with `InsufficientDelegationAmount`
     if `EigenAdapter.getStrategiesStakeUSD(vaults)` < `committeeMaxStake` (= `coverageAmount`).
3. `PolicyManager.bindPolicy(...)` checks:
   - committee has at least one vault (`getCommitteeVaults`).

Outcome:

- Policy transitions to bound/active state only when Core backing is present and stake is sufficient.

### 4) Premium Rewards Routing

Sequence:

1. `PremiumCollector` redeems covered-vault shares to underlying.
2. `PremiumManager.distributePremium(...)` computes fee splits.
3. Coverage calls `RewardsManager.distributeRewards(policyId, operator, amount, token)`.
4. `SSPRouter` pulls the restaker share directly from `PremiumManager` (approved via `approveSpender`).

Outcome:

- Coverage specifies policy/operator reward intent.
- Core executes final per-SSP reward distribution.

### 5) Claim-Driven Slashing

Sequence:

1. During covered-vault withdrawal, adapter detects shortfall and files claim.
2. `ClaimManager` converts requested payout amount to USD via Core price feed (`getUSDValue`).
3. `ClaimManager` calls `SlashingManager.previewSlashing(policyId, operator, baseSlashAmountUSD)`
   (in a `try/catch`) to obtain the expected per-vault collateral distribution.
4. For each vault, `ClaimManager` fetches a live Uniswap quote via `Swapper.quoteSwap` →
   `UniswapV3Adapter.quote` → `QuoterV2.quoteExactInputSingle` (also in a `try/catch`).
5. Real-time slippage bps is computed as `(oracleExpected − totalQuoted) × 10_000 / oracleExpected`;
   the USD slash target is inflated by this factor before slashing.
6. `ClaimManager` calls `SlashingManager.executeSlashing(policyId, operator, inflatedSlashAmountUSD, taskId)`.
7. Core returns actual collateral token arrays; Coverage swaps or directly transfers to beneficiary.

Outcome:

- Core performs SSP slashing mechanics.
- Coverage performs beneficiary-facing settlement, then adapter completes make-whole transfer flow.
- Slash amount is inflated by real on-chain slippage, minimising shortfall due to swap price impact.

No-shortfall withdrawal path:

- If adapter deallocation returns sufficient assets, no claim is filed and no Core slashing call is made.

## Data and Unit Conventions

- Committee slash target input to Core is USD-valued (8 decimals) from `ChainlinkPriceFeed`.
- Coverage payouts are token-denominated by `payoutToken`.
- `coverageAmount` in `PolicyDraft` is treated as the committee stake requirement.

## Trust and Failure Boundaries

Coverage assumptions about Core:

- committee state and stake reads are correct and timely,
- reward/slash execution either succeeds or reverts atomically,
- token arrays returned from slashing are valid and aligned.

Failure patterns:

- If Core stake is insufficient at bind check, policy bind reverts.
- If slashing returns empty arrays, claim payout reverts.
- If price feed conversion fails or is stale, slash calculation path fails.

## Operational Best Practices

- Keep `policyId` and committee references consistent in all off-chain orchestration.
- Ensure restakers have deposited into the committee's duration vault before bind. Duration vaults act as EigenLayer operators — no separate magnitude allocation or operator-set registration is needed. See [Restaker Setup](./04-restaker-setup.md).
- Register and verify vault module mappings in Core (`SSPRouter.registerVaultModule`) before bind.
- Configure swap routes for expected collateral → payout token pairs before claims.
- `WETH` price feed must be registered in `ChainlinkPriceFeed` before claims can be filed against WETH-payout policies.

## Next Steps

- [Restaker Setup and Delegation Lifecycle](./04-restaker-setup.md)
- [Policy Lifecycle](./05-policy-lifecycle.md)
- [Premiums and Claims](./06-premiums-claims.md)
- [Covered Vault Integration](./07-covered-vault-integration.md)
