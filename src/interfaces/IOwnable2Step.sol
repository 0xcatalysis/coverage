// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IOwnable2Step
 * @notice Minimal ERC-173 compatible interface for two-step ownership transfers.
 */
interface IOwnable2Step {
    /**
     * @notice Returns the current owner of the contract.
     * @return owner_ Address that controls privileged operations.
     */
    function owner() external view returns (address);

    /**
     * @notice Returns the address that has been nominated to accept ownership.
     * @dev Will be the zero address if no transfer is in progress.
     * @return pendingOwner_ Address that must call `acceptOwnership` to finalize the transfer.
     */
    function pendingOwner() external view returns (address);

    /**
     * @notice Initiates a two-step ownership transfer by setting `newOwner` as pending owner.
     * @dev Reverts if called by anyone other than the current owner or if `newOwner` is the zero address.
     * @param newOwner Address that will gain ownership once `acceptOwnership` is executed.
     */
    function transferOwnership(address newOwner) external;

    /**
     * @notice Completes a pending ownership transfer.
     * @dev Must be called by the nominated pending owner.
     */
    function acceptOwnership() external;
}
