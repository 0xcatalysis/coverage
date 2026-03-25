# Premiums and Claims

## Overview

Coverage economics are split into two operational paths:

- **premium path**: covered-vault share accrual -> redemption -> split -> reward routing,
- **claim path**: claim evaluation -> committee slashing -> collateral conversion -> beneficiary payout.

Premiums and claims both use the same policy/committee identity (`policyId`).

Policy actor note:

- In this architecture, the policy `buyer` is expected to be the covered vault or its adapter contract.

## Dual Vault Model Context

The covered integration assumes:

- **Covered Vault (Morpho V2)**: insured user entrypoint.
- **Catalysis Cover Adapter**: allocation/deallocation + shortfall detection + claim trigger.
- **Base Vault (Morpho V1/V2)**: underlying capital destination.

A covered vault maps to one base vault. Users opt into insurance by choosing the covered vault path.

## Deposit Flow (Covered Path)

```mermaid
sequenceDiagram
    participant User
    participant CV as Covered Vault
    participant ADP as Catalysis Cover Adapter
    participant BV as Base Vault

    User->>CV: approve + deposit(assets, receiver)
    CV->>ADP: allocate(amount)
    ADP->>ADP: record principal + PPS reference
    ADP->>BV: deposit(amount)
    BV-->>ADP: base-vault shares
    ADP-->>CV: update reporting (adapter interface)
    CV-->>User: mint covered-vault shares
```

Adapter accounting details (implementation-specific):

- principal and reference PPS tracking are adapter responsibilities,
- these references are later used to detect withdrawal-time shortfall.

## Premium Flow

### Components

- `PremiumCollector` - collects ERC-4626 shares and redeems to underlying.
- `PremiumManager` - fee splitting and reward routing.
- `CoverPool` - source of pool fee settings and fee recipient.
- Core `RewardsManager` - downstream restaker reward distribution.

### Premium Distribution Sequence

```mermaid
sequenceDiagram
    participant Vault as Covered Vault (ERC-4626)
    participant PC as PremiumCollector
    participant PRM as PremiumManager
    participant Pool as CoverPool
    participant Treasury as Platform Treasury
    participant PoolRecipient as Pool Fee Recipient
    participant RM as Core RewardsManager
    participant SSP as SSPRouter

    Vault->>PC: management fee shares accrue
    PC->>PC: redeem(shares) -> underlying assets
    PC->>PRM: transfer underlying
    PC->>PRM: distributePremium(pool, policyId, token, amount)
    PRM->>Pool: read poolFeeBps + feeRecipient + owner
    PRM->>PRM: compute fee splits (retain restaker share)
    PRM->>Treasury: platform fee
    PRM->>PoolRecipient: pool fee
    PRM->>RM: distributeRewards(policyId, operator, amount, token)
    RM->>SSP: distributeRewards(..., tokenSource=premiumManager)
    SSP->>PRM: safeTransferFrom(premiumManager, adapter, restakerShare)
```

### Fee Split Logic

`PremiumManager.getFeeSplits(grossPremium, platformFeeBps, poolFeeBps)`:

- `platformSplit = gross * platformFeeBps / 10_000`
- `poolSplit = gross * poolFeeBps / 10_000`
- `restakerSplit = gross - platformSplit - poolSplit`

Guardrail:

- `platformFeeBps + poolFeeBps <= 10_000`.

## Claim Flow

### Components

- `ClaimManager` - claim intake, evaluation, and settlement.
- `SpecRegistry` + `ISpec` - payability decision logic. Only admin-approved `ISpec` implementations
  can be registered; once registered, a spec remains resolvable for existing policies regardless of
  subsequent revocation.
- Core `ChainlinkPriceFeed` - payout token amount -> USD slash target.
- Core `SlashingManager` - committee slashing execution.
- `Swapper` - collateral token conversion.

### Claim Settlement Sequence

```mermaid
sequenceDiagram
    participant Claimer
    participant CM as ClaimManager
    participant SR as SpecRegistry
    participant Spec as ISpec
    participant PF as Core ChainlinkPriceFeed
    participant SLM as Core SlashingManager
    participant SW as Swapper
    participant Beneficiary

    Claimer->>CM: fileClaim(policyId, requestedAmount, evidenceHash, data)
    CM->>CM: validate claimer, window, remaining coverage
    CM->>SR: resolveSpec(pool, specId)
    SR-->>CM: spec
    CM->>Spec: evaluate(context)
    Spec-->>CM: EvaluationResult

    alt non-payable
        CM-->>Claimer: claim rejected
    else payable
        CM->>PF: getUSDValue(payoutToken, requestedAmount)
        PF-->>CM: slashAmountUSD
        CM->>SLM: executeSlashing(policyId, operator, slashAmountUSD)
        SLM-->>CM: collateralTokens[], collateralAmounts[]
        loop each collateral token
            alt token == payoutToken
                CM->>Beneficiary: transfer payout token
            else token != payoutToken
                CM->>SW: executeSwap(tokenIn -> payoutToken)
                SW-->>CM: payoutToken amountOut
                CM->>Beneficiary: transfer payout token
            end
        end
    end
```

### Withdrawal (No Shortfall / Happy Path)

```mermaid
sequenceDiagram
    participant User
    participant CV as Covered Vault
    participant ADP as Catalysis Cover Adapter
    participant BV as Base Vault

    User->>CV: redeem/withdraw
    CV->>ADP: deallocate(amount)
    ADP->>BV: deallocate(amount)
    BV-->>ADP: assets_received
    ADP->>ADP: compare assets_received vs covered reference
    Note over ADP: assets_received >= assets_deposited
    ADP-->>CV: transfer assets
    CV-->>User: transfer assets
```

