// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IAllocationManagerPrepare {
    struct OperatorSet {
        address avs;
        uint32 id;
    }

    struct AllocateParams {
        OperatorSet operatorSet;
        address[] strategies;
        uint64[] newMagnitudes;
    }

    struct RegisterParams {
        address avs;
        uint32[] operatorSetIds;
        bytes data;
    }

    function modifyAllocations(address operator, AllocateParams[] calldata params) external;
    function registerForOperatorSets(address operator, RegisterParams calldata params) external;
    function getMaxMagnitude(address operator, address strategy) external view returns (uint64);
    function getAllocatableMagnitude(address operator, address strategy) external view returns (uint64);
    function getAllocation(
        address operator,
        OperatorSet calldata operatorSet,
        address strategy
    )
        external
        view
        returns (uint64 currentMagnitude, int128 pendingDiff, uint32 effectBlock);
    function isMemberOfOperatorSet(address operator, OperatorSet calldata operatorSet) external view returns (bool);
    function isOperatorSlashable(address operator, OperatorSet calldata operatorSet) external view returns (bool);
    function ALLOCATION_CONFIGURATION_DELAY() external view returns (uint32);
    function getMinimumSlashableStake(
        OperatorSet calldata operatorSet,
        address[] calldata operators,
        address[] calldata strategies,
        uint32 futureBlock
    )
        external
        view
        returns (uint256[][] memory slashableStake);
}

/**
 * @title PrepareEigenLayer
 * @notice Sets up EigenLayer operator allocation and registration for a given committee (operatorSet).
 * @dev Performs two operations:
 *      1. Increases the operator's allocated magnitude for the target operatorSet to a proper value,
 *         enabling meaningful slashing. The change takes effect after ALLOCATION_CONFIGURATION_DELAY
 *         blocks (~75 blocks on Sepolia = ~15 minutes).
 *      2. Registers the operator in the EigenLayer operatorSet (if not already registered),
 *         making them slashable.
 *
 *      Run this script BEFORE BindPolicy + FileClaim for any committee. After running, wait
 *      for ALLOCATION_CONFIGURATION_DELAY blocks before filing claims.
 *
 * Usage:
 *   forge script script/testing/PrepareEigenLayer.s.sol:PrepareEigenLayer \
 *     --rpc-url $SEPOLIA_RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Operator private key
 *   - EIGEN_ALLOCATION_MANAGER: EigenLayer AllocationManager address
 *   - EIGEN_ADAPTER_ADDRESS: EigenAdapter contract address (acts as AVS)
 *   - EIGEN_STRATEGY: EigenLayer strategy address (DurationVault or WETH strategy)
 *   - COMMITTEE_ID: Committee ID / EigenLayer operatorSet ID to prepare
 *   - NEW_MAGNITUDE: Magnitude to allocate (uint64, scaled to 1e18 max; default 5e17 = 50%)
 */
