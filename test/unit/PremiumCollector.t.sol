// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {PremiumCollector} from "../../src/PremiumCollector.sol";
import {IPremiumCollector} from "../../src/interfaces/IPremiumCollector.sol";

contract PremiumCollectorTest is Test {
    uint64 internal constant DEFAULT_DISTRIBUTE_INTERVAL = 86_400; // 24 hours
    uint96 internal constant POLICY_ID = 123;

    address internal admin;
    address internal pool;
    address internal operator;
    address internal vault1;
    address internal vault2;

    PremiumCollector internal premiumCollector;
    MockPremiumManager internal premiumManager;
    MockCoverPool internal mockPool;
    MockERC4626 internal mockVault1;
    MockERC4626 internal mockVault2;
    MockToken internal underlying1;
    MockToken internal underlying2;

    event VaultRegistered(address indexed vault, address indexed underlying, address pool, uint96 policyId);
    event VaultRemoved(address indexed vault);
    event VaultUpdated(address indexed vault, address pool, uint96 policyId);
    event Distributed(address indexed vault, uint256 shares, uint256 assets);
    event DistributeIntervalSet(uint64 interval);
    event PremiumManagerSet(address indexed premiumManager_);

    function setUp() public {
        vm.warp(1_000_000);

        admin = makeAddr("admin");
        operator = makeAddr("operator");

        vm.label(admin, "Admin");
        vm.label(operator, "Operator");

        mockPool = new MockCoverPool(operator);
        pool = address(mockPool);

        vm.label(pool, "Pool");

        underlying1 = new MockToken("Underlying1", "U1");
        underlying2 = new MockToken("Underlying2", "U2");
        mockVault1 = new MockERC4626(underlying1, "Vault1", "V1");
        mockVault2 = new MockERC4626(underlying2, "Vault2", "V2");
        premiumManager = new MockPremiumManager();

        vault1 = address(mockVault1);
        vault2 = address(mockVault2);

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "PremiumCollector.sol",
            abi.encodeCall(PremiumCollector.initialize, (admin, address(premiumManager), DEFAULT_DISTRIBUTE_INTERVAL)),
            deployOpts
        );
        premiumCollector = PremiumCollector(proxy);

        vm.label(address(premiumCollector), "PremiumCollector");
        vm.label(address(premiumManager), "PremiumManager");
        vm.label(address(underlying1), "Underlying1");
        vm.label(address(underlying2), "Underlying2");
        vm.label(vault1, "Vault1");
        vm.label(vault2, "Vault2");
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_initialize_WhenAdminZero_Reverts() public {
        PremiumCollector implementation = new PremiumCollector();
        PremiumCollector freshCollector = PremiumCollector(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPremiumCollector.ZeroAddress.selector);
        freshCollector.initialize(address(0), address(premiumManager), DEFAULT_DISTRIBUTE_INTERVAL);
    }

    function test_initialize_WhenPremiumManagerZero_Reverts() public {
        PremiumCollector implementation = new PremiumCollector();
        PremiumCollector freshCollector = PremiumCollector(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPremiumCollector.ZeroAddress.selector);
        freshCollector.initialize(admin, address(0), DEFAULT_DISTRIBUTE_INTERVAL);
    }

    function test_initialize_WhenIntervalZero_Reverts() public {
        PremiumCollector implementation = new PremiumCollector();
        PremiumCollector freshCollector = PremiumCollector(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(abi.encodeWithSelector(IPremiumCollector.InvalidDistributeInterval.selector, 0));
        freshCollector.initialize(admin, address(premiumManager), 0);
    }

    function test_initialize_Success() public view {
        assertEq(premiumCollector.premiumManager(), address(premiumManager));
        assertEq(premiumCollector.distributeInterval(), DEFAULT_DISTRIBUTE_INTERVAL);
        assertTrue(premiumCollector.hasRole(bytes32(0), admin));
    }

    /*//////////////////////////////////////////////////////////////
                           REGISTER VAULT
    //////////////////////////////////////////////////////////////*/

    function test_registerVault_WhenNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        premiumCollector.registerVault(vault1, pool, POLICY_ID);
    }

    function test_registerVault_WhenVaultZero_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(IPremiumCollector.ZeroAddress.selector);
        premiumCollector.registerVault(address(0), pool, POLICY_ID);
    }

    function test_registerVault_WhenPoolZero_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(IPremiumCollector.ZeroAddress.selector);
        premiumCollector.registerVault(vault1, address(0), POLICY_ID);
    }

    function test_registerVault_WhenCommitteeIdZero_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(IPremiumCollector.ZeroAmount.selector);
        premiumCollector.registerVault(vault1, pool, 0);
    }

    function test_registerVault_WhenAlreadyRegistered_Reverts() public {
        vm.startPrank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        vm.expectRevert(abi.encodeWithSelector(IPremiumCollector.VaultAlreadyRegistered.selector, vault1));
        premiumCollector.registerVault(vault1, pool, POLICY_ID);
        vm.stopPrank();
    }

    function test_registerVault_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit VaultRegistered(vault1, address(underlying1), pool, POLICY_ID);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        IPremiumCollector.VaultConfig memory config = premiumCollector.getVaultConfig(vault1);
        assertEq(config.underlying, address(underlying1));
        assertEq(config.pool, pool);
        assertEq(config.policyId, POLICY_ID);
        assertEq(config.lastDistributeTime, 0);
        assertTrue(config.registered);

        address[] memory vaults = premiumCollector.getRegisteredVaults();
        assertEq(vaults.length, 1);
        assertEq(vaults[0], vault1);
    }

    function test_registerVault_WhenUnderlyingZero_Reverts() public {
        MockZeroAssetVault zeroVault = new MockZeroAssetVault();
        vm.prank(admin);
        vm.expectRevert(IPremiumCollector.ZeroAddress.selector);
        premiumCollector.registerVault(address(zeroVault), pool, POLICY_ID);
    }

    /*//////////////////////////////////////////////////////////////
                           REMOVE VAULT
    //////////////////////////////////////////////////////////////*/

    function test_removeVault_WhenNotAdmin_Reverts() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        premiumCollector.removeVault(vault1);
    }

    function test_removeVault_WhenNotRegistered_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPremiumCollector.VaultNotRegistered.selector, vault1));
        premiumCollector.removeVault(vault1);
    }

    function test_removeVault_WhenHasShares_Reverts() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        mockVault1.mint(address(premiumCollector), 100 ether);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPremiumCollector.VaultHasShares.selector, vault1, 100 ether));
        premiumCollector.removeVault(vault1);
    }

    function test_removeVault_Success() public {
        vm.startPrank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);
        premiumCollector.registerVault(vault2, pool, POLICY_ID);

        vm.expectEmit(true, false, false, false);
        emit VaultRemoved(vault1);
        premiumCollector.removeVault(vault1);
        vm.stopPrank();

        IPremiumCollector.VaultConfig memory config = premiumCollector.getVaultConfig(vault1);
        assertFalse(config.registered);

        address[] memory vaults = premiumCollector.getRegisteredVaults();
        assertEq(vaults.length, 1);
        assertEq(vaults[0], vault2);
    }

    function test_removeVault_WhenLastElement_Succeeds() public {
        vm.startPrank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        vm.expectEmit(true, false, false, false);
        emit VaultRemoved(vault1);
        premiumCollector.removeVault(vault1);
        vm.stopPrank();

        IPremiumCollector.VaultConfig memory config = premiumCollector.getVaultConfig(vault1);
        assertFalse(config.registered, "Vault should be deregistered");

        address[] memory vaults = premiumCollector.getRegisteredVaults();
        assertEq(vaults.length, 0, "Registered vaults list should be empty");
    }

    /*//////////////////////////////////////////////////////////////
                           UPDATE VAULT
    //////////////////////////////////////////////////////////////*/

    function test_updateVault_WhenNotAdmin_Reverts() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        address newPool = makeAddr("newPool");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        premiumCollector.updateVault(vault1, newPool, POLICY_ID + 1);
    }

    function test_updateVault_WhenNotRegistered_Reverts() public {
        address newPool = makeAddr("newPool");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPremiumCollector.VaultNotRegistered.selector, vault1));
        premiumCollector.updateVault(vault1, newPool, POLICY_ID + 1);
    }

    function test_updateVault_Success() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        address newPool = makeAddr("newPool");
        uint96 newPolicyId = POLICY_ID + 1;

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit VaultUpdated(vault1, newPool, newPolicyId);
        premiumCollector.updateVault(vault1, newPool, newPolicyId);

        IPremiumCollector.VaultConfig memory config = premiumCollector.getVaultConfig(vault1);
        assertEq(config.pool, newPool);
        assertEq(config.policyId, newPolicyId);
        assertEq(config.underlying, address(underlying1));
    }

    function test_updateVault_WhenPoolZero_Reverts() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        vm.prank(admin);
        vm.expectRevert(IPremiumCollector.ZeroAddress.selector);
        premiumCollector.updateVault(vault1, address(0), POLICY_ID);
    }

    function test_updateVault_WhenPolicyIdZero_Reverts() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        vm.prank(admin);
        vm.expectRevert(IPremiumCollector.ZeroAmount.selector);
        premiumCollector.updateVault(vault1, pool, 0);
    }

    /*//////////////////////////////////////////////////////////////
                          DISTRIBUTE BATCH
    //////////////////////////////////////////////////////////////*/

    function test_distributeBatch_WhenPaused_Reverts() public {
        vm.prank(admin);
        premiumCollector.pause();

        address[] memory vaults = new address[](1);
        vaults[0] = vault1;

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        premiumCollector.distributeBatch(vaults);
    }

    function test_distributeBatch_SkipsUnregisteredVault() public {
        address[] memory vaults = new address[](1);
        vaults[0] = vault1;

        premiumCollector.distributeBatch(vaults);
    }

    function test_distributeBatch_SkipsWhenIntervalNotElapsed() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        mockVault1.mint(address(premiumCollector), 100 ether);
        underlying1.mint(vault1, 100 ether);

        address[] memory vaults = new address[](1);
        vaults[0] = vault1;

        premiumCollector.distributeBatch(vaults);

        mockVault1.mint(address(premiumCollector), 50 ether);
        underlying1.mint(vault1, 50 ether);

        premiumCollector.distributeBatch(vaults);

        assertEq(mockVault1.balanceOf(address(premiumCollector)), 50 ether);
    }

    function test_distributeBatch_SkipsWhenNoShares() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        address[] memory vaults = new address[](1);
        vaults[0] = vault1;

        premiumCollector.distributeBatch(vaults);
    }

    function test_distributeBatch_SingleVaultSuccess() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        uint256 shares = 100 ether;
        uint256 assets = 100 ether;
        mockVault1.mint(address(premiumCollector), shares);
        underlying1.mint(address(mockVault1), assets);

        address[] memory vaults = new address[](1);
        vaults[0] = vault1;

        vm.expectEmit(true, false, false, true);
        emit Distributed(vault1, shares, assets);
        premiumCollector.distributeBatch(vaults);

        assertEq(mockVault1.balanceOf(address(premiumCollector)), 0);
        assertEq(underlying1.balanceOf(address(premiumManager)), assets);

        IPremiumCollector.VaultConfig memory config = premiumCollector.getVaultConfig(vault1);
        assertEq(config.lastDistributeTime, block.timestamp);
    }

    function test_distributeBatch_MultipleVaultsSuccess() public {
        vm.startPrank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);
        premiumCollector.registerVault(vault2, pool, POLICY_ID);
        vm.stopPrank();

        mockVault1.mint(address(premiumCollector), 100 ether);
        underlying1.mint(address(mockVault1), 100 ether);
        mockVault2.mint(address(premiumCollector), 200 ether);
        underlying2.mint(address(mockVault2), 200 ether);

        address[] memory vaults = new address[](2);
        vaults[0] = vault1;
        vaults[1] = vault2;

        premiumCollector.distributeBatch(vaults);

        assertEq(mockVault1.balanceOf(address(premiumCollector)), 0);
        assertEq(mockVault2.balanceOf(address(premiumCollector)), 0);
        assertEq(underlying1.balanceOf(address(premiumManager)), 100 ether);
        assertEq(underlying2.balanceOf(address(premiumManager)), 200 ether);
    }

    function test_distributeBatch_SkipsWhenRedeemReturnsZeroAssets() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        uint256 shares = 100 ether;
        mockVault1.mint(address(premiumCollector), shares);

        address[] memory vaults = new address[](1);
        vaults[0] = vault1;

        premiumCollector.distributeBatch(vaults);

        assertEq(mockVault1.balanceOf(address(premiumCollector)), 0);
        assertEq(underlying1.balanceOf(address(premiumManager)), 0);

        IPremiumCollector.VaultConfig memory config = premiumCollector.getVaultConfig(vault1);
        assertEq(config.lastDistributeTime, 0);
    }

    function test_distributeBatch_ZeroAssetVaultDoesNotBlockOthers() public {
        vm.startPrank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);
        premiumCollector.registerVault(vault2, pool, POLICY_ID);
        vm.stopPrank();

        mockVault1.mint(address(premiumCollector), 100 ether);
        mockVault2.mint(address(premiumCollector), 200 ether);
        underlying2.mint(address(mockVault2), 200 ether);

        address[] memory vaults = new address[](2);
        vaults[0] = vault1;
        vaults[1] = vault2;

        premiumCollector.distributeBatch(vaults);

        assertEq(mockVault1.balanceOf(address(premiumCollector)), 0);
        assertEq(underlying1.balanceOf(address(premiumManager)), 0);

        assertEq(mockVault2.balanceOf(address(premiumCollector)), 0);
        assertEq(underlying2.balanceOf(address(premiumManager)), 200 ether);

        IPremiumCollector.VaultConfig memory config1 = premiumCollector.getVaultConfig(vault1);
        assertEq(config1.lastDistributeTime, 0);

        IPremiumCollector.VaultConfig memory config2 = premiumCollector.getVaultConfig(vault2);
        assertEq(config2.lastDistributeTime, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                      GET DISTRIBUTABLE VAULTS
    //////////////////////////////////////////////////////////////*/

    function test_getDistributableVaults_EmptyWhenNoneEligible() public view {
        address[] memory distributable = premiumCollector.getDistributableVaults();
        assertEq(distributable.length, 0);
    }

    function test_getDistributableVaults_ExcludesNoShares() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        address[] memory distributable = premiumCollector.getDistributableVaults();
        assertEq(distributable.length, 0);
    }

    function test_getDistributableVaults_ExcludesIntervalNotElapsed() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        mockVault1.mint(address(premiumCollector), 100 ether);
        underlying1.mint(address(mockVault1), 100 ether);

        address[] memory vaults = new address[](1);
        vaults[0] = vault1;
        premiumCollector.distributeBatch(vaults);

        mockVault1.mint(address(premiumCollector), 50 ether);

        address[] memory distributable = premiumCollector.getDistributableVaults();
        assertEq(distributable.length, 0);
    }

    function test_getDistributableVaults_IncludesEligible() public {
        vm.startPrank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);
        premiumCollector.registerVault(vault2, pool, POLICY_ID);
        vm.stopPrank();

        mockVault1.mint(address(premiumCollector), 100 ether);

        address[] memory distributable = premiumCollector.getDistributableVaults();
        assertEq(distributable.length, 1);
        assertEq(distributable[0], vault1);
    }

    function test_distributeBatch_EndToEndPremiumFlow() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        uint256 shares = 1000 ether;
        mockVault1.mint(address(premiumCollector), shares);

        uint256 assets = 1000 ether;
        underlying1.mint(vault1, assets);

        vm.warp(block.timestamp + DEFAULT_DISTRIBUTE_INTERVAL);

        address[] memory vaults = new address[](1);
        vaults[0] = vault1;

        vm.prank(address(this));
        premiumCollector.distributeBatch(vaults);

        assertEq(mockVault1.balanceOf(address(premiumCollector)), 0, "Shares should be redeemed");
        assertEq(underlying1.balanceOf(address(premiumManager)), assets, "Underlying should be sent to PremiumManager");
        assertEq(premiumManager.lastDistributedAmount(), assets, "PremiumManager should receive correct amount");
    }

    function test_distributeBatch_CallsPremiumManagerWithCorrectParameters() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        uint256 shares = 500 ether;
        uint256 assets = 500 ether;
        mockVault1.mint(address(premiumCollector), shares);
        underlying1.mint(vault1, assets);

        vm.warp(block.timestamp + DEFAULT_DISTRIBUTE_INTERVAL);

        address[] memory vaults = new address[](1);
        vaults[0] = vault1;

        vm.prank(address(this));
        premiumCollector.distributeBatch(vaults);

        assertEq(premiumManager.lastPool(), pool, "Pool address should match");
        assertEq(premiumManager.lastPremiumToken(), address(underlying1), "Premium token should be underlying asset");
        assertEq(premiumManager.lastCommitteeId(), POLICY_ID, "CommitteeId should equal policyId");
        assertEq(premiumManager.lastDistributedAmount(), assets, "Amount should match redeemed assets");
    }

    function test_distributeBatch_MultiplePoliciesSamePool_DistributesWithCorrectCommitteeIds() public {
        uint96 policyId2 = 456;

        vm.startPrank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);
        premiumCollector.registerVault(vault2, pool, policyId2);
        vm.stopPrank();

        uint256 shares1 = 300 ether;
        uint256 shares2 = 700 ether;
        mockVault1.mint(address(premiumCollector), shares1);
        mockVault2.mint(address(premiumCollector), shares2);

        underlying1.mint(vault1, shares1);
        underlying2.mint(vault2, shares2);

        vm.warp(block.timestamp + DEFAULT_DISTRIBUTE_INTERVAL);

        address[] memory vaults1 = new address[](1);
        vaults1[0] = vault1;
        vm.prank(address(this));
        premiumCollector.distributeBatch(vaults1);

        uint96 firstCommitteeId = premiumManager.lastCommitteeId();

        address[] memory vaults2 = new address[](1);
        vaults2[0] = vault2;
        vm.prank(address(this));
        premiumCollector.distributeBatch(vaults2);

        uint96 secondCommitteeId = premiumManager.lastCommitteeId();

        assertEq(firstCommitteeId, POLICY_ID, "First distribution should use first policyId");
        assertEq(secondCommitteeId, policyId2, "Second distribution should use second policyId");
        assertNotEq(firstCommitteeId, secondCommitteeId, "Different policies should have different committeeIds");
    }

    function test_distributeBatch_ShareConversionToUnderlyingAssets() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        uint256 shares = 100 ether;
        uint256 expectedAssets = 95 ether;
        mockVault1.mint(address(premiumCollector), shares);
        underlying1.mint(vault1, expectedAssets);

        vm.warp(block.timestamp + DEFAULT_DISTRIBUTE_INTERVAL);

        address[] memory vaults = new address[](1);
        vaults[0] = vault1;

        vm.prank(address(this));
        premiumCollector.distributeBatch(vaults);

        assertEq(mockVault1.balanceOf(address(premiumCollector)), 0, "All shares should be redeemed");
        assertEq(
            underlying1.balanceOf(address(premiumManager)),
            expectedAssets,
            "PremiumManager should receive underlying assets"
        );
        assertEq(
            premiumManager.lastDistributedAmount(), expectedAssets, "Distribution amount should equal redeemed assets"
        );
    }

    /*//////////////////////////////////////////////////////////////
                       SET DISTRIBUTE INTERVAL
    //////////////////////////////////////////////////////////////*/

    function test_setDistributeInterval_WhenNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        premiumCollector.setDistributeInterval(3600);
    }

    function test_setDistributeInterval_WhenZero_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPremiumCollector.InvalidDistributeInterval.selector, 0));
        premiumCollector.setDistributeInterval(0);
    }

    function test_setDistributeInterval_Success() public {
        uint64 newInterval = 3600;
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit DistributeIntervalSet(newInterval);
        premiumCollector.setDistributeInterval(newInterval);

        assertEq(premiumCollector.distributeInterval(), newInterval);
    }

    /*//////////////////////////////////////////////////////////////
                        SET PREMIUM MANAGER
    //////////////////////////////////////////////////////////////*/

    function test_setPremiumManager_WhenNotAdmin_Reverts() public {
        address newManager = makeAddr("newManager");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        premiumCollector.setPremiumManager(newManager);
    }

    function test_setPremiumManager_WhenZero_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(IPremiumCollector.ZeroAddress.selector);
        premiumCollector.setPremiumManager(address(0));
    }

    function test_setPremiumManager_Success() public {
        address newManager = makeAddr("newManager");
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit PremiumManagerSet(newManager);
        premiumCollector.setPremiumManager(newManager);

        assertEq(premiumCollector.premiumManager(), newManager);
    }

    /*//////////////////////////////////////////////////////////////
                              PAUSE / UNPAUSE
    //////////////////////////////////////////////////////////////*/

    function test_pause_WhenCalledByAdmin_PausesCollector() public {
        vm.prank(admin);
        premiumCollector.pause();
        assertTrue(premiumCollector.paused());
    }

    function test_pause_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        premiumCollector.pause();
    }

    function test_unpause_WhenCalledByAdmin_UnpausesCollector() public {
        vm.startPrank(admin);
        premiumCollector.pause();
        premiumCollector.unpause();
        vm.stopPrank();
        assertFalse(premiumCollector.paused());
    }

    function test_unpause_WhenCallerNotAdmin_Reverts() public {
        vm.prank(admin);
        premiumCollector.pause();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        premiumCollector.unpause();
    }

    function test_paused_ReturnsCorrectState() public {
        assertFalse(premiumCollector.paused(), "Should start unpaused");

        vm.prank(admin);
        premiumCollector.pause();
        assertTrue(premiumCollector.paused(), "Should be paused after pause()");

        vm.prank(admin);
        premiumCollector.unpause();
        assertFalse(premiumCollector.paused(), "Should be unpaused after unpause()");
    }

    /*//////////////////////////////////////////////////////////////
                           GET ACCRUED SHARES
    //////////////////////////////////////////////////////////////*/

    function test_getAccruedShares_WhenNoShares_ReturnsZero() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);
        assertEq(premiumCollector.getAccruedShares(vault1), 0, "Should return 0 when no shares held");
    }

    function test_getAccruedShares_WhenHasShares_ReturnsBalance() public {
        vm.prank(admin);
        premiumCollector.registerVault(vault1, pool, POLICY_ID);

        uint256 shares = 500 ether;
        mockVault1.mint(address(premiumCollector), shares);
        assertEq(premiumCollector.getAccruedShares(vault1), shares, "Should return correct accrued shares");
    }

    /*//////////////////////////////////////////////////////////////
                                UPGRADE
    //////////////////////////////////////////////////////////////*/

    function test_authorizeUpgrade_WhenCallerNotAdmin_Reverts() public {
        PremiumCollector newImpl = new PremiumCollector();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        premiumCollector.upgradeToAndCall(address(newImpl), "");
    }

    function test_authorizeUpgrade_WhenCalledByAdmin_Succeeds() public {
        PremiumCollector newImpl = new PremiumCollector();
        vm.prank(admin);
        premiumCollector.upgradeToAndCall(address(newImpl), "");

        assertEq(premiumCollector.premiumManager(), address(premiumManager), "PremiumManager should be preserved");
        assertEq(premiumCollector.distributeInterval(), DEFAULT_DISTRIBUTE_INTERVAL, "Interval should be preserved");
        assertTrue(premiumCollector.hasRole(bytes32(0), admin), "Admin role should be preserved");
    }
}

