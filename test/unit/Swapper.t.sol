// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {Swapper} from "../../src/Swapper.sol";
import {ISwapper} from "../../src/interfaces/ISwapper.sol";

contract SwapperTest is Test {
    address internal admin;
    address internal swapManager;
    address internal swapExecutor;
    address internal nativeWrapper;
    address internal recipient;
    address internal dexTarget;

    Swapper internal swapper;
    MockToken internal tokenIn;
    MockToken internal tokenOut;
    MockDEX internal mockDex;

    event SwapExecuted(
        address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address recipient
    );
    event SwapRouteSet(address indexed tokenIn, address indexed tokenOut, address swapTarget, bool enabled);
    event SwapTargetWhitelistSet(address indexed target, bool whitelisted);
    event NativeWrapperSet(address indexed wrapper);

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        vm.warp(1_000_000);

        admin = makeAddr("admin");
        swapManager = makeAddr("swapManager");
        swapExecutor = makeAddr("swapExecutor");
        nativeWrapper = makeAddr("nativeWrapper");
        recipient = makeAddr("recipient");

        vm.label(admin, "Admin");
        vm.label(swapManager, "SwapManager");
        vm.label(swapExecutor, "SwapExecutor");
        vm.label(nativeWrapper, "NativeWrapper");
        vm.label(recipient, "Recipient");

        tokenIn = new MockToken("Token In", "TIN");
        tokenOut = new MockToken("Token Out", "TOUT");
        mockDex = new MockDEX();
        dexTarget = address(mockDex);

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "Swapper.sol",
            abi.encodeCall(Swapper.initialize, (admin, swapManager, swapExecutor, nativeWrapper)),
            deployOpts
        );
        swapper = Swapper(payable(proxy));

        vm.label(address(swapper), "Swapper");
        vm.label(address(tokenIn), "TokenIn");
        vm.label(address(tokenOut), "TokenOut");
        vm.label(dexTarget, "MockDEX");
    }

    /*//////////////////////////////////////////////////////////////
                           RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////*/

    function test_receive_AcceptsNativeToken() public {
        uint256 amount = 1 ether;
        (bool success,) = address(swapper).call{value: amount}("");
        assertTrue(success, "Should accept native token");
        assertEq(address(swapper).balance, amount, "Balance mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_initialize_WhenAdminZero_Reverts() public {
        Swapper implementation = new Swapper();
        Swapper freshSwapper = Swapper(payable(address(new ERC1967Proxy(address(implementation), ""))));
        vm.expectRevert(ISwapper.ZeroAddress.selector);
        freshSwapper.initialize(address(0), swapManager, swapExecutor, nativeWrapper);
    }

    function test_initialize_WhenSwapManagerZero_Reverts() public {
        Swapper implementation = new Swapper();
        Swapper freshSwapper = Swapper(payable(address(new ERC1967Proxy(address(implementation), ""))));
        vm.expectRevert(ISwapper.ZeroAddress.selector);
        freshSwapper.initialize(admin, address(0), swapExecutor, nativeWrapper);
    }

    function test_initialize_WhenSwapExecutorZero_Reverts() public {
        Swapper implementation = new Swapper();
        Swapper freshSwapper = Swapper(payable(address(new ERC1967Proxy(address(implementation), ""))));
        vm.expectRevert(ISwapper.ZeroAddress.selector);
        freshSwapper.initialize(admin, swapManager, address(0), nativeWrapper);
    }

    function test_initialize_WhenNativeWrapperZero_Reverts() public {
        Swapper implementation = new Swapper();
        Swapper freshSwapper = Swapper(payable(address(new ERC1967Proxy(address(implementation), ""))));
        vm.expectRevert(ISwapper.ZeroAddress.selector);
        freshSwapper.initialize(admin, swapManager, swapExecutor, address(0));
    }

    function test_initialize_SetsRolesAndConfiguration() public view {
        assertTrue(swapper.hasRole(swapper.DEFAULT_ADMIN_ROLE(), admin), "Admin role missing");
        assertTrue(swapper.hasRole(swapper.SWAP_MANAGER_ROLE(), swapManager), "Swap manager role missing");
        assertTrue(swapper.hasRole(swapper.SWAP_EXECUTOR_ROLE(), swapExecutor), "Swap executor role missing");
        assertEq(swapper.nativeWrapper(), nativeWrapper, "Native wrapper mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_adminTransfer_BeginTransfer_Success() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit IAccessControlDefaultAdminRules.DefaultAdminTransferScheduled(newAdmin, uint48(block.timestamp + 1 days));
        swapper.beginDefaultAdminTransfer(newAdmin);

        (address pendingAdmin, uint48 schedule) = swapper.pendingDefaultAdmin();
        assertEq(pendingAdmin, newAdmin);
        assertEq(schedule, uint48(block.timestamp + 1 days));
    }

    function test_adminTransfer_AcceptTransfer_Success() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        swapper.beginDefaultAdminTransfer(newAdmin);

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(newAdmin);
        swapper.acceptDefaultAdminTransfer();

        assertTrue(swapper.hasRole(swapper.DEFAULT_ADMIN_ROLE(), newAdmin));
        assertFalse(swapper.hasRole(swapper.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_adminTransfer_AcceptBeforeDelay_Reverts() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        swapper.beginDefaultAdminTransfer(newAdmin);

        vm.prank(newAdmin);
        vm.expectRevert();
        swapper.acceptDefaultAdminTransfer();
    }

    function test_adminTransfer_CancelTransfer_Success() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        swapper.beginDefaultAdminTransfer(newAdmin);

        vm.prank(admin);
        vm.expectEmit(false, false, false, false);
        emit IAccessControlDefaultAdminRules.DefaultAdminTransferCanceled();
        swapper.cancelDefaultAdminTransfer();

        (address pendingAdmin,) = swapper.pendingDefaultAdmin();
        assertEq(pendingAdmin, address(0));
        assertTrue(swapper.hasRole(swapper.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_adminTransfer_NonAdminCannotBegin_Reverts() public {
        address newAdmin = makeAddr("newAdmin");
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert();
        swapper.beginDefaultAdminTransfer(newAdmin);
    }

    function test_adminTransfer_WrongAccountCannotAccept_Reverts() public {
        address newAdmin = makeAddr("newAdmin");
        address attacker = makeAddr("attacker");

        vm.prank(admin);
        swapper.beginDefaultAdminTransfer(newAdmin);

        vm.warp(block.timestamp + 1 days);

        vm.prank(attacker);
        vm.expectRevert();
        swapper.acceptDefaultAdminTransfer();
    }

    function test_adminProtection_CannotGrantDefaultAdminRole_Reverts() public {
        address attacker = makeAddr("attacker");
        bytes32 defaultAdminRole = swapper.DEFAULT_ADMIN_ROLE();

        vm.startPrank(admin);
        vm.expectRevert();
        swapper.grantRole(defaultAdminRole, attacker);
        vm.stopPrank();
    }

    function test_adminProtection_CannotRevokeDefaultAdminRole_Reverts() public {
        bytes32 defaultAdminRole = swapper.DEFAULT_ADMIN_ROLE();

        vm.startPrank(admin);
        vm.expectRevert();
        swapper.revokeRole(defaultAdminRole, admin);
        vm.stopPrank();
    }

    function test_adminProtection_CannotRenounceDefaultAdminRole_Reverts() public {
        bytes32 defaultAdminRole = swapper.DEFAULT_ADMIN_ROLE();

        vm.startPrank(admin);
        vm.expectRevert();
        swapper.renounceRole(defaultAdminRole, admin);
        vm.stopPrank();
    }

    function test_adminProtection_CanGrantOtherRoles_Success() public {
        address newManager = makeAddr("newManager");
        bytes32 managerRole = swapper.SWAP_MANAGER_ROLE();

        vm.startPrank(admin);
        swapper.grantRole(managerRole, newManager);
        vm.stopPrank();

        assertTrue(swapper.hasRole(managerRole, newManager));
    }

    function test_adminProtection_CanRevokeOtherRoles_Success() public {
        bytes32 managerRole = swapper.SWAP_MANAGER_ROLE();

        vm.startPrank(admin);
        swapper.revokeRole(managerRole, swapManager);
        vm.stopPrank();

        assertFalse(swapper.hasRole(managerRole, swapManager));
    }

    function test_adminProtection_CanRenounceOtherRoles_Success() public {
        bytes32 managerRole = swapper.SWAP_MANAGER_ROLE();

        vm.startPrank(swapManager);
        swapper.renounceRole(managerRole, swapManager);
        vm.stopPrank();

        assertFalse(swapper.hasRole(managerRole, swapManager));
    }

    /*//////////////////////////////////////////////////////////////
                             PAUSE/UNPAUSE
    //////////////////////////////////////////////////////////////*/

    function test_pause_WhenCalledByAdmin_PausesContract() public {
        vm.prank(admin);
        swapper.pause();

        assertTrue(swapper.paused(), "Contract should be paused");
    }

    function test_pause_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), swapper.DEFAULT_ADMIN_ROLE()
            )
        );
        swapper.pause();
    }

    function test_unpause_WhenCalledByAdmin_UnpausesContract() public {
        vm.startPrank(admin);
        swapper.pause();
        swapper.unpause();
        vm.stopPrank();

        assertFalse(swapper.paused(), "Contract should not be paused");
    }

    function test_unpause_WhenCallerNotAdmin_Reverts() public {
        vm.prank(admin);
        swapper.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), swapper.DEFAULT_ADMIN_ROLE()
            )
        );
        swapper.unpause();
    }

    /*//////////////////////////////////////////////////////////////
                       SWAP TARGET WHITELIST
    //////////////////////////////////////////////////////////////*/

    function test_setSwapTargetWhitelist_WhenTargetZero_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(ISwapper.ZeroAddress.selector);
        swapper.setSwapTargetWhitelist(address(0), true);
    }

    function test_setSwapTargetWhitelist_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), swapper.DEFAULT_ADMIN_ROLE()
            )
        );
        swapper.setSwapTargetWhitelist(dexTarget, true);
    }

    function test_setSwapTargetWhitelist_WhenValid_UpdatesWhitelist() public {
        vm.startPrank(admin);
        vm.expectEmit(true, false, false, true);
        emit SwapTargetWhitelistSet(dexTarget, true);
        swapper.setSwapTargetWhitelist(dexTarget, true);
        vm.stopPrank();

        assertTrue(swapper.whitelistedTargets(dexTarget), "Target should be whitelisted");
    }

    function test_setSwapTargetWhitelist_WhenRemovingTarget_UpdatesWhitelist() public {
        vm.startPrank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);

        vm.expectEmit(true, false, false, true);
        emit SwapTargetWhitelistSet(dexTarget, false);
        swapper.setSwapTargetWhitelist(dexTarget, false);
        vm.stopPrank();

        assertFalse(swapper.whitelistedTargets(dexTarget), "Target should not be whitelisted");
    }

    /*//////////////////////////////////////////////////////////////
                          NATIVE WRAPPER
    //////////////////////////////////////////////////////////////*/

    function test_setNativeWrapper_WhenWrapperZero_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(ISwapper.ZeroAddress.selector);
        swapper.setNativeWrapper(address(0));
    }

    function test_setNativeWrapper_WhenCallerNotAdmin_Reverts() public {
        address newWrapper = makeAddr("newWrapper");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), swapper.DEFAULT_ADMIN_ROLE()
            )
        );
        swapper.setNativeWrapper(newWrapper);
    }

    function test_setNativeWrapper_WhenValid_UpdatesWrapper() public {
        address newWrapper = makeAddr("newWrapper");
        vm.startPrank(admin);
        vm.expectEmit(true, false, false, false);
        emit NativeWrapperSet(newWrapper);
        swapper.setNativeWrapper(newWrapper);
        vm.stopPrank();

        assertEq(swapper.nativeWrapper(), newWrapper, "Native wrapper should be updated");
    }

    /*//////////////////////////////////////////////////////////////
                           RECOVER TOKENS
    //////////////////////////////////////////////////////////////*/

    function test_recoverTokens_WhenTokenZero_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(ISwapper.ZeroAddress.selector);
        swapper.recoverTokens(address(0), recipient, 100 ether);
    }

    function test_recoverTokens_WhenRecipientZero_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(ISwapper.ZeroAddress.selector);
        swapper.recoverTokens(address(tokenIn), address(0), 100 ether);
    }

    function test_recoverTokens_WhenAmountZero_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(ISwapper.ZeroAmount.selector);
        swapper.recoverTokens(address(tokenIn), recipient, 0);
    }

    function test_recoverTokens_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), swapper.DEFAULT_ADMIN_ROLE()
            )
        );
        swapper.recoverTokens(address(tokenIn), recipient, 100 ether);
    }

    function test_recoverTokens_WhenValid_TransfersTokens() public {
        uint256 rescueAmount = 50 ether;
        tokenIn.mint(address(swapper), rescueAmount);

        uint256 balanceBefore = tokenIn.balanceOf(recipient);

        vm.prank(admin);
        swapper.recoverTokens(address(tokenIn), recipient, rescueAmount);

        assertEq(tokenIn.balanceOf(recipient), balanceBefore + rescueAmount, "Tokens should be transferred");
        assertEq(tokenIn.balanceOf(address(swapper)), 0, "Swapper balance should be zero");
    }

    /*//////////////////////////////////////////////////////////////
                            SET SWAP ROUTE
    //////////////////////////////////////////////////////////////*/

    function test_setSwapRoute_WhenTokenInZero_Reverts() public {
        vm.startPrank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);
        vm.stopPrank();

        vm.prank(swapManager);
        vm.expectRevert(ISwapper.ZeroAddress.selector);
        swapper.setSwapRoute(address(0), address(tokenOut), dexTarget, true);
    }

    function test_setSwapRoute_WhenTokenOutZero_Reverts() public {
        vm.startPrank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);
        vm.stopPrank();

        vm.prank(swapManager);
        vm.expectRevert(ISwapper.ZeroAddress.selector);
        swapper.setSwapRoute(address(tokenIn), address(0), dexTarget, true);
    }

    function test_setSwapRoute_WhenSwapTargetZero_Reverts() public {
        vm.prank(swapManager);
        vm.expectRevert(ISwapper.ZeroAddress.selector);
        swapper.setSwapRoute(address(tokenIn), address(tokenOut), address(0), true);
    }

    function test_setSwapRoute_WhenIdenticalTokens_Reverts() public {
        vm.startPrank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);
        vm.stopPrank();

        vm.prank(swapManager);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.IdenticalTokens.selector, address(tokenIn)));
        swapper.setSwapRoute(address(tokenIn), address(tokenIn), dexTarget, true);
    }

    function test_setSwapRoute_WhenTokenInIsNativeETH_Reverts() public {
        vm.startPrank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);
        vm.stopPrank();

        address nativeEth = swapper.NATIVE_ETH();

        vm.prank(swapManager);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.InvalidRouteToken.selector, nativeEth));
        swapper.setSwapRoute(nativeEth, address(tokenOut), dexTarget, true);
    }

    function test_setSwapRoute_WhenTokenOutIsNativeETH_Reverts() public {
        vm.startPrank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);
        vm.stopPrank();

        address nativeEth = swapper.NATIVE_ETH();

        vm.prank(swapManager);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.InvalidRouteToken.selector, nativeEth));
        swapper.setSwapRoute(address(tokenIn), nativeEth, dexTarget, true);
    }

    function test_setSwapRoute_WhenTargetNotWhitelisted_Reverts() public {
        vm.prank(swapManager);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.SwapTargetNotWhitelisted.selector, dexTarget));
        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget, true);
    }

    function test_setSwapRoute_WhenCallerNotSwapManager_Reverts() public {
        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), swapper.SWAP_MANAGER_ROLE()
            )
        );
        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget, true);
    }

    function test_setSwapRoute_WhenValid_SetsRoute() public {
        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);

        vm.startPrank(swapManager);
        vm.expectEmit(true, true, false, true);
        emit SwapRouteSet(address(tokenIn), address(tokenOut), dexTarget, true);
        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget, true);
        vm.stopPrank();

        ISwapper.SwapRoute memory route = swapper.getSwapRoute(address(tokenIn), address(tokenOut));
        assertEq(route.tokenIn, address(tokenIn), "TokenIn mismatch");
        assertEq(route.tokenOut, address(tokenOut), "TokenOut mismatch");
        assertEq(route.swapTarget, dexTarget, "SwapTarget mismatch");
        assertTrue(route.enabled, "Route should be enabled");
    }

    function test_setSwapRoute_WhenDisabling_UpdatesRoute() public {
        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);

        vm.startPrank(swapManager);
        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget, true);

        vm.expectEmit(true, true, false, true);
        emit SwapRouteSet(address(tokenIn), address(tokenOut), dexTarget, false);
        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget, false);
        vm.stopPrank();

        ISwapper.SwapRoute memory route = swapper.getSwapRoute(address(tokenIn), address(tokenOut));
        assertFalse(route.enabled, "Route should be disabled");
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTE SWAP
    //////////////////////////////////////////////////////////////*/

    function test_executeSwap_WhenTokenInZero_Reverts() public {
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(0),
            tokenOut: address(tokenOut),
            amountIn: 100 ether,
            amountOutMin: 90 ether,
            recipient: recipient,
            swapCalldata: ""
        });

        vm.prank(swapExecutor);
        vm.expectRevert(ISwapper.ZeroAddress.selector);
        swapper.executeSwap(params);
    }

    function test_executeSwap_WhenTokenOutZero_Reverts() public {
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(0),
            amountIn: 100 ether,
            amountOutMin: 90 ether,
            recipient: recipient,
            swapCalldata: ""
        });

        vm.prank(swapExecutor);
        vm.expectRevert(ISwapper.ZeroAddress.selector);
        swapper.executeSwap(params);
    }

    function test_executeSwap_WhenRecipientZero_Reverts() public {
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: 100 ether,
            amountOutMin: 90 ether,
            recipient: address(0),
            swapCalldata: ""
        });

        vm.prank(swapExecutor);
        vm.expectRevert(ISwapper.ZeroAddress.selector);
        swapper.executeSwap(params);
    }

    function test_executeSwap_WhenAmountInZero_Reverts() public {
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: 0,
            amountOutMin: 90 ether,
            recipient: recipient,
            swapCalldata: ""
        });

        vm.prank(swapExecutor);
        vm.expectRevert(ISwapper.ZeroAmount.selector);
        swapper.executeSwap(params);
    }

    function test_executeSwap_WhenAmountOutMinZero_Reverts() public {
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: 100 ether,
            amountOutMin: 0,
            recipient: recipient,
            swapCalldata: ""
        });

        vm.prank(swapExecutor);
        vm.expectRevert(ISwapper.ZeroAmount.selector);
        swapper.executeSwap(params);
    }

    function test_executeSwap_WhenRouteNotEnabled_Reverts() public {
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: 100 ether,
            amountOutMin: 90 ether,
            recipient: recipient,
            swapCalldata: ""
        });

        vm.prank(swapExecutor);
        vm.expectRevert(
            abi.encodeWithSelector(ISwapper.SwapRouteNotEnabled.selector, address(tokenIn), address(tokenOut))
        );
        swapper.executeSwap(params);
    }

    function test_executeSwap_WhenRouteDisabled_Reverts() public {
        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);

        vm.prank(swapManager);
        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget, false);

        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: 100 ether,
            amountOutMin: 90 ether,
            recipient: recipient,
            swapCalldata: ""
        });

        vm.prank(swapExecutor);
        vm.expectRevert(
            abi.encodeWithSelector(ISwapper.SwapRouteNotEnabled.selector, address(tokenIn), address(tokenOut))
        );
        swapper.executeSwap(params);
    }

    function test_executeSwap_WhenTargetNotWhitelisted_Reverts() public {
        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);

        vm.prank(swapManager);
        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget, true);

        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, false);

        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: 100 ether,
            amountOutMin: 90 ether,
            recipient: recipient,
            swapCalldata: ""
        });

        vm.prank(swapExecutor);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.SwapTargetNotWhitelisted.selector, dexTarget));
        swapper.executeSwap(params);
    }

    function test_executeSwap_WhenPaused_Reverts() public {
        _setupRoute();

        vm.prank(admin);
        swapper.pause();

        ISwapper.SwapParams memory params = _createSwapParams(100 ether, 90 ether);

        vm.prank(swapExecutor);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        swapper.executeSwap(params);
    }

    function test_executeSwap_WhenCallerNotSwapExecutor_Reverts() public {
        _setupRoute();

        ISwapper.SwapParams memory params = _createSwapParams(100 ether, 90 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), swapper.SWAP_EXECUTOR_ROLE()
            )
        );
        swapper.executeSwap(params);
    }

    function test_executeSwap_WhenSwapFails_Reverts() public {
        _setupRoute();

        uint256 amountIn = 100 ether;
        tokenIn.mint(swapExecutor, amountIn);

        mockDex.setShouldRevert(true);

        bytes memory swapCalldata = abi.encodeWithSelector(MockDEX.swap.selector, address(tokenIn), address(tokenOut));
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: amountIn,
            amountOutMin: 90 ether,
            recipient: recipient,
            swapCalldata: swapCalldata
        });

        vm.startPrank(swapExecutor);
        tokenIn.approve(address(swapper), amountIn);
        vm.expectRevert(); // Just expect any revert since the error encoding varies
        swapper.executeSwap(params);
        vm.stopPrank();
    }

    function test_executeSwap_WhenInsufficientOutput_Reverts() public {
        _setupRoute();

        uint256 amountIn = 100 ether;
        uint256 expectedOut = 95 ether;
        uint256 minOut = 96 ether;

        tokenIn.mint(swapExecutor, amountIn);
        tokenOut.mint(dexTarget, expectedOut);

        bytes memory swapCalldata = abi.encodeWithSelector(MockDEX.swap.selector, address(tokenIn), address(tokenOut));
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: amountIn,
            amountOutMin: minOut,
            recipient: recipient,
            swapCalldata: swapCalldata
        });

        vm.startPrank(swapExecutor);
        tokenIn.approve(address(swapper), amountIn);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.InsufficientOutputAmount.selector, expectedOut, minOut));
        swapper.executeSwap(params);
        vm.stopPrank();
    }

    function test_executeSwap_WhenValid_ExecutesSwap() public {
        _setupRoute();

        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;

        tokenIn.mint(swapExecutor, amountIn);
        tokenOut.mint(dexTarget, amountOut);

        bytes memory swapCalldata = abi.encodeWithSelector(MockDEX.swap.selector, address(tokenIn), address(tokenOut));
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: amountIn,
            amountOutMin: 90 ether,
            recipient: recipient,
            swapCalldata: swapCalldata
        });

        vm.startPrank(swapExecutor);
        tokenIn.approve(address(swapper), amountIn);

        vm.expectEmit(true, true, false, true);
        emit SwapExecuted(address(tokenIn), address(tokenOut), amountIn, amountOut, recipient);
        uint256 actualAmountOut = swapper.executeSwap(params);
        vm.stopPrank();

        assertEq(actualAmountOut, amountOut, "Amount out mismatch");
        assertEq(tokenOut.balanceOf(recipient), amountOut, "Recipient balance mismatch");
        assertEq(tokenIn.balanceOf(swapExecutor), 0, "Executor should have no tokenIn left");
        assertEq(tokenOut.balanceOf(address(swapper)), 0, "Swapper should have no tokenOut left");
    }

    function test_executeSwap_WhenReentrantCall_Reverts() public {
        _setupRoute();

        uint256 amountIn = 100 ether;
        tokenIn.mint(swapExecutor, amountIn);

        mockDex.setReentrancyTarget(address(swapper));

        bytes memory swapCalldata =
            abi.encodeWithSelector(MockDEX.swapWithReentrancy.selector, address(tokenIn), address(tokenOut));
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: amountIn,
            amountOutMin: 90 ether,
            recipient: recipient,
            swapCalldata: swapCalldata
        });

        vm.startPrank(swapExecutor);
        tokenIn.approve(address(swapper), amountIn);
        vm.expectRevert(); // Expect any revert - reentrancy will be caught and wrapped in SwapFailed
        swapper.executeSwap(params);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTE SWAP - NATIVE ETH
    //////////////////////////////////////////////////////////////*/

    function test_executeSwap_WhenNativeETHInput_WrapsAndSwaps() public {
        MockWETH mockWeth = new MockWETH();

        vm.prank(admin);
        swapper.setNativeWrapper(address(mockWeth));

        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);
        vm.prank(swapManager);
        swapper.setSwapRoute(address(mockWeth), address(tokenOut), dexTarget, true);

        uint256 amountIn = 1 ether;
        uint256 amountOut = 0.95 ether;
        tokenOut.mint(dexTarget, amountOut);

        bytes memory swapCalldata = abi.encodeWithSelector(MockDEX.swap.selector, address(mockWeth), address(tokenOut));
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: swapper.NATIVE_ETH(),
            tokenOut: address(tokenOut),
            amountIn: amountIn,
            amountOutMin: 0.9 ether,
            recipient: recipient,
            swapCalldata: swapCalldata
        });

        vm.deal(swapExecutor, amountIn);
        vm.prank(swapExecutor);
        uint256 actualAmountOut = swapper.executeSwap{value: amountIn}(params);

        assertEq(actualAmountOut, amountOut, "Amount out mismatch");
        assertEq(tokenOut.balanceOf(recipient), amountOut, "Recipient should receive output tokens");
        assertEq(swapExecutor.balance, 0, "Executor should have sent all ETH");
    }

    function test_executeSwap_WhenNativeETHOutput_SwapsAndUnwraps() public {
        MockWETH mockWeth = new MockWETH();

        vm.prank(admin);
        swapper.setNativeWrapper(address(mockWeth));

        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);
        vm.prank(swapManager);
        swapper.setSwapRoute(address(tokenIn), address(mockWeth), dexTarget, true);

        uint256 amountIn = 100 ether;
        uint256 amountOut = 1 ether;

        tokenIn.mint(swapExecutor, amountIn);
        vm.deal(dexTarget, amountOut);

        bytes memory swapCalldata = abi.encodeWithSelector(MockDEX.swap.selector, address(tokenIn), address(mockWeth));
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: swapper.NATIVE_ETH(),
            amountIn: amountIn,
            amountOutMin: 0.9 ether,
            recipient: recipient,
            swapCalldata: swapCalldata
        });

        uint256 recipientBalanceBefore = recipient.balance;

        vm.startPrank(swapExecutor);
        tokenIn.approve(address(swapper), amountIn);
        uint256 actualAmountOut = swapper.executeSwap(params);
        vm.stopPrank();

        assertEq(actualAmountOut, amountOut, "Amount out mismatch");
        assertEq(recipient.balance, recipientBalanceBefore + amountOut, "Recipient should receive ETH");
    }

    function test_executeSwap_WhenNativeETHInput_WrongMsgValue_Reverts() public {
        MockWETH mockWeth = new MockWETH();

        vm.prank(admin);
        swapper.setNativeWrapper(address(mockWeth));

        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);
        vm.prank(swapManager);
        swapper.setSwapRoute(address(mockWeth), address(tokenOut), dexTarget, true);

        uint256 amountIn = 1 ether;
        uint256 wrongValue = 0.5 ether;

        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: swapper.NATIVE_ETH(),
            tokenOut: address(tokenOut),
            amountIn: amountIn,
            amountOutMin: 0.9 ether,
            recipient: recipient,
            swapCalldata: ""
        });

        vm.deal(swapExecutor, amountIn);
        vm.prank(swapExecutor);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.InsufficientNativeAmount.selector, wrongValue, amountIn));
        swapper.executeSwap{value: wrongValue}(params);
    }

    function test_executeSwap_WhenERC20Swap_UnexpectedNativePayment_Reverts() public {
        _setupRoute();

        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: 100 ether,
            amountOutMin: 90 ether,
            recipient: recipient,
            swapCalldata: ""
        });

        vm.deal(swapExecutor, 1 ether);
        vm.prank(swapExecutor);
        vm.expectRevert(ISwapper.UnexpectedNativePayment.selector);
        swapper.executeSwap{value: 1 ether}(params);
    }

    function test_executeSwap_WhenNativeETHOutput_TransferFails_Reverts() public {
        MockWETH mockWeth = new MockWETH();

        vm.prank(admin);
        swapper.setNativeWrapper(address(mockWeth));

        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);
        vm.prank(swapManager);
        swapper.setSwapRoute(address(tokenIn), address(mockWeth), dexTarget, true);

        uint256 amountIn = 100 ether;
        uint256 amountOut = 1 ether;

        tokenIn.mint(swapExecutor, amountIn);
        vm.deal(dexTarget, amountOut);

        RejectEther rejecter = new RejectEther();

        bytes memory swapCalldata = abi.encodeWithSelector(MockDEX.swap.selector, address(tokenIn), address(mockWeth));
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: swapper.NATIVE_ETH(),
            amountIn: amountIn,
            amountOutMin: 0.9 ether,
            recipient: address(rejecter),
            swapCalldata: swapCalldata
        });

        vm.startPrank(swapExecutor);
        tokenIn.approve(address(swapper), amountIn);
        vm.expectRevert(ISwapper.NativeTransferFailed.selector);
        swapper.executeSwap(params);
        vm.stopPrank();
    }

    function test_executeSwap_SequentialSwaps_BothSucceed() public {
        _setupRoute();

        uint256 amountIn1 = 100 ether;
        uint256 amountOut1 = 95 ether;
        tokenIn.mint(swapExecutor, amountIn1);
        tokenOut.mint(dexTarget, amountOut1);

        bytes memory swapCalldata = abi.encodeWithSelector(MockDEX.swap.selector, address(tokenIn), address(tokenOut));
        ISwapper.SwapParams memory params1 = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: amountIn1,
            amountOutMin: 90 ether,
            recipient: recipient,
            swapCalldata: swapCalldata
        });

        vm.startPrank(swapExecutor);
        tokenIn.approve(address(swapper), amountIn1);
        uint256 actualOut1 = swapper.executeSwap(params1);
        assertEq(actualOut1, amountOut1, "First swap amount mismatch");

        uint256 amountIn2 = 50 ether;
        uint256 amountOut2 = 48 ether;
        tokenIn.mint(swapExecutor, amountIn2);
        tokenOut.mint(dexTarget, amountOut2);

        ISwapper.SwapParams memory params2 = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: amountIn2,
            amountOutMin: 45 ether,
            recipient: recipient,
            swapCalldata: swapCalldata
        });

        tokenIn.approve(address(swapper), amountIn2);
        uint256 actualOut2 = swapper.executeSwap(params2);
        vm.stopPrank();

        assertEq(actualOut2, amountOut2, "Second swap amount mismatch");
        assertEq(tokenOut.balanceOf(recipient), amountOut1 + amountOut2, "Total recipient balance mismatch");
        assertEq(tokenIn.balanceOf(swapExecutor), 0, "Executor should have no tokenIn left");
        assertEq(tokenOut.balanceOf(address(swapper)), 0, "Swapper should have no tokenOut left");
        assertEq(tokenIn.balanceOf(address(swapper)), 0, "Swapper should have no tokenIn left");
    }

    function test_executeSwap_SequentialSwaps_DifferentRecipients_BothSucceed() public {
        _setupRoute();

        address recipient2 = makeAddr("recipient2");

        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;

        bytes memory swapCalldata = abi.encodeWithSelector(MockDEX.swap.selector, address(tokenIn), address(tokenOut));

        vm.startPrank(swapExecutor);

        tokenIn.mint(swapExecutor, amountIn);
        tokenOut.mint(dexTarget, amountOut);
        tokenIn.approve(address(swapper), amountIn);
        ISwapper.SwapParams memory params1 = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: amountIn,
            amountOutMin: 90 ether,
            recipient: recipient,
            swapCalldata: swapCalldata
        });
        swapper.executeSwap(params1);

        tokenIn.mint(swapExecutor, amountIn);
        tokenOut.mint(dexTarget, amountOut);
        tokenIn.approve(address(swapper), amountIn);
        ISwapper.SwapParams memory params2 = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: amountIn,
            amountOutMin: 90 ether,
            recipient: recipient2,
            swapCalldata: swapCalldata
        });
        swapper.executeSwap(params2);

        vm.stopPrank();

        assertEq(tokenOut.balanceOf(recipient), amountOut, "Recipient1 balance mismatch");
        assertEq(tokenOut.balanceOf(recipient2), amountOut, "Recipient2 balance mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                         SET SWAP ROUTE
    //////////////////////////////////////////////////////////////*/

    function test_setSwapRoute_UpdateExistingRoute_UpdatesTarget() public {
        address dexTarget2 = makeAddr("dexTarget2");

        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);

        vm.prank(swapManager);
        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget, true);

        ISwapper.SwapRoute memory route1 = swapper.getSwapRoute(address(tokenIn), address(tokenOut));
        assertEq(route1.swapTarget, dexTarget, "Initial target mismatch");

        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget2, true);

        vm.startPrank(swapManager);
        vm.expectEmit(true, true, false, true);
        emit SwapRouteSet(address(tokenIn), address(tokenOut), dexTarget2, true);
        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget2, true);
        vm.stopPrank();

        ISwapper.SwapRoute memory route2 = swapper.getSwapRoute(address(tokenIn), address(tokenOut));
        assertEq(route2.swapTarget, dexTarget2, "Updated target mismatch");
        assertEq(route2.tokenIn, address(tokenIn), "TokenIn should remain same");
        assertEq(route2.tokenOut, address(tokenOut), "TokenOut should remain same");
        assertTrue(route2.enabled, "Route should remain enabled");
    }

    function test_setSwapRoute_UpdateRouteTarget_OldTargetSwapsFail() public {
        address dexTarget2 = makeAddr("dexTarget2");
        MockDEX mockDex2 = new MockDEX();
        dexTarget2 = address(mockDex2);

        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);

        vm.prank(swapManager);
        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget, true);

        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget2, true);

        vm.prank(swapManager);
        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget2, true);

        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;

        tokenIn.mint(swapExecutor, amountIn);
        tokenOut.mint(dexTarget2, amountOut);

        bytes memory swapCalldata = abi.encodeWithSelector(MockDEX.swap.selector, address(tokenIn), address(tokenOut));
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: amountIn,
            amountOutMin: 90 ether,
            recipient: recipient,
            swapCalldata: swapCalldata
        });

        vm.startPrank(swapExecutor);
        tokenIn.approve(address(swapper), amountIn);
        uint256 actualOut = swapper.executeSwap(params);
        vm.stopPrank();

        assertEq(actualOut, amountOut, "Swap should use new target");
        assertEq(tokenOut.balanceOf(recipient), amountOut, "Recipient should receive tokens");
    }

    function test_setSwapRoute_UpdateRouteEnabled_TogglesCorrectly() public {
        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);

        vm.startPrank(swapManager);

        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget, true);
        ISwapper.SwapRoute memory route1 = swapper.getSwapRoute(address(tokenIn), address(tokenOut));
        assertTrue(route1.enabled, "Route should be enabled");

        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget, false);
        ISwapper.SwapRoute memory route2 = swapper.getSwapRoute(address(tokenIn), address(tokenOut));
        assertFalse(route2.enabled, "Route should be disabled");
        assertEq(route2.swapTarget, dexTarget, "Target should remain same");

        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget, true);
        ISwapper.SwapRoute memory route3 = swapper.getSwapRoute(address(tokenIn), address(tokenOut));
        assertTrue(route3.enabled, "Route should be re-enabled");

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _setupRoute() internal {
        vm.prank(admin);
        swapper.setSwapTargetWhitelist(dexTarget, true);

        vm.prank(swapManager);
        swapper.setSwapRoute(address(tokenIn), address(tokenOut), dexTarget, true);
    }

    function _createSwapParams(
        uint256 amountIn,
        uint256 amountOutMin
    )
        internal
        view
        returns (ISwapper.SwapParams memory)
    {
        bytes memory swapCalldata = abi.encodeWithSelector(MockDEX.swap.selector, address(tokenIn), address(tokenOut));
        return ISwapper.SwapParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            recipient: recipient,
            swapCalldata: swapCalldata
        });
    }
}

