# Coverage Smart Contracts

[![CI](https://github.com/0xcatalysis/coverage/actions/workflows/ci.yml/badge.svg)](https://github.com/0xcatalysis/coverage/actions/workflows/ci.yml)

Coverage is the onchain risk coverage infrastructure for institutional DeFi. It transforms the $20B+ of restaked ETH, BTC, SOL and other assets into programmable protection for lending markets, stablecoins, structured yield desks, and other real-world credit exposures. The smart contracts in this repository back Catalysis Core and its CoverPool marketplace, providing the onchain rails for premium intake, underwriting logic, and claims execution.

## Overview

- **Institution-first design:** Contracts and deployment flows mirror the PRD’s compliance-ready CoverPool framework so curators can underwrite institutional credit without building bespoke infra.
- **Shared security abstraction:** Catalysis Core standardises delegations across EigenLayer, Symbiotic, SatLayer, and other restaking networks, turning slashable collateral into uniform coverage capacity.
- **CoverPool marketplace:** Each pool isolates risk, pricing logic, tranching, and claim adjudication, letting specialist curators issue tailored policies while keeping capital backing composable.
- **Programmable operations:** Premium routing, leverage limits, and slashing hooks are enforced entirely onchain, enabling fast, objective payouts and consistent accounting for restakers and buyers.

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
make setup          # installs pre-commit hook for format, unit tests, and gas snapshots
make test           # 3-path test harness (unit, fuzz, invariant) via match-path flags
make test-unit      # target only the unit-test suite while iterating
make test-fuzz      # target only the fuzz suite while iterating
make test-invariant # target only the invariant suite while iterating
make gas            # gas snapshot using the production Foundry profile
make cover          # summary coverage report
make cover-lcov     # LCOV + optional HTML artifacts
make format         # forge fmt with project style defaults
make docs           # regenerate NatSpec documentation
make snapshot       # refresh gas snapshot baseline for regression tracking
make slither        # optional static analysis coverage with Slither
make mythril        # optional symbolic analysis with Mythril
```

## Deployment

```bash
make deploy-anvil      # local iteration loop against anvil
make deploy-sepolia    # broadcast to Sepolia (needs PRIVATE_KEY + RPC env vars)
make deploy-ethereum   # mainnet-ready deployment with prod optimizer profile
make show-sepolia      # inspect last Sepolia broadcast metadata
make show-ethereum     # inspect last Ethereum broadcast metadata

# ensure SEPOLIA_RPC_URL, SEPOLIA_ETHERSCAN_API_KEY, ETHEREUM_RPC_URL, etc. are set in .env
make verify-coverpool-sepolia   # wraps forge verify-contract with Sepolia compiler settings
make verify-coverpool-ethereum  # wraps forge verify-contract with Ethereum compiler settings
```

## License

The smart contracts are released under the Business Source License 1.1 (`BUSL-1.1`).
