// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/// @title ICreateX
/// @notice Minimal interface for the CreateX deterministic deployer.
/// @dev Full contract at https://github.com/pcaversaccio/createx
///      Deployed at 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed on all EVM chains.
interface ICreateX {
    /// @notice Deploys a contract via CREATE3 using an explicit salt.
    /// @param salt 32-byte salt (bytes 0-19: permissioned deployer, byte 20: redeploy protection, bytes 21-31:
    /// entropy). @param initCode Creation bytecode of the contract to deploy.
    /// @return newContract Address of the deployed contract.
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);

    /// @notice Computes the CREATE3 deployment address for a given salt and deployer.
    /// @param salt 32-byte salt (same format as deployCreate3).
    /// @param deployer Address of the account calling deployCreate3.
    /// @return computedAddress The deterministic address.
    function computeCreate3Address(bytes32 salt, address deployer) external pure returns (address computedAddress);

    /// @notice Computes the CREATE3 deployment address for a given salt (deployer = address(this)).
    /// @param salt 32-byte salt (same format as deployCreate3).
    /// @return computedAddress The deterministic address.
    function computeCreate3Address(bytes32 salt) external view returns (address computedAddress);
}