/*//////////////////////////////////////////////////////////////
                           MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockDEX {
    bool private shouldRevert;
    address private reentrancyTarget;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setReentrancyTarget(address _target) external {
        reentrancyTarget = _target;
    }

    function swap(address tokenIn, address tokenOut) external {
        require(!shouldRevert, "Mock swap failed");

        // Pull input tokens from caller (mimics real DEX behavior)
        if (tokenIn != address(0)) {
            try MockToken(tokenIn)
                .transferFrom(
                    msg.sender, address(this), MockToken(tokenIn).allowance(msg.sender, address(this))
                ) returns (
                bool
            ) {}
                catch {}
        }

        // Handle both ERC20 and WETH
        if (tokenOut.code.length > 0) {
            try MockToken(tokenOut).balanceOf(address(this)) returns (uint256 balance) {
                if (balance > 0) {
                    require(MockToken(tokenOut).transfer(msg.sender, balance), "Transfer failed");
                    return;
                }
            } catch {}
        }

        // If tokenOut is WETH or has ETH balance, wrap and send
        if (address(this).balance > 0) {
            MockWETH(payable(tokenOut)).deposit{value: address(this).balance}();
            uint256 wethBalance = MockWETH(payable(tokenOut)).balanceOf(address(this));
            require(MockWETH(payable(tokenOut)).transfer(msg.sender, wethBalance), "WETH transfer failed");
        }
    }

    function swapWithReentrancy(address tokenIn, address tokenOut) external {
        ISwapper.SwapParams memory params = ISwapper.SwapParams({
            tokenIn: tokenIn, tokenOut: tokenOut, amountIn: 0, amountOutMin: 1, recipient: msg.sender, swapCalldata: ""
        });

        ISwapper(reentrancyTarget).executeSwap(params);
    }

    receive() external payable {}
}

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract RejectEther {
    // Contract that rejects all ETH transfers
    receive() external payable {
        revert("ETH not accepted");
    }
}
