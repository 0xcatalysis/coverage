// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPremiumCollector} from "./interfaces/IPremiumCollector.sol";
import {IPremiumManager} from "./interfaces/IPremiumManager.sol";
import {ICoverPoolFactory} from "./interfaces/ICoverPoolFactory.sol";

/**
 * @title PremiumCollector
 * @notice Accrues ERC-4626 vault shares and periodically redeems them to underlying assets,
 *         then distributes the premiums via PremiumManager.
 * @dev Supports batch distribution with keeper automation via Gelato Web3 Functions.
 */
// slither-disable-next-line unimplemented-functions
contract PremiumCollector is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IPremiumCollector
{
    using SafeERC20 for IERC20;

    mapping(address vault => VaultConfig) private _vaultConfigs;
    address[] private _registeredVaults;
    mapping(address vault => uint256 index) private _vaultIndex;

    address public override premiumManager;
    uint64 public override distributeInterval;
    address public override coverPoolFactory;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the PremiumCollector with role assignments and configuration.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param premiumManager_ Address of the PremiumManager contract for premium distribution.
     * @param coverPoolFactory_ Address of the CoverPoolFactory used for pool validation.
     * @param distributeInterval_ Minimum seconds between distributions per vault (default: 86400 = 24h).
     */
    function initialize(
        address admin_,
        address premiumManager_,
        address coverPoolFactory_,
        uint64 distributeInterval_
    )
        external
        initializer
    {
        require(admin_ != address(0) && premiumManager_ != address(0) && coverPoolFactory_ != address(0), ZeroAddress());
        require(distributeInterval_ > 0, InvalidDistributeInterval(distributeInterval_));

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        premiumManager = premiumManager_;
        coverPoolFactory = coverPoolFactory_;
        distributeInterval = distributeInterval_;
    }

    /**
     * @inheritdoc IPremiumCollector
     */
    function pause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc IPremiumCollector
     */
    function unpause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @inheritdoc IPremiumCollector
     */
    function registerVault(
        address vault,
        address pool,
        uint96 policyId
    )
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(vault != address(0) && pool != address(0), ZeroAddress());
        require(policyId != 0, InvalidPolicyId());
        require(ICoverPoolFactory(coverPoolFactory).coverPoolExists(pool), InvalidCoverPool(pool));
        require(!_vaultConfigs[vault].registered, VaultAlreadyRegistered(vault));

        address underlying = IERC4626(vault).asset();
        require(underlying != address(0), ZeroAddress());

        _vaultConfigs[vault] = VaultConfig({
            underlying: underlying, pool: pool, policyId: policyId, lastDistributeTime: 0, registered: true
        });

        _vaultIndex[vault] = _registeredVaults.length;
        _registeredVaults.push(vault);

        emit VaultRegistered(vault, underlying, pool, policyId);
    }

    /**
     * @inheritdoc IPremiumCollector
     */
    function removeVault(address vault) external override nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_vaultConfigs[vault].registered, VaultNotRegistered(vault));

        uint256 shares = IERC4626(vault).balanceOf(address(this));
        // slither-disable-next-line incorrect-equality
        require(shares == 0, VaultHasShares(vault, shares));

        uint256 index = _vaultIndex[vault];
        uint256 lastIndex = _registeredVaults.length - 1;

        if (index != lastIndex) {
            address lastVault = _registeredVaults[lastIndex];
            _registeredVaults[index] = lastVault;
            _vaultIndex[lastVault] = index;
        }

        _registeredVaults.pop();
        delete _vaultIndex[vault];
        delete _vaultConfigs[vault];

        emit VaultRemoved(vault);
    }

    /**
     * @inheritdoc IPremiumCollector
     */
    function updateVault(
        address vault,
        address pool,
        uint96 policyId
    )
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_vaultConfigs[vault].registered, VaultNotRegistered(vault));
        require(pool != address(0), ZeroAddress());
        require(policyId != 0, InvalidPolicyId());
        require(ICoverPoolFactory(coverPoolFactory).coverPoolExists(pool), InvalidCoverPool(pool));

        VaultConfig storage config = _vaultConfigs[vault];
        config.pool = pool;
        config.policyId = policyId;

        emit VaultUpdated(vault, pool, policyId);
    }

    /**
     * @inheritdoc IPremiumCollector
     */
    function distributeBatch(address[] calldata vaults) external override nonReentrant whenNotPaused {
        uint256 length = vaults.length;
        for (uint256 i = 0; i < length; ++i) {
            _distribute(vaults[i]);
        }
    }

    /**
     * @inheritdoc IPremiumCollector
     */
    function setDistributeInterval(uint64 interval) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(interval > 0, InvalidDistributeInterval(interval));
        distributeInterval = interval;
        emit DistributeIntervalSet(interval);
    }

    /**
     * @inheritdoc IPremiumCollector
     */
    function setPremiumManager(address premiumManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(premiumManager_ != address(0), ZeroAddress());
        premiumManager = premiumManager_;
        emit PremiumManagerSet(premiumManager_);
    }

    /**
     * @inheritdoc IPremiumCollector
     */
    function setCoverPoolFactory(address coverPoolFactory_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(coverPoolFactory_ != address(0), ZeroAddress());
        coverPoolFactory = coverPoolFactory_;
        emit CoverPoolFactorySet(coverPoolFactory_);
    }

    /**
     * @inheritdoc IPremiumCollector
     */
    function getRegisteredVaults() external view override returns (address[] memory) {
        return _registeredVaults;
    }

    /**
     * @inheritdoc IPremiumCollector
     */
    function getVaultConfig(address vault) external view override returns (VaultConfig memory config) {
        return _vaultConfigs[vault];
    }

    /**
     * @inheritdoc IPremiumCollector
     */
    function getAccruedShares(address vault) external view override returns (uint256 shares) {
        return IERC4626(vault).balanceOf(address(this));
    }

    /**
     * @inheritdoc IPremiumCollector
     */
    // slither-disable-next-line calls-loop
    function getDistributableVaults() external view override returns (address[] memory) {
        uint256 length = _registeredVaults.length;
        address[] memory eligible = new address[](length);
        uint256 count = 0;

        for (uint256 i = 0; i < length; ++i) {
            address vault = _registeredVaults[i];
            VaultConfig memory config = _vaultConfigs[vault];

            // slither-disable-next-line calls-loop
            if (
                block.timestamp >= config.lastDistributeTime + distributeInterval
                    && IERC4626(vault).balanceOf(address(this)) > 0
            ) {
                eligible[count] = vault;
                ++count;
            }
        }

        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            result[i] = eligible[i];
        }

        return result;
    }

    /**
     * @inheritdoc IPremiumCollector
     */
    function paused() public view override (IPremiumCollector, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    /**
     * @notice Recovers accidentally sent ERC-20 tokens from this contract.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param token ERC-20 token to recover.
     * @param to Recipient address.
     * @param amount Amount to transfer.
     */
    function recoverTokens(address token, address to, uint256 amount) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0) && to != address(0), ZeroAddress());
        require(amount != 0, ZeroAmount());
        IERC20(token).safeTransfer(to, amount);
        emit TokensRecovered(token, to, amount);
    }

    /**
     * @notice Restricts UUPS upgrade authorization to DEFAULT_ADMIN_ROLE holders.
     */
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Internal function to distribute premiums for a single vault.
     * @param vault Address of the ERC-4626 vault.
     */
    // slither-disable-next-line calls-loop,reentrancy-no-eth
    function _distribute(address vault) private {
        VaultConfig storage config = _vaultConfigs[vault];
        if (!config.registered) {
            return;
        }
        if (block.timestamp < config.lastDistributeTime + distributeInterval) {
            return;
        }

        // slither-disable-next-line calls-loop
        uint256 shares = IERC4626(vault).balanceOf(address(this));
        // slither-disable-next-line incorrect-equality
        if (shares == 0) {
            return;
        }

        // slither-disable-next-line calls-loop
        uint256 assets = IERC4626(vault).redeem(shares, address(this), address(this));
        // slither-disable-next-line incorrect-equality
        if (assets == 0) {
            return;
        }

        config.lastDistributeTime = uint32(block.timestamp);
        IERC20(config.underlying).safeTransfer(premiumManager, assets);

        // slither-disable-next-line calls-loop
        IPremiumManager(premiumManager).distributePremium(config.pool, config.policyId, config.underlying, assets);

        emit Distributed(vault, shares, assets);
    }
}
