// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
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
contract PremiumManager is
    Initializable,
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the PremiumManager with role assignments and reserve wiring.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param policyManager_ Address granted POLICY_MANAGER_ROLE for triggering premium collection.
     * @param premiumReserve_ Address of the PremiumReserve contract for escrow operations.
     */
    function initialize(address admin_, address policyManager_, address premiumReserve_) external initializer {
        require(admin_ != address(0) && policyManager_ != address(0) && premiumReserve_ != address(0), ZeroAddress());

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(POLICY_MANAGER_ROLE, policyManager_);

        premiumReserve = premiumReserve_;
        emit PremiumReserveSet(premiumReserve_);
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
    function setPremiumReserve(address reserve) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(reserve != address(0), ZeroAddress());
        premiumReserve = reserve;
        emit PremiumReserveSet(reserve);
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

        uint256 poolSharesLength = allocation.poolShares.length;
        require(poolSharesLength != 0, NoPoolShares());

        uint256 observedTotal = 0;
        for (uint256 i = 0; i < poolSharesLength; ++i) {
            observedTotal += allocation.poolShares[i].grossPremium;
        }
        require(
            observedTotal == allocation.basePremiumTotal,
            PremiumTotalsMismatch(allocation.basePremiumTotal, observedTotal)
        );

        (uint256 totalPlatformFees, uint256 totalRestakerPremiums, IPremiumReserve.PoolPremium[] memory poolPremiums) =
            _processPoolShares(allocation);

        if (totalPlatformFees != 0) {
            IERC20(allocation.premiumToken)
                .safeTransferFrom(allocation.buyer, allocation.platformFeeRecipient, totalPlatformFees);
        }

        if (totalRestakerPremiums != 0) {
            IERC20(allocation.premiumToken).safeTransferFrom(allocation.buyer, premiumReserve, totalRestakerPremiums);

            IPremiumReserve.EscrowPosition memory escrowPosition = IPremiumReserve.EscrowPosition({
                policyId: allocation.policyId,
                policyCommit: allocation.policyCommit,
                restakerPremiumTotal: totalRestakerPremiums,
                premiumToken: allocation.premiumToken,
                buyer: allocation.buyer,
                startTime: allocation.startTime,
                maturityTime: allocation.maturityTime,
                claimLocked: false,
                poolPremiums: poolPremiums
            });

            IPremiumReserve(premiumReserve).openEscrow(escrowPosition);
        }

        emit PremiumCollected(allocation.policyId, allocation.basePremiumTotal);
    }

    /**
     * @inheritdoc IPremiumManager
     */
    function quoteFees(
        uint256 grossPremium,
        uint16 platformFeeBps,
        uint16 poolFeeBps
    )
        public
        pure
        override
        returns (uint256 platformCut, uint256 poolCut, uint256 escrowedAmount)
    {
        platformCut = (grossPremium * platformFeeBps) / _BPS_DENOMINATOR;
        poolCut = (grossPremium * poolFeeBps) / _BPS_DENOMINATOR;
        escrowedAmount = grossPremium - platformCut - poolCut;
    }

    /**
     * @inheritdoc IPremiumManager
     */
    // slither-disable-next-line unimplemented-functions
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
        require(allocation.buyer != address(0), ZeroAddress());
        require(allocation.premiumToken != address(0), ZeroAddress());
        require(allocation.platformFeeRecipient != address(0), ZeroAddress());
        require(allocation.basePremiumTotal != 0, ZeroAmount());
        require(allocation.policyCommit != bytes32(0), InvalidPolicyCommit());
        require(
            allocation.startTime < allocation.maturityTime,
            InvalidCoverageWindow(allocation.startTime, allocation.maturityTime)
        );
    }

    /**
     * @notice Processes pool shares, distributes fees, and prepares escrow data.
     * @param allocation Premium allocation containing pool share details.
     * @return totalPlatformFees Aggregate platform fees collected.
     * @return totalRestakerPremiums Aggregate restaker premiums for escrow.
     * @return poolPremiums Array of pool premium data for escrow position.
     */
    function _processPoolShares(PremiumAllocation calldata allocation)
        private
        returns (
            uint256 totalPlatformFees,
            uint256 totalRestakerPremiums,
            IPremiumReserve.PoolPremium[] memory poolPremiums
        )
    {
        uint256 poolSharesLength = allocation.poolShares.length;
        poolPremiums = new IPremiumReserve.PoolPremium[](poolSharesLength);

        IERC20 token = IERC20(allocation.premiumToken);

        for (uint256 i = 0; i < poolSharesLength; ++i) {
            PoolShare calldata share = allocation.poolShares[i];

            require(share.coverPool != address(0), ZeroAddress());
            require(share.poolFeeRecipient != address(0), ZeroAddress());
            require(share.operator != address(0), ZeroAddress());
            require(share.grossPremium != 0, ZeroAmount());
            require(allocation.platformFeeBps <= _MAX_FEE_BPS, InvalidFeeBps(allocation.platformFeeBps));
            require(share.poolFeeBps <= _MAX_FEE_BPS, InvalidFeeBps(share.poolFeeBps));

            (uint256 platformCut, uint256 poolCut, uint256 restakerPremium) =
                quoteFees(share.grossPremium, allocation.platformFeeBps, share.poolFeeBps);

            totalPlatformFees += platformCut;
            totalRestakerPremiums += restakerPremium;

            if (poolCut != 0) {
                token.safeTransferFrom(allocation.buyer, share.poolFeeRecipient, poolCut);
            }

            poolPremiums[i] = IPremiumReserve.PoolPremium({
                pool: share.coverPool, operator: share.operator, restakerPremium: restakerPremium
            });
        }
    }
}

