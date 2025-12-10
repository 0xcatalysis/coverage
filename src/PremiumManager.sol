// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPremiumManager} from "./interfaces/IPremiumManager.sol";
import {IPremiumReserve} from "./interfaces/IPremiumReserve.sol";

/**
 * @title PremiumManager
 * @notice Collects upfront base premiums, carves protocol/curator fees, and forwards restaker shares into escrow.
 * @dev Normalizes premium flows across pools and provides pause hooks for emergency halts.
 *      Integrates with PremiumReserve to open escrow positions for newly bound policies.
 */
// slither-disable-next-line unimplemented-functions
contract PremiumManager is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IPremiumManager
{
    using SafeERC20 for IERC20;

    bytes32 public constant override POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");

    uint16 private constant _BPS_DENOMINATOR = 10_000;
    uint16 private constant _MAX_FEE_BPS = 10_000;

    address public override premiumReserve;
    address public override platformTreasury;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the PremiumManager with role assignments and reserve wiring.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param policyManager_ Address granted POLICY_MANAGER_ROLE for triggering premium collection.
     * @param premiumReserve_ Address of the PremiumReserve contract for escrow operations.
     * @param platformTreasury_ Address of the platform treasury.
     */
    function initialize(
        address admin_,
        address policyManager_,
        address premiumReserve_,
        address platformTreasury_
    )
        external
        initializer
    {
        require(
            admin_ != address(0) && policyManager_ != address(0) && premiumReserve_ != address(0)
                && platformTreasury_ != address(0),
            ZeroAddress()
        );

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(POLICY_MANAGER_ROLE, policyManager_);

        premiumReserve = premiumReserve_;
        platformTreasury = platformTreasury_;
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
    function setPremiumReserve(address premiumReserve_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(premiumReserve_ != address(0), ZeroAddress());
        premiumReserve = premiumReserve_;
        emit PremiumReserveSet(premiumReserve_);
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
    function collectPremium(PremiumAllocation calldata allocation)
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(POLICY_MANAGER_ROLE)
    {
        _validateAllocation(allocation);

        PoolShare calldata poolShare = allocation.poolShare;

        require(poolShare.coverPool != address(0), ZeroAddress());
        require(poolShare.poolFeeRecipient != address(0), ZeroAddress());
        require(poolShare.operator != address(0), ZeroAddress());
        require(poolShare.grossPremium != 0, ZeroAmount());
        require(allocation.committeeId != 0, InvalidCommitteeId());
        require(
            poolShare.grossPremium == allocation.basePremium,
            PremiumTotalsMismatch(allocation.basePremium, poolShare.grossPremium)
        );

        uint16 totalFeeBps = allocation.platformFeeBps + poolShare.poolFeeBps;
        require(
            totalFeeBps <= _MAX_FEE_BPS,
            ExcessiveCombinedFees(allocation.platformFeeBps, poolShare.poolFeeBps, totalFeeBps)
        );

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerPremium) =
            getFeeSplits(poolShare.grossPremium, allocation.platformFeeBps, poolShare.poolFeeBps);

        IERC20 token = IERC20(allocation.premiumToken);

        if (platformSplit > 0) {
            // slither-disable-next-line arbitrary-send-erc20
            token.safeTransferFrom(allocation.buyer, platformTreasury, platformSplit);
        }

        if (poolSplit > 0) {
            // slither-disable-next-line arbitrary-send-erc20
            token.safeTransferFrom(allocation.buyer, poolShare.poolFeeRecipient, poolSplit);
        }

        if (restakerPremium > 0) {
            // slither-disable-next-line arbitrary-send-erc20
            token.safeTransferFrom(allocation.buyer, premiumReserve, restakerPremium);

            IPremiumReserve.EscrowPosition memory escrowPosition = IPremiumReserve.EscrowPosition({
                policyId: allocation.policyId,
                policyCommit: allocation.policyCommit,
                restakerPremiumTotal: restakerPremium,
                premiumToken: allocation.premiumToken,
                buyer: allocation.buyer,
                pool: poolShare.coverPool,
                operator: poolShare.operator,
                committeeId: allocation.committeeId,
                startTime: allocation.startTime,
                maturityTime: allocation.maturityTime,
                claimLocked: false
            });

            IPremiumReserve(premiumReserve).openEscrow(escrowPosition);
        }

        emit PremiumCollected(allocation.policyId, allocation.basePremium);
    }

    /**
     * @inheritdoc IPremiumManager
     */
    function getFeeSplits(
        uint256 grossPremium,
        uint16 platformFeeBps,
        uint16 poolFeeBps
    )
        public
        pure
        override
        returns (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit)
    {
        platformSplit = (grossPremium * platformFeeBps) / _BPS_DENOMINATOR;
        poolSplit = (grossPremium * poolFeeBps) / _BPS_DENOMINATOR;
        restakerSplit = grossPremium - platformSplit - poolSplit;
    }

    /**
     * @inheritdoc IPremiumManager
     */
    function paused() public view override (IPremiumManager, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    /**
     * @notice Restricts UUPS upgrade authorization to DEFAULT_ADMIN_ROLE holders.
     */
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Validates allocation data before premium collection.
     * @param allocation Premium allocation details to validate.
     */
    function _validateAllocation(PremiumAllocation calldata allocation) private pure {
        require(allocation.buyer != address(0) && allocation.premiumToken != address(0), ZeroAddress());
        require(allocation.basePremium != 0, ZeroAmount());
        require(allocation.policyCommit != bytes32(0), InvalidPolicyCommit());
        require(
            allocation.startTime < allocation.maturityTime,
            InvalidCoverageWindow(allocation.startTime, allocation.maturityTime)
        );
    }
}