/*//////////////////////////////////////////////////////////////
                            MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC4626 is IERC4626, ERC20 {
    IERC20 private immutable _ASSET;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _ASSET = asset_;
    }

    function asset() external view override returns (address) {
        return address(_ASSET);
    }

    function totalAssets() external view override returns (uint256) {
        return _ASSET.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) external pure override returns (uint256) {
        return assets;
    }

    function convertToAssets(uint256 shares) external pure override returns (uint256) {
        return shares;
    }

    function maxDeposit(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view override returns (uint256) {
        return balanceOf(owner);
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 assets) external pure override returns (uint256) {
        return assets;
    }

    function previewMint(uint256 shares) external pure override returns (uint256) {
        return shares;
    }

    function previewWithdraw(uint256 assets) external pure override returns (uint256) {
        return assets;
    }

    function previewRedeem(uint256 shares) external pure override returns (uint256) {
        return shares;
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256) {
        require(_ASSET.transferFrom(msg.sender, address(this), assets), "transfer failed");
        _mint(receiver, assets);
        return assets;
    }

    function mint(uint256 shares, address receiver) external override returns (uint256) {
        uint256 assets = shares;
        require(_ASSET.transferFrom(msg.sender, address(this), assets), "transfer failed");
        _mint(receiver, shares);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256) {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, assets);
        }
        _burn(owner, assets);
        require(_ASSET.transfer(receiver, assets), "transfer failed");
        return assets;
    }

    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256) {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        uint256 assets = shares;
        uint256 available = _ASSET.balanceOf(address(this));
        if (available < assets) {
            assets = available;
        }
        if (assets > 0) {
            require(_ASSET.transfer(receiver, assets), "transfer failed");
        }
        return assets;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPremiumManager {
    address public lastPool;
    address public lastPremiumToken;
    uint96 public lastCommitteeId;
    uint256 public lastDistributedAmount;

    function distributePremium(address pool, uint96 policyId, address premiumToken, uint256 amount) external {
        lastPool = pool;
        lastCommitteeId = policyId;
        lastPremiumToken = premiumToken;
        lastDistributedAmount = amount;
    }
}

contract MockCoverPool {
    address private immutable _owner;

    constructor(address owner_) {
        _owner = owner_;
    }

    function owner() external view returns (address) {
        return _owner;
    }
}

/// @dev ERC-4626 vault stub whose asset() returns address(0) to trigger the zero-underlying guard in registerVault.
contract MockZeroAssetVault {
    function asset() external pure returns (address) {
        return address(0);
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}
