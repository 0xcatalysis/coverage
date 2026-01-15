# Coverage Smart Contracts

[![CI](https://github.com/0xcatalysis/coverage/actions/workflows/ci.yml/badge.svg)](https://github.com/0xcatalysis/coverage/actions/workflows/ci.yml)

<!-- [![Wiki](https://github.com/0xcatalysis/coverage/actions/workflows/wiki.yml/badge.svg)](https://github.com/0xcatalysis/coverage/actions/workflows/wiki.yml) -->

Coverage is the onchain risk coverage infrastructure for institutional DeFi. It transforms the $20B+ of restaked ETH, BTC, SOL and other assets into programmable protection for lending markets, stablecoins, structured yield desks, and other real-world credit exposures. The smart contracts in this repository back Catalysis Core and its CoverPool marketplace, providing the onchain rails for premium intake, underwriting logic, and claims execution.

## Overview

- **Institution-first design:** Contracts and deployment flows mirror the PRD's compliance-ready CoverPool framework so curators can underwrite institutional credit without building bespoke infra.
- **Shared security abstraction:** Catalysis Core standardises delegations across EigenLayer, Symbiotic, SatLayer, and other restaking networks, turning slashable collateral into uniform coverage capacity.
- **CoverPool marketplace:** Each pool isolates risk, pricing logic, tranching, and claim adjudication, letting specialist curators issue tailored policies while keeping capital backing composable.
- **Programmable operations:** Premium routing, leverage limits, and slashing hooks are enforced entirely onchain, enabling fast, objective payouts and consistent accounting for restakers and buyers.

## Architecture

The Coverage protocol consists of seven core contracts deployed as UUPS proxies (plus one implementation for pool cloning):

| Contract | Description |
|----------|-------------|
| **CoverPool** | Curator-controlled pool handling quote validation and policy binding. Deployed as minimal proxy clones via CoverPoolFactory. |
| **CoverPoolFactory** | Creates and registers CoverPool clones; assigns default PolicyManager role to each pool. |
| **PolicyManager** | Entrypoint for policy binding; coordinates premium collection and mints Policy NFTs. |
| **Policy** | Soulbound ERC-721 representing bound coverage policies with canonical metadata. |
| **PremiumManager** | Collects premiums from policy buyers and routes fees to pool curators and the platform treasury. |
| **PremiumReserve** | Escrow vault holding restaker premiums; releases funds on maturity or locks for claim payouts. |
| **ClaimManager** | Processes parametric and discretionary claims; orchestrates slashing and payout distribution. |
| **Swapper** | Converts slashed collateral tokens via configured swap routes before payout. |

External dependencies from Catalysis Core:
- **SpecRegistry** – parametric spec definitions for claim triggers.
- **SlashingManager** – collateral slashing execution across restaking networks.
- **ChainlinkPriceFeed** – converts token amounts to USD values (8 decimals) for slashing calculations.

## Quick Start

```bash
git clone https://github.com/0xcatalysis/coverage.git
cd coverage

# install forge-based toolchain hooks and copy env template
make setup
cp .env.example .env

# compile and run the full suite
make build
make test
```

## Development

```bash
make setup                      # installs pre-commit hook for format checks and unit tests
make build                      # compile with default profile (200 optimizer runs)
make build-prod                 # compile with production profile (1000 optimizer runs, via-ir)
make test                       # 3-path test harness (unit, fuzz, invariant)
make test-unit                  # target only the unit-test suite while iterating
make test-fuzz                  # target only the fuzz suite while iterating
make test-invariant             # target only the invariant suite while iterating
make test-ci                    # run full suite with CI profile (higher fuzz/invariant runs)
make gas                        # gas report using the production profile
make cover                      # summary coverage report
make cover-lcov                 # LCOV + optional HTML artifacts (requires genhtml)
make format                     # forge fmt with project style defaults
make format-check               # check formatting without modifying files
make lint                       # run forge lint with configured exclusions
make docs                       # regenerate NatSpec documentation into docs/
make snapshot                   # capture gas snapshot baseline for regression tracking
make snapshot-check             # verify current gas usage against baseline
make slither                    # static analysis with Slither
make mythril                    # symbolic analysis with Mythril
make clean                      # remove build artifacts, localhost broadcasts, and coverage files
make help                       # show all available commands
```

## Deployment

All deployment scripts extend the shared `Deploy.s.sol` base which handles contract deployment, cross-contract role configuration, and logging.

```bash
make deploy-anvil                # local iteration loop against anvil
make deploy-specregistry-sepolia # deploy SpecRegistry mocks to Sepolia
make deploy-sepolia              # deploy Coverage contracts to Sepolia
make deploy-ethereum             # mainnet deployment with production optimizer profile

make show-sepolia                # inspect last Sepolia deployment metadata
make show-ethereum               # inspect last Ethereum deployment metadata

make verify-coverpool-sepolia    # verify CoverPool on Sepolia Etherscan
make verify-coverpool-ethereum   # verify CoverPool on Ethereum Etherscan
```

### Environment Variables

Required for testnet/mainnet deployments:

| Variable | Description |
|----------|-------------|
| `PRIVATE_KEY` | Deployer private key |
| `NATIVE_WRAPPER` | WETH or equivalent native wrapper address |
| `SPEC_REGISTRY` | SpecRegistry address |
| `SLASHING_MANAGER` | Catalysis Core SlashingManager address |
| `CHAINLINK_PRICE_FEED` | ChainlinkPriceFeed address |
| `STAKE_MANAGER` | Catalysis Core StakeManager address |
| `REWARDS_MANAGER` | Catalysis Core RewardsManager address |
| `SEPOLIA_RPC_URL` | Sepolia RPC endpoint |
| `ETHEREUM_RPC_URL` | Ethereum mainnet RPC endpoint |
| `SEPOLIA_ETHERSCAN_API_KEY` | Etherscan API key for Sepolia verification |
| `ETHERSCAN_API_KEY` | Etherscan API key for mainnet verification |

Optional role configuration (defaults to deployer/admin):

| Variable | Description |
|----------|-------------|
| `ADMIN` | DEFAULT_ADMIN_ROLE holder (defaults to deployer) |
| `PLATFORM_TREASURY` | Platform fee recipient |
| `COVER_POOL_FACTORY_CREATOR` | CREATOR_ROLE on CoverPoolFactory |
| `CLAIM_OPERATOR` | CLAIM_OPERATOR_ROLE on ClaimManager |
| `SWAP_MANAGER` | SWAP_MANAGER_ROLE on Swapper |

## License

The smart contracts are released under the Business Source License 1.1 (`BUSL-1.1`).
