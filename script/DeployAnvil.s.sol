// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Deploy} from "./Deploy.s.sol";

/**
 * @title DeployAnvil
 * @notice Deploys all Catalysis Coverage contracts to a local Anvil chain.
 * @dev All external dependencies must be provided via environment variables:
 *      - NATIVE_WRAPPER: Address of WETH or mock wrapper contract
 *      - SPEC_REGISTRY: Address of SpecRegistry contract
 *      - SLASHING_MANAGER: Address of SlashingManager from Catalysis Core
 *      - STAKE_MANAGER: Address of StakeManager from Catalysis Core
 *      - REWARDS_MANAGER: Address of RewardsManager from Catalysis Core
 *      - CHAINLINK_PRICE_FEED: Address of ChainlinkPriceFeed
 *
 *      Usage:
 *        NATIVE_WRAPPER=0x... SPEC_REGISTRY=0x... SLASHING_MANAGER=0x... STAKE_MANAGER=0x... REWARDS_MANAGER=0x...
 * CHAINLINK_PRICE_FEED=0x... \
 *          forge script script/DeployAnvil.s.sol --broadcast --rpc-url http://localhost:8545
 */
contract DeployAnvil is Deploy {
    /**
     * @inheritdoc Deploy
     * @return DeploymentConfig for Anvil local chain (chain id 31337).
     */
    function getDeploymentConfig() internal pure override returns (DeploymentConfig memory) {
        return DeploymentConfig({networkName: "Anvil", chainId: 31_337});
    }

    /**
     * @inheritdoc Deploy
     * @dev Loads all external addresses from environment variables. No hardcoded addresses
     *      for local testing to allow flexible mock contract deployment.
     * @return ExternalConfig loaded from NATIVE_WRAPPER, SPEC_REGISTRY, SLASHING_MANAGER, STAKE_MANAGER,
     * REWARDS_MANAGER, CHAINLINK_PRICE_FEED env vars.
     */
    function getExternalConfig() internal view override returns (ExternalConfig memory) {
        return ExternalConfig({
            nativeWrapper: vm.envAddress("NATIVE_WRAPPER"),
            specRegistry: vm.envAddress("SPEC_REGISTRY"),
            slashingManager: vm.envAddress("SLASHING_MANAGER"),
            chainlinkPriceFeed: vm.envAddress("CHAINLINK_PRICE_FEED"),
            stakeManager: vm.envAddress("STAKE_MANAGER"),
            rewardsManager: vm.envAddress("REWARDS_MANAGER")
        });
    }
}
