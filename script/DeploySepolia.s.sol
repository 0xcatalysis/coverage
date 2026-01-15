// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Deploy} from "./Deploy.s.sol";

/**
 * @title DeploySepolia
 * @notice Deploys all Catalysis Coverage contracts to the Ethereum Sepolia testnet.
 * @dev WETH address is hardcoded for Sepolia. Catalysis Core addresses must be provided
 *      via environment variables:
 *      - SPEC_REGISTRY: Address of SpecRegistry contract
 *      - SLASHING_MANAGER: Address of SlashingManager from Catalysis Core
 *      - STAKE_MANAGER: Address of StakeManager from Catalysis Core
 *      - REWARDS_MANAGER: Address of RewardsManager from Catalysis Core
 *      - CHAINLINK_PRICE_FEED: Address of ChainlinkPriceFeed
 *
 *      For testnet testing, deploy mock SpecRegistry first using:
 *        make deploy-specregistry-sepolia
 *      Then use the output address as SPEC_REGISTRY value.
 *
 *      Usage:
 *        SPEC_REGISTRY=0x... SLASHING_MANAGER=0x... STAKE_MANAGER=0x... REWARDS_MANAGER=0x...
 * CHAINLINK_PRICE_FEED=0x... PRIVATE_KEY=0x... \
 *          forge script script/DeploySepolia.s.sol --broadcast --rpc-url sepolia --verify
 */
contract DeploySepolia is Deploy {
    /// @notice Canonical WETH address on Ethereum Sepolia testnet.
    address internal constant WETH_SEPOLIA = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;

    /**
     * @inheritdoc Deploy
     * @return DeploymentConfig for Sepolia testnet (chain id 11155111).
     */
    function getDeploymentConfig() internal pure override returns (DeploymentConfig memory) {
        return DeploymentConfig({networkName: "Sepolia", chainId: 11_155_111});
    }

    /**
     * @inheritdoc Deploy
     * @dev Uses hardcoded WETH address for Sepolia. SpecRegistry, SlashingManager, StakeManager,
     *      and RewardsManager addresses must be provided via environment variables.
     * @return ExternalConfig with Sepolia WETH and env-loaded Catalysis Core addresses.
     */
    function getExternalConfig() internal view override returns (ExternalConfig memory) {
        return ExternalConfig({
            nativeWrapper: WETH_SEPOLIA,
            specRegistry: vm.envAddress("SPEC_REGISTRY"),
            slashingManager: vm.envAddress("SLASHING_MANAGER"),
            chainlinkPriceFeed: vm.envAddress("CHAINLINK_PRICE_FEED"),
            stakeManager: vm.envAddress("STAKE_MANAGER"),
            rewardsManager: vm.envAddress("REWARDS_MANAGER")
        });
    }
}
