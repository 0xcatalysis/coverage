# Design Context — Catalysis Coverage Protocol

## Protocol Purpose

Catalysis Coverage is an on-chain risk coverage infrastructure for institutional DeFi. It transforms restaked assets (ETH, BTC, SOL via EigenLayer, Symbiotic, SatLayer) into programmable protection for lending markets, stablecoins, structured yield desks, and real-world credit exposures.

The smart contracts back Catalysis Core and its CoverPool marketplace, providing on-chain rails for:
- **Premium intake** — continuous per-second premium accrual on depositor principal
- **Underwriting logic** — curator-controlled pools with EIP-712 signed quotes
- **Claims execution** — parametric claim evaluation, committee slashing, collateral conversion, and beneficiary payout

## Architecture Overview

### Core Coverage Contracts (7 + 1 implementation for cloning)

| Contract | Pattern | Description |
|----------|---------|-------------|
| **CoverPool** | Minimal proxy clone | Curator-controlled pool; quote validation (EIP-712), policy binding, fee settings |
| **CoverPoolFactory** | UUPS proxy | Deploys and tracks CoverPool clones; deterministic CREATE2 |
| **PolicyManager** | UUPS proxy | Policy draft + bound lifecycle; coordinates premium collection; mints Policy NFTs |
| **PremiumCollector** | UUPS proxy | Collects ERC-4626 vault shares; periodic batch redeem + distribute |
| **PremiumManager** | UUPS proxy | Fee splitting (platform/pool/restaker); reward routing to Core RewardsManager |
| **ClaimManager** | UUPS proxy | File-and-resolve claims atomically; spec evaluation; slashing; collateral swap; payout |
| **SpecRegistry** | UUPS proxy | Immutable (pool, specId) -> ISpec mapping; admin-controlled spec approval whitelist |
| **Swapper** | UUPS proxy | Controlled token conversion for claim collateral via whitelisted DEX routes |

### CoveredVaultWrapper (Morpho Integration)

| Contract | Pattern | Description |
|----------|---------|-------------|
| **CoveredVaultWrapper** | UUPS proxy (ERC-4626) | User-facing insured vault wrapping Morpho V2; per-user principal tracking; premium accrual; insurance claim on withdrawal shortfall |
| **CoveredVaultAdmin** | Abstract (inherited) | Timelocked parameter setters, UUPS upgrade governance, Morpho gate, rescue |
| **CoveredVaultAccrual** | Abstract (inherited) | Premium accrual engine using reward-per-token accumulator pattern |
| **CoveredVaultStorage** | Abstract (inherited) | Constants, storage layout, errors, structs |
| **BasePolicyInteractions** | Abstract (inherited) | Base for interacting with PolicyManager and ClaimManager |

### Adapter

| Contract | Pattern | Description |
|----------|---------|-------------|
| **UniswapV3Adapter** | Immutable (Ownable2Step) | Bridges Swapper's static-calldata model to Uniswap V3 SwapRouter02; implements IQuotableAdapter for DEX-based quoting via QuoterV2 |

### Inheritance Chain (CoveredVaultWrapper)

```
CoveredVaultStorage (constants + storage + errors)
  └─ CoveredVaultAccrual (premium accrual engine)
       └─ CoveredVaultAdmin (timelocked setters, upgrade governance, Morpho gate)
            └─ CoveredVaultWrapper (ERC-4626 overrides, policy binding, insurance internals, views)
```

CoveredVaultStorage inherits from: ICoveredVaultWrapper, ERC4626Upgradeable, Ownable2StepUpgradeable, BasePolicyInteractions, UUPSUpgradeable, ReentrancyGuardTransient

## Vault Architecture

```
User → CoveredVaultWrapper (ERC-4626, UUPS proxy)
         → Morpho V2 vault (fees=0, sole depositor=wrapper)
             → MorphoVaultV1Adapter (off-the-shelf)
                 → Underlying ERC-4626 yield source
```

Key properties:
- Shares are **soulbound** (non-transferable) — only mints and burns permitted
- Premium accrues on **totalPrincipal** (cost basis), NOT on yield — users don't pay premium on gains
- Per-user **principal** tracked in `userPrincipal[user]`
- Per-user **Morpho shares** tracked in `userMorphoShares[user]`
- `totalAssets() = morphoValue - totalPremiumLiability - accruedPremium` (floored at 0)
- Insurance is paid directly to receiver on withdrawal, not via share price
- `depositCap = coverageLimit * BPS_DENOMINATOR / maxCoverableLossBps`

