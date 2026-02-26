// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStakeManager} from "../../src/interfaces/IStakeManager.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal inline interfaces for Symbiotic and EigenLayer contracts.
// These protocols are not direct dependencies of this repo; full implementations
// live in the core repo and the upstream protocol libraries.
// ─────────────────────────────────────────────────────────────────────────────

interface ISymbioticVault {
    function delegator() external view returns (address);
    function deposit(
        address onBehalfOf,
        uint256 amount
    )
        external
        returns (uint256 depositedAmount, uint256 mintedShares);
    function activeSharesOf(address account) external view returns (uint256);
}

/// @dev Matches Symbiotic's FullRestakeDelegator role-gated functions.
interface ISymbioticDelegator {
    function setNetworkLimit(bytes32 subnetwork, uint256 amount) external;
    function setOperatorNetworkLimit(bytes32 subnetwork, address operator, uint256 amount) external;
}

/// @dev Simple direct opt-in (msg.sender == operator, no signature needed).
interface ISymbioticOptInService {
    function optIn(address where) external;
    function isOptedIn(address who, address where) external view returns (bool);
}

interface IEigenAllocationManager {
    struct OperatorSet {
        address avs;
        uint32 id;
    }

    struct AllocateParams {
        OperatorSet operatorSet;
        address[] strategies;
        uint64[] newMagnitudes;
    }

    function setAllocationDelay(address operator, uint32 delay) external;
    function getAllocationDelay(address operator) external view returns (bool isSet, uint32 delay);
    function modifyAllocations(address operator, AllocateParams[] calldata params) external;
}

interface IEigenStrategyManager {
    function depositIntoStrategy(address strategy, address token, uint256 amount) external returns (uint256 shares);
}

/// @dev Minimal DelegationManager interface used to verify EigenLayer operator registration.
interface IDelegationManager {
    function isOperator(address operator) external view returns (bool);
}

interface IAllocationManagerRegistration {
    struct RegisterParams {
        address avs;
        uint32[] operatorSetIds;
        bytes data;
    }

    function registerForOperatorSets(address operator, RegisterParams calldata params) external;
    function isOperatorSlashable(
        address operator,
        IEigenAllocationManager.OperatorSet calldata operatorSet
    )
        external
        view
        returns (bool);
}

