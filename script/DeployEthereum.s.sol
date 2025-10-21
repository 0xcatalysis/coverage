// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Deploy} from "./Deploy.s.sol";

/**
 * @title DeployEthereum
 * @notice Deploys a CoverPool instance to the Ethereum mainnet.
 */
contract DeployEthereum is Deploy {
    /// @inheritdoc Deploy
    function getDeploymentConfig() internal view override returns (DeploymentConfig memory) {
        uint256 expectedChainId = vm.envOr("ETHEREUM_CHAIN_ID", uint256(1));
        return DeploymentConfig({networkName: "Ethereum", expectedChainId: expectedChainId});
    }
}
