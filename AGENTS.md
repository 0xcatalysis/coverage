# Repository Guidelines

## Agent Workflow & Best Practices

- The shell is already in the project root directory; run commands directly without `cd` prefixes.

## Project Structure & Module Organization

Coverage contracts live in `src/`. Tests in `test/unit`, `test/fuzz`, and `test/invariant` map to the same modules. Deployment scripts belong in `script/`, generated docs land in `docs/`, and `out/` stores build artifacts plus storage layouts. Shared settings stay in `foundry.toml` and `Makefile`; update those instead of copying flags locally.

### Core Contracts (`src/`)

| Contract | Purpose |
|----------|---------|
| `CoverPool.sol` | Curator-controlled pool for quote validation and policy binding; deployed as minimal proxy clones. |
| `CoverPoolFactory.sol` | Creates CoverPool clones and assigns PolicyManager role to each new pool. |
| `PolicyManager.sol` | Entrypoint for policy binding; coordinates premium collection and mints Policy NFTs. |
| `PremiumManager.sol` | Collects premiums and distributes fees to curators and platform treasury. |
| `ClaimManager.sol` | Processes parametric/discretionary claims; orchestrates slashing and payouts. |
| `Swapper.sol` | Converts slashed collateral via configured swap routes. |
| `SpecRegistry.sol` | Registry mapping `(pool, specId)` pairs to `ISpec` evaluation implementations. |

### Interfaces (`src/interfaces/`)

Interfaces mirror each core contract (`ICoverPool`, `IClaimManager`, etc.) plus external Catalysis Core dependencies (`ISpecRegistry`, `ISlashingManager`, `IRewardsManager`, `IChainlinkPriceFeed`, `IStakeManager`).

### Swappers (`src/swappers/`)

| Contract | Purpose |
|----------|---------|
| `UniswapV3Adapter.sol` | Bridges the Swapper's static-calldata pattern to Uniswap V3 SwapRouter02; deployed as `swapTarget` for Swapper routes when collateral must be swapped to payout token. |

### DeFi Integration Layer (`src/defi/`)

| Contract | Purpose |
|----------|---------|
| `adapters/morpho/CoveredVaultWrapper.sol` | UUPS ERC-4626 vault wrapping a Morpho V2 vault. Accrues premiums against depositor principal, files claims on withdrawal if NAV has fallen. Shares are non-transferable. |
| `base/BasePolicyInteractions.sol` | Shared base for filing and resolving claims against a bound Catalysis policy. |

### Mock Contracts (`src/mocks/`)

| Mock | Purpose |
|------|---------|
| `MockSpec.sol` | Configurable claim evaluation logic; auto-approves by default. |
| `MockSpecRegistry.sol` | Registry mapping pools to Spec implementations; supports default fallback. |

### Test Structure

- `test/unit/*.t.sol` – unit tests for each contract
- `test/fuzz/*.t.sol` – stateless fuzz tests
- `test/invariant/*.t.sol` – stateful invariant tests

### Deployment Scripts (`script/`)

**Initial Deployment:**
- `Deploy.s.sol` – shared base handling all deployment logic
- `DeployAnvil.s.sol` – local Anvil deployment
- `DeploySepolia.s.sol` – Sepolia deployment
- `DeployEthereum.s.sol` – mainnet deployment

**UUPS Upgrades** (shared base + Sepolia variant for each; CoverPoolFactory also has an Ethereum variant):
- `UpgradeCoverPoolFactory.s.sol`, `UpgradePolicyManager.s.sol`, `UpgradePremiumManager.s.sol`
- `UpgradeClaimManager.s.sol`, `UpgradeSwapper.s.sol`, `UpgradeSpecRegistry.s.sol`

**Post-Deployment:**
- `WireCoreContracts.s.sol` – grants cross-contract roles between Coverage and Catalysis Core contracts
- `ApproveSpec.s.sol` – registers a Spec implementation in SpecRegistry
- `DeployUniswapV3Adapter.s.sol` – deploys and registers a UniswapV3Adapter swap route
- `VerifySepoliaConfig.s.sol` – reads and logs all on-chain configuration for a Sepolia deployment
- `Show.s.sol`, `ShowSepolia.s.sol`, `ShowEthereum.s.sol` – inspect deployment metadata

**DeFi Adapter (`script/adapter/`):**
- `DeployCoveredVaultWrapper.s.sol` – deploys a CoveredVaultWrapper UUPS proxy
- `UpgradeCoveredVaultWrapper.s.sol` – upgrades an existing CoveredVaultWrapper proxy

