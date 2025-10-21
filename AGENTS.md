# Repository Guidelines

## Project Structure & Module Organization
Coverage contracts live in `src/`. Tests in `test/unit`, `test/fuzz`, and `test/invariant` map to the same modules. Deployment scripts belong in `script/`, generated docs land in `docs/`, and `out/` stores build artifacts plus storage layouts. Shared settings stay in `foundry.toml` and `Makefile`; update those instead of copying flags locally.

## Build, Test, and Development Commands
- `make setup` – install Foundry deps and add the `forge fmt --check` pre-commit hook.
- `make build` / `make build-prod` – compile with the default or production optimizer profile.
- `make test`, `make test-unit`, `make test-fuzz`, `make test-invariant` – targeted suites (`-vvv --fail-fast`).
- `make gas`, `make cover`, `make cover-lcov` – gas, summary coverage, or LCOV + HTML reports.

## Coding Style & Naming Conventions
Formatting is enforced by `make format` (`forge fmt`) with 4-space indentation, 130-character lines, double-quoted strings, and long integer types. Contracts, interfaces and libraries use PascalCase (`ExampleContract`, `IExampleContract`, `LExampleLibrary`). Follow the official [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html) for naming and layout; prefer descriptive camelCase function names, past-tense events, explicit `uint256`/`int256`, and NatSpec around tricky invariants.

## Testing Guidelines
Add `.t.sol` files alongside each feature in the appropriate `test` subfolder and prefix test methods with `test_<Scenario>()`. Keep fuzz seeds deterministic unless randomness is required; defaults sit in `foundry.toml`. Run `make test` before every PR and include `make gas` or `make cover` output when altering gas-sensitive logic. Generate `make cover-lcov` only when CI or auditors request HTML artifacts.

## Commit & Pull Request Guidelines
Follow the conventional commit style seen in history (`feat:`, `fix:`, `refactor:`, `chore:`, `ci:`, `style:`, `perf:`) with subjects under 72 characters. Bundle contract edits with matching tests in the same commit. PRs should summarize intent, list touched contracts, attach relevant command output, and link issues or deployment plans. Add screenshots only when explorer states or dashboards change.

## Security & Configuration Tips
Never commit secrets; mirror new environment keys in `.env.example` instead. When updating upgradeable contracts, inspect `out/<Contract>.storageLayout.json` to confirm slot ordering. Check `foundry.toml` `fs_permissions` before broadcasting and surface required env vars in the PR body.
