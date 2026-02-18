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
| `CoverPoolFactory` | `StakeManager` | `registerOperatorToNetwork(operator, deadline, signature)` | Register curator/operator to network during pool creation |
| `PolicyManager` | `StakeManager` | `createCommittee(policyId, coverageAmount, duration)` | Create policy-scoped committee capacity |
| `PolicyManager` | `StakeManager` | `addOperatorToCommittee(curator, policyId)` | Assign pool operator to committee |
| `CoverPool` | `StakeManager` | `addCommitteeVaults(policyId, vaults[])` | Bind selected vaults/strategies backing policy |
| `PolicyManager` | `StakeManager` | `getCommitteeVaults(policyId)` | Verify vault backing exists before bind finalization |
| `PolicyManager` | `StakeManager` | `getOperatorCommitteeStake(curator, policyId)` | Enforce stake sufficiency before policy activation |
| `PremiumManager` | `RewardsManager` | `distributeRewards(policyId, operator, amount, token)` | Route restaker premium share to Core reward fan-out |
| `ClaimManager` | `ChainlinkPriceFeed` | `getUSDValue(token, amount)` | Normalize requested payout to USD slash target |
| `ClaimManager` | `SlashingManager` | `executeSlashing(policyId, operator, slashAmountUSD)` | Execute policy-scoped slashing and retrieve collateral |

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

### 1) Pool Creation and Operator Registration

Sequence:

1. Curator invokes `CoverPoolFactory.createCoverPool(...)`.
2. Factory deploys and initializes a pool clone.
3. Factory calls `StakeManager.registerOperatorToNetwork(...)`.

Outcome:

- Curator is pool owner at Coverage level.
- Curator/operator is registered at Core/restaking boundary.

### 2) Coverage Request and Committee Creation

Sequence:

1. Covered vault (or its adapter acting as buyer) calls `PolicyManager.requestCoverage(...)`.
2. Manager creates draft and increments `policyId`.
3. Manager calls `StakeManager.createCommittee(policyId, coverageAmount, duration)`.
4. Manager calls `StakeManager.addOperatorToCommittee(curator, policyId)`.

Outcome:

- Draft exists in Coverage.
- Committee scaffold exists in Core with policy-aligned id.

### 3) Vault Binding and Policy Activation

Sequence:

1. Curator calls `CoverPool.bindPolicyForRequest(...)` with quote and vaults.
2. Pool calls `StakeManager.addCommitteeVaults(policyId, vaults)`.
3. `PolicyManager.bindPolicy(...)` checks:
   - committee has vaults (`getCommitteeVaults`),
   - operator stake covers requested amount (`getOperatorCommitteeStake`).

Outcome:

- Policy transitions to bound/active state only when Core backing is present.

### 4) Premium Rewards Routing

Sequence:

1. `PremiumCollector` redeems covered-vault shares to underlying.
2. `PremiumManager.distributePremium(...)` computes fee splits.
3. Restaker share is sent to Core `RewardsManager`.
4. Coverage calls `RewardsManager.distributeRewards(policyId, operator, amount, token)`.

Outcome:

- Coverage specifies policy/operator reward intent.
- Core executes final per-SSP reward distribution.

### 5) Claim-Driven Slashing

Sequence:

1. During covered-vault withdrawal, adapter detects shortfall and files claim.
2. `ClaimManager` converts requested payout amount to USD via Core price feed.
3. `ClaimManager` calls `SlashingManager.executeSlashing(policyId, operator, slashAmountUSD)`.
4. Core returns collateral token arrays.
5. Coverage swaps or directly transfers to beneficiary (adapter in this integration model).

Outcome:

- Core performs SSP slashing mechanics.
- Coverage performs beneficiary-facing settlement, then adapter completes make-whole transfer flow.

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
- Pre-check operator committee stake before attempting bind.
- Register and verify vault module mappings in Core before bind.
- Configure swap routes for expected collateral -> payout token pairs before claims.

## Next Steps

- [Covered Vault Integration](./04-covered-vault-integration.md)
- [Policy Lifecycle](./05-policy-lifecycle.md)
- [Premiums and Claims](./06-premiums-claims.md)
