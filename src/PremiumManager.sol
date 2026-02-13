// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPremiumManager} from "./interfaces/IPremiumManager.sol";
import {IRewardsManager} from "./interfaces/IRewardsManager.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";

/**
 * @title PremiumManager
 * @notice Receives premiums from PremiumCollector, carves protocol/curator fees, and distributes restaker shares.
 * @dev Normalizes premium flows across pools and provides pause hooks for emergency halts.
 *      Integrates with RewardsManager to distribute premiums to restakers.
 */
// slither-disable-next-line unimplemented-functions
contract PremiumManager is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IPremiumManager
{
    using SafeERC20 for IERC20;

    bytes32 public constant override PREMIUM_COLLECTOR_ROLE = keccak256("PREMIUM_COLLECTOR_ROLE");

    uint16 private constant _BPS_DENOMINATOR = 10_000;
    uint16 private constant _MAX_FEE_BPS = 10_000;
    uint16 private constant _MAX_PLATFORM_FEE_BPS = 2500; // 25%

    address public override rewardsManager;
    address public override platformTreasury;
    uint16 public override platformFeeBps;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the PremiumManager with role assignments and configuration.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param rewardsManager_ Address of the RewardsManager contract for reward distribution.
     * @param platformTreasury_ Address of the platform treasury.
     * @param platformFeeBps_ Platform fee in basis points (max 2500 = 25%).
     */
    function initialize(
        address admin_,
        address rewardsManager_,
        address platformTreasury_,
        uint16 platformFeeBps_
    )
        external
        initializer
    {
        require(admin_ != address(0) && rewardsManager_ != address(0) && platformTreasury_ != address(0), ZeroAddress());
        require(platformFeeBps_ <= _MAX_PLATFORM_FEE_BPS, InvalidPlatformFeeBps(platformFeeBps_));

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        rewardsManager = rewardsManager_;
        platformTreasury = platformTreasury_;
        platformFeeBps = platformFeeBps_;
    }

    /**
     * @inheritdoc IPremiumManager
     */
    function pause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc IPremiumManager
     */
    function unpause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @inheritdoc IPremiumManager
     */
    function setRewardsManager(address rewardsManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(rewardsManager_ != address(0), ZeroAddress());
        rewardsManager = rewardsManager_;
        emit RewardsManagerSet(rewardsManager_);
    }

    /**
     * @inheritdoc IPremiumManager
     */
    function setPlatformTreasury(address platformTreasury_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(platformTreasury_ != address(0), ZeroAddress());
        platformTreasury = platformTreasury_;
        emit PlatformTreasurySet(platformTreasury_);
    }

    /**
     * @inheritdoc IPremiumManager
     */
    function setPlatformFeeBps(uint16 platformFeeBps_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(platformFeeBps_ <= _MAX_PLATFORM_FEE_BPS, InvalidPlatformFeeBps(platformFeeBps_));
        platformFeeBps = platformFeeBps_;
        emit PlatformFeeBpsSet(platformFeeBps_);
    }

    /**
     * @inheritdoc IPremiumManager
     */
    function distributePremium(
        address pool,
        uint96 policyId,
        address operator,
        address premiumToken,
        uint256 amount
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(PREMIUM_COLLECTOR_ROLE)
    {
        require(pool != address(0) && operator != address(0) && premiumToken != address(0), ZeroAddress());
        require(amount != 0, ZeroAmount());
        require(policyId != 0, InvalidCommitteeId());

        uint16 poolFeeBps = ICoverPool(pool).poolFeeBps();
        address poolFeeRecipient = ICoverPool(pool).owner();
        require(poolFeeRecipient != address(0), ZeroAddress());

        uint16 totalFeeBps = platformFeeBps + poolFeeBps;
        require(totalFeeBps <= _MAX_FEE_BPS, ExcessiveCombinedFees(platformFeeBps, poolFeeBps, totalFeeBps));

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            getFeeSplits(amount, platformFeeBps, poolFeeBps);

        IERC20 token = IERC20(premiumToken);

        if (platformSplit > 0) {
            token.safeTransfer(platformTreasury, platformSplit);
        }

        if (poolSplit > 0) {
            token.safeTransfer(poolFeeRecipient, poolSplit);
        }

        if (restakerSplit > 0) {
            token.safeTransfer(rewardsManager, restakerSplit);
            IRewardsManager(rewardsManager).distributeRewards(policyId, operator, restakerSplit, token);
        }

        emit PremiumDistributed(pool, policyId, amount);
    }

    /**
     * @inheritdoc IPremiumManager
     */
    function paused() public view override (IPremiumManager, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    /**
     * @inheritdoc IPremiumManager
     */
    function getFeeSplits(
        uint256 grossPremium,
        uint16 platformFeeBps_,
        uint16 poolFeeBps_
    )
        public
        pure
        override
        returns (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit)
    {
        platformSplit = (grossPremium * platformFeeBps_) / _BPS_DENOMINATOR;
        poolSplit = (grossPremium * poolFeeBps_) / _BPS_DENOMINATOR;
        restakerSplit = grossPremium - platformSplit - poolSplit;
    }

    /**
     * @notice Restricts UUPS upgrade authorization to DEFAULT_ADMIN_ROLE holders.
     */
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
