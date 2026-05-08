// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Deploy} from "./Deploy.s.sol";

/**
 * @title DeployAnvil
 * @notice Deploys all Catalysis Coverage contracts to a local Anvil chain.
 * @dev WETH address is hardcoded for Anvil. External dependencies must be provided via environment variables:
 *      - SLASHING_MANAGER: Address of SlashingManager from Catalysis Core
 *      - STAKE_MANAGER: Address of StakeManager from Catalysis Core
 *      - REWARDS_MANAGER: Address of RewardsManager from Catalysis Core
 *      - ORACLE_PRICE_FEED: Address of OraclePriceFeed
 *
 *      Usage:
 *        SLASHING_MANAGER=0x... STAKE_MANAGER=0x... REWARDS_MANAGER=0x...
 * ORACLE_PRICE_FEED=0x... \
 *          forge script script/DeployAnvil.s.sol --broadcast --rpc-url http://localhost:8545
 */
contract DeployAnvil is Deploy {
    /// @notice Hardcoded WETH address for Anvil local testing.
    address internal constant WETH_ANVIL = 0x0000000000000000000000000000000000000001;

    /// @notice Zero timelock delay for instant local testing.
    function getTimelockMinDelay() internal pure override returns (uint256) {
        return 0;
    }

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
            slashingManager: vm.envAddress("SLASHING_MANAGER"),
            oraclePriceFeed: vm.envAddress("ORACLE_PRICE_FEED"),
            stakeManager: vm.envAddress("STAKE_MANAGER"),
            rewardsManager: vm.envAddress("REWARDS_MANAGER")
        });
    }
}
