// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";

/**
 * @title Swapper
 * @notice Facilitates token swaps to enable premium payments in different tokens.
 * @dev Integrates with external DEX protocols and aggregators to execute swaps with proper slippage protection.
 *      Uses role-based access control to restrict swap execution and route configuration.
 */
contract Swapper is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    ISwapper
{
    using SafeERC20 for IERC20;
    using Address for address;

    bytes32 public constant override SWAP_MANAGER_ROLE = keccak256("SWAP_MANAGER_ROLE");
    bytes32 public constant override SWAP_EXECUTOR_ROLE = keccak256("SWAP_EXECUTOR_ROLE");

    address public override nativeWrapper;
    mapping(address target => bool whitelisted) public override whitelistedTargets;

    mapping(bytes32 routeKey => SwapRoute) private _swapRoutes;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the Swapper contract with role assignments.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param swapManager_ Address granted SWAP_MANAGER_ROLE for configuring routes.
     * @param swapExecutor_ Address granted SWAP_EXECUTOR_ROLE for executing swaps.
     * @param nativeWrapper_ Address of the native token wrapper (e.g., WETH).
     */
    function initialize(
        address admin_,
        address swapManager_,
        address swapExecutor_,
        address nativeWrapper_
    )
        external
        initializer
    {
        require(
            admin_ != address(0) && swapManager_ != address(0) && swapExecutor_ != address(0)
                && nativeWrapper_ != address(0),
            ZeroAddress()
        );

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(SWAP_MANAGER_ROLE, swapManager_);
        _grantRole(SWAP_EXECUTOR_ROLE, swapExecutor_);

        nativeWrapper = nativeWrapper_;
        emit NativeWrapperSet(nativeWrapper_);
    }

    /**
     * @inheritdoc ISwapper
     */
    function pause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc ISwapper
     */
    function unpause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @inheritdoc ISwapper
     */
    function setSwapTargetWhitelist(address target, bool whitelisted) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(target != address(0), ZeroAddress());
        whitelistedTargets[target] = whitelisted;
        emit SwapTargetWhitelistSet(target, whitelisted);
    }

    /**
     * @inheritdoc ISwapper
     */
    function setNativeWrapper(address wrapper) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(wrapper != address(0), ZeroAddress());
        nativeWrapper = wrapper;
        emit NativeWrapperSet(wrapper);
    }

    /**
     * @inheritdoc ISwapper
     */
    function recoverTokens(address token, address to, uint256 amount) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0) && to != address(0), ZeroAddress());
        require(amount != 0, ZeroAmount());

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @inheritdoc ISwapper
     */
    function setSwapRoute(
        address tokenIn,
        address tokenOut,
        address swapTarget,
        bool enabled,
        bytes calldata swapCalldata
    )
        external
        override
        onlyRole(SWAP_MANAGER_ROLE)
    {
        require(tokenIn != address(0) && tokenOut != address(0) && swapTarget != address(0), ZeroAddress());
        require(tokenIn != tokenOut, IdenticalTokens(tokenIn));
        require(whitelistedTargets[swapTarget], SwapTargetNotWhitelisted(swapTarget));

        bytes32 routeKey = _getRouteKey(tokenIn, tokenOut);
        SwapRoute storage route = _swapRoutes[routeKey];

        route.tokenIn = tokenIn;
        route.tokenOut = tokenOut;
        route.swapTarget = swapTarget;
        route.enabled = enabled;
        route.swapCalldata = swapCalldata;

        emit SwapRouteSet(tokenIn, tokenOut, swapTarget, enabled);
    }

    /**
     * @inheritdoc ISwapper
     */
    function executeSwap(SwapParams calldata params)
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(SWAP_EXECUTOR_ROLE)
        returns (uint256 amountOut)
    {
        require(
            params.tokenIn != address(0) && params.tokenOut != address(0) && params.recipient != address(0),
            ZeroAddress()
        );
        require(params.amountIn != 0 && params.amountOutMin != 0, ZeroAmount());

        bytes32 routeKey = _getRouteKey(params.tokenIn, params.tokenOut);
        SwapRoute storage route = _swapRoutes[routeKey];

        require(route.enabled, SwapRouteNotConfigured(params.tokenIn, params.tokenOut));
        require(whitelistedTargets[route.swapTarget], SwapTargetNotWhitelisted(route.swapTarget));

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        uint256 balanceBefore = IERC20(params.tokenOut).balanceOf(address(this));

        IERC20(params.tokenIn).forceApprove(route.swapTarget, params.amountIn);

        // slither-disable-next-line arbitrary-send-eth
        (bool success, bytes memory returnData) = route.swapTarget.call(params.swapCalldata);
        require(success, SwapFailed(returnData));

        IERC20(params.tokenIn).forceApprove(route.swapTarget, 0);

        uint256 balanceAfter = IERC20(params.tokenOut).balanceOf(address(this));
        amountOut = balanceAfter - balanceBefore;

        require(amountOut >= params.amountOutMin, InsufficientOutputAmount(amountOut, params.amountOutMin));

        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);

        emit SwapExecuted(params.tokenIn, params.tokenOut, params.amountIn, amountOut, params.recipient);
    }

    /**
     * @inheritdoc ISwapper
     */
    function getSwapRoute(address tokenIn, address tokenOut) external view override returns (SwapRoute memory) {
        bytes32 routeKey = _getRouteKey(tokenIn, tokenOut);
        return _swapRoutes[routeKey];
    }

    /**
     * @inheritdoc ISwapper
     */
    // slither-disable-next-line unimplemented-functions
    function paused() public view override (ISwapper, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    /**
     * @notice Restricts UUPS upgrade authorization to DEFAULT_ADMIN_ROLE holders.
     */
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Generates a unique key for a swap route based on token pair.
     * @dev Uses keccak256 to create a deterministic identifier for the route.
     * @param tokenIn Source token address.
     * @param tokenOut Destination token address.
     * @return Unique bytes32 key for the route.
     */
    function _getRouteKey(address tokenIn, address tokenOut) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenIn, tokenOut));
    }

    /**
     * @notice Allows contract to receive native currency (e.g., ETH).
     * @dev Required for wrapping/unwrapping native tokens during swaps.
     */
    receive() external payable {}
}