contract PrepareEigenLayer is Script {
    IAllocationManagerPrepare public allocationManager;
    address public eigenAdapter;
    address public strategy;
    address public operator;
    uint256 public operatorPrivateKey;
    uint32 public committeeId;
    uint64 public newMagnitude;

    constructor() {
        operatorPrivateKey = vm.envUint("PRIVATE_KEY");
        operator = vm.addr(operatorPrivateKey);

        allocationManager = IAllocationManagerPrepare(vm.envAddress("EIGEN_ALLOCATION_MANAGER"));
        eigenAdapter = vm.envAddress("EIGEN_ADAPTER_ADDRESS");
        strategy = vm.envAddress("EIGEN_STRATEGY");
        committeeId = uint32(vm.envUint("COMMITTEE_ID"));
        // Default magnitude: 5e17 (50% of max 1e18)
        newMagnitude = uint64(vm.envOr("NEW_MAGNITUDE", uint256(5e17)));
    }

    function run() external {
        console.log("=== EIGENLAYER COMMITTEE PREPARATION ===");
        console.log("Operator:", operator);
        console.log("AllocationManager:", address(allocationManager));
        console.log("EigenAdapter (AVS):", eigenAdapter);
        console.log("Strategy:", strategy);
        console.log("CommitteeId / OperatorSetId:", committeeId);
        console.log("Target magnitude:", newMagnitude);

        _printCurrentState();

        IAllocationManagerPrepare.OperatorSet memory opSet =
            IAllocationManagerPrepare.OperatorSet({avs: eigenAdapter, id: committeeId});

        (uint64 currentMagnitude,,) = allocationManager.getAllocation(operator, opSet, strategy);
        bool isMember = allocationManager.isMemberOfOperatorSet(operator, opSet);

        vm.startBroadcast(operatorPrivateKey);

        // Step 1: Update magnitude if needed
        if (currentMagnitude != newMagnitude) {
            console.log("\n[1] Setting magnitude (current -> target):");
            console.log("  current:", currentMagnitude);
            console.log("  target:", newMagnitude);
            IAllocationManagerPrepare.AllocateParams[] memory params = new IAllocationManagerPrepare.AllocateParams[](1);
            address[] memory strategies = new address[](1);
            strategies[0] = strategy;
            uint64[] memory magnitudes = new uint64[](1);
            magnitudes[0] = newMagnitude;
            params[0] = IAllocationManagerPrepare.AllocateParams({
                operatorSet: opSet,
                strategies: strategies,
                newMagnitudes: magnitudes
            });
            allocationManager.modifyAllocations(operator, params);
            console.log("[OK] modifyAllocations submitted");
        } else {
            console.log("\n[1] Magnitude already set to target:", currentMagnitude, "- skipping");
        }

        // Step 2: Register in operator set if not already a member
        if (!isMember) {
            console.log("\n[2] Registering operator in operatorSet", committeeId);
            uint32[] memory operatorSetIds = new uint32[](1);
            operatorSetIds[0] = committeeId;
            IAllocationManagerPrepare.RegisterParams memory regParams =
                IAllocationManagerPrepare.RegisterParams({avs: eigenAdapter, operatorSetIds: operatorSetIds, data: ""});
            allocationManager.registerForOperatorSets(operator, regParams);
            console.log("[OK] registerForOperatorSets submitted");
        } else {
            console.log("\n[2] Operator already member of operatorSet", committeeId, "- skipping");
        }

        vm.stopBroadcast();

        _printPostState();
    }

    function _printCurrentState() internal view {
        console.log("\n--- Current EigenLayer State ---");
        uint64 maxMag = allocationManager.getMaxMagnitude(operator, strategy);
        uint64 allocatable = allocationManager.getAllocatableMagnitude(operator, strategy);
        console.log("Max magnitude:", maxMag);
        console.log("Allocatable magnitude:", allocatable);

        IAllocationManagerPrepare.OperatorSet memory opSet =
            IAllocationManagerPrepare.OperatorSet({avs: eigenAdapter, id: committeeId});
        (uint64 currentMag, int128 pendingDiff, uint32 effectBlock) =
            allocationManager.getAllocation(operator, opSet, strategy);
        console.log("Current magnitude for opset", committeeId, ":", currentMag);
        console.log("Pending diff:", pendingDiff);
        console.log("Effect block:", effectBlock);

        bool isMember = allocationManager.isMemberOfOperatorSet(operator, opSet);
        bool isSlashable = allocationManager.isOperatorSlashable(operator, opSet);
        console.log("Is member of opset:", isMember);
        console.log("Is slashable:", isSlashable);

        uint32 delay = allocationManager.ALLOCATION_CONFIGURATION_DELAY();
        console.log("Allocation config delay (blocks):", delay);
    }

    function _printPostState() internal view {
        console.log("\n--- Post-Tx State ---");
        IAllocationManagerPrepare.OperatorSet memory opSet =
            IAllocationManagerPrepare.OperatorSet({avs: eigenAdapter, id: committeeId});
        (uint64 currentMag,, uint32 effectBlock) = allocationManager.getAllocation(operator, opSet, strategy);
        bool isMember = allocationManager.isMemberOfOperatorSet(operator, opSet);
        bool isSlashable = allocationManager.isOperatorSlashable(operator, opSet);

        console.log("Magnitude for opset", committeeId, ":", currentMag);
        console.log("Magnitude effective at block:", effectBlock);
        console.log("Is member:", isMember);
        console.log("Is slashable:", isSlashable);

        if (effectBlock > 0) {
            console.log(
                "\n[IMPORTANT] Wait for block", effectBlock, "before filing claims against committee", committeeId
            );
            console.log("(Current block will be known after tx mines)");
        } else {
            console.log("[OK] Operator is fully configured and slashable for committee", committeeId);
        }
    }
}
