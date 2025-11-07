// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Deploy} from "./Deploy.s.sol";

/**
 * @title DeployEthereum
 * @notice Deploys a CoverPool instance to the Ethereum mainnet.
 */
contract DeployEthereum is Deploy {
    /// @inheritdoc Deploy
    function getDeploymentConfig() internal pure override returns (DeploymentConfig memory) {
        return DeploymentConfig({networkName: "Ethereum", chainId: 1});
    }
}