/**
 * @title PrepareBindPolicy
 * @notice Orchestrates Flow 4 – restaker delegation setup – so that BindPolicy.s.sol can succeed.
 * @dev Bridges the gap between RequestCoverage.s.sol (Flows 2-3) and BindPolicy.s.sol (Flow 5).
 *
 *      The script runs five phases in order:
 *
 *        Phase 2 – Set EigenLayer allocation delay
 *                  Self-service; operator signs with OPERATOR_PRIVATE_KEY.
 *                  Skipped automatically if the delay is already initialised.
 *
 *        Phase 3 – Operator opts into the Symbiotic vault [SYMBIOTIC ONLY]
 *                  Self-service; operator signs with OPERATOR_PRIVATE_KEY.
 *                  Skipped entirely if SYMBIOTIC_VAULT is not set or zero.
 *                  Skipped if already opted in.
 *
 *        Phase 4 – Deposit stake into vaults
 *                  Self-service; operator signs with OPERATOR_PRIVATE_KEY.
 *                  Always deposits into the EigenLayer strategy.
 *                  Deposits into the Symbiotic vault only if SYMBIOTIC_VAULT is set.
 *
 *        Phase 5 – Allocate EigenLayer magnitude
 *                  Self-service; operator signs with OPERATOR_PRIVATE_KEY.
 *                  Makes the deposited tokens slashable by the committee.
 *
 *        Phase 6 – Configure Symbiotic delegation limits [SYMBIOTIC ONLY]
 *                  Requires ADMIN_PRIVATE_KEY with:
 *                    • NETWORK_LIMIT_SET_ROLE on the Symbiotic delegator
 *                    • OPERATOR_NETWORK_LIMIT_SET_ROLE on the Symbiotic delegator
 *                  Skipped entirely if SYMBIOTIC_VAULT is not set or zero.
 *
 *      Prerequisites before running this script:
 *        ✓ Flows 1-3 done: CoverPool created, coverage requested, committee exists.
 *        ✓ Operator registered in EigenLayer via DelegationManager.registerAsOperator().
 *        ✓ EigenLayer strategy already deployed and registered in SSPRouter.
 *        ✓ (Symbiotic only) Operator registered in Symbiotic OperatorRegistry.
 *        ✓ (Symbiotic only) Symbiotic vault deployed.
 *
 * Usage:
 *   forge script script/testing/PrepareBindPolicy.s.sol:PrepareBindPolicy \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *
 *   Accounts:
 *     OPERATOR_PRIVATE_KEY          Curator / operator private key (self-service phases)
 *     ADMIN_PRIVATE_KEY             Admin private key (privileged Symbiotic phases; may equal
 *                                   OPERATOR_PRIVATE_KEY on testnet)
 *
 *   Coverage contracts:
 *     POLICY_MANAGER                PolicyManager proxy address
 *
 *   Core contracts:
 *     STAKE_MANAGER                 StakeManager proxy address
 *
 *   EigenLayer (required):
 *     EIGEN_ADAPTER                 EigenAdapter address (acts as the EigenLayer AVS)
 *     EIGEN_STRATEGY_MANAGER        EigenLayer StrategyManager address
 *     EIGEN_ALLOCATION_MANAGER      EigenLayer AllocationManager address
 *     EIGEN_DELEGATION_MANAGER      EigenLayer DelegationManager address
 *     EIGENLAYER_STRATEGY           EigenLayer strategy address for collateral
 *     EIGENLAYER_COLLATERAL_TOKEN   Collateral token for the EigenLayer strategy
 *
 *   Committee:
 *     POLICY_ID                     Policy / committee ID (output of RequestCoverage.s.sol)
 *
 *   Stake parameters:
 *     DEPOSIT_AMOUNT                Token amount to deposit (wei)
 *
 *   Symbiotic (optional — all default to address(0)/0, phases are skipped when unset):
 *     SYMBIOTIC_ADAPTER             SymbioticAdapter address (acts as the Symbiotic network)
 *     SYMBIOTIC_VAULT               Deployed Symbiotic vault address
 *     SYMBIOTIC_COLLATERAL_TOKEN    Collateral token for the Symbiotic vault
 *     OPERATOR_VAULT_OPT_IN_SERVICE Symbiotic OperatorVaultOptInService address
 *     NETWORK_LIMIT                 Symbiotic delegator network-wide limit (wei, >= DEPOSIT_AMOUNT)
 *     OPERATOR_NETWORK_LIMIT        Symbiotic delegator per-operator limit (wei, >= DEPOSIT_AMOUNT)
 *
 *   Optional:
 *     ALLOCATION_MAGNITUDE          EigenLayer magnitude 0-10000 (default: 10000 = 100%)
 *     ALLOCATION_DELAY              EigenLayer allocation delay in blocks (default: 0 for testnet)
 */
