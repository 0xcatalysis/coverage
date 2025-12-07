ifneq (,$(wildcard .env))
    include .env
    export
endif

PRIVATE_KEY ?= 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ANVIL_RPC_URL ?= http://127.0.0.1:8545
ANVIL_CHAIN_ID ?= 31337

FORGE_DEFAULT = FOUNDRY_PROFILE=default forge
FORGE_CI = FOUNDRY_PROFILE=ci forge
FORGE_COVERAGE = FOUNDRY_PROFILE=coverage forge
FORGE_PROD = FOUNDRY_PROFILE=prod forge

FORGE_SCRIPT_DEFAULT = $(FORGE_DEFAULT) script --ffi
FORGE_SCRIPT_PROD = $(FORGE_PROD) script --ffi
FORGE_VERIFY_PROD = $(FORGE_PROD) verify-contract --verifier etherscan --compilation-profile prod
FORGE_SCRIPT_OPTS = --broadcast --slow

.PHONY: all setup build test test-ci test-unit test-fuzz test-invariant cover cover-lcov gas snapshot snapshot-check build-prod deploy-anvil deploy-sepolia deploy-ethereum verify-coverpool-sepolia verify-coverpool-ethereum show-sepolia show-ethereum format format-check lint docs clean slither mythril help

all: clean build test

setup:
	@echo "Setting up project..."
	@printf '#!/bin/sh\nset -e\nmake format-check\nmake lint\nmake test-unit\n' > .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "Setup complete"

build:
	@echo "Building contracts with default profile..."
	@$(FORGE_DEFAULT) build --sizes

build-prod:
	@echo "Building contracts with production profile..."
	@$(FORGE_PROD) build --sizes

format:
	@echo "Formatting code..."
	@$(FORGE_DEFAULT) fmt

format-check:
	@echo "Checking code format..."
	@$(FORGE_DEFAULT) fmt --check
lint:
	@echo "Linting code..."
	@$(FORGE_DEFAULT) lint

test:
	@echo "Running all tests..."
	@$(FORGE_DEFAULT) test -vvv --fail-fast

test-ci:
	@echo "Running all tests with ci profile..."
	@$(FORGE_CI) test -vvv --fail-fast

test-unit:
	@echo "Running unit tests..."
	@$(FORGE_DEFAULT) test --match-path "test/unit/*.t.sol" -vvv --fail-fast

test-fuzz:
	@echo "Running fuzz tests..."
	@$(FORGE_DEFAULT) test --match-path "test/fuzz/*.t.sol" -vvv --fail-fast

test-invariant:
	@echo "Running invariant tests..."
	@$(FORGE_DEFAULT) test --match-path "test/invariant/*.t.sol" -vvv --fail-fast

cover:
	@echo "Generating coverage summary..."
	@$(FORGE_COVERAGE) coverage --report summary

cover-lcov:
	@echo "Generating lcov coverage report..."
	@$(FORGE_COVERAGE) coverage --report lcov
	@echo "Coverage report generated at ./lcov.info"
	@if command -v genhtml >/dev/null 2>&1; then \
		echo "Generating HTML coverage report..."; \
		genhtml lcov.info --output-directory coverage --branch-coverage --function-coverage; \
		echo "HTML coverage report generated in ./coverage/"; \
		open coverage/index.html 2>/dev/null || echo "Open ./coverage/index.html in your browser"; \
	else \
		echo "Warning: genhtml not found. HTML report not generated."; \
	fi

gas:
	@echo "Generating gas report..."
	@$(FORGE_PROD) test --gas-report

snapshot:
	@echo "Generating gas snapshot..."
	@$(FORGE_PROD) snapshot --match-path "test/unit/*.t.sol"

snapshot-check:
	@echo "Checking gas snapshot..."
	@$(FORGE_PROD) snapshot --match-path "test/unit/*.t.sol" --check

deploy-anvil: clean
	@echo "Deploying contracts to Anvil..."
	@$(FORGE_SCRIPT_DEFAULT) script/DeployAnvil.s.sol \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--chain $(ANVIL_CHAIN_ID) \
		$(FORGE_SCRIPT_OPTS)

deploy-sepolia: clean
	@echo "Deploying contracts to Sepolia..."
	@$(FORGE_SCRIPT_PROD) script/DeploySepolia.s.sol \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--chain sepolia \
		$(FORGE_SCRIPT_OPTS)

