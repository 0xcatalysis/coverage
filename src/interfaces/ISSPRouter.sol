// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ISSPRouter
 * @notice Interface for Catalysis Core SSPRouter contract.
 * @dev Coverage contracts interact with SSPRouter to register operators to restaking networks.
 */
interface ISSPRouter {
    /**
     * @notice Registers an operator to the network through the Symbiotic module (Symbiotic Protocol)
     * @dev This function is specifically for Symbiotic protocol operator registration
     * @param operator The address of the operator to register
     * @param deadline The deadline of the registration
     * @param signature The signature of the operator
     */
    function registerOperatorToNetwork(address operator, uint48 deadline, bytes calldata signature) external;
}