## Key Invariants

### Accounting Invariants
1. `totalPremiumLiability <= morphoValue` (enforced by `_liabilityHeadroom` cap on each accrual)
2. `totalAssets() >= 0` (consequence of invariant 1; floored at 0)
3. `sum(userPrincipal) == totalPrincipal` (maintained by deposit/withdraw accounting)
4. New depositors do not inherit pre-existing premium (via `userPremiumDebt` offset at deposit)
5. Premium stops accruing when liability headroom is exhausted (catastrophic loss protection)

### Transfer Invariant
6. Share transfers between non-zero addresses revert (`TransfersDisabled`)

### Policy Invariants
7. `policyId == committeeId` across all cross-layer calls (Coverage <-> Core)
8. One draft -> one bound policy metadata record
9. Cumulative payouts per policy cannot exceed `coverageLimit`
10. Claims accepted only within `[startTime, maturityTime]` (extended by `gateGracePeriod`)

### Premium Invariants
11. Premium accrues only during active policy window (via `_activeElapsedFrom`)
12. Premium accrual paused when `morphoGateActive` is true
13. `premiumRatePerSecond <= MAX_PREMIUM_RATE_PER_SECOND` (~50% APR)

### Insurance Invariants
14. `insuredBasis = principal - premiumForWithdrawal` (not uncappedPremium — deep-loss guard)
15. Insurance payout = `min(shortfall, maxCoverableLossBps * basis) - deductibleBps * basis` (floored at 0)
16. `deductibleBps < maxCoverableLossBps` (enforced at init and parameter changes)

## Trust Assumption Table

| # | Actor | Trust Level | Assumption | Source |
|---|-------|-------------|------------|--------|
| 1 | **DEFAULT_ADMIN_ROLE** (all UUPS proxies: PolicyManager, ClaimManager, PremiumManager, PremiumCollector, SpecRegistry, Swapper, CoverPoolFactory) | FULLY_TRUSTED | Can upgrade implementations, pause/unpause, set critical contract addresses (stakeManager, claimManager, etc.), recover tokens, configure fee parameters. Complete control over protocol operation. | AccessControlUpgradeable + UUPS pattern; README env vars show deployer = admin |
| 2 | **CoverPool Curator** (DEFAULT_ADMIN_ROLE on each CoverPool clone) | SEMI_TRUSTED(bounds: pool-scoped operations, 24h admin transfer delay) | Can bind policies, set pool fees (max 20%), set fee recipient, grant/revoke QUOTE_SIGNER_ROLE, pause/unpause pool, set premium defaulted status. Cannot affect other pools. | CoverPool.sol AccessControlDefaultAdminRulesUpgradeable; `_MAX_POOL_FEE_BPS = 2000` |
| 3 | **CoveredVaultWrapper Owner** | SEMI_TRUSTED(bounds: timelocked parameter changes) | Can change premiumRate (2h delay), maxCoverableLossBps (2d delay), deductibleBps (2d delay), premiumRecipient (2d delay), propose upgrades (7d delay), toggle Morpho gate, rescue tokens. Rate capped at MAX_PREMIUM_RATE_PER_SECOND. Cannot renounce ownership. | CoveredVaultAdmin.sol; Ownable2StepUpgradeable; timelocked propose/execute pattern |
| 4 | **QUOTE_SIGNER_ROLE** (per CoverPool) | SEMI_TRUSTED(bounds: quote signing only) | Signs EIP-712 quotes that define coverage terms (limit, premium, window, spec). A compromised signer could sign unfavorable quotes but cannot bind policies (requires curator). | CoverPool.sol `_verifyQuote` |
| 5 | **PREMIUM_COLLECTOR_ROLE** (PremiumManager) | SEMI_TRUSTED(bounds: can only trigger distribution of collected premiums) | Can call `distributePremium()` which splits and routes already-collected premiums. Cannot extract funds beyond the fee split logic. | PremiumManager.sol |
| 6 | **SWAP_MANAGER_ROLE** (Swapper) | SEMI_TRUSTED(bounds: route configuration only) | Can set swap routes and whitelist swap targets. Malicious routes could redirect collateral during claims. | Swapper.sol |
| 7 | **SWAP_EXECUTOR_ROLE** (Swapper, held by ClaimManager) | PRECONDITION | Can execute swaps. Only ClaimManager should hold this role. | Swapper.sol |
| 8 | **Morpho V2 Vault** | SEMI_TRUSTED(bounds: external dependency) | Expected to have fees=0 and wrapper as sole depositor. `convertToAssets()`, `balanceOf()`, `deposit()`, `redeem()` must be correct. Gate mechanism may block redemptions. | IVaultV2.sol; deployment script abdicates fee setters |
| 9 | **ClaimManager** (from CoveredVaultWrapper perspective) | SEMI_TRUSTED(bounds: claim evaluation and payout) | `fileClaim()` is wrapped in try/catch — if ClaimManager is paused or unavailable, withdrawal proceeds without insurance (emergency path). Approval gate (`_claimApprovalRequired`) requires curator approval after each successful claim. | CoveredVaultWrapper.sol `_claimInsurance`; ClaimManager.sol |
| 10 | **PolicyManager** | SEMI_TRUSTED(bounds: policy lifecycle) | Provides policy metadata for `_isPolicyActive()` checks. If metadata is incorrect, premium accrual and insurance eligibility may be wrong. | CoveredVaultAccrual.sol, BasePolicyInteractions.sol |
| 11 | **ChainlinkPriceFeed** | SEMI_TRUSTED(bounds: USD price conversion at bind time only) | Used only at `PolicyManager.bindPolicy()` for stake sufficiency check. Stale/missing feed causes bind revert. Not used at claim time. | PolicyManager.sol L266-274 |
| 12 | **UniswapV3 / DEX** | UNTRUSTED | Swaps go through whitelisted adapters with slippage protection (`maxSwapSlippageBps`, `amountOutMinimum`). Quote failures handled gracefully (try/catch, returns 0). | ClaimManager.sol, Swapper.sol, UniswapV3Adapter.sol |
| 13 | **Depositors (Users)** | UNTRUSTED | Can deposit/withdraw within caps. Cannot transfer shares. Insurance claims are automatic on withdrawal shortfall. | CoveredVaultWrapper.sol |
| 14 | **SpecRegistry Admin** | FULLY_TRUSTED | Controls which ISpec implementations can be registered (`approveSpec`/`revokeSpec`). Revocation does not affect in-flight claims (resolveSpec is not gated by approval status). | SpecRegistry.sol |
| 15 | **CoverPool Curator (setPremiumDefaulted)** | SEMI_TRUSTED(bounds: can block claims for defaulted policies) | Curator can mark a policy as premium-defaulted, which blocks all future claims for that policy. This is a powerful capability. | CoverPool.sol `setPremiumDefaulted`; ClaimManager.sol L297 |

