// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Deploy} from "./Deploy.s.sol";

/**
 * @title DeployAnvil
 * @notice Deploys all Catalysis Coverage contracts to a local Anvil chain.
 * @dev WETH address is hardcoded for Anvil. External dependencies must be provided via environment variables:
 *      - SPEC_REGISTRY: Address of SpecRegistry contract
 *      - SLASHING_MANAGER: Address of SlashingManager from Catalysis Core
 *      - STAKE_MANAGER: Address of StakeManager from Catalysis Core
 *      - REWARDS_MANAGER: Address of RewardsManager from Catalysis Core
 *      - CHAINLINK_PRICE_FEED: Address of ChainlinkPriceFeed
 *
 *      Usage:
 *        SPEC_REGISTRY=0x... SLASHING_MANAGER=0x... STAKE_MANAGER=0x... REWARDS_MANAGER=0x...
 * CHAINLINK_PRICE_FEED=0x... \
 *          forge script script/DeployAnvil.s.sol --broadcast --rpc-url http://localhost:8545
 */
contract DeployAnvil is Deploy {
    /// @notice Hardcoded WETH address for Anvil local testing.
    address internal constant WETH_ANVIL = 0x0000000000000000000000000000000000000001;

    /**
     * @inheritdoc Deploy
     * @return DeploymentConfig for Anvil local chain (chain id 31337).
     */
    function getDeploymentConfig() internal pure override returns (DeploymentConfig memory) {
        return DeploymentConfig({networkName: "Anvil", chainId: 31_337});
    }

    /**
     * @inheritdoc Deploy
     * @dev Uses hardcoded WETH address for Anvil. Other external addresses loaded from environment variables.
     * @return ExternalConfig with Anvil WETH and env-loaded Catalysis Core addresses.
     */
    function getExternalConfig() internal view override returns (ExternalConfig memory) {
        return ExternalConfig({
            nativeWrapper: WETH_ANVIL,
            specRegistry: vm.envAddress("SPEC_REGISTRY"),
            slashingManager: vm.envAddress("SLASHING_MANAGER"),
            chainlinkPriceFeed: vm.envAddress("CHAINLINK_PRICE_FEED"),
            stakeManager: vm.envAddress("STAKE_MANAGER"),
            rewardsManager: vm.envAddress("REWARDS_MANAGER")
        });
    }
}
