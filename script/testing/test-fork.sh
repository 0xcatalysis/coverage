#!/usr/bin/env bash
# test-fork.sh — End-to-end Coverage testing against a forked Ethereum mainnet
#
# Sequence:
#   1. Start an Anvil fork of mainnet
#   2. Use live Catalysis Core contracts; grant required roles to deployer via MASTER_ADMIN impersonation
#   2b. Register USDC/USD price feed if not already registered on live ChainlinkPriceFeed
#   3. Deploy Catalysis Coverage on the fork (fresh each run)
#   3b. Restore deployer DEFAULT_ADMIN_ROLE on Coverage contracts via TimelockController impersonation
#   3c. Bump PolicyManager._nextPolicyId above existing live committee IDs (avoids CommitteeAlreadyExists)
#   4. Wire Core <-> Coverage (WireCoreContracts.s.sol)
#   5. Deploy MockSpec via `forge create`; approve it in SpecRegistry
#   6. Deploy MockBindPolicyHook (used when DEPLOY_COVERED_VAULT=false)
#   6.5 Deploy UniswapV3Adapter and register WETH -> PAYOUT_TOKEN swap route on Swapper
#   7. Run ForkCompleteCoverageFlow end-to-end
#   8. Kill Anvil
#
# Prerequisites:
#   - ETHEREUM_RPC_URL set in environment or .env.fork
#   - forge, anvil, cast available on PATH
#   - Run from the coverage workspace root (or via `make test-fork`)
#
# Usage:
#   bash script/testing/test-fork.sh
#   make test-fork  # equivalent
#
# Live Catalysis Core addresses (Ethereum mainnet, docs/deployment/Ethereum-Mainnet.md):
#   STAKE_MANAGER      = 0x5be5220F81e76e0CF6089fb7E7aE9eF48a8D64Be
#   SLASHING_MANAGER   = 0x7Bc39bf135eF3c30E542C196719c91455ff489f0
#   REWARDS_MANAGER    = 0x8ae0F0B94fe782D7F055B04d4699c3cc01632b46
#   SSP_ROUTER         = 0xF39E592E93A7a925a57464e0120B555A25590486
#   CHAINLINK_PRICE_FEED = 0x57F750E3B8e095A5b3AE96030F0cac5dFe2f8A16
#   MASTER_ADMIN       = 0xd2d03377Fa96687e9C11380DA9956AcC5F307e2c
#
# Required .env.fork variables:
#   ETHEREUM_RPC_URL, PRIVATE_KEY, PAYOUT_TOKEN, COVERAGE_LIMIT
#   CURATOR_PRIVATE_KEY, BUYER_PRIVATE_KEY, CLAIMER_PRIVATE_KEY, QUOTE_SIGNER_PRIVATE_KEY
#   POOL_FEE_BPS, DURATION, SPEC_ID, TERMS_HASH, EXPIRATION_TIME
#
# Live Core addresses (can be overridden via .env.fork for Sepolia or future redeployments):
#   STAKE_MANAGER, SLASHING_MANAGER, REWARDS_MANAGER, SSP_ROUTER, CHAINLINK_PRICE_FEED, MASTER_ADMIN
#
# Optional covered-vault mode (DEPLOY_COVERED_VAULT=true):
#   COVERED_VAULT_MAX_LOSS_BPS, COVERED_VAULT_DEDUCTIBLE_BPS,
#   COVERED_VAULT_USER_PRIVATE_KEY, COVERED_VAULT_DEPOSIT_AMOUNT, COVERED_VAULT_LOSS_PCT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COVERAGE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Colour helpers ───────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
step()  { echo -e "${GREEN}[STEP]${NC} $*"; }
info()  { echo -e "${YELLOW}[INFO]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Load .env.fork ───────────────────────────────────────────────────────────
ENV_FILE="$COVERAGE_ROOT/.env.fork"
if [[ -f "$ENV_FILE" ]]; then
    info "Sourcing $ENV_FILE"
    _saved_rpc="${ETHEREUM_RPC_URL:-}"
    _saved_anvil_rpc="${ANVIL_RPC_URL:-}"
    # shellcheck disable=SC1090
    set -o allexport; source "$ENV_FILE"; set +o allexport
    [[ -n "$_saved_rpc" ]]        && ETHEREUM_RPC_URL="$_saved_rpc"
    [[ -n "$_saved_anvil_rpc" ]]  && ANVIL_RPC_URL="$_saved_anvil_rpc"
else
    error ".env.fork not found at $ENV_FILE"
    error "Copy .env.fork.example to .env.fork and set ETHEREUM_RPC_URL."
    exit 1
fi

: "${ETHEREUM_RPC_URL:?ETHEREUM_RPC_URL must be set in .env.fork}"
: "${PRIVATE_KEY:?PRIVATE_KEY must be set}"
: "${PAYOUT_TOKEN:?PAYOUT_TOKEN must be set}"

ANVIL_RPC_URL="${ANVIL_RPC_URL:-http://127.0.0.1:8545}"
ANVIL_PID=""

# ─── Live Core addresses (Ethereum mainnet — docs/deployment/Ethereum-Mainnet.md) ────
STAKE_MANAGER="${STAKE_MANAGER:-0x5be5220F81e76e0CF6089fb7E7aE9eF48a8D64Be}"
SLASHING_MANAGER="${SLASHING_MANAGER:-0x7Bc39bf135eF3c30E542C196719c91455ff489f0}"
REWARDS_MANAGER="${REWARDS_MANAGER:-0x8ae0F0B94fe782D7F055B04d4699c3cc01632b46}"
SSP_ROUTER="${SSP_ROUTER:-0xF39E592E93A7a925a57464e0120B555A25590486}"
CHAINLINK_PRICE_FEED="${CHAINLINK_PRICE_FEED:-0x57F750E3B8e095A5b3AE96030F0cac5dFe2f8A16}"
MASTER_ADMIN="${MASTER_ADMIN:-0xd2d03377Fa96687e9C11380DA9956AcC5F307e2c}"

# ─── Covered vault mode ───────────────────────────────────────────────────────
DEPLOY_COVERED_VAULT="${DEPLOY_COVERED_VAULT:-false}"

# ─── Derive deployer address from private key ────────────────────────────────
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
info "DEPLOYER = $DEPLOYER"
info "STAKE_MANAGER = $STAKE_MANAGER"
info "SLASHING_MANAGER = $SLASHING_MANAGER"
info "REWARDS_MANAGER = $REWARDS_MANAGER"
info "SSP_ROUTER = $SSP_ROUTER"
info "CHAINLINK_PRICE_FEED = $CHAINLINK_PRICE_FEED"
info "MASTER_ADMIN = $MASTER_ADMIN"
info "DEPLOY_COVERED_VAULT = $DEPLOY_COVERED_VAULT"

# ─── Cleanup on exit ─────────────────────────────────────────────────────────
cleanup() {
    if [[ -n "$ANVIL_PID" ]] && kill -0 "$ANVIL_PID" 2>/dev/null; then
        step "Stopping Anvil (pid $ANVIL_PID)..."
        kill "$ANVIL_PID" || true
    fi
}
trap cleanup EXIT

# ─── Helper: extract last logged address for a label ─────────────────────────
extract_log_addr() {
    local label="$1"
    local logfile="$2"
    grep -oE "${label}: 0x[0-9a-fA-F]{40}" "$logfile" \
        | grep -oE '0x[0-9a-fA-F]{40}' \
        | tail -1
}

# ─── 1. Start Anvil fork ──────────────────────────────────────────────────────
step "Starting Anvil fork of mainnet at $ANVIL_RPC_URL..."
anvil --fork-url "$ETHEREUM_RPC_URL" \
      --host 127.0.0.1 \
      --port 8545 \
      --chain-id 1 \
      --silent \
      &> /tmp/anvil-fork.log &
ANVIL_PID=$!
info "Anvil started with pid $ANVIL_PID"

for i in $(seq 1 30); do
    if cast block latest --rpc-url "$ANVIL_RPC_URL" &>/dev/null; then
        info "Anvil is ready (attempt $i)"
        break
    fi
    if [[ $i -eq 30 ]]; then
        error "Anvil did not become ready in time. Check /tmp/anvil-fork.log"
        exit 1
    fi
    sleep 1
done

# ─── 2. Grant Core roles to deployer via MASTER_ADMIN impersonation ───────────
# WireCoreContracts.s.sol requires the deployer to hold roles on the live Core contracts.
# MASTER_ADMIN holds all required roles (delay=0 on all Core contracts, verified 2026-04).
step "Granting Core roles to deployer via MASTER_ADMIN impersonation..."
ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"
STAKE_CFG_ROLE=$(cast keccak "STAKE_MANAGER_CONFIG_ROLE")
REWARDS_CFG_ROLE=$(cast keccak "REWARDS_MANAGER_CONFIG_ROLE")

cast rpc anvil_impersonateAccount "$MASTER_ADMIN" --rpc-url "$ANVIL_RPC_URL" > /dev/null
cast rpc anvil_setBalance "$MASTER_ADMIN" 0xDE0B6B3A7640000 --rpc-url "$ANVIL_RPC_URL" > /dev/null

# DEFAULT_ADMIN_ROLE on all Core contracts
for addr in "$STAKE_MANAGER" "$SLASHING_MANAGER" "$REWARDS_MANAGER" "$SSP_ROUTER" "$CHAINLINK_PRICE_FEED"; do
    cast send --from "$MASTER_ADMIN" --unlocked --rpc-url "$ANVIL_RPC_URL" \
        "$addr" "grantRole(bytes32,address)" "$ADMIN_ROLE" "$DEPLOYER" > /dev/null
done

# Config roles on StakeManager and RewardsManager
cast send --from "$MASTER_ADMIN" --unlocked --rpc-url "$ANVIL_RPC_URL" \
    "$STAKE_MANAGER" "grantRole(bytes32,address)" "$STAKE_CFG_ROLE" "$DEPLOYER" > /dev/null
cast send --from "$MASTER_ADMIN" --unlocked --rpc-url "$ANVIL_RPC_URL" \
    "$REWARDS_MANAGER" "grantRole(bytes32,address)" "$REWARDS_CFG_ROLE" "$DEPLOYER" > /dev/null

cast rpc anvil_stopImpersonatingAccount "$MASTER_ADMIN" --rpc-url "$ANVIL_RPC_URL" > /dev/null
info "Core roles granted to deployer"

# ─── 2b. Register price feeds if missing ──────────────────────────────────────
# WETH/USD is already registered on the live ChainlinkPriceFeed (verified 2026-04).
# USDC/USD must be registered because it was not set at deployment time.
step "Registering price feeds on live ChainlinkPriceFeed (if missing)..."
WETH_ADDR="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
USDC_ADDR="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
ETH_USD_AGG="0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419"
USDC_USD_AGG="0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6"

has_weth=$(cast call "$CHAINLINK_PRICE_FEED" "hasPriceFeed(address)(bool)" "$WETH_ADDR" --rpc-url "$ANVIL_RPC_URL" 2>/dev/null || echo "false")
if [[ "$has_weth" != "true" ]]; then
    cast send --private-key "$PRIVATE_KEY" --rpc-url "$ANVIL_RPC_URL" \
        "$CHAINLINK_PRICE_FEED" "registerPriceFeed(address,address,uint256)" \
        "$WETH_ADDR" "$ETH_USD_AGG" "86400"
    info "WETH/USD price feed registered"
else
    info "[SKIP] WETH/USD price feed already registered"
fi

has_usdc=$(cast call "$CHAINLINK_PRICE_FEED" "hasPriceFeed(address)(bool)" "$USDC_ADDR" --rpc-url "$ANVIL_RPC_URL" 2>/dev/null || echo "false")
if [[ "$has_usdc" != "true" ]]; then
    cast send --private-key "$PRIVATE_KEY" --rpc-url "$ANVIL_RPC_URL" \
        "$CHAINLINK_PRICE_FEED" "registerPriceFeed(address,address,uint256)" \
        "$USDC_ADDR" "$USDC_USD_AGG" "86400"
    info "USDC/USD price feed registered"
else
    info "[SKIP] USDC/USD price feed already registered"
fi

# ─── 3. Deploy Catalysis Coverage ─────────────────────────────────────────────
step "Deploying Catalysis Coverage on fork..."
COVERAGE_DEPLOY_LOG=/tmp/coverage-deploy.log

# OZ upgrade safety validation requires a full compilation.
forge clean --root "$COVERAGE_ROOT"

DEPLOYER_ADDRESS="$DEPLOYER" \
NATIVE_WRAPPER="$PAYOUT_TOKEN" \
STAKE_MANAGER="$STAKE_MANAGER" \
SLASHING_MANAGER="$SLASHING_MANAGER" \
REWARDS_MANAGER="$REWARDS_MANAGER" \
CHAINLINK_PRICE_FEED="$CHAINLINK_PRICE_FEED" \
forge script --root "$COVERAGE_ROOT" \
    "$COVERAGE_ROOT/script/DeployEthereum.s.sol:DeployEthereum" \
    --rpc-url "$ANVIL_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --slow \
    -vvvv \
    2>&1 | tee "$COVERAGE_DEPLOY_LOG"

PREMIUM_MANAGER=$(extract_log_addr "PremiumManager Proxy" "$COVERAGE_DEPLOY_LOG")
CLAIM_MANAGER=$(extract_log_addr "ClaimManager Proxy" "$COVERAGE_DEPLOY_LOG")
POLICY_MANAGER=$(extract_log_addr "PolicyManager Proxy" "$COVERAGE_DEPLOY_LOG")
COVER_POOL_FACTORY=$(extract_log_addr "CoverPoolFactory Proxy" "$COVERAGE_DEPLOY_LOG")
SPEC_REGISTRY=$(extract_log_addr "SpecRegistry Proxy" "$COVERAGE_DEPLOY_LOG")
SWAPPER=$(extract_log_addr "Swapper Proxy" "$COVERAGE_DEPLOY_LOG")
TIMELOCK=$(extract_log_addr "TimelockController" "$COVERAGE_DEPLOY_LOG")

for var in PREMIUM_MANAGER CLAIM_MANAGER POLICY_MANAGER COVER_POOL_FACTORY SPEC_REGISTRY SWAPPER TIMELOCK; do
    val="${!var}"
    if [[ -z "$val" || "$val" == "0x" ]]; then
        error "Failed to extract $var from Coverage deploy log. Check $COVERAGE_DEPLOY_LOG"
        exit 1
    fi
    info "$var = $val"
done

export PREMIUM_MANAGER CLAIM_MANAGER POLICY_MANAGER COVER_POOL_FACTORY SPEC_REGISTRY SWAPPER TIMELOCK

# ─── 3b. Restore deployer DEFAULT_ADMIN_ROLE on Coverage contracts ────────────
step "Restoring deployer DEFAULT_ADMIN_ROLE on Coverage contracts via TimelockController impersonation..."

cast rpc anvil_impersonateAccount "$TIMELOCK" --rpc-url "$ANVIL_RPC_URL" > /dev/null
cast rpc anvil_setBalance "$TIMELOCK" 0xDE0B6B3A7640000 --rpc-url "$ANVIL_RPC_URL" > /dev/null

for addr in "$POLICY_MANAGER" "$PREMIUM_MANAGER" "$CLAIM_MANAGER" \
            "$COVER_POOL_FACTORY" "$SPEC_REGISTRY" "$SWAPPER"; do
    cast send --from "$TIMELOCK" --unlocked --rpc-url "$ANVIL_RPC_URL" \
        "$addr" "grantRole(bytes32,address)" "$ADMIN_ROLE" "$DEPLOYER" > /dev/null
done

cast rpc anvil_stopImpersonatingAccount "$TIMELOCK" --rpc-url "$ANVIL_RPC_URL" > /dev/null
info "DEFAULT_ADMIN_ROLE restored to deployer on all Coverage contracts"

# ─── 3c. Bump PolicyManager._nextPolicyId above live committee IDs ─────────
# The freshly-deployed PolicyManager starts at _nextPolicyId=0.  The first
# requestCoverage does ++_nextPolicyId → 1 and then calls
# StakeManager.createCommittee(1, ...).  If the live mainnet StakeManager
# already has committee 1 (from existing live policies) this reverts with
# CommitteeAlreadyExists().  Read the current max and patch the counter.
step "Bumping PolicyManager policy counter above live committee IDs..."
MAX_COMMITTEE_ID=$(cast call "$STAKE_MANAGER" "getAllCommitteeIds()(uint256[])" \
    --rpc-url "$ANVIL_RPC_URL" \
    | python3 -c "
import sys, re
nums = [int(x) for x in re.findall(r'\d+', sys.stdin.read())]
print(max(nums) if nums else 0)
")
info "Max existing committee ID on live StakeManager: $MAX_COMMITTEE_ID"

if [[ "$MAX_COMMITTEE_ID" -gt 0 ]]; then
    # Slot 2 packs: [_nextPolicyId (uint96, bits 160-255)] | [coverPoolFactory (address, bits 0-159)]
    SLOT2_VAL=$(cast storage "$POLICY_MANAGER" 2 --rpc-url "$ANVIL_RPC_URL")
    NEW_SLOT2=$(python3 -c "
slot2 = int('$SLOT2_VAL', 16)
factory = slot2 & ((1 << 160) - 1)
print('0x{:064x}'.format(factory | ($MAX_COMMITTEE_ID << 160)))
")
    cast rpc anvil_setStorageAt "$POLICY_MANAGER" \
        "0x0000000000000000000000000000000000000000000000000000000000000002" \
        "$NEW_SLOT2" \
        --rpc-url "$ANVIL_RPC_URL" > /dev/null
    info "PolicyManager._nextPolicyId set to $MAX_COMMITTEE_ID (next policyId = $((MAX_COMMITTEE_ID + 1)))"
else
    info "[SKIP] No existing committees; PolicyManager counter unchanged"
fi

# ─── 4. Wire Core <-> Coverage ────────────────────────────────────────────────
step "Wiring Core <-> Coverage..."

DEPLOYER_ADDRESS="$DEPLOYER" \
STAKE_MANAGER="$STAKE_MANAGER" \
SLASHING_MANAGER="$SLASHING_MANAGER" \
REWARDS_MANAGER="$REWARDS_MANAGER" \
SSP_ROUTER="$SSP_ROUTER" \
POLICY_MANAGER="$POLICY_MANAGER" \
CLAIM_MANAGER="$CLAIM_MANAGER" \
PREMIUM_MANAGER="$PREMIUM_MANAGER" \
COVER_POOL_FACTORY="$COVER_POOL_FACTORY" \
PAYOUT_TOKEN="$PAYOUT_TOKEN" \
forge script --root "$COVERAGE_ROOT" \
    "$COVERAGE_ROOT/script/WireCoreContracts.s.sol:WireCoreContracts" \
    --rpc-url "$ANVIL_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --slow \
    -vvvv

info "Core <-> Coverage wiring complete"

# ─── 5. Deploy MockSpec and approve in SpecRegistry ───────────────────────────
step "Deploying MockSpec..."
forge create --root "$COVERAGE_ROOT" \
    "$COVERAGE_ROOT/src/mocks/MockSpec.sol:MockSpec" \
    --rpc-url "$ANVIL_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    2>&1 | tee /tmp/forge-create-spec.log || true
SPEC_ADDRESS=$(grep "Deployed to:" /tmp/forge-create-spec.log | awk '{print $NF}' || true)
if [[ -z "$SPEC_ADDRESS" ]]; then
    error "MockSpec deployment failed. Full output:"
    cat /tmp/forge-create-spec.log >&2
    exit 1
fi
info "SPEC_ADDRESS = $SPEC_ADDRESS"
export SPEC_ADDRESS

DEPLOYER_ADDRESS="$DEPLOYER" \
SPEC_REGISTRY="$SPEC_REGISTRY" \
SPEC_ADDRESS="$SPEC_ADDRESS" \
TIMELOCK=0x0000000000000000000000000000000000000000 \
forge script --root "$COVERAGE_ROOT" \
    "$COVERAGE_ROOT/script/ApproveSpec.s.sol:ApproveSpec" \
    --rpc-url "$ANVIL_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --slow \
    -vvvv

info "MockSpec approved in SpecRegistry"

# ─── 6. Deploy MockBindPolicyHook (used when DEPLOY_COVERED_VAULT=false) ──────
if [[ "$DEPLOY_COVERED_VAULT" == "false" ]]; then
    step "Deploying MockBindPolicyHook..."
    forge create --root "$COVERAGE_ROOT" \
        "$COVERAGE_ROOT/src/mocks/MockBindPolicyHook.sol:MockBindPolicyHook" \
        --rpc-url "$ANVIL_RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        --broadcast \
        2>&1 | tee /tmp/forge-create-hook.log || true
    BIND_POLICY_HOOK=$(grep "Deployed to:" /tmp/forge-create-hook.log | awk '{print $NF}' || true)
    if [[ -z "$BIND_POLICY_HOOK" ]]; then
        error "MockBindPolicyHook deployment failed. Full output:"
        cat /tmp/forge-create-hook.log >&2
        exit 1
    fi
    info "BIND_POLICY_HOOK = $BIND_POLICY_HOOK"
    export BIND_POLICY_HOOK
fi

# ─── 6.5 Deploy UniswapV3Adapter and register swap routes ────────────────────
# Registers two routes on the Swapper:
#   WETH    → PAYOUT_TOKEN  (used when payoutToken itself is slashed)
#   wstETH  → PAYOUT_TOKEN  (live mainnet: EigenLayer vaults hold wstETH as collateral)
step "Deploying UniswapV3Adapter and registering swap routes..."

SWAP_ROUTER="0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45"   # Uniswap V3 SwapRouter02
QUOTER_V2="0x61fFE014bA17989E743c5F6cB21bF9697530B21e"      # Uniswap V3 QuoterV2
WETH="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"          # WETH
WSTETH="0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0"        # wstETH (live mainnet EigenLayer collateral)
POOL_FEE_ROUTE="500"                                        # 0.05% Uniswap V3 pool

ADAPTER_DEPLOY_LOG=/tmp/forge-adapter-deploy.log
DEPLOYER_ADDRESS="$DEPLOYER" \
SWAPPER="$SWAPPER" \
SWAP_ROUTER="$SWAP_ROUTER" \
QUOTER_V2="$QUOTER_V2" \
TOKEN_IN="$WETH" \
TOKEN_OUT="$PAYOUT_TOKEN" \
POOL_FEE="$POOL_FEE_ROUTE" \
forge script --root "$COVERAGE_ROOT" \
    "$COVERAGE_ROOT/script/DeployUniswapV3Adapter.s.sol:DeployUniswapV3Adapter" \
    --sig "run()" \
    --rpc-url "$ANVIL_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --slow \
    -vvvv \
    2>&1 | tee "$ADAPTER_DEPLOY_LOG"

UNISWAP_V3_ADAPTER=$(grep "UniswapV3Adapter deployed at:" "$ADAPTER_DEPLOY_LOG" | awk '{print $NF}' | tail -1)
if [[ -z "$UNISWAP_V3_ADAPTER" || "$UNISWAP_V3_ADAPTER" == "0x" ]]; then
    error "Failed to extract UNISWAP_V3_ADAPTER from deploy log. Check $ADAPTER_DEPLOY_LOG"
    exit 1
fi
info "UNISWAP_V3_ADAPTER = $UNISWAP_V3_ADAPTER"
export UNISWAP_V3_ADAPTER

# Route 1: WETH → PAYOUT_TOKEN
DEPLOYER_ADDRESS="$DEPLOYER" \
SWAPPER="$SWAPPER" \
SWAP_ROUTER="$SWAP_ROUTER" \
QUOTER_V2="$QUOTER_V2" \
UNISWAP_V3_ADAPTER="$UNISWAP_V3_ADAPTER" \
TOKEN_IN="$WETH" \
TOKEN_OUT="$PAYOUT_TOKEN" \
POOL_FEE="$POOL_FEE_ROUTE" \
forge script --root "$COVERAGE_ROOT" \
    "$COVERAGE_ROOT/script/DeployUniswapV3Adapter.s.sol:DeployUniswapV3Adapter" \
    --sig "configure()" \
    --rpc-url "$ANVIL_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --slow \
    -vvvv

# Route 2: wstETH → PAYOUT_TOKEN
DEPLOYER_ADDRESS="$DEPLOYER" \
SWAPPER="$SWAPPER" \
SWAP_ROUTER="$SWAP_ROUTER" \
QUOTER_V2="$QUOTER_V2" \
UNISWAP_V3_ADAPTER="$UNISWAP_V3_ADAPTER" \
TOKEN_IN="$WSTETH" \
TOKEN_OUT="$PAYOUT_TOKEN" \
POOL_FEE="$POOL_FEE_ROUTE" \
forge script --root "$COVERAGE_ROOT" \
    "$COVERAGE_ROOT/script/DeployUniswapV3Adapter.s.sol:DeployUniswapV3Adapter" \
    --sig "configure()" \
    --rpc-url "$ANVIL_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --slow \
    -vvvv

info "Uniswap V3 swap routes registered (WETH and wstETH)"

# ─── 7. Derive test accounts ──────────────────────────────────────────────────
if [[ "$DEPLOY_COVERED_VAULT" == "false" ]]; then
    BENEFICIARY=$(cast wallet address --private-key "$CLAIMER_PRIVATE_KEY")
    info "BENEFICIARY = $BENEFICIARY"
    export BENEFICIARY
fi

# ─── 8. Run ForkCompleteCoverageFlow ─────────────────────────────────────────
step "Running ForkCompleteCoverageFlow end-to-end (DEPLOY_COVERED_VAULT=$DEPLOY_COVERED_VAULT)..."

CURATOR_PRIVATE_KEY="$CURATOR_PRIVATE_KEY" \
BUYER_PRIVATE_KEY="$BUYER_PRIVATE_KEY" \
CLAIMER_PRIVATE_KEY="$CLAIMER_PRIVATE_KEY" \
QUOTE_SIGNER_PRIVATE_KEY="$QUOTE_SIGNER_PRIVATE_KEY" \
COVER_POOL_FACTORY="$COVER_POOL_FACTORY" \
POLICY_MANAGER="$POLICY_MANAGER" \
CLAIM_MANAGER="$CLAIM_MANAGER" \
PREMIUM_MANAGER="$PREMIUM_MANAGER" \
SPEC_REGISTRY="$SPEC_REGISTRY" \
STAKE_MANAGER="$STAKE_MANAGER" \
CHAINLINK_PRICE_FEED="$CHAINLINK_PRICE_FEED" \
POOL_FEE_BPS="${POOL_FEE_BPS:-0}" \
BENEFICIARY="${BENEFICIARY:-0x0000000000000000000000000000000000000001}" \
PAYOUT_TOKEN="$PAYOUT_TOKEN" \
DURATION="${DURATION:-15768000}" \
BIND_POLICY_HOOK="${BIND_POLICY_HOOK:-0x0000000000000000000000000000000000000001}" \
SPEC_ADDRESS="$SPEC_ADDRESS" \
VAULTS="${VAULTS:-}" \
COVERAGE_LIMIT="${COVERAGE_LIMIT:-100000000000}" \
SPEC_ID="${SPEC_ID:-0x$(printf '%064x' 1)}" \
TERMS_HASH="${TERMS_HASH:-0x$(printf '%064x' 2)}" \
EXPIRATION_TIME="${EXPIRATION_TIME:-$(( $(date +%s) + 86400 ))}" \
COVERED_VAULT="${COVERED_VAULT:-0x0000000000000000000000000000000000000000}" \
DEPLOY_COVERED_VAULT="$DEPLOY_COVERED_VAULT" \
REQUESTED_CLAIM_AMOUNT="${REQUESTED_CLAIM_AMOUNT:-0}" \
EVIDENCE_HASH="${EVIDENCE_HASH:-0x0000000000000000000000000000000000000000000000000000000000000000}" \
forge script --root "$COVERAGE_ROOT" \
    "$COVERAGE_ROOT/script/testing/ForkCompleteCoverageFlow.s.sol:ForkCompleteCoverageFlow" \
    --rpc-url "$ANVIL_RPC_URL" \
    --broadcast \
    --slow \
    -vvvv

echo ""
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo -e "${GREEN}  FORK TEST FLOW COMPLETED SUCCESSFULLY     ${NC}"
echo -e "${GREEN}════════════════════════════════════════════${NC}"
