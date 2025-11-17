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
import {IWETH} from "./interfaces/IWETH.sol";

/**
 * @title Swapper
 * @notice Converts slashed collateral into payout tokens during claim settlements.
 * @dev The ClaimManager receives slashed assets (ETH, wBTC, etc.) from the SlashingManager and uses
 *      this contract to convert them to the policy's designated payout token (USDC, DAI, etc.) before
 *      transferring to beneficiaries or reimbursing the PremiumReserve.
 *
 *      Native ETH Support:
 *      - Automatically wraps incoming native ETH to WETH before swapping
 *      - Automatically unwraps WETH to native ETH when specified as output token
 *      - Use NATIVE_ETH constant (0xEeee...eeEE) to denote native ETH in swap parameters
 *      - Routes are configured using the nativeWrapper (WETH) address, not NATIVE_ETH
 *
 *      Integration Pattern:
 *      1. ClaimManager receives slashed collateral from SlashingManager (ETH, WETH, wBTC, etc.)
 *      2. For ERC20: ClaimManager approves Swapper for the collateral amount
 *      3. ClaimManager calls executeSwap() with recipient as the final destination
 *      4. For native ETH input: Swapper wraps to WETH, executes swap, transfers output to recipient
 *      5. For native ETH output: Swapper executes swap, unwraps WETH to ETH, sends to recipient
 *
 *      Supported DEX Protocols:
 *      Integrates with any DEX or aggregator (Uniswap, Curve, 1inch, ParaSwap) via generic calldata approach.
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
    address public constant override NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public override nativeWrapper;
    mapping(address target => bool whitelisted) public override whitelistedTargets;

    mapping(bytes32 routeKey => SwapRoute) private _swapRoutes;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Allows contract to receive native currency (e.g., ETH).
     * @dev Required for wrapping/unwrapping native tokens during swaps.
     */
    receive() external payable {}

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
        payable
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

        address actualTokenIn = params.tokenIn == NATIVE_ETH ? nativeWrapper : params.tokenIn;
        address actualTokenOut = params.tokenOut == NATIVE_ETH ? nativeWrapper : params.tokenOut;

        address swapTarget = _validateAndGetSwapTarget(actualTokenIn, actualTokenOut, params.tokenIn, params.tokenOut);

        _handleTokenInput(params.tokenIn, actualTokenIn, params.amountIn);

        amountOut = _performSwap(actualTokenIn, actualTokenOut, swapTarget, params.amountIn, params.swapCalldata);

        require(amountOut >= params.amountOutMin, InsufficientOutputAmount(amountOut, params.amountOutMin));

        _handleTokenOutput(params.tokenOut, amountOut, params.recipient);

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
     * @notice Handles token input - wraps native ETH or pulls ERC20 tokens.
     * @param tokenIn Input token address (may be NATIVE_ETH constant).
     * @param actualTokenIn Resolved token address (WETH if native ETH).
     * @param amountIn Amount of input tokens.
     */
    function _handleTokenInput(address tokenIn, address actualTokenIn, uint256 amountIn) private {
        if (tokenIn == NATIVE_ETH) {
            require(msg.value == amountIn, InsufficientNativeAmount(msg.value, amountIn));
            IWETH(nativeWrapper).deposit{value: amountIn}();
        } else {
            require(msg.value == 0, UnexpectedNativePayment());
            IERC20(actualTokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }
    }

    /**
     * @notice Executes the swap via external DEX call with balance verification.
     * @param actualTokenIn Resolved input token address.
     * @param actualTokenOut Resolved output token address.
     * @param swapTarget DEX address to execute swap on.
     * @param amountIn Amount of input tokens.
     * @param swapCalldata Calldata for the DEX swap function.
     * @return amountOut Amount of output tokens received.
     */
    function _performSwap(
        address actualTokenIn,
        address actualTokenOut,
        address swapTarget,
        uint256 amountIn,
        bytes calldata swapCalldata
    )
        private
        returns (uint256 amountOut)
    {
        uint256 balanceBefore = IERC20(actualTokenOut).balanceOf(address(this));

        IERC20(actualTokenIn).forceApprove(swapTarget, amountIn);

        // slither-disable-next-line arbitrary-send-eth
        (bool success, bytes memory returnData) = swapTarget.call(swapCalldata);
        require(success, SwapFailed(returnData));

        IERC20(actualTokenIn).forceApprove(swapTarget, 0);

        uint256 balanceAfter = IERC20(actualTokenOut).balanceOf(address(this));
        amountOut = balanceAfter - balanceBefore;
    }

    /**
     * @notice Handles token output - unwraps to native ETH or transfers ERC20 tokens.
     * @param tokenOut Output token address (may be NATIVE_ETH constant).
     * @param amountOut Amount of output tokens to send.
     * @param recipient Address to receive the output tokens.
     */
    function _handleTokenOutput(address tokenOut, uint256 amountOut, address recipient) private {
        if (tokenOut == NATIVE_ETH) {
            IWETH(nativeWrapper).withdraw(amountOut);
            // slither-disable-next-line arbitrary-send-eth
            (bool sent,) = recipient.call{value: amountOut}("");
            require(sent, NativeTransferFailed());
        } else {
            IERC20(tokenOut).safeTransfer(recipient, amountOut);
        }
    }

    /**
     * @notice Validates route and returns the swap target address.
     * @param actualTokenIn Resolved input token address (WETH if native ETH).
     * @param actualTokenOut Resolved output token address (WETH if native ETH).
     * @param paramTokenIn Original tokenIn from params (may be NATIVE_ETH constant).
     * @param paramTokenOut Original tokenOut from params (may be NATIVE_ETH constant).
     * @return swapTarget Address of the whitelisted DEX to execute the swap.
     */
    function _validateAndGetSwapTarget(
        address actualTokenIn,
        address actualTokenOut,
        address paramTokenIn,
        address paramTokenOut
    )
        private
        view
        returns (address swapTarget)
    {
        bytes32 routeKey = _getRouteKey(actualTokenIn, actualTokenOut);
        SwapRoute storage route = _swapRoutes[routeKey];

        require(route.enabled, SwapRouteNotEnabled(paramTokenIn, paramTokenOut));

        swapTarget = route.swapTarget;
        require(whitelistedTargets[swapTarget], SwapTargetNotWhitelisted(swapTarget));
    }

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
}
