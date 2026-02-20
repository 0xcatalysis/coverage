// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Deploy} from "./Deploy.s.sol";

/**
 * @title DeployEthereum
 * @notice Deploys all Catalysis Coverage contracts to Ethereum mainnet.
 * @dev WETH address is hardcoded for mainnet. Catalysis Core addresses must be provided
 *      via environment variables:
 *      - SLASHING_MANAGER: Address of SlashingManager from Catalysis Core
 *      - STAKE_MANAGER: Address of StakeManager from Catalysis Core
 *      - REWARDS_MANAGER: Address of RewardsManager from Catalysis Core
 *      - CHAINLINK_PRICE_FEED: Address of ChainlinkPriceFeed
 *
 *      Usage:
 *        SLASHING_MANAGER=0x... STAKE_MANAGER=0x... REWARDS_MANAGER=0x...
 * CHAINLINK_PRICE_FEED=0x... PRIVATE_KEY=0x... \
 *          forge script script/DeployEthereum.s.sol --broadcast --rpc-url mainnet --verify
 */
contract DeployEthereum is Deploy {
    /// @notice Canonical WETH address on Ethereum mainnet.
    address internal constant WETH_MAINNET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /**
     * @inheritdoc Deploy
     * @return DeploymentConfig for Ethereum mainnet (chain id 1).
     */
    function getDeploymentConfig() internal pure override returns (DeploymentConfig memory) {
        return DeploymentConfig({networkName: "Ethereum", chainId: 1});
    }

    /**
     * @inheritdoc Deploy
     * @dev Uses hardcoded WETH address for mainnet. SpecRegistry, SlashingManager, StakeManager,
     *      and RewardsManager addresses must be provided via environment variables.
     * @return ExternalConfig with mainnet WETH and env-loaded Catalysis Core addresses.
     */
    function getExternalConfig() internal view override returns (ExternalConfig memory) {
        return ExternalConfig({
            nativeWrapper: WETH_MAINNET,
            slashingManager: vm.envAddress("SLASHING_MANAGER"),
            chainlinkPriceFeed: vm.envAddress("CHAINLINK_PRICE_FEED"),
            stakeManager: vm.envAddress("STAKE_MANAGER"),
            rewardsManager: vm.envAddress("REWARDS_MANAGER")
        });
    }
}
