# Coverage Smart Contracts

[![CI](https://github.com/0xcatalysis/coverage/actions/workflows/ci.yml/badge.svg)](https://github.com/0xcatalysis/coverage/actions/workflows/ci.yml)

Coverage is the onchain risk coverage infrastructure for institutional DeFi. It transforms restaked ETH, BTC, SOL, and other assets into programmable protection for lending markets, stablecoins, structured yield desks, and other credit exposures. The smart contracts in this repository back Catalysis Core and its CoverPool marketplace, providing the onchain rails for premium intake, underwriting logic, and claims execution.

## Overview

- **Institution-first design:** Contracts and deployment flows mirror a compliance-ready CoverPool framework so curators can underwrite institutional credit without building bespoke infra.
- **Shared security abstraction:** Catalysis Core standardises delegations across EigenLayer, Symbiotic, SatLayer, and other restaking networks, turning slashable collateral into uniform coverage capacity.
- **CoverPool marketplace:** Each pool isolates risk, pricing logic, and claim adjudication, letting specialist curators issue tailored policies while keeping capital composable.
- **Programmable operations:** Premium routing, leverage limits, and slashing hooks are enforced entirely onchain, enabling fast, objective payouts and consistent accounting.

## Architecture

### Core Contracts

Seven contracts deployed as UUPS proxies, plus one implementation for pool cloning:

| Contract | Description |
|----------|-------------|
| `CoverPool` | Curator-controlled pool handling quote validation and policy binding. Deployed as minimal proxy clones via `CoverPoolFactory`. |
| `CoverPoolFactory` | Creates and registers `CoverPool` clones; assigns default `PolicyManager` role to each pool. |
| `PolicyManager` | Entrypoint for policy binding; coordinates premium collection and mints Policy NFTs. |
| `PremiumManager` | Collects premiums from policy buyers and routes fees to pool curators and the platform treasury. |
| `ClaimManager` | Processes parametric and discretionary claims; orchestrates slashing and payout distribution. |
| `Swapper` | Converts slashed collateral tokens via configured swap routes before payout. |
| `SpecRegistry` | Registry mapping `(pool, specId)` pairs to `ISpec` evaluation implementations. |

External dependencies from Catalysis Core:

| Dependency | Description |
|------------|-------------|
| `SlashingManager` | Collateral slashing execution across restaking networks. |
| `StakeManager` | Manages restaker stake and delegation. |
| `RewardsManager` | Distributes rewards to restakers. |
| `SSPRouter` | Routes shared security provider interactions. |
| `ChainlinkPriceFeed` | Converts token amounts to USD values for slashing calculations. |

### Swappers (`src/swappers/`)

| Contract | Description |
|----------|-------------|
| `UniswapV3Adapter` | Bridges the `Swapper`'s static-calldata pattern to Uniswap V3 `SwapRouter02`; deployed as `swapTarget` when collateral must be swapped to the payout token. |

### DeFi Integration Layer (`src/defi/`)

A standalone ERC-4626 wrapper stack that provides automatic insurance coverage to depositors in Morpho vaults:

| Contract | Description |
|----------|-------------|
| `CoveredVaultWrapper` | UUPS ERC-4626 vault wrapping a Morpho V2 vault. Accrues premiums continuously against depositor principal, files parametric insurance claims on withdrawal if NAV has fallen. Shares are non-transferable. |
| `BasePolicyInteractions` | Shared base for filing and resolving claims against a bound Catalysis policy. |

See [`docs/COVERED_VAULT_ACCOUNTING.md`](docs/COVERED_VAULT_ACCOUNTING.md) for the full accounting and liability model.

### Mocks (`src/mocks/`)

| Contract | Description |
|----------|-------------|
| `MockSpec` | Configurable claim evaluation; auto-approves by default. Used for testnet deployments. |
| `MockSpecRegistry` | Registry mapping pools to Spec implementations with a default fallback. |

## Quick Start

```bash
git clone https://github.com/0xcatalysis/coverage.git
cd coverage

make setup        # install Foundry deps and add pre-commit hooks
cp .env.example .env

make build
make test
```

## Development

```bash
make setup                  # install pre-commit hook (forge fmt --check + test-unit)
make build                  # compile with default profile (200 optimizer runs)
make build-prod             # compile with production profile (1000 optimizer runs, via-ir)
make test                   # unit + fuzz + invariant suites (-vvv --fail-fast)
make test-unit              # unit tests only
make test-fuzz              # fuzz tests only
make test-invariant         # invariant tests only
make test-ci                # full suite with CI profile (higher fuzz/invariant runs)
make gas                    # gas report (production profile)
make cover                  # summary coverage report
make cover-lcov             # LCOV + HTML artifacts (requires genhtml)
make format                 # enforce forge fmt style
make format-check           # check formatting without modifying files
make lint                   # forge lint with configured exclusions
make docs                   # regenerate NatSpec docs into docs/
make snapshot               # capture gas snapshot baseline
make snapshot-check         # verify gas usage against baseline
make slither                # static analysis
make mythril                # symbolic analysis
make clean                  # remove build artifacts, broadcasts, and coverage files
make help                   # list all targets
```

## Deployment

All deployment scripts extend `Deploy.s.sol`, which handles contract deployment in dependency order, cross-contract role configuration, and result logging.

```bash
make deploy-anvil            # local Anvil deployment
make deploy-sepolia          # Sepolia testnet deployment
make deploy-ethereum         # mainnet deployment

make show-sepolia            # inspect last Sepolia deployment metadata
make show-ethereum           # inspect last Ethereum deployment metadata

make verify-sepolia          # verify all contracts on Sepolia Etherscan
make verify-ethereum         # verify all contracts on Ethereum Etherscan
```

### Upgrade Scripts

Each core UUPS proxy has a dedicated upgrade script pair (`UpgradeX.s.sol` + `UpgradeXSepolia.s.sol`):

- `UpgradeCoverPoolFactory` / `UpgradePolicyManager` / `UpgradePremiumManager`
- `UpgradeClaimManager` / `UpgradeSwapper` / `UpgradeSpecRegistry`

### Post-Deployment Scripts

| Script | Description |
|--------|-------------|
| `WireCoreContracts.s.sol` | Grants cross-contract roles between Coverage and Catalysis Core contracts. |
| `ApproveSpec.s.sol` | Registers a `Spec` implementation in `SpecRegistry` for a given pool. |
| `VerifySepoliaConfig.s.sol` | Reads and logs all on-chain configuration for a Sepolia deployment. |

### DeFi Adapter Scripts (`script/adapter/`)

| Script | Description |
|--------|-------------|
| `DeployCoveredVaultWrapper.s.sol` | Deploys a `CoveredVaultWrapper` UUPS proxy wrapping a target Morpho vault. |
| `UpgradeCoveredVaultWrapper.s.sol` | Upgrades an existing `CoveredVaultWrapper` proxy to a new implementation. |

### Testing Scripts (`script/testing/`)

Step-by-step scripts that exercise the full coverage lifecycle:

| Script | Description |
|--------|-------------|
| `CreateCoverPool.s.sol` | Creates a `CoverPool` via `CoverPoolFactory`. |
| `RequestCoverage.s.sol` | Requests coverage and creates a policy draft and committee. |
| `BindPolicy.s.sol` | Signs quote, binds policy, associates vaults. |
| `DistributePremium.s.sol` | Collects and distributes premiums from vault shares. |
| `FileClaim.s.sol` | Files a claim; includes Swapper readiness checks and post-claim swap metrics. |
| `SetPremiumRate.s.sol` | Sets the per-second premium rate on a `CoveredVaultWrapper`. |
| `ResetPolicyBinding.s.sol` | Resets policy binding state on a `CoveredVaultWrapper`. |
| `PrepareEigenLayer.s.sol` | Configures EigenLayer magnitude allocation for an operator. |
| `DeployControllableVault.s.sol` | Deploys a test ERC-4626 vault with controllable NAV. |
| `DeployUniswapV3Adapter.s.sol` | Deploys and registers a `UniswapV3Adapter` swap route. |
| `CompleteCoverageFlow.s.sol` | End-to-end lifecycle from pool creation through claim settlement. |

## Environment Variables

See [`.env.example`](.env.example) for all variables with inline documentation. Key groups:

**Network & tooling** — `PRIVATE_KEY`, `SEPOLIA_RPC_URL`, `ETHEREUM_RPC_URL`, `ETHERSCAN_API_KEY`

**Catalysis Core addresses** (required for `Deploy.s.sol`):

| Variable | Description |
|----------|-------------|
| `CHAINLINK_PRICE_FEED` | ChainlinkPriceFeed contract |
| `SLASHING_MANAGER` | SlashingManager from Catalysis Core |
| `STAKE_MANAGER` | StakeManager from Catalysis Core |
| `REWARDS_MANAGER` | RewardsManager from Catalysis Core |
| `SSP_ROUTER` | SSPRouter from Catalysis Core |

**Role overrides** (all default to deployer/admin):

| Variable | Description |
|----------|-------------|
| `ADMIN` | `DEFAULT_ADMIN_ROLE` holder |
| `PLATFORM_TREASURY` | Platform fee recipient |
| `COVER_POOL_FACTORY_CREATOR` | `CREATOR_ROLE` on `CoverPoolFactory` |
| `SWAP_MANAGER` | `SWAP_MANAGER_ROLE` on `Swapper` |
| `PLATFORM_FEE_BPS` | Platform fee in basis points (default 500 = 5%) |

## License

The smart contracts are released under the Business Source License 1.1 (`BUSL-1.1`).