contract PrepareBindPolicy is Script {
    // ── Accounts ──
    uint256 public operatorPrivateKey;
    address public operator;
    uint256 public adminPrivateKey;
    address public admin;

    // ── Coverage contracts ──
    address public policyManager;

    // ── Core contracts ──
    address public stakeManager;

    // ── EigenLayer (required) ──
    address public eigenAdapter;
    address public eigenStrategyManager;
    address public eigenAllocationManager;
    address public eigenDelegationManager;
    address public eigenLayerStrategy;
    address public eigenLayerCollateralToken;

    // ── Symbiotic (optional — zero means skip) ──
    address public symbioticAdapter;
    address public symbioticVault;
    address public symbioticCollateralToken;
    address public operatorVaultOptInService;
    uint256 public networkLimit;
    uint256 public operatorNetworkLimit;

    // ── Committee ──
    uint96 public policyId;

    // ── Stake parameters ──
    uint256 public depositAmount;
    uint64 public allocationMagnitude;
    uint32 public allocationDelay;

    // ── Events ──
    event AllocationDelaySet(address indexed operator, uint32 delay);
    event VaultOptInConfigured(address indexed operator, address indexed vault);
    event SymbioticStakeDeposited(address indexed operator, address indexed vault, uint256 amount);
    event EigenLayerStakeDeposited(address indexed operator, address indexed strategy, uint256 amount, uint256 shares);
    event MagnitudeAllocated(
        address indexed operator, address indexed eigenAdapter, uint32 operatorSetId, uint64 magnitude
    );
    event SymbioticLimitsConfigured(address indexed vault, bytes32 subnetwork, uint256 networkLim, uint256 operatorLim);
    event PreparationCompleted(address indexed operator, uint96 indexed policyId, uint256 totalStake);

    constructor() {
        operatorPrivateKey = vm.envUint("OPERATOR_PRIVATE_KEY");
        operator = vm.addr(operatorPrivateKey);
        adminPrivateKey = vm.envUint("ADMIN_PRIVATE_KEY");
        admin = vm.addr(adminPrivateKey);

        policyManager = vm.envAddress("POLICY_MANAGER");
        stakeManager = vm.envAddress("STAKE_MANAGER");

        // EigenLayer – required
        eigenAdapter = vm.envAddress("EIGEN_ADAPTER");
        eigenStrategyManager = vm.envAddress("EIGEN_STRATEGY_MANAGER");
        eigenAllocationManager = vm.envAddress("EIGEN_ALLOCATION_MANAGER");
        eigenDelegationManager = vm.envAddress("EIGEN_DELEGATION_MANAGER");
        eigenLayerStrategy = vm.envAddress("EIGENLAYER_STRATEGY");
        eigenLayerCollateralToken = vm.envAddress("EIGENLAYER_COLLATERAL_TOKEN");

        // Symbiotic – optional; phases are skipped when symbioticVault == address(0)
        symbioticAdapter = vm.envOr("SYMBIOTIC_ADAPTER", address(0));
        symbioticVault = vm.envOr("SYMBIOTIC_VAULT", address(0));
        symbioticCollateralToken = vm.envOr("SYMBIOTIC_COLLATERAL_TOKEN", address(0));
        operatorVaultOptInService = vm.envOr("OPERATOR_VAULT_OPT_IN_SERVICE", address(0));
        networkLimit = vm.envOr("NETWORK_LIMIT", uint256(0));
        operatorNetworkLimit = vm.envOr("OPERATOR_NETWORK_LIMIT", uint256(0));

        policyId = uint96(vm.envUint("POLICY_ID"));

        depositAmount = vm.envUint("DEPOSIT_AMOUNT");
        allocationMagnitude = uint64(vm.envOr("ALLOCATION_MAGNITUDE", uint256(10_000)));
        allocationDelay = uint32(vm.envOr("ALLOCATION_DELAY", uint256(0)));
    }

    function run() external {
        console.log("=================================================");
        console.log("  PREPARE BIND POLICY - FLOW 4: RESTAKER DELEGATION");
        console.log("=================================================");
        console.log("Operator:", operator);
        console.log("Admin:", admin);
        console.log("Policy / Committee ID:", policyId);
        console.log("Symbiotic enabled:", symbioticVault != address(0));
        console.log("");

        _verifyPrerequisites();

        _phase2_setAllocationDelay();
        if (symbioticVault != address(0)) _phase3_optIntoSymbioticVault();
        _phase4_depositStake();
        _phase5_allocateEigenLayerMagnitude();
        _phase5b_registerToOperatorSet();
        if (symbioticVault != address(0)) _phase6_configureSymbioticLimits();

        _verifySufficientStake();

        console.log("\n=================================================");
        console.log("  PREPARATION COMPLETE - BindPolicy.s.sol is ready");
        console.log("=================================================");
        emit PreparationCompleted(operator, policyId, IStakeManager(stakeManager).getOperatorCommitteeStake(policyId));
    }

    // ═══════════════════════════════════════════════════
    //  Prerequisites check
    // ═══════════════════════════════════════════════════

    function _verifyPrerequisites() internal view {
        console.log("--- Prerequisite Checks ---");

        IPolicyManager pm = IPolicyManager(policyManager);
        IPolicyManager.PolicyDraft memory draft = pm.getPolicyDraft(policyId);
        require(draft.pool != address(0), "Policy draft not found - run RequestCoverage.s.sol first");
        require(draft.status == IPolicyManager.PolicyStatus.Created, "Policy draft not in Created status");
        console.log("Policy draft exists (status = Created) for policy ID:", policyId);
        console.log("Coverage amount required (USD 8 dec):", draft.coverageAmount);

        require(
            IDelegationManager(eigenDelegationManager).isOperator(operator),
            "Operator not registered in EigenLayer - run CreateCoverPool.s.sol first"
        );
        console.log("Operator is registered in EigenLayer");

        uint256 eigenBalance = IERC20(eigenLayerCollateralToken).balanceOf(operator);
        console.log("Operator EigenLayer collateral balance:", eigenBalance);
        require(eigenBalance >= depositAmount, "Insufficient EigenLayer collateral balance");

        if (symbioticVault != address(0)) {
            uint256 symbioticBalance = IERC20(symbioticCollateralToken).balanceOf(operator);
            console.log("Operator Symbiotic collateral balance:", symbioticBalance);
            require(symbioticBalance >= depositAmount, "Insufficient Symbiotic collateral balance");
        }

        console.log("[OK] Prerequisites satisfied\n");
    }

    // ═══════════════════════════════════════════════════
    //  Phase 2: Set EigenLayer allocation delay
    //  Requires: operator self-service
    // ═══════════════════════════════════════════════════

    function _phase2_setAllocationDelay() internal {
        console.log("=== PHASE 2: SET EIGENLAYER ALLOCATION DELAY ===");

        IEigenAllocationManager alloc = IEigenAllocationManager(eigenAllocationManager);
        (bool isSet, uint32 currentDelay) = alloc.getAllocationDelay(operator);

        if (isSet) {
            console.log("[SKIP] Allocation delay already set:", currentDelay, "blocks");
            console.log("");
            return;
        }

        console.log("Setting allocation delay to", allocationDelay, "blocks...");

        vm.startBroadcast(operatorPrivateKey);
        alloc.setAllocationDelay(operator, allocationDelay);
        vm.stopBroadcast();

        console.log("[OK] Allocation delay set:", allocationDelay, "blocks");
        emit AllocationDelaySet(operator, allocationDelay);
        console.log("");
    }

    // ═══════════════════════════════════════════════════
    //  Phase 3: Operator opts into the Symbiotic vault [SYMBIOTIC ONLY]
    //  Requires: operator self-service
    // ═══════════════════════════════════════════════════

    function _phase3_optIntoSymbioticVault() internal {
        console.log("=== PHASE 3: OPT INTO SYMBIOTIC VAULT ===");
        console.log("Vault:", symbioticVault);

        ISymbioticOptInService optInService = ISymbioticOptInService(operatorVaultOptInService);

        if (optInService.isOptedIn(operator, symbioticVault)) {
            console.log("[SKIP] Operator already opted into vault");
            console.log("");
            return;
        }

        vm.startBroadcast(operatorPrivateKey);
        optInService.optIn(symbioticVault);
        vm.stopBroadcast();

        require(optInService.isOptedIn(operator, symbioticVault), "Vault opt-in failed");
        console.log("[OK] Operator opted into Symbiotic vault");
        emit VaultOptInConfigured(operator, symbioticVault);
        console.log("");
    }

    // ═══════════════════════════════════════════════════
    //  Phase 4: Deposit stake into vaults
    //  Requires: operator self-service, sufficient token balance
    //  EigenLayer is always executed; Symbiotic only when vault is set.
    // ═══════════════════════════════════════════════════

    function _phase4_depositStake() internal {
        console.log("=== PHASE 4: DEPOSIT STAKE INTO VAULTS ===");
        console.log("Deposit amount:", depositAmount);

        if (symbioticVault != address(0)) _depositIntoSymbioticVault();
        _depositIntoEigenLayerStrategy();
        console.log("");
    }

    function _depositIntoSymbioticVault() internal {
        console.log("  Depositing into Symbiotic vault:", symbioticVault);

        vm.startBroadcast(operatorPrivateKey);
        IERC20(symbioticCollateralToken).approve(symbioticVault, depositAmount);
        ISymbioticVault(symbioticVault).deposit(operator, depositAmount);
        vm.stopBroadcast();

        uint256 shares = ISymbioticVault(symbioticVault).activeSharesOf(operator);
        console.log("  [OK] Deposited. Active vault shares:", shares);
        emit SymbioticStakeDeposited(operator, symbioticVault, depositAmount);
    }

    function _depositIntoEigenLayerStrategy() internal {
        console.log("  Depositing into EigenLayer strategy:", eigenLayerStrategy);

        vm.startBroadcast(operatorPrivateKey);
        IERC20(eigenLayerCollateralToken).approve(eigenStrategyManager, depositAmount);
        uint256 shares = IEigenStrategyManager(eigenStrategyManager)
            .depositIntoStrategy(eigenLayerStrategy, eigenLayerCollateralToken, depositAmount);
        vm.stopBroadcast();

        console.log("  [OK] Deposited. Shares received:", shares);
        emit EigenLayerStakeDeposited(operator, eigenLayerStrategy, depositAmount, shares);
    }

    // ═══════════════════════════════════════════════════
    //  Phase 5: Allocate EigenLayer magnitude
    //  Requires: operator self-service
    //  Note: becomes slashable after the allocation delay period.
    // ═══════════════════════════════════════════════════

    function _phase5_allocateEigenLayerMagnitude() internal {
        console.log("=== PHASE 5: ALLOCATE EIGENLAYER MAGNITUDE ===");
        console.log("  EigenAdapter (AVS):", eigenAdapter);
        console.log("  Committee / OperatorSet ID:", policyId);
        console.log("  Magnitude:", allocationMagnitude, "/ 10000");

        address[] memory strategies = new address[](1);
        strategies[0] = eigenLayerStrategy;

        uint64[] memory magnitudes = new uint64[](1);
        magnitudes[0] = allocationMagnitude;

        IEigenAllocationManager.AllocateParams[] memory params = new IEigenAllocationManager.AllocateParams[](1);
        params[0] = IEigenAllocationManager.AllocateParams({
            operatorSet: IEigenAllocationManager.OperatorSet({avs: eigenAdapter, id: uint32(policyId)}),
            strategies: strategies,
            newMagnitudes: magnitudes
        });

        vm.startBroadcast(operatorPrivateKey);
        IEigenAllocationManager(eigenAllocationManager).modifyAllocations(operator, params);
        vm.stopBroadcast();

        console.log("  [OK] Magnitude allocated. Deposits become slashable after allocation delay.");
        emit MagnitudeAllocated(operator, eigenAdapter, uint32(policyId), allocationMagnitude);
        console.log("");
    }

    // ═══════════════════════════════════════════════════
    //  Phase 5b: Register operator to EigenLayer operator set
    //  Required for the operator to be slashable by the committee.
    //  Requires: operator self-service (via DelegationManager checkCanCall).
    //  Idempotent: skipped if already a member.
    // ═══════════════════════════════════════════════════

    function _phase5b_registerToOperatorSet() internal {
        console.log("=== PHASE 5b: REGISTER OPERATOR TO EIGENLAYER OPERATOR SET ===");
        console.log("  EigenAdapter (AVS):", eigenAdapter);
        console.log("  Committee / OperatorSet ID:", policyId);

        IAllocationManagerRegistration.RegisterParams memory params = IAllocationManagerRegistration.RegisterParams({
            avs: eigenAdapter, operatorSetIds: new uint32[](1), data: bytes("")
        });
        params.operatorSetIds[0] = uint32(policyId);

        IAllocationManagerRegistration alloc = IAllocationManagerRegistration(eigenAllocationManager);

        // Check if already registered to this operator set
        IEigenAllocationManager.OperatorSet memory opSet =
            IEigenAllocationManager.OperatorSet({avs: eigenAdapter, id: uint32(policyId)});
        if (alloc.isOperatorSlashable(operator, opSet)) {
            console.log("[SKIP] Operator already registered to operator set");
            console.log("");
            return;
        }

        vm.startBroadcast(operatorPrivateKey);
        alloc.registerForOperatorSets(operator, params);
        vm.stopBroadcast();

        console.log("  [OK] Operator registered to EigenLayer operator set");
        console.log("");
    }

    // ═══════════════════════════════════════════════════
    //  Phase 6: Configure Symbiotic delegation limits [SYMBIOTIC ONLY]
    //  Requires:
    //    NETWORK_LIMIT_SET_ROLE + OPERATOR_NETWORK_LIMIT_SET_ROLE on delegator
    //
    //  NOTE: Stake is computed dynamically by StakeManager (via adapters).
    //        No manual stake recording is needed.
    // ═══════════════════════════════════════════════════

    function _phase6_configureSymbioticLimits() internal {
        console.log("=== PHASE 6: CONFIGURE SYMBIOTIC DELEGATION LIMITS ===");
        console.log("Admin:", admin);

        address delegator = ISymbioticVault(symbioticVault).delegator();
        console.log("  Symbiotic delegator:", delegator);

        // Subnetwork = (symbioticAdapter << 96) | committeeId
        bytes32 subnetwork = bytes32((uint256(uint160(symbioticAdapter)) << 96) | uint256(policyId));
        console.log("  Subnetwork (network | committeeId):", vm.toString(uint256(subnetwork)));
        console.log("  Network limit:", networkLimit);
        console.log("  Operator network limit:", operatorNetworkLimit);

        vm.startBroadcast(adminPrivateKey);
        ISymbioticDelegator(delegator).setNetworkLimit(subnetwork, networkLimit);
        ISymbioticDelegator(delegator).setOperatorNetworkLimit(subnetwork, operator, operatorNetworkLimit);
        vm.stopBroadcast();

        console.log("  [OK] Symbiotic delegation limits configured");
        emit SymbioticLimitsConfigured(symbioticVault, subnetwork, networkLimit, operatorNetworkLimit);
        console.log("");
    }

    // ═══════════════════════════════════════════════════
    //  Final verification
    // ═══════════════════════════════════════════════════

    function _verifySufficientStake() internal view {
        console.log("--- Final Stake Verification ---");

        uint256 totalStake = IStakeManager(stakeManager).getOperatorCommitteeStake(policyId);
        IPolicyManager.PolicyDraft memory draft = IPolicyManager(policyManager).getPolicyDraft(policyId);

        console.log("Total operator stake (USD 8 dec):", totalStake);
        console.log("Required coverage amount (USD 8 dec):", draft.coverageAmount);

        if (totalStake >= draft.coverageAmount) {
            console.log("[OK] Stake is sufficient. BindPolicy.s.sol can proceed.");
        } else {
            console.log("[WARNING] Stake is still insufficient.");
            console.log("  Shortfall:", draft.coverageAmount - totalStake);
            console.log("  Increase DEPOSIT_AMOUNT or wait for delegation to propagate.");
        }
    }
}
