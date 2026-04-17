#!/usr/bin/env bash
# test-fork.sh — End-to-end Coverage testing against a forked Ethereum mainnet
#
# Sequence:
#   1. Start an Anvil fork of mainnet
#   2a. [SKIP_CORE_DEPLOY=false] Deploy Catalysis Core, extract addresses, register WETH feed
#       [SKIP_CORE_DEPLOY=true]  Use pre-deployed Core addresses from .env.fork; grant roles to deployer
#   3. Deploy Catalysis Coverage on the fork
#   3b. Restore deployer DEFAULT_ADMIN_ROLE on Coverage contracts via TimelockController impersonation
#   4. Wire Core <-> Coverage (WireCoreContracts.s.sol)
#   5. Deploy MockSpec + MockBindPolicyHook via `forge create`
#   6. Approve MockSpec in SpecRegistry (ApproveSpec.s.sol)
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
    _saved_skip_core="${SKIP_CORE_DEPLOY:-}"
    _saved_anvil_rpc="${ANVIL_RPC_URL:-}"
    # shellcheck disable=SC1090
    set -o allexport; source "$ENV_FILE"; set +o allexport
    [[ -n "$_saved_rpc" ]]        && ETHEREUM_RPC_URL="$_saved_rpc"
    [[ -n "$_saved_skip_core" ]]  && SKIP_CORE_DEPLOY="$_saved_skip_core"
    [[ -n "$_saved_anvil_rpc" ]]  && ANVIL_RPC_URL="$_saved_anvil_rpc"
else
    error ".env.fork not found at $ENV_FILE"
    error "Copy .env.fork from the repo and set ETHEREUM_RPC_URL."
    exit 1
fi

: "${ETHEREUM_RPC_URL:?ETHEREUM_RPC_URL must be set in .env.fork}"
: "${PRIVATE_KEY:?PRIVATE_KEY must be set}"
: "${PAYOUT_TOKEN:?PAYOUT_TOKEN must be set}"
: "${ACCEPTABLE_TOKENS:?ACCEPTABLE_TOKENS must be set}"

SKIP_CORE_DEPLOY="${SKIP_CORE_DEPLOY:-false}"
ANVIL_RPC_URL="${ANVIL_RPC_URL:-http://127.0.0.1:8545}"
ANVIL_PID=""

# Derive deployer address from private key once; used by all forge scripts.
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
info "DEPLOYER = $DEPLOYER"

# ─── Cleanup on exit ─────────────────────────────────────────────────────────
cleanup() {
    if [[ -n "$ANVIL_PID" ]] && kill -0 "$ANVIL_PID" 2>/dev/null; then
        step "Stopping Anvil (pid $ANVIL_PID)..."
        kill "$ANVIL_PID" || true
    fi
}
trap cleanup EXIT