## External Dependencies

### From Catalysis Core (not in this repo)
- **StakeManager** — committee creation, vault binding, stake reads
- **RewardsManager** — reward fan-out trigger for premium distribution
- **SlashingManager** — committee slashing preview and execution for claim payouts
- **ChainlinkPriceFeed** — USD price conversion for bind-time stake sufficiency
- **SSPRouter** — pulls restaker share from PremiumManager via pre-set approval

### Third-party
- **Morpho V2 Vault** — underlying ERC-4626 yield source wrapper
- **MorphoVaultV1Adapter** — off-the-shelf adapter connecting Morpho V2 to underlying ERC-4626
- **UniswapV3 SwapRouter02** — DEX for collateral conversion during claims
  - Sepolia: `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E`
  - Mainnet: `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45`
- **UniswapV3 QuoterV2** — for swap quoting
- **EigenLayer** — restaking infrastructure (DelegationManager, StrategyManager, AllocationManager)
- **Symbiotic** — alternative restaking infrastructure
- **OpenZeppelin Contracts** — ERC-4626, AccessControl, UUPS, Pausable, ReentrancyGuard, SafeERC20
- **Solady** — EfficientHashLib (used in CoverPool quote hashing)

## Roles Summary

| Role | Contract | Holders | Capabilities |
|------|----------|---------|-------------|
| DEFAULT_ADMIN_ROLE | PolicyManager, ClaimManager, PremiumManager, PremiumCollector, SpecRegistry, Swapper, CoverPoolFactory | Protocol admin | Upgrade, pause, configure dependencies, recover tokens |
| DEFAULT_ADMIN_ROLE | CoverPool (per clone) | Curator | Bind policies, manage pool fees, manage roles, pause pool |
| QUOTE_SIGNER_ROLE | CoverPool | Designated signer(s) | Sign EIP-712 coverage quotes |
| PREMIUM_COLLECTOR_ROLE | PremiumManager | PremiumCollector | Trigger premium distribution |
| SWAP_MANAGER_ROLE | Swapper | Admin/operator | Configure swap routes and whitelist targets |
| SWAP_EXECUTOR_ROLE | Swapper | ClaimManager | Execute swaps during claim settlement |
| CREATOR_ROLE | CoverPoolFactory | Designated creator | Create new CoverPool clones |
| Owner | CoveredVaultWrapper | Catalysis admin | Timelocked parameter changes, Morpho gate, upgrade governance |

