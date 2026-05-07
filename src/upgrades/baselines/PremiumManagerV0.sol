// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title PremiumManagerV0
 * @notice Skeleton reference contract capturing the audit-baseline storage layout of PremiumManager
 *         (commit d8d492a). Used by the OpenZeppelin Upgrades plugin as referenceContract.
 *
 *         Storage layout (audit baseline d8d492a):
 *           slot 0: ReentrancyGuard._status
 *           slot 1: rewardsManager (addr 20)
 *           slot 2: platformTreasury (addr 20) + platformFeeBps (uint16 2), packed
 *           slot 3: _distributionNonce (uint256)
 *
 * @dev This contract is ONLY used as a layout reference. It has no logic and must never be deployed.
 */
contract PremiumManagerV0 is UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuard {
    address public rewardsManager;
    address public platformTreasury;
    uint16 public platformFeeBps;

    uint256 private _distributionNonce;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