deploy-ethereum: clean
	@echo "Deploying contracts to Ethereum..."
	@$(FORGE_SCRIPT_PROD) script/DeployEthereum.s.sol \
		--rpc-url $(ETHEREUM_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--chain mainnet \
		$(FORGE_SCRIPT_OPTS)

verify-coverpool-sepolia:
	@echo "Verifying CoverPool on Sepolia..."
	@test -n "$(COVER_POOL_ADDRESS)" || (echo "COVER_POOL_ADDRESS environment variable required" && exit 1)
	@$(FORGE_VERIFY_PROD) $(COVER_POOL_ADDRESS) src/CoverPool.sol:CoverPool \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--chain sepolia \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--watch || true

verify-coverpool-ethereum:
	@echo "Verifying CoverPool on Ethereum..."
	@test -n "$(COVER_POOL_ADDRESS)" || (echo "COVER_POOL_ADDRESS environment variable required" && exit 1)
	@$(FORGE_VERIFY_PROD) $(COVER_POOL_ADDRESS) src/CoverPool.sol:CoverPool \
		--rpc-url $(ETHEREUM_RPC_URL) \
		--chain mainnet \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--watch || true

show-sepolia:
	@echo "Showing deployments for Sepolia..."
	@$(FORGE_SCRIPT_DEFAULT) script/ShowSepolia.s.sol \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--chain sepolia

show-ethereum:
	@echo "Showing deployments for Ethereum..."
	@$(FORGE_SCRIPT_DEFAULT) script/ShowEthereum.s.sol \
		--rpc-url $(ETHEREUM_RPC_URL) \
		--chain mainnet

docs:
	@echo "Generating documentation..."
	@$(FORGE_DEFAULT) doc

clean:
	@echo "Cleaning build artifacts..."
	@$(FORGE_DEFAULT) clean
	@rm -rf broadcast/*/31337 cache coverage out .gas-snapshot anvil.log lcov.info

slither:
	@echo "Running slither analysis..."
	@slither . --config-file slither.config.json --checklist --fail-pedantic

mythril:
	@echo "Running mythril analysis..."
	@myth analyze src/CoverPool.sol --solv 0.8.28

help:
	@echo "Coverage Smart Contracts - Available commands:"
	@echo ""
	@echo "Setup:"
	@echo "  make setup            - Install dependencies and configure git hooks"
	@echo ""
	@echo "Building:"
	@echo "  make all              - Clean, build and test"
	@echo "  make build            - Build contracts with default profile"
	@echo "  make build-prod       - Build contracts with production profile (optimized)"
	@echo ""
	@echo "Testing:"
	@echo "  make test             - Run all tests (default profile)"
	@echo "  make test-ci          - Run all tests with CI profile (more runs)"
	@echo "  make test-unit        - Run unit tests only"
	@echo "  make test-fuzz        - Run fuzz tests only"
	@echo "  make test-invariant   - Run invariant tests only"
	@echo "  make cover            - Generate coverage summary (console output)"
	@echo "  make cover-lcov       - Generate lcov report + HTML (if genhtml installed)"
	@echo "  make gas              - Generate gas report"
	@echo ""
	@echo "Deployment:"
	@echo "  make deploy-anvil       - Deploy contracts to Anvil"
	@echo "  make deploy-sepolia     - Deploy contracts to Sepolia"
	@echo "  make deploy-ethereum    - Deploy contracts to Ethereum"
	@echo ""
	@echo "Verification:"
	@echo "  make verify-coverpool-sepolia  - Verify CoverPool on Sepolia"
	@echo "  make verify-coverpool-ethereum - Verify CoverPool on Ethereum"
	@echo ""
	@echo "Inspection:"
	@echo "  make show-sepolia       - Show Sepolia deployment metadata"
	@echo "  make show-ethereum      - Show Ethereum deployment metadata"
	@echo ""
	@echo "Code Quality:"
	@echo "  make format           - Format code"
	@echo "  make format-check     - Check code format"
	@echo "  make lint             - Lint code"
	@echo "  make docs             - Generate documentation"
	@echo "  make clean            - Clean build artifacts and localhost deployments"
	@echo "  make slither          - Run Slither static analysis"
	@echo "  make mythril          - Run Mythril security analysis"
	@echo ""
	@echo "  make help             - Show this help message"
