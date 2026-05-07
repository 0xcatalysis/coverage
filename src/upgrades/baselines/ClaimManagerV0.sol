// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title ClaimManagerV0
 * @notice Skeleton reference contract capturing the audit-baseline storage layout of ClaimManager
 *         (commit d8d492a). Used by the OpenZeppelin Upgrades plugin as referenceContract to
 *         detect breaking layout changes before any in-place upgrade.
 *
 *         Storage layout (audit baseline d8d492a):
 *           slot 0: ReentrancyGuard._status
 *           slot 1: specRegistry
 *           slot 2: slashingManager
 *           slot 3: swapper
 *           slot 4: policyManager
 *           slot 5: chainlinkPriceFeed (addr 20) + maxSwapSlippageBps (uint16 2), packed
 *           slot 6: _claims mapping seed
 *           slot 7: _policyClaims mapping seed
 *           slot 8: _claimApprovalRequired mapping seed
 *           slot 9: _usedEvidenceHashes mapping seed
 *
 * @dev This contract is ONLY used as a layout reference. It has no logic and must never be deployed.
 */
contract ClaimManagerV0 is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    address public specRegistry;
    address public slashingManager;
    address public swapper;
    address public policyManager;
    address public chainlinkPriceFeed;
    uint16 public maxSwapSlippageBps;

    mapping(uint96 => mapping(uint256 => bytes32)) private _claims;
    mapping(uint96 => bytes32) private _policyClaims;
    mapping(uint96 => bool) private _claimApprovalRequired;
    mapping(uint96 => mapping(bytes32 => bool)) private _usedEvidenceHashes;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
