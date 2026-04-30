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
| `PolicyManager.sol` | Entrypoint for policy request, binding, and cancellation lifecycle. |
| `PremiumManager.sol` | Receives premiums from vault collectors and distributes fees to curators, platform treasury, and restakers. |
| `ClaimManager.sol` | Processes parametric/discretionary claims; orchestrates slashing and payouts. |
| `Swapper.sol` | Converts slashed collateral via configured swap routes. |
| `SpecRegistry.sol` | Registry mapping `(pool, specId)` pairs to `ISpec` evaluation implementations. |

### Interfaces (`src/interfaces/`)

Interfaces mirror each core contract (`ICoverPool`, `IClaimManager`, `ISpecRegistry`, etc.) plus external Catalysis Core dependencies (`ISlashingManager`, `IRewardsManager`, `IChainlinkPriceFeed`, `IStakeManager`). Additional interfaces cover hook callbacks (`IBindPolicyHook`), swap adapter patterns (`IQuotableAdapter`, `IQuoterV2`), evaluation logic (`ISpec`), and token wrappers (`IWETH`).

### Swappers (`src/swappers/`)

| Contract | Purpose |
|----------|---------|
| `UniswapV3Adapter.sol` | Bridges the Swapper's static-calldata pattern to Uniswap V3 SwapRouter02; deployed as `swapTarget` for Swapper routes when collateral must be swapped to payout token. |

### DeFi Integration Layer (`src/defi/`)

| Contract | Purpose |
|----------|---------|
| `adapters/morpho/CoveredVaultWrapper.sol` | UUPS ERC-4626 vault wrapping a Morpho V2 vault. Accrues premiums against depositor principal, files claims on withdrawal if NAV has fallen. Shares are non-transferable. Composed of `CoveredVaultAccrual`, `CoveredVaultAdmin`, and `CoveredVaultStorage` modules. |
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
- `test/defi/` – `CoveredVaultWrapper` tests (unit, fuzz, precision, scenarios, fork) plus test helpers and mocks

**Fork tests** – two distinct suites, both requiring `ETHEREUM_RPC_URL`:

- `make test-fork-v2` – full broadcast e2e flow on a forked mainnet using a fresh Morpho VaultV2 vault; deploys Coverage contracts, wires live Core, funds EigenLayer vaults via Lido, binds policy, seeds a WETH deposit into the wrapper, and simulates a 5 % vault loss.
- `make test-fork-v1` – same broadcast flow using MetaMorpho v1; the seed-deposit phase is skipped because factory-fresh v1 vaults have an empty supply queue, so this exercises the skip-branch explicitly.

The `CoveredVaultWrapper.fork.t.sol` forge test suite (under `test/defi/`) runs against a pinned block and uses `deal`/`vm.prank` — it is the only test that exercises `fileClaim + slash + Uniswap swap + payout` end-to-end. Run it locally with `FOUNDRY_PROFILE=fork forge test --match-path "test/defi/CoveredVaultWrapper.fork.t.sol"` (gracefully skipped when `ETHEREUM_RPC_URL` is unset).

### Deployment Scripts (`script/`)

**Initial Deployment:**
- `Deploy.s.sol` – shared base handling all deployment logic
- `DeployAnvil.s.sol` – local Anvil deployment
- `DeploySepolia.s.sol` – Sepolia deployment
- `DeployEthereum.s.sol` – mainnet deployment

**UUPS Upgrades** (shared base `UpgradeBase.s.sol` + contract-specific base + Sepolia variant for each; CoverPoolFactory also has an Ethereum variant):
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
- `ForkCompleteCoverageFlow.s.sol` – extends CompleteCoverageFlow with Morpho vault + CoveredVaultWrapper deployment and EigenLayer vault-funding for fresh mainnet forks (used by `make test-fork-v2` / `make test-fork-v1`)

## Build, Test, and Development Commands

- `make setup` – add the `format-check` + `lint` + `test-unit` pre-commit hook.
- `make build` / `make build-prod` – compile with the default or production optimizer profile.
- `make test`, `make test-unit`, `make test-fuzz`, `make test-invariant` – targeted suites (`-vvv --fail-fast`).
- `make test-ci` – full suite with CI profile (higher fuzz/invariant runs).
- `make gas`, `make cover`, `make cover-lcov` – gas, summary coverage, or LCOV + HTML reports.
- `make format` / `make format-check` – enforce the `forge fmt` style before committing.
- `make lint` – run `forge lint` with configured exclusions.
- `make docs` – regenerate NatSpec documentation into `docs/`.
- `make snapshot` / `make snapshot-check` – capture or verify gas baselines for regression tracking.
- `make test-fork-v2` / `make test-fork-v1` – run the Morpho VaultV2 or MetaMorpho v1 e2e flow on a forked mainnet.
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
