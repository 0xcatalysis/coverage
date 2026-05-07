// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title PolicyManagerV0
 * @notice Skeleton reference contract capturing the audit-baseline storage layout of PolicyManager
 *         (commit d8d492a). Used by the OpenZeppelin Upgrades plugin as referenceContract.
 *
 *         Storage layout (audit baseline d8d492a):
 *           slot 0: ReentrancyGuard._status
 *           slot 1: stakeManager (addr 20)
 *           slot 2: claimManager (addr 20)
 *           slot 3: coverPoolFactory (addr 20)
 *           slot 4: _nextPolicyId (uint96, lower 12 bytes)
 *           slot 5: _policyDrafts mapping seed
 *           slot 6: _policies mapping seed
 *           slot 7: _registeredPolicyCommits mapping seed
 *           slot 8: supportedPayoutTokens mapping seed
 *           slot 9: chainlinkPriceFeed (addr 20)
 *
 * @dev This contract is ONLY used as a layout reference. It has no logic and must never be deployed.
 */
contract PolicyManagerV0 is UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuard {
    address public stakeManager;
    address public claimManager;
    address public coverPoolFactory;

    uint96 private _nextPolicyId;
    mapping(uint96 => bytes32) private _policyDrafts;
    mapping(uint96 => bytes32) private _policies;
    mapping(bytes32 => bool) private _registeredPolicyCommits;
    mapping(address => bool) public supportedPayoutTokens;
    address public chainlinkPriceFeed;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
