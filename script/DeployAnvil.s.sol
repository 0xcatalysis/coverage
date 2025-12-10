// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Deploy} from "./Deploy.s.sol";

/**
 * @title DeployAnvil
 * @notice Deploys all Catalysis Coverage contracts to a local Anvil chain.
 * @dev All external dependencies must be provided via environment variables:
 *      - NATIVE_WRAPPER: Address of WETH or mock wrapper contract
 *      - SPEC_REGISTRY: Address of SpecRegistry from Catalysis Core
 *      - SLASHING_MANAGER: Address of SlashingManager from Catalysis Core
 *
 *      Usage:
 *        NATIVE_WRAPPER=0x... SPEC_REGISTRY=0x... SLASHING_MANAGER=0x... \
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
     * @return ExternalConfig loaded from NATIVE_WRAPPER, SPEC_REGISTRY, SLASHING_MANAGER env vars.
     */
    function getExternalConfig() internal view override returns (ExternalConfig memory) {
        return ExternalConfig({
            nativeWrapper: vm.envAddress("NATIVE_WRAPPER"),
            specRegistry: vm.envAddress("SPEC_REGISTRY"),
            slashingManager: vm.envAddress("SLASHING_MANAGER"),
            priceFeed: vm.envAddress("PRICE_FEED")
        });
    }
}