### Withdrawal (With Shortfall / Claim Path)

```mermaid
sequenceDiagram
    participant User
    participant CV as Covered Vault
    participant ADP as Catalysis Cover Adapter
    participant BV as Base Vault
    participant CM as ClaimManager

    User->>CV: redeem/withdraw
    CV->>ADP: deallocate(amount)
    ADP->>BV: deallocate(amount)
    BV-->>ADP: assets_received
    ADP->>ADP: detect shortfall
    Note over ADP: assets_received < assets_deposited
    ADP->>CM: fileClaim(policyId, shortfallAmount, evidenceHash, data)
    CM-->>ADP: payout assets (if payable)
    ADP-->>CV: transfer assets_received + payout
    CV-->>User: transfer assets
```

Function naming note:

- external docs may refer to `fileAndResolveClaim(...)`,
- current Coverage implementation uses `ClaimManager.fileClaim(...)`, which performs file + resolve atomically.
- for adapter-based make-whole flows, `payoutToken` is typically set to the base-vault underlying token.

## Coverage and Payout Controls

### Remaining Coverage Accounting

For each policy:

- requested claim must be <= current remaining coverage,
- actual payout updates cumulative paid-out amount,
- remaining coverage never drops below zero.

### Claim Window

Claims are accepted only while policy is active:

- `startTime <= now <= maturityTime`.

### Approval Gate

Claim payout path is entered only if `ISpec.evaluate(context).isPayable == true`.

### Evidence Hash

Every call to `fileClaim` must supply a non-zero `evidenceHash` that is unique per policy. The
`ClaimManager` maintains a per-policy set of consumed hashes and reverts with `DuplicateEvidenceHash`
if the same hash is reused, whether the original claim was approved or rejected. This ensures each
claim references distinct evidence and supports post-claim auditing.

Callers should supply a hash that identifies a retrievable evidence document, such as an IPFS CID
digest (`keccak256` of the CID multihash bytes), to enable off-chain verification.

## Collateral Conversion Rules

In `_processCollateral(...)`:

- If collateral already equals payout token:
  - transfer directly up to remaining payout target.
- Else:
  - approve `Swapper`,
  - execute configured route,
  - cap delivered amount to remaining payout target,
  - clear approval.

This supports heterogeneous slash collateral while preserving payout-token settlement.

## Swapper Configuration for Cross-Token Payouts

When the vault collateral token differs from the policy `payoutToken`, a swap route must be
configured in the `Swapper` before any claim can be paid out. The `UniswapV3Adapter` bridges
the Swapper's static-calldata model to Uniswap V3.

**One-time setup per `(tokenIn, tokenOut)` pair:**

```bash
forge script script/DeployUniswapV3Adapter.s.sol \
  --rpc-url $RPC_URL --broadcast --slow -vvvv
```

Required env vars:

| Variable | Description |
|----------|-------------|
| `PRIVATE_KEY` | Admin key holding `SWAP_MANAGER_ROLE` on Swapper |
| `SWAPPER` | Swapper proxy address (from `ClaimManager.swapper()`) |
| `SWAP_ROUTER` | Uniswap V3 SwapRouter02 (Sepolia: `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E`) |
| `TOKEN_IN` | Collateral token (e.g. Uniswap-native WETH on Sepolia: `0xfff9976782d46cc05630d1f6ebab18b2324d6b14`) |
| `TOKEN_OUT` | Payout token (e.g. Circle Sepolia USDC: `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`) |
| `POOL_FEE` | Uniswap V3 fee tier (e.g. `3000` = 0.3%, `500` = 0.05%) |

The script deploys the adapter, whitelists it in Swapper, and registers the route in a single
transaction.

**Verify before filing a claim:**

`FileClaim.s.sol` Phase 2 (Swapper Readiness) automatically checks each committee vault's
collateral token against the policy payout token and validates that a route is configured and the
target is whitelisted. It reverts before broadcasting if any route is missing.

## Risk and Operations

### Configuration Risks

- Missing or bad swap routes can impair payout conversion for non-payout collateral.
- Incorrect fee settings can over-route or under-route premium shares.
- Wrong vault registration in `PremiumCollector` can mis-route policy rewards.

### Runtime Risks

- If Core slashing returns no collateral, payout path reverts.
- If price conversion fails, slash target cannot be computed.
- Claim timing outside coverage window always reverts.

### Operational Controls

- Keep claim swap routes and whitelisted targets maintained ahead of incidents.
- Monitor `PremiumDistributed`, `ClaimFiled`, `ClaimApproved`, `ClaimRejected`, `CollateralSwapped`.
- Validate policy-to-vault mappings before policy activation.

## Migration Flow (Base Vault -> Covered Vault)

For existing base-vault users opting into insurance:

1. User calls a migrator contract.
2. Migrator redeems user position from base vault to underlying asset.
3. Migrator deposits underlying into covered vault on behalf of user.
4. Covered vault mints covered shares to user.

This migration is an integration-layer flow and usually implemented outside Coverage core contracts.

## Practical Testing Coverage

The scripts in `script/testing/` map directly to this document:

- `DistributePremium.s.sol` validates premium distribution path.
- `FileClaim.s.sol` validates claim evaluation and payout path.
- `CompleteCoverageFlow.s.sol` exercises both paths in sequence.

## Next Steps

- [Covered Vault Integration](./07-covered-vault-integration.md)
- [System Overview](./01-system-overview.md)
- [Policy Lifecycle](./05-policy-lifecycle.md)
