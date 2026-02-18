// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ICoverPoolFactory} from "../../src/interfaces/ICoverPoolFactory.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";

/**
 * @title CreateCoverPool
 * @notice Creates a CoverPool via CoverPoolFactory and registers the curator as an operator.
 * @dev Corresponds to Document Flow 1 – CoverPool Creation:
 *      1a. Curator creates a CoverPool from CoverPoolFactory
 *      1b. CoverPool curator registers itself as the operator of Catalysis AVS/Network
 *
 * Usage:
 *   forge script script/testing/CreateCoverPool.s.sol:CreateCoverPool \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - CURATOR_PRIVATE_KEY: Private key of the curator (will be pool owner/operator)
 *   - COVER_POOL_FACTORY: CoverPoolFactory proxy address
 *   - QUOTE_SIGNER: Address authorized to sign coverage quotes
 *   - POOL_FEE_BPS: Pool fee in basis points (e.g. 1000 = 10%, max 2000 = 20%)
 *   - OPERATOR_DEADLINE: Deadline timestamp for operator registration signature
 *   - OPERATOR_SIGNATURE: Hex-encoded operator registration signature for StakeManager
 *
 * Prerequisites:
 *   - Curator must have CREATOR_ROLE on CoverPoolFactory (or caller must be the CREATOR)
 *   - Curator must be registered as an operator on Symbiotic/EigenLayer
 *   - Operator signature must be valid for StakeManager.registerOperatorToNetwork()
 */
contract CreateCoverPool is Script {
    /// @notice Curator address derived from private key
    address public curator;

    /// @notice Curator's private key for signing transactions
    uint256 public curatorPrivateKey;

    /// @notice CoverPoolFactory proxy address
    address public coverPoolFactory;

    /// @notice Quote signer address
    address public quoteSigner;

    /// @notice Pool fee in basis points
    uint16 public poolFeeBps;

    /// @notice Operator registration deadline
    uint48 public operatorDeadline;

    /// @notice Operator registration signature
    bytes public operatorSignature;

    /// @notice CoverPoolFactory contract instance
    ICoverPoolFactory public factoryContract;

    /// @notice Emitted when cover pool is created
    event CoverPoolCreated(address indexed coverPool, address indexed curator, address quoteSigner, uint16 poolFeeBps);

    constructor() {
        curatorPrivateKey = vm.envUint("CURATOR_PRIVATE_KEY");
        curator = vm.addr(curatorPrivateKey);

        coverPoolFactory = vm.envAddress("COVER_POOL_FACTORY");
        quoteSigner = vm.envAddress("QUOTE_SIGNER");
        poolFeeBps = uint16(vm.envUint("POOL_FEE_BPS"));
        operatorDeadline = uint48(vm.envUint("OPERATOR_DEADLINE"));
        operatorSignature = vm.envBytes("OPERATOR_SIGNATURE");

        factoryContract = ICoverPoolFactory(coverPoolFactory);
    }

    function run() external {
        console.log("=== FLOW 1: COVER POOL CREATION ===");
        console.log("Curator:", curator);
        console.log("CoverPoolFactory:", coverPoolFactory);
        console.log("Quote Signer:", quoteSigner);
        console.log("Pool Fee BPS:", poolFeeBps);

        ICoverPoolFactory.CreateCoverPoolParams memory params = ICoverPoolFactory.CreateCoverPoolParams({
            curator: curator,
            quoteSigner: quoteSigner,
            poolFeeBps: poolFeeBps,
            deadline: operatorDeadline,
            signature: operatorSignature
        });

        // Predict the deterministic address before creation
        address predictedPool = factoryContract.computeCoverPoolAddress(params);
        console.log("Predicted Pool Address:", predictedPool);

        uint256 totalPoolsBefore = factoryContract.totalCoverPools();
        console.log("Total Pools Before:", totalPoolsBefore);

        vm.startBroadcast(curatorPrivateKey);

        factoryContract.createCoverPool(params);

        vm.stopBroadcast();

        _verifyCreation(predictedPool, totalPoolsBefore);

        console.log("\n=== COVER POOL CREATION COMPLETED ===");
        emit CoverPoolCreated(predictedPool, curator, quoteSigner, poolFeeBps);
    }

    function _verifyCreation(address predictedPool, uint256 totalPoolsBefore) internal view {
        console.log("\n--- Verification ---");

        uint256 totalPoolsAfter = factoryContract.totalCoverPools();
        console.log("Total Pools After:", totalPoolsAfter);
        require(totalPoolsAfter == totalPoolsBefore + 1, "Pool count did not increase");

        bool exists = factoryContract.coverPoolExists(predictedPool);
        console.log("Pool exists in factory:", exists);
        require(exists, "Pool not found in factory");

        ICoverPool pool = ICoverPool(predictedPool);
        address owner = pool.owner();
        console.log("Pool owner (curator):", owner);
        require(owner == curator, "Pool owner mismatch");

        uint16 fee = pool.poolFeeBps();
        console.log("Pool fee BPS:", fee);
        require(fee == poolFeeBps, "Pool fee mismatch");

        console.log("[SUCCESS] CoverPool created and verified");
    }
}