**Testing Scripts (`script/testing/`):**
- `CreateCoverPool.s.sol` – creates a CoverPool via CoverPoolFactory
- `RequestCoverage.s.sol` – requests coverage, creates policy draft and committee
- `BindPolicy.s.sol` – signs quote, binds policy, associates vaults
- `DistributePremium.s.sol` – collects and distributes premiums from vault shares
- `FileClaim.s.sol` – files claim; includes Swapper readiness checks and post-claim swap metrics
- `SetPremiumRate.s.sol` – sets the per-second premium rate on a CoveredVaultWrapper
- `ResetPolicyBinding.s.sol` – resets policy binding state on a CoveredVaultWrapper
- `PrepareEigenLayer.s.sol` – configures EigenLayer magnitude allocation for an operator
- `DeployControllableVault.s.sol` – deploys a test ERC-4626 vault with controllable NAV
- `CompleteCoverageFlow.s.sol` – end-to-end lifecycle from pool creation through claim settlement
- `ForkCompleteCoverageFlow.s.sol` – extends CompleteCoverageFlow with EigenLayer vault-funding for fresh mainnet forks (used by `make test-fork`)

## Build, Test, and Development Commands

- `make setup` – install Foundry deps and add the `forge fmt --check` + `test-unit` pre-commit hook.
- `make build` / `make build-prod` – compile with the default or production optimizer profile.
- `make test`, `make test-unit`, `make test-fuzz`, `make test-invariant` – targeted suites (`-vvv --fail-fast`).
- `make test-ci` – full suite with CI profile (higher fuzz/invariant runs).
- `make gas`, `make cover`, `make cover-lcov` – gas, summary coverage, or LCOV + HTML reports.
- `make format` / `make format-check` – enforce the `forge fmt` style before committing.
- `make lint` – run `forge lint` with configured exclusions.
- `make docs` – regenerate NatSpec documentation into `docs/`.
- `make snapshot` / `make snapshot-check` – capture or verify gas baselines for regression tracking.
- `make slither`, `make mythril` – optional static and symbolic analysis passes mirroring CI.
- `make clean` – remove build artifacts, localhost broadcasts, and coverage files.
- `make help` – list all available Makefile targets.

## Coding Style & Naming Conventions

Formatting is enforced by `make format` (`forge fmt`) with 4-space indentation, 120-character lines, double-quoted strings, and long integer types. Contracts, interfaces and libraries use PascalCase (`Example`, `IExample`, `LExample` respectively). Follow the official [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html) for naming and layout; prefer descriptive camelCase function names, past-tense events, explicit `uint256`/`int256`, and NatSpec around tricky invariants.

## Testing Guidelines

Add `.t.sol` files alongside each feature in the appropriate `test` subfolder and prefix test methods with `test_<Scenario>()`. Keep fuzz seeds deterministic unless randomness is required; defaults sit in `foundry.toml`. Run `make test` before every PR and include `make gas` or `make cover` output when altering gas-sensitive logic. Generate `make cover-lcov` only when CI or auditors request HTML artifacts.

## Deployment Guidelines

All network deployments extend `Deploy.s.sol`. The base script deploys contracts in dependency order, configures cross-contract roles, then logs results.

### Required Environment Variables

**All deployments:**
- `PRIVATE_KEY` – deployer key
- Network-specific RPC: `SEPOLIA_RPC_URL`, `ETHEREUM_RPC_URL`
- Catalysis Core addresses: `NATIVE_WRAPPER`, `CHAINLINK_PRICE_FEED`, `SLASHING_MANAGER`, `STAKE_MANAGER`, `REWARDS_MANAGER`

**Optional role overrides** (default to deployer/admin):
- `ADMIN`, `PLATFORM_TREASURY`, `COVER_POOL_FACTORY_CREATOR`, `SWAP_MANAGER`, `PLATFORM_FEE_BPS`

## Commit & Pull Request Guidelines

Follow the conventional commit style seen in history (`feat:`, `fix:`, `refactor:`, `chore:`, `ci:`, `style:`, `perf:`, `doc:`) with subjects under 72 characters. Bundle contract edits with matching tests in the same commit. PRs should summarize intent, list touched contracts, attach relevant command output, and link issues or deployment plans. Add screenshots only when explorer states or dashboards change.

## Security & Configuration Tips

Never commit secrets; mirror new environment keys in `.env.example` instead. When updating upgradeable contracts, inspect `out/<Contract>.storageLayout.json` to confirm slot ordering. Check `foundry.toml` `fs_permissions` before broadcasting and surface required env vars in the PR body.
