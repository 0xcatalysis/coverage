// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPremiumReserve} from "./interfaces/IPremiumReserve.sol";
import {IRewardsManager} from "./interfaces/IRewardsManager.sol";

/**
 * @title PremiumReserve
 * @notice Holds restaker premiums until maturity or claim execution.
 */
contract PremiumReserve is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IPremiumReserve
{
    using SafeERC20 for IERC20;

    bytes32 public constant override PREMIUM_MANAGER_ROLE = keccak256("PREMIUM_MANAGER_ROLE");
    bytes32 public constant override CLAIM_MANAGER_ROLE = keccak256("CLAIM_MANAGER_ROLE");
    bytes32 public constant override POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");
    bytes private constant _COVERAGE_POLICY_TASK = "COVERAGE_POLICY";

    mapping(uint256 => EscrowAccount) private _escrows;
    // slither-disable-next-line uninitialized-state
    mapping(uint256 => PoolPremium[]) private _poolPremiums;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the reserve and configures role assignments.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param premiumManager_ Address granted PREMIUM_MANAGER_ROLE.
     * @param claimManager_ Address granted CLAIM_MANAGER_ROLE.
     * @param policyManager_ Address granted POLICY_MANAGER_ROLE.
     */
    function initialize(
        address admin_,
        address premiumManager_,
        address claimManager_,
        address policyManager_
    )
        external
        initializer
    {
        require(
            admin_ != address(0) && premiumManager_ != address(0) && claimManager_ != address(0)
                && policyManager_ != address(0),
            ZeroAddress()
        );

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PREMIUM_MANAGER_ROLE, premiumManager_);
        _grantRole(CLAIM_MANAGER_ROLE, claimManager_);
        _grantRole(POLICY_MANAGER_ROLE, policyManager_);
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function pause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function unpause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function openEscrow(EscrowPosition calldata position)
        external
        override
        whenNotPaused
        onlyRole(PREMIUM_MANAGER_ROLE)
    {
        require(position.premiumToken != address(0) && position.buyer != address(0), ZeroAddress());
        require(position.policyCommit != bytes32(0), InvalidPolicyCommit());
        require(
            position.startTime < position.maturityTime, InvalidCoverageWindow(position.startTime, position.maturityTime)
        );

        EscrowAccount storage escrow = _escrows[position.policyId];
        require(escrow.premiumToken == address(0), EscrowAlreadyExists(position.policyId));

        PoolPremium[] storage poolPremiums = _poolPremiums[position.policyId];
        require(poolPremiums.length == 0, EscrowAlreadyExists(position.policyId));

        uint256 poolsLength = position.poolPremiums.length;
        if (position.restakerPremiumTotal == 0) {
            require(poolsLength == 0, InvalidPoolPremiums());
        } else {
            require(poolsLength != 0, InvalidPoolPremiums());
        }

        uint256 observedTotal = 0;
        for (uint256 i = 0; i < poolsLength; ++i) {
            PoolPremium calldata poolPremium = position.poolPremiums[i];
            require(
                poolPremium.pool != address(0) && poolPremium.operator != address(0)
                    && poolPremium.restakerPremium != 0,
                InvalidPoolPremiums()
            );
            poolPremiums.push(poolPremium);
            observedTotal += poolPremium.restakerPremium;
        }

        if (position.restakerPremiumTotal != 0) {
            require(
                observedTotal == position.restakerPremiumTotal,
                PremiumTotalsMismatch(position.restakerPremiumTotal, observedTotal)
            );
        }

        escrow.restakerPremiumTotal = position.restakerPremiumTotal;
        escrow.restakerPremiumInitial = position.restakerPremiumTotal;
        escrow.premiumToken = position.premiumToken;
        escrow.buyer = position.buyer;
        escrow.policyCommit = position.policyCommit;
        escrow.startTime = position.startTime;
        escrow.maturityTime = position.maturityTime;
        escrow.claimLocked = false;
        escrow.released = false;

        emit EscrowOpened(position.policyId, position.premiumToken, position.restakerPremiumTotal);
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function setClaimLockStatus(
        uint256 policyId,
        bool locked
    )
        external
        override
        whenNotPaused
        onlyRole(CLAIM_MANAGER_ROLE)
    {
        EscrowAccount storage escrow = _escrow(policyId);
        require(!escrow.released, EscrowAlreadyReleased(policyId));

        escrow.claimLocked = locked;
        emit ClaimLockStatusSet(policyId, locked);
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function payClaim(
        uint256 policyId,
        address payoutRecipient,
        uint256 settledAmount
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(CLAIM_MANAGER_ROLE)
    {
        require(payoutRecipient != address(0), ZeroAddress());
        require(settledAmount != 0, ZeroSettledAmount());

        EscrowAccount storage escrow = _escrow(policyId);
        require(!escrow.released, EscrowAlreadyReleased(policyId));
        require(escrow.claimLocked, EscrowNotLocked(policyId));

        uint256 available = escrow.restakerPremiumTotal;
        require(available >= settledAmount, InsufficientEscrow(policyId, settledAmount, available));

        escrow.restakerPremiumTotal -= settledAmount;
        IERC20(escrow.premiumToken).safeTransfer(payoutRecipient, settledAmount);

        emit ClaimPaid(policyId, settledAmount);
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function releasePremium(
        uint256 policyId,
        address rewardsManager
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(POLICY_MANAGER_ROLE)
    {
        require(rewardsManager != address(0), ZeroAddress());

        EscrowAccount storage escrow = _escrow(policyId);
        require(!escrow.released, EscrowAlreadyReleased(policyId));
        require(!escrow.claimLocked, EscrowLocked(policyId));
        require(block.timestamp >= escrow.maturityTime, MaturityNotReached(policyId, escrow.maturityTime));

        uint256 totalRestakerPayout = escrow.restakerPremiumTotal;
        if (totalRestakerPayout != 0) {
            _releaseToRewards(policyId, escrow, rewardsManager, IERC20(escrow.premiumToken), totalRestakerPayout);
        }

        escrow.released = true;
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function escrowPosition(uint256 policyId) external view override returns (EscrowPosition memory position) {
        EscrowAccount storage escrow = _escrow(policyId);

        position.policyId = policyId;
        position.policyCommit = escrow.policyCommit;
        position.restakerPremiumTotal = escrow.restakerPremiumTotal;
        position.premiumToken = escrow.premiumToken;
        position.buyer = escrow.buyer;
        position.startTime = escrow.startTime;
        position.maturityTime = escrow.maturityTime;
        position.claimLocked = escrow.claimLocked;

        PoolPremium[] storage poolPremiums = _poolPremiums[policyId];
        uint256 poolsLength = poolPremiums.length;
        position.poolPremiums = new PoolPremium[](poolsLength);

        if (poolsLength == 0 || escrow.restakerPremiumInitial == 0 || escrow.restakerPremiumTotal == 0) {
            for (uint256 i = 0; i < poolsLength; ++i) {
                position.poolPremiums[i] =
                    PoolPremium({pool: poolPremiums[i].pool, operator: poolPremiums[i].operator, restakerPremium: 0});
            }
            return position;
        }

        uint256 distributed = 0;
        for (uint256 i = 0; i < poolsLength; ++i) {
            PoolPremium storage base = poolPremiums[i];
            uint256 amount = (base.restakerPremium * escrow.restakerPremiumTotal) / escrow.restakerPremiumInitial;

            if (i == poolsLength - 1) {
                amount = escrow.restakerPremiumTotal - distributed;
            } else {
                distributed += amount;
            }

            position.poolPremiums[i] = PoolPremium({pool: base.pool, operator: base.operator, restakerPremium: amount});
        }
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    // slither-disable-next-line unimplemented-functions
    function paused() public view override (IPremiumReserve, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    /**
     * @notice Restricts UUPS upgrade authorization to DEFAULT_ADMIN_ROLE holders.
     */
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Streams the remaining restaker premium to the RewardsManager on a per-pool basis.
     * @dev Preserves proportional weights by using the initial restaker premium totals so that any
     *      prior claim drawdowns are reflected across all pools uniformly and notifies RewardsManager
     *      so Core can attribute distributions to the correct operator/policy combination.
     * @param policyId Identifier of the policy whose escrow is being released.
     * @param escrow Storage pointer to the policy escrow being processed.
     * @param rewardsManager Core RewardsManager address receiving the payouts.
     * @param premiumToken Premium token (ERC20) used for transfers.
     * @param totalRestakerPayout Aggregate amount that should be distributed to restaker pools.
     */
    function _releaseToRewards(
        uint256 policyId,
        EscrowAccount storage escrow,
        address rewardsManager,
        IERC20 premiumToken,
        uint256 totalRestakerPayout
    )
        private
    {
        PoolPremium[] storage poolPremiums = _poolPremiums[policyId];
        uint256 poolsLength = poolPremiums.length;
        require(poolsLength != 0, InvalidPoolPremiums());

        uint256 totalInitial = escrow.restakerPremiumInitial;
        uint256 distributed = 0;
        for (uint256 i = 0; i < poolsLength; ++i) {
            PoolPremium storage base = poolPremiums[i];
            uint256 amount = (totalInitial == 0) ? 0 : (base.restakerPremium * totalRestakerPayout) / totalInitial;

            if (i == poolsLength - 1) {
                amount = totalRestakerPayout - distributed;
            } else {
                distributed += amount;
            }

            if (amount != 0) {
                premiumToken.safeTransfer(rewardsManager, amount);
                // slither-disable-next-line calls-loop
                IRewardsManager(rewardsManager)
                    .distributeRewards(_COVERAGE_POLICY_TASK, base.operator, escrow.policyCommit, amount);
            }

            emit PoolPremiumReleased(policyId, base.pool, amount);
        }

        escrow.restakerPremiumTotal = 0;
        emit PremiumReleased(policyId, rewardsManager, totalRestakerPayout);
    }

    /**
     * @notice Loads an escrow account from storage, reverting when the policy has no escrow.
     * @dev This helper centralizes the not-found guard so that all internal callers receive a
     *      consistent error surface.
     * @param policyId Identifier of the policy whose escrow should be returned.
     * @return escrow Storage pointer to the located escrow account.
     */
    function _escrow(uint256 policyId) private view returns (EscrowAccount storage escrow) {
        escrow = _escrows[policyId];
        require(escrow.premiumToken != address(0), EscrowNotFound(policyId));
    }
}