# ─── Helper: extract last logged address for a label ─────────────────────────
# Usage: extract_log_addr "StakeManager Proxy" /tmp/deploy.log
extract_log_addr() {
    local label="$1"
    local logfile="$2"
    grep "${label}:" "$logfile" | tail -1 | awk '{print $NF}'
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

# Wait for Anvil to be ready
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

# ─── 2. Core setup ────────────────────────────────────────────────────────────
if [[ "$SKIP_CORE_DEPLOY" == "true" ]]; then
    # ── 2a. Use pre-deployed mainnet Core contracts ────────────────────────────
    step "Using pre-deployed Core contracts (SKIP_CORE_DEPLOY=true)..."
    : "${CHAINLINK_PRICE_FEED:?CHAINLINK_PRICE_FEED must be set when SKIP_CORE_DEPLOY=true}"
    : "${STAKE_MANAGER:?STAKE_MANAGER must be set when SKIP_CORE_DEPLOY=true}"
    : "${REWARDS_MANAGER:?REWARDS_MANAGER must be set when SKIP_CORE_DEPLOY=true}"
    : "${SLASHING_MANAGER:?SLASHING_MANAGER must be set when SKIP_CORE_DEPLOY=true}"
    : "${SSP_ROUTER:?SSP_ROUTER must be set when SKIP_CORE_DEPLOY=true}"
    : "${CORE_ADMIN:?CORE_ADMIN must be set when SKIP_CORE_DEPLOY=true}"
    info "CHAINLINK_PRICE_FEED = $CHAINLINK_PRICE_FEED"
    info "STAKE_MANAGER        = $STAKE_MANAGER"
    info "REWARDS_MANAGER      = $REWARDS_MANAGER"
    info "SLASHING_MANAGER     = $SLASHING_MANAGER"
    info "SSP_ROUTER           = $SSP_ROUTER"
    info "CORE_ADMIN           = $CORE_ADMIN"

    # ── 2b. Grant Core roles to deployer via Core admin impersonation ──────────
    # WireCoreContracts.s.sol requires the deployer to hold:
    #   - DEFAULT_ADMIN_ROLE       on StakeManager, SlashingManager, RewardsManager, SSPRouter
    #   - STAKE_MANAGER_CONFIG_ROLE on StakeManager
    #   - REWARDS_MANAGER_CONFIG_ROLE on RewardsManager
    step "Granting Core roles to deployer via Core admin impersonation..."
    ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"
    STAKE_CFG_ROLE=$(cast keccak "STAKE_MANAGER_CONFIG_ROLE")
    REWARDS_CFG_ROLE=$(cast keccak "REWARDS_MANAGER_CONFIG_ROLE")

    cast rpc anvil_impersonateAccount "$CORE_ADMIN" --rpc-url "$ANVIL_RPC_URL" > /dev/null
    cast rpc anvil_setBalance "$CORE_ADMIN" 0xDE0B6B3A7640000 --rpc-url "$ANVIL_RPC_URL" > /dev/null

    for addr in "$STAKE_MANAGER" "$SLASHING_MANAGER" "$REWARDS_MANAGER" "$SSP_ROUTER"; do
        cast send --from "$CORE_ADMIN" --unlocked --rpc-url "$ANVIL_RPC_URL" \
            "$addr" "grantRole(bytes32,address)" "$ADMIN_ROLE" "$DEPLOYER" > /dev/null
    done

    cast send --from "$CORE_ADMIN" --unlocked --rpc-url "$ANVIL_RPC_URL" \
        "$STAKE_MANAGER" "grantRole(bytes32,address)" "$STAKE_CFG_ROLE" "$DEPLOYER" > /dev/null
    cast send --from "$CORE_ADMIN" --unlocked --rpc-url "$ANVIL_RPC_URL" \
        "$REWARDS_MANAGER" "grantRole(bytes32,address)" "$REWARDS_CFG_ROLE" "$DEPLOYER" > /dev/null

    cast rpc anvil_stopImpersonatingAccount "$CORE_ADMIN" --rpc-url "$ANVIL_RPC_URL" > /dev/null
    info "Core roles granted to deployer"

else
    # ── 2a. Deploy Catalysis Core from sibling repo ────────────────────────────
    CORE_ROOT="$(cd "$COVERAGE_ROOT/../core" && pwd)"
    step "Deploying Catalysis Core on fork..."
    CORE_DEPLOY_LOG=/tmp/core-deploy.log

    ACCEPTABLE_TOKENS="$ACCEPTABLE_TOKENS" \
    PRIVATE_KEY="$PRIVATE_KEY" \
    forge script --root "$CORE_ROOT" \
        "$CORE_ROOT/src/script/DeployEthereum.s.sol:DeployEthereum" \
        --rpc-url "$ANVIL_RPC_URL" \
        --broadcast \
        --slow \
        -vvvv \
        2>&1 | tee "$CORE_DEPLOY_LOG"

    # Extract Core proxy addresses from console output
    CHAINLINK_PRICE_FEED=$(extract_log_addr "ChainlinkPriceFeed Proxy" "$CORE_DEPLOY_LOG")
    STAKE_MANAGER=$(extract_log_addr "StakeManager Proxy" "$CORE_DEPLOY_LOG")
    REWARDS_MANAGER=$(extract_log_addr "RewardsManager Proxy" "$CORE_DEPLOY_LOG")
    SLASHING_MANAGER=$(extract_log_addr "SlashingManager Proxy" "$CORE_DEPLOY_LOG")
    SSP_ROUTER=$(extract_log_addr "SSPRouter Proxy" "$CORE_DEPLOY_LOG")

    for var in CHAINLINK_PRICE_FEED STAKE_MANAGER REWARDS_MANAGER SLASHING_MANAGER SSP_ROUTER; do
        val="${!var}"
        if [[ -z "$val" || "$val" == "0x" ]]; then
            error "Failed to extract $var from Core deploy log. Check $CORE_DEPLOY_LOG"
            exit 1
        fi
        info "$var = $val"
    done

    export CHAINLINK_PRICE_FEED STAKE_MANAGER REWARDS_MANAGER SLASHING_MANAGER SSP_ROUTER

    # ── 2b. Register WETH price feed on the freshly-deployed ChainlinkPriceFeed ─
    # bindPolicyForRequest -> setCommitteeVaults calls ChainlinkPriceFeed.getTokenAmount(WETH, ...)
    # to verify vault stake in USD terms. Without a registered feed it reverts with PriceFeedNotSet.
    # On the mainnet fork the real Chainlink ETH/USD aggregator is live at:
    #   0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419 (8 decimals, 1h heartbeat)
    step "Registering WETH/USD price feed on ChainlinkPriceFeed..."
    cast send \
        --rpc-url "$ANVIL_RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        "$CHAINLINK_PRICE_FEED" \
        "registerPriceFeed(address,address,uint256)" \
        "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2" \
        "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419" \
        "86400"
    info "WETH/USD price feed registered (staleness threshold: 86400s)"
fi

# ─── 3. Deploy Catalysis Coverage ────────────────────────────────────────────
step "Deploying Catalysis Coverage on fork..."
COVERAGE_DEPLOY_LOG=/tmp/coverage-deploy.log

# OZ upgrade safety validation requires a full compilation (not incremental).
# forge clean removes the partial build-info so the next forge script does a full rebuild.
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

# Extract Coverage proxy addresses from console output
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
# Deploy.s.sol transfers DEFAULT_ADMIN_ROLE to the TimelockController and revokes it from
# the deployer. On the fork we impersonate the TimelockController (which holds admin on all
# Coverage contracts) to grant DEFAULT_ADMIN_ROLE back to the deployer so that subsequent
# steps (wiring, ApproveSpec, payout token whitelisting) work without a 2-day timelock delay.
step "Restoring deployer DEFAULT_ADMIN_ROLE on Coverage contracts via TimelockController impersonation..."
ADMIN_ROLE="${ADMIN_ROLE:-0x0000000000000000000000000000000000000000000000000000000000000000}"

cast rpc anvil_impersonateAccount "$TIMELOCK" --rpc-url "$ANVIL_RPC_URL" > /dev/null
cast rpc anvil_setBalance "$TIMELOCK" 0xDE0B6B3A7640000 --rpc-url "$ANVIL_RPC_URL" > /dev/null

for addr in "$POLICY_MANAGER" "$PREMIUM_MANAGER" "$CLAIM_MANAGER" \
            "$COVER_POOL_FACTORY" "$SPEC_REGISTRY" "$SWAPPER"; do
    cast send --from "$TIMELOCK" --unlocked --rpc-url "$ANVIL_RPC_URL" \
        "$addr" "grantRole(bytes32,address)" "$ADMIN_ROLE" "$DEPLOYER" > /dev/null
done

cast rpc anvil_stopImpersonatingAccount "$TIMELOCK" --rpc-url "$ANVIL_RPC_URL" > /dev/null
info "DEFAULT_ADMIN_ROLE restored to deployer on all Coverage contracts"

# ─── 4. Wire Core <-> Coverage ───────────────────────────────────────────────
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

# ─── 5. Deploy mock contracts ─────────────────────────────────────────────────
# Run forge create directly (not inside a subshell), tee output to a log file,
# then parse "Deployed to: 0x..." from the log. The || true prevents set -e from
# firing on a non-zero exit so we can show a helpful error message.

step "Deploying MockSpec..."
forge create --root "$COVERAGE_ROOT" \
    "$COVERAGE_ROOT/src/mocks/MockSpec.sol:MockSpec" \
    --rpc-url "$ANVIL_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    2>&1 | tee /tmp/forge-create-spec.log || true
SPEC_ADDRESS=$(grep "Deployed to:" /tmp/forge-create-spec.log | awk '{print $NF}' || true)
if [[ -z "$SPEC_ADDRESS" ]]; then
    error "MockSpec deployment failed or address not found. Full output:"
    cat /tmp/forge-create-spec.log >&2
    exit 1
fi
info "SPEC_ADDRESS = $SPEC_ADDRESS"
export SPEC_ADDRESS

step "Deploying MockBindPolicyHook..."
forge create --root "$COVERAGE_ROOT" \
    "$COVERAGE_ROOT/src/mocks/MockBindPolicyHook.sol:MockBindPolicyHook" \
    --rpc-url "$ANVIL_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    2>&1 | tee /tmp/forge-create-hook.log || true
BIND_POLICY_HOOK=$(grep "Deployed to:" /tmp/forge-create-hook.log | awk '{print $NF}' || true)
if [[ -z "$BIND_POLICY_HOOK" ]]; then
    error "MockBindPolicyHook deployment failed or address not found. Full output:"
    cat /tmp/forge-create-hook.log >&2
    exit 1
fi
info "BIND_POLICY_HOOK = $BIND_POLICY_HOOK"
export BIND_POLICY_HOOK

# ─── 6. Approve MockSpec in SpecRegistry ─────────────────────────────────────
step "Approving MockSpec in SpecRegistry..."

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

# ─── 7. Derive remaining test accounts ───────────────────────────────────────
# Beneficiary = address corresponding to CLAIMER_PRIVATE_KEY (Anvil account #2)
BENEFICIARY=$(cast wallet address --private-key "$CLAIMER_PRIVATE_KEY")
info "BENEFICIARY = $BENEFICIARY"
export BENEFICIARY

# ─── 8. Run CompleteCoverageFlow ─────────────────────────────────────────────
step "Running CompleteCoverageFlow end-to-end..."

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
POOL_FEE_BPS="$POOL_FEE_BPS" \
BENEFICIARY="$BENEFICIARY" \
PAYOUT_TOKEN="$PAYOUT_TOKEN" \
DURATION="$DURATION" \
BIND_POLICY_HOOK="$BIND_POLICY_HOOK" \
SPEC_ADDRESS="$SPEC_ADDRESS" \
VAULTS="${VAULTS:-}" \
COVERAGE_LIMIT="$COVERAGE_LIMIT" \
SPEC_ID="$SPEC_ID" \
TERMS_HASH="$TERMS_HASH" \
EXPIRATION_TIME="$EXPIRATION_TIME" \
COVERED_VAULT="${COVERED_VAULT:-0x0000000000000000000000000000000000000000}" \
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
