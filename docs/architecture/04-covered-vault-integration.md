# Covered Vault Integration (Morpho Adapter Model)

## Overview

This page documents the adapter-based Morpho integration pattern used for insured vaults.

Core idea:

- users choose between an uninsured base vault and an insured covered vault,
- the covered vault allocates through a Catalysis adapter,
- withdrawal-time shortfall is optionally repaired through Coverage claim payout.

## Components

### Covered Vault (Morpho V2)

- user-facing insured vault,
- accrues premium via management-fee-like mechanism,
- allocates to the adapter.

### CatalysisCoverAdapter

- Morpho adapter implementation,
- allocates/deallocates into the base vault,
- tracks reference accounting for shortfall detection,
- calls Coverage claim path on shortfall.

### Base Vault (Morpho V1/V2)

- underlying investment destination,
- may also serve uninsured users directly.

## Policy Actor Mapping for This Integration

Typical settings in `PolicyManager.requestCoverage(...)`:

- `buyer`: covered vault or adapter contract,
- `claimer`: adapter,
- `beneficiary`: adapter,
- `bindPolicyHook`: adapter.

Recommended token alignment:

- set policy `payoutToken` to the base-vault underlying asset (for direct make-whole transfer),
- otherwise adapter must convert payout token into the withdrawal asset before forwarding.

This allows the adapter to receive payout and complete atomic make-whole flow.

## Flow 1: Deposit

```mermaid
sequenceDiagram
    participant User
    participant CV as Covered Vault
    participant ADP as Cover Adapter
    participant BV as Base Vault

    User->>CV: deposit
    CV->>ADP: allocate
    ADP->>ADP: track principal/reference
    ADP->>BV: deposit
    BV-->>ADP: shares
    ADP-->>CV: accounting update
    CV-->>User: covered shares minted
```

## Flow 2: Withdrawal (No Shortfall)

```mermaid
sequenceDiagram
    participant User
    participant CV as Covered Vault
    participant ADP as Cover Adapter
    participant BV as Base Vault

    User->>CV: withdraw/redeem
    CV->>ADP: deallocate
    ADP->>BV: withdraw
    BV-->>ADP: assets_received
    ADP->>ADP: compare against covered reference
    Note over ADP: no shortfall
    ADP-->>CV: transfer assets
    CV-->>User: transfer assets
```

## Flow 3: Withdrawal (With Shortfall)

```mermaid
sequenceDiagram
    participant User
    participant CV as Covered Vault
    participant ADP as Cover Adapter
    participant BV as Base Vault
    participant CM as ClaimManager

    User->>CV: withdraw/redeem
    CV->>ADP: deallocate
    ADP->>BV: withdraw
    BV-->>ADP: assets_received
    ADP->>ADP: compute shortfall
    Note over ADP: shortfall = assets_deposited - assets_received
    ADP->>CM: fileClaim(policyId, shortfall, evidence, data)
    CM-->>ADP: payout (if approved)
    ADP-->>CV: transfer assets + payout
    CV-->>User: transfer assets
```

Notes:

- Some external docs call this `fileAndResolveClaim(...)`.
- In current Coverage contracts, `ClaimManager.fileClaim(...)` is atomic (file + resolve).

## Flow 4: Migration (Base -> Covered)

```mermaid
sequenceDiagram
    participant User
    participant M as Migrator
    participant BV as Base Vault
    participant CV as Covered Vault

    User->>M: migrate()
    M->>BV: redeem user position
    BV-->>M: underlying assets
    M->>CV: deposit on behalf of user
    CV-->>User: covered shares minted
```

## Coverage/Core Touchpoints in This Model

- policy request: `PolicyManager.requestCoverage(...)`,
- policy binding: `CoverPool.bindPolicyForRequest(...)`,
- premium routing: `PremiumCollector -> PremiumManager -> RewardsManager`,
- claim execution: `ClaimManager.fileClaim(...) -> SlashingManager.executeSlashing(...)`.

## Related Pages

- [System Overview](./01-system-overview.md)
- [Policy Lifecycle](./05-policy-lifecycle.md)
- [Premiums and Claims](./06-premiums-claims.md)