## Policy Lifecycle

1. **Request** (`PolicyManager.requestCoverage`) — buyer creates draft; committee created in Core with `committeeId = policyId`
2. **Restaker Deposit** — restakers deposit collateral into EigenLayer duration vaults (auto-deployed)
3. **Bind** (`CoverPool.bindPolicyForRequest` -> `PolicyManager.bindPolicy`) — curator binds with signed quote; spec registered; vaults bound; stake sufficiency checked (USD); `onPolicyBound` callback sets `depositCap`
4. **Active Coverage** — claims accepted during `[startTime, maturityTime + gateGracePeriod]`
5. **Claim** (`ClaimManager.fileClaim`) — spec evaluation -> if payable: slash committee -> swap collateral -> payout to beneficiary

## Withdrawal Flow (CoveredVaultWrapper)

1. `_accruePremium()` — checkpoint premium liability
2. Compute `userPrincipalForWithdrawal` (pro-rata of owner's principal based on shares)
3. `_computeOwedAmounts()` — reward-per-token formula for premium
4. Compute Morpho redeem shares (pro-rata of user's Morpho shares)
5. At final withdrawal: cap redeem shares to actual balance (dust guard)
6. Burn wrapper shares, update debts BEFORE claim
7. `Morpho.redeem()` → get underlying assets
8. `_settleWithdrawalTransfer()`:
   - Cap premium at `assetsReceived` (deep-loss guard)
   - Compute `insuredBasis = principal - premiumForWithdrawal`
   - Compute `netAssetsReceived = assetsReceived - premiumForWithdrawal`
   - If `insuredBasis > netAssetsReceived` AND policy active: compute insurance
   - `_capAndApplyDeductible(shortfall, basis)`: cap at `maxCoverableLossBps`, subtract `deductibleBps`
   - `_claimInsurance()` → `ClaimManager.fileClaim()` (try/catch for availability)
   - Transfer `netAssets + insurancePayout` to receiver
9. `pendingPremium += premiumForWithdrawal`
10. `totalPremiumLiability -= premiumForWithdrawal`
11. `totalPrincipal -= userPrincipalForWithdrawal`

## Timelock Configuration (CoveredVaultWrapper)

| Parameter | Delay | Rationale |
|-----------|-------|-----------|
| UUPS upgrade | 7 days | Full logic replacement; maximum user notice |
| maxCoverableLossBps | 2 days | Coverage term change |
| deductibleBps | 2 days | Coverage term change |
| premiumRecipient | 2 days | Coverage term change |
| premiumRatePerSecond | 2 hours | Operational — rate cap limits per-hour damage; fast Morpho stress response |

## Claim Approval Gate

After each successful claim payout in ClaimManager, `_claimApprovalRequired[policyId]` is set to `true`. The CoverPool curator must call `approveNextClaim(policyId)` to re-enable claims for that policy. This prevents rapid serial claiming.

## Morpho Gate Mechanism

When Morpho vault blocks redemptions (gate active):
1. Owner activates `morphoGateActive` — premium accrual pauses; timestamp recorded
2. `_morphoValue()` falls back to `lastKnownMorphoValue` (cached)
3. When gate lifted: `gateGracePeriod += gateDuration` — extends policy maturity by the gate overlap duration
4. Premium accrual resumes with no catch-up for the gated period

## Notable Design Patterns

1. **Reward-per-token accumulator** — `cumulativePremiumPerUnit` for fair pro-rata premium allocation across users who enter at different times
2. **Deep-loss guard** — premium capped at `assetsReceived` from Morpho; uncollected premium is "forgiven"
3. **Transient storage** — `PENDING_CLAIM_AMOUNT_SLOT`, `ACTUAL_OUT_SLOT`, `SKIP_INSURANCE_SLOT` for intra-transaction state
4. **Decimal offset** — `_decimalsOffset() = 6` for inflation attack protection (10^6 virtual shares)
5. **Soulbound shares** — prevents cost-basis manipulation via transfer
6. **Emergency exit** — `emergencyRedeem`/`emergencyWithdraw` bypass insurance (ClaimManager dependency) but not Morpho gate
7. **Try/catch resilience** — ClaimManager unavailability does not block withdrawals; Morpho `convertToAssets` failures fall back to cached value
