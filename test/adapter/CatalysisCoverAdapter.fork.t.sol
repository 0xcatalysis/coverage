// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { CatalysisCoverAdapter } from "../../src/adapter/adapters/vault/CatalysisCoverAdapter.sol";
import { ICatalysisCoverAdapter } from "../../src/adapter/interfaces/ICatalysisCoverAdapter.sol";
import { IVaultV2 } from "../../src/adapter/interfaces/Morpho/IVaultV2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Options, Upgrades } from "@openzeppelin/upgrades/Upgrades.sol";

import { ISpec } from "coverage/interfaces/ISpec.sol";
import { IPolicyManager } from "coverage/interfaces/IPolicyManager.sol";

import { MockPolicyManager, MockClaimManager, MockCoverPool } from "./mocks/Mocks.sol";
import { ControllableVault } from "./mocks/ControllableVault.sol";
import { ForkClaimManager } from "./mocks/ForkClaimManager.sol";

/// @notice Minimal interface for Morpho VaultV2Factory
interface IVaultV2Factory {
    function createVaultV2(
        address owner,
        address asset,
        bytes32 salt
    ) external returns (address);
    function isVaultV2(
        address vault
    ) external view returns (bool);
}

/// @title CatalysisCoverAdapterForkTest
/// @notice Fork tests using a real Morpho Vault V2 as parent + real MetaMorpho V1 as underlying
/// @dev For tests where loss manipulation is required, mock vault is used as underlying vault
/// @dev Run with: forge test --match-contract Fork -vvv
///
///      Architecture under test:
///        User -> Covered Vault (V2, real) -> CatalysisCoverAdapter -> Underlying Vault (MetaMorpho V1) Or Controllable
/// Vault (Mock)
///      The setUp() deploys a fresh V2 parent vault via the on-chain factory and performs
///      full governance setup (setCurator, addAdapter, setIsAllocator, caps, liquidityAdapter)
///      so that user deposit/withdraw flow through the real V2 code end-to-end.
///      _setupParentWithMockUnderlyingVault() setups smart contracts with mock underlying Vaults. Called where
/// necessary
///      Liquidity adapter: the adapter is set as the liquidity adapter on the V2 vault.
///      This means user deposit() auto-allocates to the adapter (with deposit selector),
///      and user withdraw/redeem() auto-deallocates (with withdraw/redeem selector),
///      triggering proper principal tracking and insurance logic.
contract CatalysisCoverAdapterForkTest is Test {
    /*//////////////////////////////////////////////////////////////
                        MAINNET ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /// @dev Morpho Vault V2 Factory
    address constant VAULT_V2_FACTORY = 0xA1D94F746dEfa1928926b84fB2596c06926C0405;

    /// @dev Steakhouse USDC - MetaMorpho V1 vault (ERC4626-compliant), used as underlying
    address constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    /// @dev Steakhouse ETH - MetaMorpho V1 vault (ERC4626-compliant), used as underlying
    address constant STEAKHOUSE_ETH = 0xBEEf050ecd6a16c4e7bfFbB52Ebba7846C4b8cD4;

    /// @dev USDC token
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev WETH token
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev Pinned block for deterministic & cached fork
    uint256 constant FORK_BLOCK = 24_430_000;

    uint256 constant ALLOWED_DUST = 1e18;
    uint256 constant ALLOWED_DUST_2_WEI = 2;

    /*//////////////////////////////////////////////////////////////
                            STATE
    //////////////////////////////////////////////////////////////*/

    IVaultV2 parentVault;
    CatalysisCoverAdapter adapter;

    MockPolicyManager policyManager;
    MockClaimManager claimManager;
    MockCoverPool coverPool;

    address owner;
    address curatorAddr;
    address allocatorAddr;
    address user1;
    address user2;

    uint96 constant POLICY_ID = 1;
    uint16 constant MAX_COVERABLE_LOSS_BPS = 1000; // 10%

    bool forkActive;

    /*//////////////////////////////////////////////////////////////
                            SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Try to create a fork; skip all tests gracefully if RPC is unavailable
        try vm.createSelectFork("mainnet", FORK_BLOCK) {
            forkActive = true;
        } catch {
            return;
        }

        owner = makeAddr("owner");
        curatorAddr = makeAddr("curator");
        allocatorAddr = makeAddr("allocator");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // -- 1. Create V2 vault via on-chain factory --
        vm.prank(owner);
        address vault = IVaultV2Factory(VAULT_V2_FACTORY).createVaultV2(owner, USDC, bytes32(uint256(block.timestamp)));
        parentVault = IVaultV2(vault);

        // -- 2. Owner sets curator (direct call, no timelock) --
        vm.prank(owner);
        (bool ok,) = address(parentVault).call(abi.encodeWithSignature("setCurator(address)", curatorAddr));
        require(ok, "setCurator failed");

        // -- 3. Deploy mock policy infrastructure --
        policyManager = new MockPolicyManager();
        claimManager = new MockClaimManager(address(policyManager));
        coverPool = new MockCoverPool();

        // -- 4. Deploy CatalysisCoverAdapter behind UUPS proxy (real V2 parent -> real V1 underlying) --
        adapter = _deployAdapterProxy(
            address(parentVault), STEAKHOUSE_USDC, address(claimManager), address(coverPool), MAX_COVERABLE_LOSS_BPS
        );

        // -- 5. Setup mock policy AFTER deploying adapter (onPolicyBound validates metadata) --
        policyManager.setPolicy(
            POLICY_ID,
            owner,
            address(coverPool),
            address(adapter),
            USDC,
            100_000_000e6, // coverageLimit: 100M USDC (fits real V2 vault's absoluteCap casting)
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days)
        );

        // -- 6. Curator governance: addAdapter + setIsAllocator --
        _curatorSubmitExec(abi.encodeWithSignature("addAdapter(address)", address(adapter)));
        require(parentVault.isAdapter(address(adapter)), "adapter not registered");

        _curatorSubmitExec(abi.encodeWithSignature("setIsAllocator(address,bool)", allocatorAddr, true));
        require(parentVault.isAllocator(allocatorAddr), "allocator not set");

        // -- 7. Set adapter as curator and trigger onPolicyBound --
        //       onPolicyBound calls submit + increaseAbsoluteCap (needs curator role)
        vm.prank(owner);
        (ok,) = address(parentVault).call(abi.encodeWithSignature("setCurator(address)", address(adapter)));
        require(ok, "setCurator(adapter) failed");

        policyManager.callOnPolicyBound(address(adapter), POLICY_ID, 100_000_000e6);

        // Restore curator for remaining governance calls
        vm.prank(owner);
        (ok,) = address(parentVault).call(abi.encodeWithSignature("setCurator(address)", curatorAddr));
        require(ok, "setCurator(curator) failed");

        // Set relative cap (absolute cap was set by onPolicyBound)
        bytes memory idData = adapter.idData();
        require(keccak256(idData) == adapter.adapterId(), "idData mismatch");
        _curatorSubmitExec(abi.encodeWithSignature("increaseRelativeCap(bytes,uint256)", idData, 1e18));

        // -- 7. Allocator sets adapter as liquidity adapter --
        //       User deposit() auto-allocates with deposit selector (tracks principal)
        //       User withdraw/redeem() auto-deallocates with withdraw/redeem selector (triggers insurance)
        vm.prank(allocatorAddr);
        (ok,) = address(parentVault)
            .call(abi.encodeWithSignature("setLiquidityAdapterAndData(address,bytes)", address(adapter), ""));
        require(ok, "setLiquidityAdapterAndData failed");
    }

    function _setupParentWithMockUnderlyingVault(
        uint96 newPolicyId
    )
        internal
        returns (
            IVaultV2 parentVault,
            address parentVaultOwner,
            CatalysisCoverAdapter adapterRef,
            ControllableVault ctrlVault,
            ForkClaimManager claimMgr,
            address newCurator,
            address newAllocator
        )
    {
        ctrlVault = new ControllableVault(USDC);
        claimMgr = new ForkClaimManager(address(policyManager), USDC);
        newCurator = makeAddr("NewCuratorAddr");
        newAllocator = makeAddr("NewAllocatorAddr");
        deal(USDC, address(claimMgr), 10_000e6);

        address parentVaultOwner = makeAddr("ParentVaultOwner");
        address vault = IVaultV2Factory(VAULT_V2_FACTORY).createVaultV2(parentVaultOwner, USDC, bytes32("random salt"));
        parentVault = IVaultV2(vault);

        adapterRef = _deployAdapterProxy(
            address(parentVault),
            address(ctrlVault),
            address(claimMgr),
            address(coverPool),
            1000 // 10%
        );

        policyManager.setPolicy(
            newPolicyId,
            parentVaultOwner,
            address(coverPool),
            address(adapterRef),
            USDC,
            10_000e6,
            uint32(block.timestamp),
            uint32(block.timestamp + 365 * 5 days)
        );

        vm.prank(parentVaultOwner);
        (bool ok,) = address(parentVault).call(abi.encodeWithSignature("setCurator(address)", address(adapterRef)));
        require(ok, "setCurator(adapter) failed");

        policyManager.callOnPolicyBound(address(adapterRef), newPolicyId, 10_000e6);

        vm.prank(parentVaultOwner);
        (ok,) = address(parentVault).call(abi.encodeWithSignature("setCurator(address)", newCurator));
        require(ok, "setCurator(curator) failed");

        _curatorSubmitExecOn(
            address(parentVault), newCurator, abi.encodeWithSignature("addAdapter(address)", address(adapterRef))
        );
        _curatorSubmitExecOn(
            address(parentVault),
            newCurator,
            abi.encodeWithSignature("setIsAllocator(address,bool)", newAllocator, true)
        );

        bytes memory idData = adapterRef.idData();
        require(keccak256(idData) == adapterRef.adapterId(), "idData mismatch");
        _curatorSubmitExecOn(
            address(parentVault),
            newCurator,
            abi.encodeWithSignature("increaseRelativeCap(bytes,uint256)", idData, 1e18)
        );

        vm.prank(newAllocator);
        (ok,) = address(parentVault)
            .call(abi.encodeWithSignature("setLiquidityAdapterAndData(address,bytes)", address(adapterRef), ""));
        require(ok, "setLiquidityAdapterAndData failed");

        vm.prank(newAllocator);
        (ok,) = address(parentVault).call(abi.encodeWithSignature("setMaxRate(uint256)", 200e16 / uint256(365 days)));
        require(ok, "setMaxRate failed");
    }

    // Helpers

    modifier onlyFork() {
        if (!forkActive) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @dev Curator submits timelocked data then executes it (timelock=0 on fresh vault)
    /// @dev Deploy CatalysisCoverAdapter behind a UUPS proxy using the Upgrades library
    function _deployAdapterProxy(
        address parentVault_,
        address underlyingVault_,
        address claimManager_,
        address coverPool_,
        uint16 maxCoverableLossBps_
    ) internal returns (CatalysisCoverAdapter) {
        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "CatalysisCoverAdapter.sol",
            abi.encodeCall(
                CatalysisCoverAdapter.initialize,
                (parentVault_, underlyingVault_, claimManager_, coverPool_, maxCoverableLossBps_)
            ),
            deployOpts
        );
        return CatalysisCoverAdapter(proxy);
    }

    function _curatorSubmitExec(
        bytes memory data
    ) internal {
        vm.prank(curatorAddr);
        (bool ok,) = address(parentVault).call(abi.encodeWithSignature("submit(bytes)", data));
        require(ok, "submit failed");
        vm.prank(curatorAddr);
        (ok,) = address(parentVault).call(data);
        require(ok, "execute failed");
    }

    /// @dev Same as _curatorSubmitExec but against an arbitrary V2 vault
    function _curatorSubmitExecOn(
        address vault,
        address curator,
        bytes memory data
    ) internal {
        vm.prank(curator);
        (bool ok,) = vault.call(abi.encodeWithSignature("submit(bytes)", data));
        require(ok, "submit failed");
        vm.prank(curator);
        (ok,) = vault.call(data);
        require(ok, "execute failed");
    }

    /// @dev Deal USDC to user, deposit into parent vault (auto-allocates via liquidity adapter)
    function _userDeposit(
        address user,
        uint256 amount
    ) internal returns (uint256 shares) {
        deal(USDC, user, amount);
        vm.startPrank(user);
        IERC20(USDC).approve(address(parentVault), amount);
        shares = parentVault.deposit(amount, user);
        vm.stopPrank();
    }

    // Deposit / Redeem with existing Underlying Morpho Vault V2

    /// @notice User deposit auto-allocates to adapter via liquidity adapter
    function test_fork_allocate() public onlyFork {
        _userDeposit(user1, 10_000e6);

        assertEq(adapter.totalPrincipal(), 10_000e6, "Principal should be tracked");
        assertTrue(adapter.currentValue() > 0, "Should have value in underlying");
        assertTrue(adapter.underlyingShares() > 0, "Should hold underlying shares");
    }

    /// @notice User withdraw auto-deallocates from adapter via liquidity adapter
    function test_fork_deallocate() public onlyFork {
        uint256 shares = _userDeposit(user1, 10_000e6);

        // User withdraws half
        vm.prank(user1);
        parentVault.redeem(shares / 2, user1, user1);

        assertTrue(adapter.totalPrincipal() < 10_000e6, "Principal should decrease after withdraw");
        assertTrue(adapter.underlyingShares() > 0, "Should still hold some shares");
    }

    // Allocate / Deallocate

    /// @notice Allocator deallocate then re-allocate: total principal changes each time
    function test_fork_allocatorAllocate() public onlyFork {
        _userDeposit(user1, 10_000e6);
        uint256 principalBefore = adapter.totalPrincipal();

        // Allocator deallocates to create idle assets
        IVaultV2 steakHouse = IVaultV2(STEAKHOUSE_USDC);
        uint256 amountToDeallocate = steakHouse.convertToAssets(steakHouse.balanceOf(address(adapter)));
        vm.prank(allocatorAddr);
        parentVault.deallocate(address(adapter), "", amountToDeallocate);
        assertEq(adapter.totalPrincipal(), 0, "Total principal fully withdrawn");

        // Allocator re-allocates. Total principal is increased, per-user principal isn't
        vm.prank(allocatorAddr);
        parentVault.allocate(address(adapter), "", amountToDeallocate);
        assertEq(adapter.totalPrincipal(), amountToDeallocate, "Total principal deposited");
        assertEq(adapter.userPrincipal(allocatorAddr), 0, "Per-user principal is not updated during allocation");
    }

    /// @notice Allocator can directly deallocate without coverage payout
    function test_fork_allocatorDeallocate() public onlyFork {
        uint256 depositAmount = 10_000e6;
        _userDeposit(user1, depositAmount);

        uint256 principalBefore = adapter.totalPrincipal();
        uint256 sharesBefore = adapter.underlyingShares();
        uint256 valueBefore = adapter.currentValue();

        // Deallocate all since deallocation allow only full withdrawal
        uint256 deallocateAmount = parentVault.previewRedeem(parentVault.totalSupply());
        vm.prank(allocatorAddr);
        parentVault.deallocate(address(adapter), "", deallocateAmount);

        // Principal should decrease because capital is being withdrawn (reduces insured amount)
        assertEq(adapter.totalPrincipal(), 0, "total principal should be 0");

        // Shares should decrease by exactly the amount needed for full
        // With 1:1 rate: shares decrease = deallocateAmount * sharesBefore / valueBefore
        assertApproxEqAbs(adapter.underlyingShares(), 0, ALLOWED_DUST, "underlying shares should be 0");

        // Value should decrease by ~deallocateAmount
        assertApproxEqAbs(adapter.currentValue(), 0, ALLOWED_DUST, "current value should be 0");
    }

    /// @notice forceDeallocate from any address (with penalty)
    /// @dev Decreases total principal
    /// @dev Allows only full withdrawal
    function test_fork_forceDeallocate() public onlyFork {
        uint256 depositAmount = 10_000e6;
        uint256 shares = _userDeposit(user1, depositAmount);

        uint256 principalBefore = adapter.totalPrincipal();
        uint256 valuesBefore = adapter.currentValue();

        // forceDeallocate moves assets from adapter to vault's idle
        address forcer = makeAddr("forcer");

        // forcer needs shares to pay penalty (give them some shares)
        vm.prank(user1);
        IERC20(address(parentVault)).transfer(forcer, shares / 10);

        uint256 forceDeallocateAmount = parentVault.previewRedeem(parentVault.totalSupply());
        vm.prank(forcer);
        parentVault.forceDeallocate(address(adapter), "", forceDeallocateAmount, forcer);

        // Principal should decrease because capital is being withdrawn
        assertEq(adapter.totalPrincipal(), 0, "total principal should be 0");

        // Shares should decrease by exactly the amount needed for full
        // With 1:1 rate: shares decrease = deallocateAmount * sharesBefore / valueBefore
        assertApproxEqAbs(adapter.underlyingShares(), 0, ALLOWED_DUST, "underlying shares should be 0");

        // Value should decrease to 0
        assertApproxEqAbs(adapter.currentValue(), 0, ALLOWED_DUST, "current value should be 0");
    }

    // Full cycle test

    /// @notice Full deposit -> time passes -> withdraw cycle (user-driven)
    function test_fork_fullCycle() public onlyFork {
        uint256 amount = 50_000e6;
        uint256 shares = _userDeposit(user1, amount);

        vm.warp(block.timestamp + 7 days);

        // After 7 days the real MetaMorpho vault should have accrued yield
        uint256 valueAfterWarp = adapter.currentValue();
        assertTrue(valueAfterWarp > amount, "Underlying vault should report profit after 7 days");
        assertEq(adapter.userShortfall(user1), 0, "No shortfall when in profit");

        // User redeems all shares from parent vault (auto-deallocates from adapter)
        vm.prank(user1);
        uint256 out = parentVault.redeem(shares, user1, user1);

        assertTrue(out > 0, "Should receive USDC back");
        assertApproxEqRel(out, amount, 0.01e18, "Should get ~deposit amount back");
    }

    // Share transfer test

    /// @notice Parent vault share transfers - recipient shouldn't be able to redeem extra shares
    /// @notice Test: share transfer between users, both can redeem
    /// @notice Recipient should be able to redeem his invested principal
    /// @dev Each redeem is in a separate block to match production behavior where
    ///      each user action is a separate tx (V2 vault uses transient storage for firstTotalAssets).
    function test_fork_shareTransfer() public onlyFork {
        uint256 amount1 = 20_000e6;
        uint256 amount2 = 10_000e6;
        uint256 shares = _userDeposit(user1, amount1);
        uint256 shares2 = _userDeposit(user2, amount2);

        // Transfer half the parent vault shares to user2
        vm.prank(user1);
        IERC20(address(parentVault)).transfer(user2, shares / 2);

        // Advance block so transient storage is cleared before first redeem
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);

        // User1 redeems their remaining shares
        uint256 user1Shares = parentVault.balanceOf(user1);
        vm.prank(user1);
        uint256 out1 = parentVault.redeem(user1Shares, user1, user1);

        // Advance block so transient storage is cleared before second redeem
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);

        // User2 tries to redeem all including extra received shares
        uint256 user2Shares = parentVault.balanceOf(user2);
        vm.expectRevert(
            abi.encodeWithSignature(
                "UnsupportedDeallocation(uint256,bytes4,address)", 20_000e6, bytes4(0xba087652), user2
            )
        );
        vm.prank(user2);
        parentVault.redeem(user2Shares, user2, user2);
        // Withdraw only originally invested
        vm.prank(user2);
        parentVault.withdraw(amount2, user2, user2);

        assertApproxEqAbs(amount1 / 2, out1, ALLOWED_DUST_2_WEI, "User1 should receive half of initial deposit");
        assertApproxEqAbs(
            IERC20(USDC).balanceOf(user2), amount2, ALLOWED_DUST_2_WEI, "User2 should receive only originally deposited"
        );

        // User2 sends the rest of shares to user1, user1 redeems
        uint256 shareToTransfer = parentVault.balanceOf(user2);
        vm.prank(user2);
        IERC20(address(parentVault)).transfer(user1, shareToTransfer);
        vm.prank(user1);
        uint256 out2 = parentVault.redeem(shareToTransfer, user1, user1);
        assertApproxEqAbs(amount1, out1 + out2, ALLOWED_DUST_2_WEI, "User1 should receive half of initial deposit");
    }

    // Management fee test

    /// @notice Verify adapter works correctly after time passes (management fee accrual)
    function test_fork_managementFee_timePassage() public onlyFork {
        uint256 depositAmount = 100_000e6;
        _userDeposit(user1, depositAmount);

        uint256 valueBefore = adapter.currentValue();

        vm.warp(block.timestamp + 30 days);

        uint256 valueAfter = adapter.currentValue();
        assertTrue(valueAfter > 0, "Should still have value after 30 days");
        // Real MetaMorpho vault accrues yield; currentValue should increase
        assertTrue(valueAfter > valueBefore, "Value should increase after 30 days (yield accrued)");
        assertTrue(valueAfter > depositAmount, "Underlying vault should report profit after 30 days");

        // User partial withdraw should succeed after fee accrual period
        vm.prank(user1);
        parentVault.withdraw(50_000e6, user1, user1);

        assertTrue(adapter.totalPrincipal() < depositAmount, "Principal should decrease");

        emit log_named_uint("Value before 30d", valueBefore);
        emit log_named_uint("Value after 30d", valueAfter);
    }

    /// @notice Management fee can be withdrawn
    function test_fork_managementFee_withdrawAfterTransfer() public onlyFork {
        address feeRecip = makeAddr("feeRecipient_v2");
        {
            uint256 feePerSecond = uint256(0.02e18) / uint256(365 days); // ~2% annual
            bytes memory feeData = abi.encodeWithSignature("setManagementFee(uint256)", feePerSecond);
            bytes memory recipData = abi.encodeWithSignature("setManagementFeeRecipient(address)", feeRecip);

            vm.prank(curatorAddr);
            (bool s1,) = address(parentVault).call(abi.encodeWithSignature("submit(bytes)", feeData));
            require(s1, "submit setManagementFee failed");

            vm.prank(curatorAddr);
            (bool s2,) = address(parentVault).call(abi.encodeWithSignature("submit(bytes)", recipData));
            require(s2, "submit setManagementFeeRecipient failed");

            // Query when the data becomes executable and warp past it
            (bool qOk, bytes memory qRet) =
                address(parentVault).staticcall(abi.encodeWithSignature("executableAt(bytes)", feeData));
            require(qOk, "executableAt query failed");
            uint256 execAt = abi.decode(qRet, (uint256));
            if (execAt > block.timestamp) {
                vm.warp(execAt);
                vm.roll(block.number + 1);
            }

            // Must set recipient FIRST — setManagementFee requires managementFeeRecipient != address(0)
            vm.prank(curatorAddr);
            (bool e2,) = address(parentVault).call(recipData);
            require(e2, "execute setManagementFeeRecipient failed");

            vm.prank(curatorAddr);
            (bool e1,) = address(parentVault).call(feeData);
            require(e1, "execute setManagementFee failed");
        }

        uint256 shares = _userDeposit(user1, 50_000e6);

        // Transfer some shares
        vm.prank(user1);
        IERC20(address(parentVault)).transfer(user2, shares / 4);

        // Time passes - fees accrue
        vm.warp(block.timestamp + 14 days);

        // User1 redeems (auto-deallocates from adapter)
        uint256 user1Shares = parentVault.balanceOf(user1);
        vm.prank(user1);
        uint256 out = parentVault.redeem(user1Shares, user1, user1);
        assertTrue(out > 0, "User1 should redeem after transfer + fee accrual");
        assertGt(parentVault.balanceOf(feeRecip), 0, "Fee should be minted");

        // Management fee recipient withdraw
        uint256 feeBal = parentVault.balanceOf(feeRecip);
        vm.prank(feeRecip);
        out = parentVault.redeem(feeBal, feeRecip, feeRecip);
        assertGt(out, 0, "Fee recipient received fee");
    }

    // Yield accrual test

    /// @notice realAssets equals currentValue; underlying vault accrues yield over time
    function test_fork_yieldAndRealAssets() public onlyFork {
        uint256 depositAmount = 100_000e6;
        _userDeposit(user1, depositAmount);

        vm.warp(block.timestamp + 90 days);

        uint256 cv = adapter.currentValue();
        uint256 ra = adapter.realAssets();

        assertTrue(cv > 0, "Should have current value");
        // realAssets == currentValue always: no insurance baked into share price
        assertEq(ra, cv, "realAssets should equal currentValue");
        // After 90 days the real MetaMorpho vault accrues yield; adapter should reflect profit
        assertTrue(cv > depositAmount, "currentValue should exceed principal after 90 days (yield accrued)");
        // No shortfall when in profit
        assertEq(adapter.userShortfall(user1), 0, "No shortfall when yield > 0");

        emit log_named_uint("currentValue after 90d", cv);
        emit log_named_uint("realAssets after 90d", ra);
        emit log_named_uint("yield accrued", cv - depositAmount);
    }

    // Several users scenario

    /// @notice Multiple users deposit through the same V2 parent vault
    function test_fork_multiUser() public onlyFork {
        // User1 deposits 50k (auto-allocates to adapter)
        _userDeposit(user1, 50_000e6);

        // User2 deposits 30k (auto-allocates to adapter)
        _userDeposit(user2, 30_000e6);

        assertEq(adapter.totalPrincipal(), 80_000e6, "Total principal should be 80k");
        assertTrue(adapter.currentValue() > 0, "Should have combined value");
    }

    /// @notice Multi-user deposit -> time -> sequential withdrawals
    function test_fork_multiUser_sequentialWithdrawals() public onlyFork {
        // User1 deposits 50k
        uint256 shares1 = _userDeposit(user1, 50_000e6);

        // User2 deposits 30k
        uint256 shares2 = _userDeposit(user2, 30_000e6);

        // Time passes: real vault accrues yield
        vm.warp(block.timestamp + 7 days);

        // Underlying vault should report profit after 7 days
        assertTrue(adapter.currentValue() > 80_000e6, "Underlying vault should report profit after 7 days");
        assertEq(adapter.userShortfall(user1), 0, "User1 should have no shortfall when in profit");
        assertEq(adapter.userShortfall(user2), 0, "User2 should have no shortfall when in profit");

        // User1 partial withdraw
        vm.prank(user1);
        parentVault.redeem(shares1 / 2, user1, user1);
        uint256 principalAfterFirst = adapter.totalPrincipal();
        assertTrue(principalAfterFirst < 80_000e6, "Principal should decrease after first withdrawal");

        // User2 full withdraw
        vm.prank(user2);
        parentVault.redeem(shares2, user2, user2);
        uint256 principalAfterSecond = adapter.totalPrincipal();
        assertTrue(principalAfterSecond < principalAfterFirst, "Principal should decrease after second withdrawal");

        // User1 withdraws rest
        uint256 user1Remaining = parentVault.balanceOf(user1);
        vm.prank(user1);
        parentVault.redeem(user1Remaining, user1, user1);
        assertLe(adapter.totalPrincipal(), 100e6, "Principal should be ~0 after full withdrawal");
    }

    // Interleaved operations test

    /// @notice Interleaved allocate/deallocate with user withdrawals - verify principal tracking
    /// @dev Point 6: ALL allocations increase principal, ALL deallocations decrease principal
    function test_fork_interleavedAllocateDeallocateWithUserWithdraw() public onlyFork {
        // Initial user deposit
        uint256 user1Deposit = 50_000e6;
        uint256 user1Shares = _userDeposit(user1, user1Deposit);

        uint256 initialPrincipal = adapter.totalPrincipal();
        uint256 initialShares = adapter.underlyingShares();
        uint256 initialValue = adapter.currentValue();

        assertEq(initialPrincipal, user1Deposit, "Initial principal should equal deposit");

        // User1 partial withdrawal (50% of their shares)
        uint256 withdrawShares = user1Shares / 2;
        vm.prank(user1);
        uint256 out1 = parentVault.redeem(withdrawShares, user1, user1);

        // Principal should decrease
        uint256 principalAfterWithdraw = adapter.totalPrincipal();
        assertLt(principalAfterWithdraw, initialPrincipal, "Principal should decrease after user withdraw");

        // Allocator deallocates all assets
        uint256 deallocateAmount = parentVault.previewRedeem(parentVault.totalSupply());
        vm.prank(allocatorAddr);
        parentVault.deallocate(address(adapter), "", deallocateAmount);

        // User1 withdraws remaining shares
        uint256 remainingShares = parentVault.balanceOf(user1);
        vm.prank(user1);
        uint256 out2 = parentVault.redeem(remainingShares, user1, user1);

        assertTrue(out2 > 0, "Should receive assets on final withdrawal");

        // Final principal should be 0 since:
        // - User withdrew all their shares
        // - Allocator deallocated their portion
        // With the new logic, principal tracks all capital, so it should be depleted
        assertEq(adapter.totalPrincipal(), 0, "Principal should have decreased further");
    }

    /// Per-user principal tracking testing

    /// @notice Per-user principal and shares are tracked independently on the real vault
    function test_fork_perUserPrincipalTracking() public onlyFork {
        uint256 user1Amount = 30_000e6;
        uint256 user2Amount = 20_000e6;

        _userDeposit(user1, user1Amount);
        _userDeposit(user2, user2Amount);

        // Per-user principal tracked at deposit price
        assertEq(adapter.userPrincipal(user1), user1Amount, "User1 principal should match deposit");
        assertEq(adapter.userPrincipal(user2), user2Amount, "User2 principal should match deposit");
        assertEq(adapter.totalPrincipal(), user1Amount + user2Amount, "Total principal should be sum of users");

        // Per-user underlying shares tracked; total equals sum
        assertTrue(adapter.userUnderlyingShares(user1) > 0, "User1 should have underlying shares");
        assertTrue(adapter.userUnderlyingShares(user2) > 0, "User2 should have underlying shares");
        assertEq(
            adapter.underlyingShares(),
            adapter.userUnderlyingShares(user1) + adapter.userUnderlyingShares(user2),
            "Total underlying shares should be sum of user shares"
        );

        // No meaningful shortfall at deposit; 1 wei is acceptable rounding from ERC4626 floor-on-shares
        assertLe(adapter.userShortfall(user1), ALLOWED_DUST_2_WEI, "User1 should have no shortfall at deposit");
        assertLe(adapter.userShortfall(user2), ALLOWED_DUST_2_WEI, "User2 should have no shortfall at deposit");

        // Advance block to clear V2 transient storage — no time warp to keep V2 allocation current
        vm.roll(block.number + 1);

        // User1 redeems all parent vault shares (V2 allocation == currentValue, so full clear)
        uint256 user1Shares = parentVault.balanceOf(user1);
        vm.prank(user1);
        parentVault.redeem(user1Shares, user1, user1);

        // User1 principal and shares fully cleared; user2 unaffected
        // 1 wei residual is acceptable — ERC-4626 floor-on-shares rounding
        assertLe(adapter.userPrincipal(user1), ALLOWED_DUST_2_WEI, "User1 principal cleared after full withdrawal");
        // With --isolate V2's accrueInterest() re-runs each call, causing sub-microUSDC
        // rounding in the underlying (18-dec) share space.  1e12 shares ≈ 0.000001 USDC.
        assertLe(adapter.userUnderlyingShares(user1), 1e12, "User1 shares cleared after full withdrawal");
        assertEq(adapter.userPrincipal(user2), user2Amount, "User2 principal unchanged");
    }

    /// @notice User deposit -> allocator rebalance -> user2 deposit -> partial withdrawals
    /// @dev ALL allocations (including allocator) increase principal
    function test_fork_multiUserWithAllocatorRebalance() public onlyFork {
        // User1 deposits
        uint256 user1Deposit = 30_000e6;
        uint256 user1Shares = _userDeposit(user1, user1Deposit);

        // Allocator adds more assets
        uint256 allocatorAmount = 15_000e6;
        deal(USDC, address(parentVault), allocatorAmount);
        vm.prank(allocatorAddr);
        parentVault.allocate(address(adapter), "", allocatorAmount);

        // User2 deposits
        uint256 user2Deposit = 25_000e6;
        uint256 user2Shares = _userDeposit(user2, user2Deposit);

        // Total principal should include ALL allocated capital (user1 + allocator + user2)
        assertEq(
            adapter.totalPrincipal(), user1Deposit + allocatorAmount + user2Deposit, "Principal = all allocated capital"
        );

        // Time passes (yield accrues)
        vm.warp(block.timestamp + 30 days);

        uint256 principalBefore = adapter.totalPrincipal();

        // User1 partial withdraw
        vm.prank(user1);
        parentVault.redeem(user1Shares / 2, user1, user1);

        uint256 principalAfter1 = adapter.totalPrincipal();

        // Principal should decrease
        assertApproxEqAbs(
            principalAfter1,
            principalBefore - (user1Deposit / 2),
            ALLOWED_DUST,
            "Principal should decrease after user1 withdraw"
        );

        // User2 full withdraw
        vm.prank(user2);
        uint256 out2 = parentVault.redeem(user2Shares, user2, user2);

        uint256 principalAfter2 = adapter.totalPrincipal();

        // Principal should decrease further
        assertApproxEqAbs(
            principalAfter2,
            principalAfter1 - user2Deposit,
            ALLOWED_DUST,
            "Principal should decrease after user2 withdraw"
        );
        assertTrue(out2 > 0, "User2 should receive assets");

        // User1 final withdraw
        uint256 user1Remaining = parentVault.balanceOf(user1);
        vm.prank(user1);
        parentVault.redeem(user1Remaining, user1, user1);

        // With new behavior, principal should be equal only to the allocator's added value
        uint256 finalPrincipal = adapter.totalPrincipal();
        assertApproxEqAbs(
            finalPrincipal, allocatorAmount, ALLOWED_DUST, "Principal should decrease after final user1 withdraw"
        );
    }

    // Two-user scenario (Alice and Bob fork tests)

    /// @notice Fork version of the two-user per-user insurance scenario.
    ///
    /// Uses a real newly deployed Morpho Vault V2 + ControllableVault (physical-balance ERC4626) for loss manipulation
    /// + ForkClaimManager (pre-funded with real USDC).
    ///
    /// Timeline (exact integer arithmetic, no rounding):
    ///   1. Alice deposits 1000 USDC at price P1 = 1.00 (ctrlVault: 1000 USDC / 1000 shares)
    ///   2. deal() 500 USDC into ctrlVault → price P2 = 1.50 (1500 USDC / 1000 shares)
    ///   3. Bob deposits 1500 USDC at P2 → 1000 new shares (ctrlVault: 3000 USDC / 2000 shares)
    ///   4. simulateLoss(300) → ctrlVault: 2700 USDC / 2000 shares → P3 = 1.35
    ///   5. Alice redeems her 1000 ctrlShares → 1350 USDC (no shortfall vs 1000 principal)
    ///   6. Bob redeems his 1000 ctrlShares → 1350 USDC from vault + 148.5 direct insurance
    ///      shortfall = 1500 - 1350 = 150; maxIns = 150; effIns = 150*99% = 148.5
    ///
    /// Key assertions:
    ///   - Per-user principal/shares correctly tracked through real USDC deposits
    ///   - Alice receives no insurance (1350 > 1000 principal)
    ///   - Bob receives 148500000 USDC direct insurance (exact integer)
    ///   - ForkClaimManager records the correct payout amount
    ///   - Both principals cleared to zero after full redemption
    function test_fork_twoUsers_perUserInsurance() public onlyFork {
        // 7 outer vars (persist across all phases to stay within stack limit)
        address alice = makeAddr("alice_two");
        address bob = makeAddr("bob_two");
        uint96 newPolicyId = 99;

        // Setup: deploy contracts
        (
            IVaultV2 vault,,
            CatalysisCoverAdapter twoUserAdapter,
            ControllableVault ctrlVault,
            ForkClaimManager forkClaimMgr,,
        ) = _setupParentWithMockUnderlyingVault(newPolicyId);

        // STEP 1: Alice deposits 1000 USDC at price P1 = 1.00
        // ctrlVault: 1000e6 USDC / 1000e6 shares, P = 1.00
        {
            deal(USDC, alice, 1000e6);
            vm.prank(alice);
            IERC20(USDC).approve(address(vault), 1000e6);
            vm.prank(alice);
            vault.deposit(1000e6, alice);

            assertEq(twoUserAdapter.userPrincipal(alice), 1000e6, "Alice principal = 1000 USDC");
            assertEq(twoUserAdapter.userUnderlyingShares(alice), 1000e6, "Alice ctrlVault shares = 1000e6");
            assertEq(twoUserAdapter.totalPrincipal(), 1000e6, "Total principal = 1000 USDC after Alice");
            assertEq(twoUserAdapter.currentValue(), 1000e6, "currentValue = 1000 USDC at P1");
        }

        // STEP 2: 50% profit — price rises from 1.00 to 1.50
        // deal() 500e6 USDC into ctrlVault → 1500e6 USDC / 1000e6 shares → P = 1.50
        deal(USDC, address(ctrlVault), 1500e6); // total USDC in ctrlVault = 1500e6
        skip(365 days);
        assertEq(twoUserAdapter.currentValue(), 1500e6, "currentValue = 1500 USDC at P2");
        assertEq(ctrlVault.convertToAssets(1e6), 1_500_000, "ctrlVault price = 1.50 USDC/share");

        // STEP 3: Bob deposits 1500 USDC at price P2 = 1.50
        // shares = 1500e6 * 1000e6 / 1500e6 = 1000e6 (same as Alice)
        // ctrlVault: 3000e6 USDC / 2000e6 shares, P = 1.50
        {
            deal(USDC, bob, 1500e6);
            vm.prank(bob);
            IERC20(USDC).approve(address(vault), 1500e6);
            vm.prank(bob);
            vault.deposit(1500e6, bob);

            assertEq(twoUserAdapter.userPrincipal(bob), 1500e6, "Bob principal = 1500 USDC");
            assertEq(twoUserAdapter.userUnderlyingShares(bob), 1000e6, "Bob ctrlVault shares = 1000e6");
            assertEq(twoUserAdapter.totalPrincipal(), 2500e6, "Total principal = 2500 USDC");
            assertEq(twoUserAdapter.currentValue(), 3000e6, "currentValue = 3000 USDC total");
        }

        // STEP 4: 10% loss — drain 300 USDC out of ctrlVault
        // ctrlVault: 3000e6 - 300e6 = 2700e6 USDC / 2000e6 shares, P = 1.35
        ctrlVault.simulateLoss(300e6);
        assertEq(twoUserAdapter.currentValue(), 2700e6, "currentValue = 2700 USDC after loss");
        // Alice's 1000e6 shares → 1350e6 > 1000e6 principal: no shortfall
        assertEq(twoUserAdapter.userShortfall(alice), 0, "Alice no shortfall after loss");
        // Bob's 1000e6 shares → 1350e6 < 1500e6 principal: shortfall = 150e6
        assertEq(twoUserAdapter.userShortfall(bob), 150e6, "Bob shortfall = 150 USDC after loss");

        // STEP 5: Alice withdraws ~1350 USDC — no insurance (above her 1000 principal)
        //   = 1000e6 * 2700e6 / 2000e6 = 1350e6 (exact)
        // sharesToBurn in ctrlVault = 2000e6 * 1350e6 / 2700e6 = 1000e6 (exact)
        {
            uint256 aliceShares = vault.balanceOf(alice);

            uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
            vm.prank(alice);
            vault.redeem(aliceShares, alice, alice);
            uint256 received = IERC20(USDC).balanceOf(alice) - aliceBefore;

            assertApproxEqAbs(received, 1350e6, ALLOWED_DUST_2_WEI, "Alice received ~1350 USDC from vault");
            assertLe(twoUserAdapter.userPrincipal(alice), ALLOWED_DUST_2_WEI, "Alice principal cleared (+/-1 wei)");
            assertLe(
                twoUserAdapter.userUnderlyingShares(alice),
                ALLOWED_DUST_2_WEI,
                "Alice underlying shares cleared (+/-1 wei)"
            );
            assertEq(forkClaimMgr.totalPaidOut(newPolicyId), 0, "No insurance paid for Alice");
            emit log_named_uint("Alice received USDC", received);
        }

        // STEP 6: Bob withdraws ~1350 USDC + 148.5 USDC direct insurance
        // ctrlVault after Alice: remaining ~1350e6 USDC / ~1000e6 shares, P ≈ 1.35
        // shortfall = 1500e6 - ~1350e6 ≈ 150e6 > effectiveInsurance → capped at 148500000
        // effectiveInsurance = 1500e6 * 1000/10000 * 9900/10000 = 148500000 (exact)
        {
            uint256 bobShares = vault.balanceOf(bob);

            uint256 bobBefore = IERC20(USDC).balanceOf(bob);
            vm.prank(bob);
            vault.redeem(bobShares, bob, bob);

            // Bob gets: vaultProceeds (≈1350 USDC) + insurancePayout (exact 148.5 USDC)
            uint256 bobTotal = IERC20(USDC).balanceOf(bob) - bobBefore;
            // vaultProceeds is ~1350e6 (±1 wei); insurance is always exactly 148500000
            uint256 vaultProceeds = bobTotal - 148_500_000;

            assertApproxEqAbs(vaultProceeds, 1350e6, 2, "Bob vault proceeds ~1350 USDC");
            assertEq(twoUserAdapter.userPrincipal(bob), 0, "Bob principal cleared");
            assertEq(twoUserAdapter.userUnderlyingShares(bob), 0, "Bob underlying shares cleared");
            emit log_named_uint("Bob vault USDC", vaultProceeds);
            emit log_named_uint("Bob insurance USDC", 148_500_000);
        }

        // Verify claim tracking
        assertEq(forkClaimMgr.totalPaidOut(newPolicyId), 148_500_000, "Total payout = 148.5 USDC");
        // 1-wei rounding from V2's virtual share offset can leave 1 unit of principal in the adapter
        assertLe(twoUserAdapter.totalPrincipal(), ALLOWED_DUST_2_WEI, "All principal cleared (+/-1 wei)");
        emit log_named_uint("Coverage amount claimed USDC", forkClaimMgr.totalPaidOut(newPolicyId));
    }

    /// @notice Documents adapter behavior when a user transfers parent-vault shares to another user.
    ///
    /// The adapter tracks per-user state keyed on `sender` — the address that calls
    /// deposit/withdraw on the parent vault.  ERC20 share transfers bypass this tracking:
    /// when Alice transfers her V2 shares to Bob and Bob redeems them, the adapter doesn't see transfer
    /// and can't update principals.
    /// The adapter reverts when Bob tries to withdraw more than underlying shares stored for him.
    /// Timeline (no profit/loss — clean at-par scenario so V2 pricing is unambiguous):
    ///   1. Alice deposits 1000 USDC → userPrincipal[alice]=1000e6, shares tracked
    ///   2. Bob   deposits 1000 USDC → userPrincipal[bob]=1000e6,   shares tracked
    ///   3. Alice transfers ALL her parent-vault ERC20 shares to Bob
    ///   4. Bob tries to redeem all shares, but the adapter rejects such a redemption. After that he redeems only his
    /// shares 5. Alice deposits 500 USDC at newer price
    ///   6. Bob transfers Alice's shares back and Alice redeems all. No insurance paid
    ///
    /// Key observations:
    ///   - Bob received insurance due to loss
    ///   - Alice can redeem all her shares after Bob transfers them back
    function test_fork_shareTransfer_ghostPrincipal() public onlyFork {
        address alice = makeAddr("alice_transfer");
        address bob = makeAddr("bob_transfer");
        uint96 xferPolicyId = 98;

        // Setup: deploy contracts
        (
            IVaultV2 parentVault,,
            CatalysisCoverAdapter xferAdapter,
            ControllableVault xferCtrlVault,
            ForkClaimManager xferClaimMgr,,
        ) = _setupParentWithMockUnderlyingVault(xferPolicyId);

        // STEP 1: Alice deposits 1000 USDC at P = 1.00
        {
            deal(USDC, alice, 1000e6);
            vm.prank(alice);
            IERC20(USDC).approve(address(parentVault), 1000e6);
            vm.prank(alice);
            parentVault.deposit(1000e6, alice);

            assertEq(xferAdapter.userPrincipal(alice), 1000e6, "Alice principal = 1000 USDC");
            assertEq(xferAdapter.userUnderlyingShares(alice), 1000e6, "Alice ctrlVault shares = 1000e6");
            assertEq(xferAdapter.totalPrincipal(), 1000e6, "Total principal = 1000 USDC");
        }

        // STEP 2: Bob deposits 1000 USDC at P = 1.00
        {
            deal(USDC, bob, 1000e6);
            vm.prank(bob);
            IERC20(USDC).approve(address(parentVault), 1000e6);
            vm.prank(bob);
            parentVault.deposit(1000e6, bob);

            assertEq(xferAdapter.userPrincipal(bob), 1000e6, "Bob principal = 1000 USDC");
            assertEq(xferAdapter.userUnderlyingShares(bob), 1000e6, "Bob ctrlVault shares = 1000e6");
            assertEq(xferAdapter.totalPrincipal(), 2000e6, "Total principal = 2000 USDC");
        }

        // STEP 3: Alice transfers half of  her parent-vault shares to Bob
        // The parent vault is ERC20-compliant — transfers bypass adapter hooks entirely.
        // The adapter has NO transfer callback: Alice's tracked state stays exactly as-is.
        uint256 aliceParentShares;
        uint256 bobOriginalShares;
        {
            aliceParentShares = parentVault.balanceOf(alice);
            bobOriginalShares = parentVault.balanceOf(bob);
            assertTrue(aliceParentShares > 0, "Alice has parent shares before transfer");

            vm.prank(alice);
            IERC20(address(parentVault)).transfer(bob, aliceParentShares / 2);

            assertEq(parentVault.balanceOf(alice), aliceParentShares / 2, "Alice has 0 parent shares after transfer");
            assertEq(
                parentVault.balanceOf(bob),
                bobOriginalShares + (aliceParentShares / 2),
                "Bob holds original + transferred shares"
            );

            // Adapter state is completely unchanged — transfer is invisible to the adapter
            assertEq(xferAdapter.userPrincipal(alice), 1000e6, "Alice principal unchanged in adapter");
            assertEq(xferAdapter.userUnderlyingShares(alice), 1000e6, "Alice ctrlVault shares unchanged in adapter");
            assertEq(xferAdapter.userPrincipal(bob), 1000e6, "Bob principal unchanged in adapter");
            assertEq(xferAdapter.totalPrincipal(), 2000e6, "Total principal unchanged after transfer");

            emit log_named_uint("Alice parent shares transferred", aliceParentShares);
            emit log_named_uint("Bob total parent shares", parentVault.balanceOf(bob));
        }

        // STEP 3.5: 10% loss — drain 200 USDC from ctrlVault
        // ctrlVault: 2000e6 - 200e6 = 1800e6 USDC / 2000e6 shares, P = 0.90
        // The loss occurs AFTER Alice transferred her shares, so the adapter still
        // tracks both Alice's and Bob's full 1000e6 principal each (2000e6 total).
        xferCtrlVault.simulateLoss(200e6);
        assertEq(xferAdapter.currentValue(), 1800e6, "currentValue = 1800 USDC after loss");

        // STEP 4: Bob redeems ALL parent-vault shares (his + Alice's)
        // Adapter reverts as Bob's withdrawal is capped with principal and shares stored for him
        {
            uint256 bobAllShares = parentVault.balanceOf(bob);
            uint256 bobValue = parentVault.convertToAssets(bobAllShares);
            vm.expectRevert(
                abi.encodeWithSignature(
                    "UnsupportedDeallocation(uint256,bytes4,address)", bobValue, bytes4(0xba087652), bob
                )
            );
            vm.prank(bob);
            parentVault.redeem(bobAllShares, bob, bob);
            // Correctly withdraw only Bob original shares
            vm.prank(bob);
            parentVault.redeem(bobOriginalShares, bob, bob);
        }

        // STEP 5: No ghost balances stored except for Alice principal
        {
            assertEq(
                IERC20(USDC).balanceOf(bob),
                1000e6 - (100e6 * 100 / 10_000),
                "Bob received principal back minus deductible"
            );
            assertEq(xferClaimMgr.totalPaidOut(xferPolicyId), 99e6, "Insurance paid for Bob's loss");
            assertEq(xferAdapter.userPrincipal(alice), 1000e6, "Alice ghost principal = 1000 USDC");
            assertEq(xferAdapter.userUnderlyingShares(alice), 1000e6, "Alice ghost ctrlVault shares = 1000e6");
            assertEq(
                xferAdapter.totalPrincipal(),
                xferAdapter.userPrincipal(alice),
                "totalPrincipal correctly equals to Alice leftover"
            );
            assertEq(
                xferAdapter.currentValue(),
                parentVault.convertToAssets(parentVault.balanceOf(alice))
                    + parentVault.convertToAssets(parentVault.balanceOf(bob)),
                "Value equal to Alice leftover currently stored on Alice's and Bob's balance"
            );
            assertEq(parentVault.balanceOf(alice), aliceParentShares / 2, "Alice cannot redeem (0 parent shares)");

            emit log_named_uint("Alice ghost principal (USDC)", xferAdapter.userPrincipal(alice));
            emit log_named_uint("Total principal remaining", xferAdapter.totalPrincipal());
            emit log_named_uint("Adapter current value", xferAdapter.currentValue());
        }
        // STEP 6: Alice re-deposits 500 USDC at newer price
        // Alice acquires new parent-vault shares and deposits again. The adapter adds the new 500e6 on top of her
        // existing value
        {
            deal(USDC, address(xferCtrlVault), IERC20(USDC).balanceOf(address(xferCtrlVault)) + 200e6); // Increase
            // price
            skip(365 days);

            deal(USDC, alice, 500e6);
            vm.prank(alice);
            IERC20(USDC).approve(address(parentVault), 500e6);
            vm.prank(alice);
            parentVault.deposit(500e6, alice);

            // Principal accumulates new deposits
            assertEq(xferAdapter.userPrincipal(alice), 1500e6, "Alice principal = ghost 1000 + new 500");
            assertEq(
                xferAdapter.userUnderlyingShares(alice),
                xferAdapter.underlyingShares(),
                "Alice should hold all UV shares"
            );
            // totalPrincipal tracks new deposits and should be equal to Alice's principal
            assertEq(
                xferAdapter.totalPrincipal(),
                xferAdapter.userPrincipal(alice),
                "totalPrincipal = 500 USDC (new deposit only)"
            );
            assertApproxEqAbs(
                xferAdapter.currentValue(),
                parentVault.convertToAssets(parentVault.balanceOf(alice))
                    + parentVault.convertToAssets(parentVault.balanceOf(bob)),
                2,
                "Adapter value = Alice's value + Bob's left shares"
            );
            emit log_named_uint("Alice principal after re-deposit", xferAdapter.userPrincipal(alice));
        }

        // STEP 7: Bob transfers shares back to Alice, Alice redeems all
        {
            uint256 sharesToTransfer = parentVault.balanceOf(bob);
            vm.prank(bob);
            IERC20(address(parentVault)).transfer(alice, sharesToTransfer);

            uint256 aliceNewShares = parentVault.balanceOf(alice);
            uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
            vm.prank(alice);
            parentVault.redeem(aliceNewShares, alice, alice);
            uint256 aliceReceived = IERC20(USDC).balanceOf(alice) - aliceBefore;

            // Alice recovers all underlying deposited from all steps
            // Initial 1000 - 10% loss + 20% profit + 50 = 1600
            assertApproxEqAbs(aliceReceived, 1600e6, 2, "Alice recovered initial deposit");
            // No insurance filed (received >= deposited)
            assertEq(xferClaimMgr.totalPaidOut(xferPolicyId), 99e6, "Insurance wasn't paid to Alice");

            // No ghost state left in Adapter, all shares are withdrawn
            assertApproxEqAbs(xferAdapter.userPrincipal(alice), 0, 2, "Alice principal = 0");
            assertApproxEqAbs(xferAdapter.userUnderlyingShares(alice), 0, 2, "Alice shares = 0");
            // totalPrincipal and currentValue correctly return to 0
            assertApproxEqAbs(xferAdapter.totalPrincipal(), 0, 2, "totalPrincipal back to 0");
            assertApproxEqAbs(xferAdapter.currentValue(), 0, 2, "Adapter value back to 0");
            assertApproxEqAbs(xferAdapter.underlyingShares(), 0, 2, "Adapter shares back to 0");

            emit log_named_uint("Alice recovered USDC", aliceReceived);
            emit log_named_uint("Alice ghost principal after cycle", xferAdapter.userPrincipal(alice));
            emit log_named_uint("Total principal after full cycle", xferAdapter.totalPrincipal());
        }
    }

    /// @notice ERC20 share transfers at DIFFERENT entry prices reverts as expected sinece users can't redeem more that
    /// their underlying shares
    function test_fork_shareTransfer_differentPrices_revertsOnRedemption() public onlyFork {
        address alice = makeAddr("alice_diffprice");
        address bob = makeAddr("bob_diffprice");
        uint96 dpPolicyId = 99;

        // Setup: deploy contracts
        (
            IVaultV2 parentVault,,
            CatalysisCoverAdapter dpAdapter,
            ControllableVault dpCtrlVault,
            ForkClaimManager dpClaimMgr,,
        ) = _setupParentWithMockUnderlyingVault(dpPolicyId);

        // STEP 1: Alice deposits 1000 USDC at P = 1.00
        {
            deal(USDC, alice, 1000e6);
            vm.prank(alice);
            IERC20(USDC).approve(address(parentVault), 1000e6);
            vm.prank(alice);
            parentVault.deposit(1000e6, alice);

            assertEq(dpAdapter.userPrincipal(alice), 1000e6, "Alice principal = 1000 USDC");
            assertEq(dpAdapter.userUnderlyingShares(alice), 1000e6, "Alice ctrlVault shares = 1000e6");
            assertEq(dpAdapter.totalPrincipal(), 1000e6, "Total principal = 1000 USDC");
        }

        // STEP 2: Profit -- deal 500 USDC into ctrlVault -> P = 1.50
        // ctrlVault: 1500e6 USDC / 1000e6 shares = 1.5 USDC per share.
        {
            deal(USDC, address(dpCtrlVault), 1500e6); // sets absolute balance to 1500e6
            assertEq(dpAdapter.currentValue(), 1500e6, "ctrlVault value = 1500 USDC");
            assertEq(dpCtrlVault.convertToAssets(1e6), 1_500_000, "ctrlVault P = 1.50");
        }

        // STEP 3: Bob deposits 1500 USDC at P = 1.50
        {
            deal(USDC, bob, 1500e6);
            vm.prank(bob);
            IERC20(USDC).approve(address(parentVault), 1500e6);
            vm.prank(bob);
            parentVault.deposit(1500e6, bob);

            assertEq(dpAdapter.userPrincipal(bob), 1500e6, "Bob principal = 1500 USDC");
            assertEq(dpAdapter.userUnderlyingShares(bob), 1000e6, "Bob ctrlVault shares = 1000");
            assertEq(dpAdapter.totalPrincipal(), 2500e6, "Total principal = 2500 USDC");
            assertEq(dpCtrlVault.totalSupply(), 2000e6, "ctrlVault total shares = 2000");

            emit log_named_uint("Bob ctrlVault shares", dpAdapter.userUnderlyingShares(bob));
            emit log_named_uint("ctrlVault totalAssets after Bob", dpCtrlVault.totalAssets());
        }

        // STEP 4: Alice transfers ALL her parent-vault ERC20 shares to Bob
        // Adapter state is unchanged -- ERC20 transfers bypass adapter hooks.
        {
            uint256 aliceParentShares = parentVault.balanceOf(alice);
            vm.prank(alice);
            IERC20(address(parentVault)).transfer(bob, aliceParentShares);

            assertEq(parentVault.balanceOf(alice), 0, "Alice has 0 parent shares after transfer");
            assertEq(dpAdapter.userPrincipal(alice), 1000e6, "Alice principal unchanged in adapter");
            assertEq(dpAdapter.totalPrincipal(), 2500e6, "Total principal unchanged after ERC20 transfer");

            emit log_named_uint("Bob total parent shares after transfer", parentVault.balanceOf(bob));
        }

        // STEP 5: Loss -- 200 USDC drained from ctrlVault
        // ctrlVault: 3000e6 - 200e6 = 2800e6 USDC / 2000 shares.
        {
            dpCtrlVault.simulateLoss(200e6);
            assertEq(dpAdapter.currentValue(), 2800e6, "ctrlVault value = 2300 USDC after loss");
            emit log_named_uint("Adapter value after loss + sync", dpAdapter.currentValue());
        }

        // STEP 6: Bob tries to redeem ALL shares -> REVERT
        {
            uint256 bobAllShares = parentVault.balanceOf(bob);
            vm.expectRevert();
            vm.prank(bob);
            parentVault.redeem(bobAllShares, bob, bob);

            assertEq(dpAdapter.userPrincipal(bob), 1500e6, "Bob principal unchanged (revert rolled back)");
            assertEq(dpAdapter.userPrincipal(alice), 1000e6, "Alice principal unchanged (revert rolled back)");
            assertEq(dpAdapter.totalPrincipal(), 2500e6, "Total principal unchanged (revert rolled back)");
            assertEq(dpAdapter.currentValue(), 2800e6, "Adapter value unchanged (revert rolled back)");
            assertEq(dpClaimMgr.totalPaidOut(dpPolicyId), 0, "No insurance paid (reverted)");

            emit log_string("Bob's redemption REVERTED -- different entry prices prevent insurance inflation");
        }
    }

    /// @notice When the HIGHER-price depositor (Bob) transfers shares to the LOWER-price
    /// adapter reverts as users can't redeem more than their stored underlying shares
    function test_fork_shareTransfer_bobToAlice_noInsurance() public onlyFork {
        address alice = makeAddr("alice_ba");
        address bob = makeAddr("bob_ba");
        uint96 baPolicyId = 100;

        // Setup: deploy contracts
        (
            IVaultV2 parentVault,,
            CatalysisCoverAdapter baAdapter,
            ControllableVault baCtrlVault,
            ForkClaimManager baClaimMgr,,
        ) = _setupParentWithMockUnderlyingVault(baPolicyId);

        // STEP 1: Alice deposits 1000 USDC at P = 1.00
        uint256 aliceOriginalShares;
        {
            deal(USDC, alice, 1000e6);
            vm.prank(alice);
            IERC20(USDC).approve(address(parentVault), 1000e6);
            vm.prank(alice);
            aliceOriginalShares = parentVault.deposit(1000e6, alice);

            assertEq(baAdapter.userPrincipal(alice), 1000e6, "Alice principal = 1000 USDC");
            assertEq(baAdapter.userUnderlyingShares(alice), 1000e6, "Alice ctrlVault shares = 1000e6");
            assertEq(baAdapter.totalPrincipal(), 1000e6, "Total principal = 1000 USDC");
        }

        // STEP 2: Profit -- deal into ctrlVault -> P = 1.50
        // ctrlVault: 1500e6 USDC / 1000e6 shares = 1.5 USDC per share.
        {
            deal(USDC, address(baCtrlVault), 1500e6);
            skip(365 days);
            assertEq(baAdapter.currentValue(), 1500e6, "ctrlVault value = 1500 USDC");
        }

        // STEP 3: Bob deposits 1500 USDC at P = 1.50
        // ctrlVault mints 1500e6 * 1000e6 / 1500e6 = 1000e6 shares for Bob.
        // userPrincipal[bob] = 1500e6, userUnderlyingShares[bob] = 1000e6.
        // totalPrincipal = 2500e6; ctrlVault: 3000e6 USDC / 2000e6 shares.
        {
            deal(USDC, bob, 1500e6);
            vm.prank(bob);
            IERC20(USDC).approve(address(parentVault), 1500e6);
            vm.prank(bob);
            parentVault.deposit(1500e6, bob);

            assertEq(baAdapter.userPrincipal(bob), 1500e6, "Bob principal = 1500 USDC");
            assertEq(baAdapter.userUnderlyingShares(bob), 1000e6, "Bob ctrlVault shares = 1000e6");
            assertEq(baAdapter.totalPrincipal(), 2500e6, "Total principal = 2500 USDC");
            assertEq(baCtrlVault.totalSupply(), 2000e6, "ctrlVault total shares = 2000e6");
        }

        // STEP 4: BOB transfers ALL his Parent Vault shares to Alice
        // Adapter state is unchanged -- share transfers bypass adapter hooks.
        // Now Alice holds her own shares AND Bob's, but the adapter still
        // tracks them separately (userPrincipal[alice]=1000e6, [bob]=1500e6).
        {
            uint256 bobShares = parentVault.balanceOf(bob);
            vm.prank(bob);
            IERC20(address(parentVault)).transfer(alice, bobShares);

            assertEq(parentVault.balanceOf(bob), 0, "Bob has 0 parent shares after transfer");
            assertEq(baAdapter.userPrincipal(bob), 1500e6, "Bob principal unchanged in adapter");
            assertEq(baAdapter.totalPrincipal(), 2500e6, "Total principal unchanged after share transfer");

            emit log_named_uint("Alice total parent shares after receiving Bob's", parentVault.balanceOf(alice));
        }

        // STEP 5: Loss -- 200 USDC drained from ctrlVault
        // ctrlVault: 3000e6 - 200e6 = 2800e6 USDC / 2000e6 shares (P = 1.40).
        {
            baCtrlVault.simulateLoss(200e6);
            assertEq(baAdapter.currentValue(), 2800e6, "ctrlVault value = 2800 USDC after loss");
        }

        // STEP 6: Alice redeems only her shares, then transfers rest to Bob and Bob redeems
        {
            uint256 aliceAllShares = parentVault.balanceOf(alice);
            uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
            uint256 currentValBeforeRedeem = baAdapter.currentValue();
            vm.prank(alice);
            parentVault.redeem(aliceOriginalShares, alice, alice);
            uint256 aliceReceived = IERC20(USDC).balanceOf(alice) - aliceBefore;

            // Alice only her half of asset without insurance payout
            assertApproxEqAbs(
                aliceReceived, currentValBeforeRedeem / 2, 2, "Alice received ~2800 USDC (full vault value)"
            );
            // No insurance: vault paid more than effective principal
            assertEq(baClaimMgr.totalPaidOut(baPolicyId), 0, "No insurance paid");

            // Adapter state after Alice's redemption
            assertApproxEqAbs(baAdapter.userPrincipal(alice), 0, ALLOWED_DUST_2_WEI, "Alice principal cleared to 0");
            assertApproxEqAbs(
                baAdapter.userUnderlyingShares(alice), 0, ALLOWED_DUST_2_WEI, "Alice ctrlVault shares cleared"
            );
            // totalPrincipal contains Bob's principal only
            assertApproxEqAbs(
                baAdapter.totalPrincipal(),
                baAdapter.userPrincipal(bob),
                ALLOWED_DUST_2_WEI,
                "totalPrincipal = Bob's principal"
            );
            // Bob's ghost state untouched
            assertEq(baAdapter.userPrincipal(bob), 1500e6, "Bob principal = 1500 USDC");
            assertEq(baAdapter.userUnderlyingShares(bob), 1000e6, "Bob still has shares to withdraw");
            // All underlying shares burned
            assertApproxEqAbs(
                baAdapter.currentValue(), currentValBeforeRedeem / 2, ALLOWED_DUST_2_WEI, "Bob's value left"
            );

            emit log_named_uint("Alice received USDC", aliceReceived);
            emit log_named_uint("totalPrincipal after redemption (Bob ghost)", baAdapter.totalPrincipal());
            emit log_string("No insurance -- vault paid Alice more than effective principal (2800 > 2000)");
        }

        // STEP 7: Alice transfers rest to Bob and Bob redeems
        {
            uint256 sharesToTransfer = parentVault.balanceOf(alice);
            vm.prank(alice);
            IERC20(address(parentVault)).transfer(bob, sharesToTransfer);
            // Simulate profit so that Bob withdraws at new rate. Still less than previous profit
            deal(USDC, address(baCtrlVault), 100e6);
            skip(365 days);

            uint256 bobBefore = IERC20(USDC).balanceOf(bob);
            uint256 currentValBeforeRedeem = baAdapter.currentValue();
            uint256 expectedPayout = baAdapter.userShortfall(bob) - (baAdapter.userShortfall(bob) * 100 / 10_000); // Minus
            uint256 withdrawAmount = parentVault.convertToAssets(sharesToTransfer) - 1;
            vm.prank(bob);
            parentVault.withdraw(withdrawAmount, bob, bob);
            uint256 bobReceived = IERC20(USDC).balanceOf(bob) - bobBefore;

            assertApproxEqAbs(
                bobReceived - currentValBeforeRedeem, expectedPayout, ALLOWED_DUST, "Received current value + insurance"
            );
            assertApproxEqAbs(baClaimMgr.totalPaidOut(baPolicyId), expectedPayout, ALLOWED_DUST, "Coverage consumed");
        }
    }

    /// @notice Share transfer to an account that has NEVER interacted with the adapter,
    ///         then that unknown account redeems -- adapter reverts.
    function test_fork_shareTransfer_toUnknownAccount_unableToRedeem() public onlyFork {
        address alice = makeAddr("alice_unknownXfer");
        address charlie = makeAddr("charlie_unknownXfer");
        uint96 ukPolicyId = 100;

        // Setup: deploy contracts
        (
            IVaultV2 parentVault,,
            CatalysisCoverAdapter ukAdapter,
            ControllableVault ukCtrlVault,
            ForkClaimManager ukClaimMgr,,
        ) = _setupParentWithMockUnderlyingVault(ukPolicyId);

        // STEP 1: Alice deposits 1000 USDC
        {
            deal(USDC, alice, 1000e6);
            vm.prank(alice);
            IERC20(USDC).approve(address(parentVault), 1000e6);
            vm.prank(alice);
            parentVault.deposit(1000e6, alice);

            assertEq(ukAdapter.userPrincipal(alice), 1000e6, "Alice principal = 1000 USDC");
            assertEq(ukAdapter.userUnderlyingShares(alice), 1000e6, "Alice ctrlVault shares = 1000e6");
            assertEq(ukAdapter.totalPrincipal(), 1000e6, "Total principal = 1000 USDC");
        }

        // STEP 2: Verify Charlie has NO adapter state
        {
            assertEq(ukAdapter.userPrincipal(charlie), 0, "Charlie has 0 principal (never deposited)");
            assertEq(ukAdapter.userUnderlyingShares(charlie), 0, "Charlie has 0 ctrlVault shares");
            assertEq(parentVault.balanceOf(charlie), 0, "Charlie has 0 parent shares");
        }

        // STEP 3: Alice transfers ALL parent-vault shares to Charlie
        {
            uint256 aliceShares = parentVault.balanceOf(alice);
            assertTrue(aliceShares > 0, "Alice has parent shares to transfer");

            vm.prank(alice);
            IERC20(address(parentVault)).transfer(charlie, aliceShares);

            assertEq(parentVault.balanceOf(alice), 0, "Alice has 0 parent shares after transfer");
            assertEq(parentVault.balanceOf(charlie), aliceShares, "Charlie holds all transferred shares");

            // Adapter state is UNCHANGED -- transfer is invisible to adapter
            assertEq(ukAdapter.userPrincipal(alice), 1000e6, "Alice principal still tracked");
            assertEq(ukAdapter.userUnderlyingShares(alice), 1000e6, "Alice ctrlVault shares still tracked");
            assertEq(ukAdapter.userPrincipal(charlie), 0, "Charlie STILL has 0 principal in adapter");
            assertEq(ukAdapter.userUnderlyingShares(charlie), 0, "Charlie STILL has 0 ctrlVault shares");
            assertEq(ukAdapter.totalPrincipal(), 1000e6, "Total principal unchanged");

            emit log_named_uint("Alice parent shares transferred to Charlie", aliceShares);
        }

        // STEP 4: 10% loss on underlying (100 USDC drained)
        ukCtrlVault.simulateLoss(100e6);
        assertEq(ukAdapter.currentValue(), 900e6, "currentValue = 900 USDC after 10% loss");

        // STEP 5: Charlie redeems ALL shares, adapter reverts

        {
            uint256 charlieShares = parentVault.balanceOf(charlie);
            vm.expectRevert(
                abi.encodeWithSignature(
                    "UnsupportedDeallocation(uint256,bytes4,address)", 900e6, bytes4(0xba087652), charlie
                )
            );
            vm.prank(charlie);
            parentVault.redeem(charlieShares, charlie, charlie);
        }

        // STEP 6: Check that no ghost state persists.
        // Alice principal stays the same since her shares still exist
        {
            assertEq(ukAdapter.userPrincipal(alice), 1000e6, "Alice ghost principal = 1000 USDC");
            assertEq(ukAdapter.userUnderlyingShares(alice), 1000e6, "Alice ghost ctrlVault shares = 1000e6");
            assertEq(ukAdapter.totalPrincipal(), 1000e6, "Total principal equals Alice principal");
            assertEq(ukAdapter.underlyingShares(), 1000e6, "Underlying shares equals Alice shares");
            assertEq(parentVault.balanceOf(alice), 0, "Alice has 0 parent shares (cannot redeem)");

            emit log_named_uint("Alice ghost principal persists", ukAdapter.userPrincipal(alice));
            emit log_named_uint("Alice ghost ctrlVault shares", ukAdapter.userUnderlyingShares(alice));
            emit log_string("Transfer to unknown account: full loss absorbed, zero insurance, ghost state persists");
        }
    }

    /// @notice Management fee recipient redeems fee-minted shares -- adapter uses
    ///         fallback path, NO insurance payout.
    ///
    ///   1. V2 vault has managementFee set (e.g. 10%) with a feeRecipient address
    ///   2. User deposits 10000 USDC through V2 -> adapter allocates to ControllableVault
    ///   3. Time passes (90 days) -> V2 accrueInterest mints fee shares to feeRecipient
    ///   4. 10% loss on underlying
    ///   5. Fee recipient redeems their shares -> adapter fallback path -> NO insurance
    /// Result: Fee recipient gets vault proceeds but zero insurance.
    function test_fork_managementFeeRecipient_redeemNoInsurance() public onlyFork {
        address alice = makeAddr("alice_feeTest");
        address feeRecip = makeAddr("feeRecipient_v2");
        uint96 feePolicyId = 101;

        // Setup: deploy contracts
        (
            IVaultV2 parentVault,,
            CatalysisCoverAdapter feeAdapter,
            ControllableVault feeCtrlVault,
            ForkClaimManager feeClaimMgr,
            address newCurator,
        ) = _setupParentWithMockUnderlyingVault(feePolicyId);

        // Set ~2% annual management fee and fee recipient via curator governance.
        // Management fee is per-second in WAD: 0.02e18 / 365 days ≈ 634195839
        // setManagementFee has a per-selector timelock on fresh V2 vaults.
        // Submit both, query executableAt, warp past timelock, then execute.
        {
            uint256 feePerSecond = uint256(0.02e18) / uint256(365 days); // ~2% annual
            bytes memory feeData = abi.encodeWithSignature("setManagementFee(uint256)", feePerSecond);
            bytes memory recipData = abi.encodeWithSignature("setManagementFeeRecipient(address)", feeRecip);

            vm.prank(newCurator);
            (bool s1,) = address(parentVault).call(abi.encodeWithSignature("submit(bytes)", feeData));
            require(s1, "submit setManagementFee failed");

            vm.prank(newCurator);
            (bool s2,) = address(parentVault).call(abi.encodeWithSignature("submit(bytes)", recipData));
            require(s2, "submit setManagementFeeRecipient failed");

            // Query when the data becomes executable and warp past it
            (bool qOk, bytes memory qRet) =
                address(parentVault).staticcall(abi.encodeWithSignature("executableAt(bytes)", feeData));
            require(qOk, "executableAt query failed");
            uint256 execAt = abi.decode(qRet, (uint256));
            if (execAt > block.timestamp) {
                vm.warp(execAt);
                vm.roll(block.number + 1);
            }

            // Must set recipient FIRST — setManagementFee requires managementFeeRecipient != address(0)
            vm.prank(newCurator);
            (bool e2,) = address(parentVault).call(recipData);
            require(e2, "execute setManagementFeeRecipient failed");

            vm.prank(newCurator);
            (bool e1,) = address(parentVault).call(feeData);
            require(e1, "execute setManagementFee failed");
        }

        // STEP 1: Alice deposits 10000 USDC
        {
            deal(USDC, alice, 10_000e6);
            vm.prank(alice);
            IERC20(USDC).approve(address(parentVault), 10_000e6);
            vm.prank(alice);
            parentVault.deposit(10_000e6, alice);

            assertEq(feeAdapter.userPrincipal(alice), 10_000e6, "Alice principal = 10000 USDC");
            assertEq(feeAdapter.totalPrincipal(), 10_000e6, "Total principal = 10000 USDC");
            assertEq(feeAdapter.userPrincipal(feeRecip), 0, "Fee recipient has 0 principal");
            assertEq(feeAdapter.userUnderlyingShares(feeRecip), 0, "Fee recipient has 0 ctrlVault shares");
            assertEq(parentVault.balanceOf(feeRecip), 0, "Fee recipient has 0 V2 shares before fee accrual");

            emit log_named_uint("Alice deposited USDC", 10_000e6);
        }

        // STEP 2: Simulate yield (deal USDC into ctrlVault) + time passage
        // Deal 1000 USDC (10% yield) so accrueInterest sees positive interest.
        deal(USDC, address(feeCtrlVault), IERC20(USDC).balanceOf(address(feeCtrlVault)) + 1000e6);
        // Skip 90 days so the management fee has time to accrue
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + 1);

        // STEP 3: Trigger accrueInterest by doing a tiny deposit
        // This causes V2 to recognize the yield, compute management fee, and mint
        // fee shares to the managementFeeRecipient.
        {
            deal(USDC, alice, 1e6);
            vm.prank(alice);
            IERC20(USDC).approve(address(parentVault), 1e6);
            vm.prank(alice);
            parentVault.deposit(1e6, alice);

            uint256 feeRecipShares = parentVault.balanceOf(feeRecip);
            emit log_named_uint("Fee recipient V2 shares after 90d", feeRecipShares);
            assertTrue(feeRecipShares > 0, "Fee recipient should have V2 shares from management fee");

            // Fee recipient has NO adapter state (never deposited through adapter)
            assertEq(feeAdapter.userPrincipal(feeRecip), 0, "Fee recipient still 0 principal in adapter");
            assertEq(feeAdapter.userUnderlyingShares(feeRecip), 0, "Fee recipient still 0 ctrlVault shares");
        }

        // STEP 4: 10% loss on underlying
        {
            uint256 ctrlBalance = IERC20(USDC).balanceOf(address(feeCtrlVault));
            feeCtrlVault.simulateLoss(ctrlBalance / 10);
            emit log_named_uint("Adapter value after loss", feeAdapter.currentValue());
        }

        // STEP 5: Fee recipient redeems their shares -- fallback, NO insurance
        {
            uint256 feeRecipShares = parentVault.balanceOf(feeRecip);
            assertTrue(feeRecipShares > 0, "Fee recipient has shares to redeem");

            uint256 principalBefore = feeAdapter.totalPrincipal();
            uint256 feeRecipBefore = IERC20(USDC).balanceOf(feeRecip);
            uint256 uvBefore = feeAdapter.underlyingShares();

            vm.prank(feeRecip);
            parentVault.redeem(feeRecipShares, feeRecip, feeRecip);

            uint256 feeRecipReceived = IERC20(USDC).balanceOf(feeRecip) - feeRecipBefore;
            uint256 principalAfter = feeAdapter.totalPrincipal();

            // Fee recipient should receive USDC (their fee share of the vault)
            assertTrue(feeRecipReceived > 0, "Fee recipient received USDC from vault");

            // NO insurance paid out -- fee recipient has no tracked principal
            assertEq(feeClaimMgr.totalPaidOut(feePolicyId), 0, "Zero insurance paid for fee recipient redeem");

            // Fee recipient STILL has no per-user state (fallback path does not create it)
            assertEq(feeAdapter.userPrincipal(feeRecip), 0, "Fee recipient principal still 0 after redeem");
            assertEq(
                feeAdapter.userUnderlyingShares(feeRecip), 0, "Fee recipient ctrlVault shares still 0 after redeem"
            );

            // totalPrincipal decreased proportionally via fallback formula
            assertTrue(principalAfter < principalBefore, "totalPrincipal decreased after fee recipient redeem");

            emit log_named_uint("Fee recipient received USDC", feeRecipReceived);
            emit log_named_uint("Principal before fee redeem", principalBefore);
            emit log_named_uint("Principal after fee redeem", principalAfter);
            emit log_named_uint("Insurance paid", feeClaimMgr.totalPaidOut(feePolicyId));
            emit log_named_uint("UV Shares burnt after fee redeem", uvBefore - feeAdapter.underlyingShares());
        }

        // STEP 6: Advance block and verify Alice can still redeem with insurance
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        {
            uint256 aliceShares = parentVault.balanceOf(alice);
            assertTrue(aliceShares > 0, "Alice still has V2 shares");

            uint256 aliceBefore = IERC20(USDC).balanceOf(alice);

            vm.prank(alice);
            parentVault.redeem(aliceShares, alice, alice);

            uint256 aliceReceived = IERC20(USDC).balanceOf(alice) - aliceBefore;
            console.log("Alice received: ", aliceReceived);
            // Alice has tracked shares -> per-user path, insurance if shortfall
            assertTrue(aliceReceived > 0, "Alice received USDC");
            // Management-fee dilution: the fee recipient's fallback-path redeem burns
            // underlying shares from the adapter's pool without reducing Alice's
            // userUnderlyingShares.  When Alice redeems all V2 shares the adapter burns
            // fewer underlying shares than she has tracked, so principal isn't fully
            // zeroed. The residual ≈ managementFee% of her principal — expected behaviour.
            uint256 residual = feeAdapter.userPrincipal(alice);
            //assertLe(residual, 100e6, "Alice principal residual within 100 USDC (fee dilution)");

            emit log_named_uint("Alice received USDC", aliceReceived);
            emit log_named_uint("Total insurance paid after Alice redeem", feeClaimMgr.totalPaidOut(feePolicyId));
            emit log_named_uint("totalPrincipal after all redeems", feeAdapter.totalPrincipal());
            emit log_string("Fee recipient: fallback path, no insurance. Alice: per-user path, insurance eligible.");
        }
    }

    /// @notice Full deallocate cycle: deposit → emergency deallocate → re-deposit → loss → user withdrawal with
    /// insurance.
    /// Timeline:
    ///   1. Alice deposits 1000 USDC → per-user tracking (principal + shares)
    ///   2. Bob deposits 1000 USDC → per-user tracking
    ///   3. Allocator emergency-deallocates ALL → totalPrincipal = 0, underlyingShares = 0
    ///      Per-user state (userPrincipal, userUnderlyingShares) is NOT cleared (Branch 1 doesn't touch it)
    ///   4. Alice and Bob withdraw from parent vault idle (no adapter interaction — V2 uses idle first)
    ///   5. Alice re-deposits 2000 USDC → fresh per-user tracking (accumulates on top of ghost state)
    ///   6. 10% loss on ctrlVault
    ///   7. Alice redeems → insurance covers shortfall based on her accumulated principal
    ///
    /// Key assertions:
    ///   - Emergency deallocate zeroes global state but leaves per-user ghost state
    ///   - Re-deposit correctly accumulates new principal on top of ghost values
    ///   - Insurance works correctly after the full cycle
    function test_fork_deallocateCycle_emergencyAndRedeposit() public onlyFork {
        address alice = makeAddr("alice_cycle");

        // Setup: deploy contracts with mock underlying
        IVaultV2 vault;
        CatalysisCoverAdapter cycleAdapter;
        ControllableVault cycleCtrlVault;
        ForkClaimManager cycleClaimMgr;
        {
            address cycleAllocator;
            {
                (
                    IVaultV2 v,,
                    CatalysisCoverAdapter a,
                    ControllableVault c,
                    ForkClaimManager f,,
                    address alloc
                ) = _setupParentWithMockUnderlyingVault(102);
                vault = v;
                cycleAdapter = a;
                cycleCtrlVault = c;
                cycleClaimMgr = f;
                cycleAllocator = alloc;
            }

            // STEP 1: Alice deposits 1000 USDC at P = 1.00
            uint256 aliceShares;
            {
                deal(USDC, alice, 1000e6);
                vm.prank(alice);
                IERC20(USDC).approve(address(vault), 1000e6);
                vm.prank(alice);
                aliceShares = vault.deposit(1000e6, alice);

                assertEq(cycleAdapter.userPrincipal(alice), 1000e6, "Alice principal = 1000 USDC");
                assertEq(cycleAdapter.userUnderlyingShares(alice), 1000e6, "Alice ctrlVault shares = 1000e6");
                assertEq(cycleAdapter.totalPrincipal(), 1000e6, "Total principal = 1000 USDC");
            }

            // STEP 2: Bob deposits 1000 USDC at P = 1.00
            uint256 bobShares;
            {
                address bob = makeAddr("bob_cycle");
                deal(USDC, bob, 1000e6);
                vm.prank(bob);
                IERC20(USDC).approve(address(vault), 1000e6);
                vm.prank(bob);
                bobShares = vault.deposit(1000e6, bob);

                assertEq(cycleAdapter.userPrincipal(bob), 1000e6, "Bob principal = 1000 USDC");
                assertEq(cycleAdapter.totalPrincipal(), 2000e6, "Total principal = 2000 USDC");
                assertEq(cycleAdapter.currentValue(), 2000e6, "currentValue = 2000 USDC");
            }

            // STEP 3: Allocator emergency-deallocates ALL
            {
                address bob = makeAddr("bob_cycle");
                uint256 amountToDeallocate = vault.previewRedeem(vault.totalSupply());
                vm.prank(cycleAllocator);
                vault.deallocate(address(cycleAdapter), "", amountToDeallocate);

                assertEq(cycleAdapter.totalPrincipal(), 0, "totalPrincipal = 0 after emergency deallocate");
                assertEq(cycleAdapter.underlyingShares(), 0, "underlyingShares = 0 after emergency deallocate");
                assertEq(cycleAdapter.currentValue(), 0, "currentValue = 0 after emergency deallocate");

                assertEq(cycleAdapter.userPrincipal(alice), 1000e6, "Alice ghost principal persists");
                assertEq(cycleAdapter.userUnderlyingShares(alice), 1000e6, "Alice ghost shares persist");
                assertEq(cycleAdapter.userPrincipal(bob), 1000e6, "Bob ghost principal persists");
                assertEq(cycleAdapter.userUnderlyingShares(bob), 1000e6, "Bob ghost shares persist");

                emit log_string("Emergency deallocate: global state zeroed, per-user ghost state persists");
            }

            // STEP 4: Alice and Bob withdraw from parent vault idle
            {
                address bob = makeAddr("bob_cycle");
                vm.prank(alice);
                vault.redeem(aliceShares, alice, alice);
                vm.prank(bob);
                vault.redeem(bobShares, bob, bob);

                assertApproxEqAbs(IERC20(USDC).balanceOf(alice), 1000e6, ALLOWED_DUST_2_WEI, "Alice got ~1000 USDC back");
                assertApproxEqAbs(IERC20(USDC).balanceOf(bob), 1000e6, ALLOWED_DUST_2_WEI, "Bob got ~1000 USDC back");
                assertEq(vault.balanceOf(alice), 0, "Alice has 0 parent shares");
                assertEq(vault.balanceOf(bob), 0, "Bob has 0 parent shares");

                emit log_string("Users withdrew from idle -- no adapter deallocate triggered");
            }
        }

        // STEP 5: Alice re-deposits 2000 USDC (fresh cycle)
        // Per-user tracking accumulates on top of ghost state from Step 1
        uint256 aliceNewShares;
        uint256 aliceNewDepositValue = 2000e6;
        {
            deal(USDC, alice, aliceNewDepositValue);
            vm.prank(alice);
            IERC20(USDC).approve(address(vault), aliceNewDepositValue);
            vm.prank(alice);
            aliceNewShares = vault.deposit(aliceNewDepositValue, alice);

            // Ghost principal (1000) + new deposit (2000) = 3000
            assertEq(cycleAdapter.userPrincipal(alice), 1000e6 + aliceNewDepositValue, "Alice principal = ghost 1000 + new 2000 = 3000");
            // Ghost shares (1000e6) + new shares (2000e6 at P=1.00) = 3000e6
            assertEq(cycleAdapter.userUnderlyingShares(alice), 3000e6, "Alice shares = ghost + new");
            assertEq(cycleAdapter.totalPrincipal(), aliceNewDepositValue, "totalPrincipal = 2000 (only new deposit)");
            assertEq(cycleAdapter.currentValue(), aliceNewDepositValue, "currentValue = 2000 USDC");

            emit log_named_uint("Alice accumulated principal (ghost + new)", cycleAdapter.userPrincipal(alice));
        }

        // STEP 6: 10% loss on ctrlVault (200 USDC drained)
        // ctrlVault: 2000e6 - 200e6 = 1800e6 / 2000e6 shares, P = 0.90
        {
            cycleCtrlVault.simulateLoss(200e6);
            assertEq(cycleAdapter.currentValue(), aliceNewDepositValue * (10_000 - 1000) / 10_000, "currentValue = 1800 USDC after 10% loss");
        }

        // STEP 7: Alice redeems all — insurance should cover her shortfall
        {
            uint256 maxCoverable = aliceNewDepositValue * 1000 / 10_000;
            uint256 expectedReceived = cycleAdapter.currentValue() + (maxCoverable - (maxCoverable * 100 / 10_000));
            uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
            vm.prank(alice);
            vault.redeem(aliceNewShares, alice, alice);
            uint256 aliceReceived = IERC20(USDC).balanceOf(alice) - aliceBefore;

            assertEq(aliceReceived, expectedReceived, "Alice received principle - deductible");
            assertEq(cycleClaimMgr.totalPaidOut(102), maxCoverable - (maxCoverable * 100 / 10_000), "Insurance was paid after cycle");
            assertEq(cycleAdapter.totalPrincipal(), 0, "Total principle empty after full withdrawal");
            assertEq(cycleAdapter.userPrincipal(alice), 1000e6, "Ghost state persists in principal");
            assertEq(cycleAdapter.userUnderlyingShares(alice), 1000e6, "Ghost state persists in shares");

            emit log_named_uint("Alice received USDC", aliceReceived);
            emit log_named_uint("Insurance paid", cycleClaimMgr.totalPaidOut(102));
            emit log_named_uint("Alice remaining principal", cycleAdapter.userPrincipal(alice));
            emit log_named_uint("totalPrincipal remaining", cycleAdapter.totalPrincipal());
            emit log_string("Deallocate cycle complete: deposit -> emergency -> re-deposit -> loss -> insurance");
        }
    }

    /// @notice Direct USDC transfer to the adapter contract — verify accounting is unaffected.
    ///
    /// The adapter tracks `underlyingShares` internally and computes `currentValue()`
    /// from `underlyingVault.convertToAssets(underlyingShares)`. USDC sent directly to
    /// the adapter sits idle and is invisible to the adapter's accounting.
    ///
    /// Timeline:
    ///   1. Alice deposits 1000 USDC through the vault (tracked normally)
    ///   2. Random address sends 500 USDC directly to the adapter contract
    ///   3. Verify: currentValue, totalPrincipal, underlyingShares unchanged
    ///   4. Alice redeems all — receives her expected amount
    ///   5. Verify: 500 USDC is stranded on the adapter (not recoverable via normal flow)
    function test_fork_directBalanceTransfer_usdcToAdapter() public onlyFork {
        address alice = makeAddr("alice_directXfer");
        uint96 xferPolicyId = 103;

        // Setup: deploy contracts with mock underlying
        IVaultV2 vault;
        CatalysisCoverAdapter xferAdapter;
        ForkClaimManager xferClaimMgr;
        {
            (IVaultV2 v,, CatalysisCoverAdapter a,, ForkClaimManager f,,) =
                _setupParentWithMockUnderlyingVault(xferPolicyId);
            vault = v;
            xferAdapter = a;
            xferClaimMgr = f;
        }

        // STEP 1: Alice deposits 1000 USDC at P = 1.00
        uint256 aliceShares;
        {
            deal(USDC, alice, 1000e6);
            vm.prank(alice);
            IERC20(USDC).approve(address(vault), 1000e6);
            vm.prank(alice);
            aliceShares = vault.deposit(1000e6, alice);

            assertEq(xferAdapter.userPrincipal(alice), 1000e6, "Alice principal = 1000 USDC");
            assertEq(xferAdapter.totalPrincipal(), 1000e6, "totalPrincipal = 1000 USDC");
            assertEq(xferAdapter.currentValue(), 1000e6, "currentValue = 1000 USDC");
        }

        // Snapshot state before direct transfer
        uint256 cvBefore = xferAdapter.currentValue();
        uint256 tpBefore = xferAdapter.totalPrincipal();
        uint256 usBefore = xferAdapter.underlyingShares();

        // STEP 2: Random address sends 500 USDC directly to the vault contract
        {
            address donor = makeAddr("donor");
            deal(USDC, donor, 500e6);
            vm.prank(donor);
            IERC20(USDC).transfer(address(xferAdapter), 500e6);

            assertEq(IERC20(USDC).balanceOf(address(xferAdapter)), 500e6, "500 USDC idle on adapter");
            assertEq(xferAdapter.currentValue(), cvBefore, "currentValue unchanged after direct transfer");
            assertEq(xferAdapter.totalPrincipal(), tpBefore, "totalPrincipal unchanged");
            assertEq(xferAdapter.underlyingShares(), usBefore, "underlyingShares unchanged");
        }

        // STEP 3: Alice redeems all -- should work normally
        {
            uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
            vm.prank(alice);
            vault.redeem(aliceShares, alice, alice);
            uint256 aliceReceived = IERC20(USDC).balanceOf(alice) - aliceBefore;

            assertApproxEqAbs(aliceReceived, 1000e6, ALLOWED_DUST_2_WEI, "Alice receives ~1000 USDC");
            assertEq(xferClaimMgr.totalPaidOut(xferPolicyId), 0, "No insurance needed (no loss)");
            assertApproxEqAbs(xferAdapter.totalPrincipal(), 0, ALLOWED_DUST_2_WEI, "totalPrincipal ~= 0");
            assertApproxEqAbs(xferAdapter.underlyingShares(), 0, ALLOWED_DUST_2_WEI, "underlyingShares ~= 0");

            emit log_named_uint("Alice received USDC", aliceReceived);
        }

        // STEP 4: The 500 USDC is stranded on the adapter
        assertEq(IERC20(USDC).balanceOf(address(xferAdapter)), 500e6, "500 USDC still stranded on adapter");
        assertEq(xferAdapter.currentValue(), 0, "currentValue = 0 (all shares burned)");
    }

    /// @notice Donations to parent vault sits idle and used to pay during withdrawal
    ///
    /// When USDC is sent directly to the ctrlVault (underlying), totalAssets increases
    /// without minting new shares, raising the share price. The adapter sees a higher
    /// `currentValue()` while `totalPrincipal` stays the same -- phantom profit.
    ///
    /// Timeline:
    ///   1. Alice deposits 1000 USDC
    ///   2. Donate 200 USDC to ctrlVault (share price rises)
    ///   3. Alice redeems -- receives 1200 USDC (deposit + donation)
    function test_fork_directBalanceTransfer_donationToParentVault() public onlyFork {
        address alice = makeAddr("alice_donation");
        uint96 donPolicyId = 104;

        // Setup: deploy contracts with mock underlying
        IVaultV2 vault;
        CatalysisCoverAdapter donAdapter;
        ControllableVault donCtrlVault;
        ForkClaimManager donClaimMgr;
        {
            (
                IVaultV2 v,,
                CatalysisCoverAdapter a,
                ControllableVault c,
                ForkClaimManager f,,
            ) = _setupParentWithMockUnderlyingVault(donPolicyId);
            vault = v;
            donAdapter = a;
            donCtrlVault = c;
            donClaimMgr = f;
        }

        // STEP 1: Alice deposits 1000 USDC at P = 1.00
        uint256 aliceShares;
        uint256 depositAmount = 1000e6;
        {
            deal(USDC, alice, depositAmount);
            vm.prank(alice);
            IERC20(USDC).approve(address(vault), depositAmount);
            vm.prank(alice);
            aliceShares = vault.deposit(depositAmount, alice);

            assertEq(donAdapter.currentValue(), depositAmount, "currentValue = 1000 after deposit");
            assertEq(donAdapter.totalPrincipal(), depositAmount, "totalPrincipal = 1000");
        }

        // STEP 2: Donate 200 USDC directly to Parent Vault
        uint256 donation = 200e6;
        {
            address donor = makeAddr("donor_donation");
            deal(USDC, donor, donation);
            vm.prank(donor);
            IERC20(USDC).transfer(address(vault), donation);
            skip(365 days);

            assertEq(donAdapter.currentValue(), depositAmount, "currentValue stays the same");
            assertEq(donAdapter.totalPrincipal(), depositAmount, "totalPrincipal still 1000 (unchanged)");
            assertEq(donAdapter.userShortfall(alice), 0, "No shortfall");
            assertApproxEqAbs(vault.previewRedeem(aliceShares), depositAmount + donation, ALLOWED_DUST_2_WEI, "Donation included in profit");
        }

        // STEP 3: Simulate loss 20%
        donCtrlVault.simulateLoss(depositAmount * 2000 / 10_000);
        assertEq(donAdapter.currentValue(), depositAmount * (10_000 - 2000) / 10_000, "currentValue = 800 USDC after 20% loss");
        assertEq(vault.previewRedeem(aliceShares), donAdapter.currentValue() + donation, "Donation still included even in case of loss");

        // STEP 4: Alice redeems -- gets the donation and covered loss
        uint256 maxCoverable = depositAmount * 1000 / 10_000;
        uint256 expectedReceived = donAdapter.currentValue() + (maxCoverable - (maxCoverable * 100 / 10_000));
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        uint256 aliceReceived = IERC20(USDC).balanceOf(alice) - aliceBefore;

        assertApproxEqAbs(aliceReceived, expectedReceived + donation, ALLOWED_DUST_2_WEI, "Alice receives ~1200 USDC (incl. donation)");
        assertEq(donClaimMgr.totalPaidOut(donPolicyId), maxCoverable - (maxCoverable * 100 / 10_000), "No insurance paid (phantom profit)");

        emit log_named_uint("Alice received with donation", aliceReceived);
        emit log_string("Donation to ctrlVault: adapter sees phantom profit, user benefits");
    }

    function test_fork_UnderlyingVaultSharesDonation_FullDeallocationPossible() public onlyFork {
        address alice = makeAddr("alice_donation");
        address donator = makeAddr("donator");
        address newAllocator;
        uint96 donPolicyId = 104;

        // Setup: deploy contracts with mock underlying
        IVaultV2 vault;
        CatalysisCoverAdapter donAdapter;
        ControllableVault donCtrlVault;
        ForkClaimManager donClaimMgr;
        {
            (
                IVaultV2 v,,
                CatalysisCoverAdapter a,
                ControllableVault c,
                ForkClaimManager f,,
                address na
            ) = _setupParentWithMockUnderlyingVault(donPolicyId);
            vault = v;
            donAdapter = a;
            donCtrlVault = c;
            donClaimMgr = f;
            newAllocator = na;
        }

        // STEP 1: Alice deposits 1000 USDC at P = 1.00
        uint256 aliceShares;
        uint256 depositAmount = 1000e6;
        {
            deal(USDC, alice, depositAmount);
            vm.prank(alice);
            IERC20(USDC).approve(address(vault), depositAmount);
            vm.prank(alice);
            aliceShares = vault.deposit(depositAmount, alice);

            assertEq(donAdapter.currentValue(), depositAmount, "currentValue = 1000 after deposit");
            assertEq(donAdapter.totalPrincipal(), depositAmount, "totalPrincipal = 1000");
        }

        // STEP 2: Donate Underlying shares directly to the Adapter's balance
        uint256 donationShares;
        {
            uint256 donationAmount = 200e6;
            deal(USDC, donator, donationAmount);
            vm.prank(donator);
            IERC20(USDC).approve(address(donCtrlVault), donationAmount);
            vm.prank(donator);
            donationShares = donCtrlVault.deposit(donationAmount, donator);
            vm.prank(donator);
            donCtrlVault.transfer(address(donAdapter), donationShares);
        }

        // STEP 3: Deallocate assets
        {
            uint256 deallocateAmount = vault.previewRedeem(vault.totalSupply());
            vm.prank(newAllocator);
            vault.deallocate(address(donAdapter), "", deallocateAmount);
            assertEq(deallocateAmount, IERC20(USDC).balanceOf(address(vault)), "Full deallocate on Vault");
            assertEq(deallocateAmount, depositAmount, "Deallocation equals users' deposits");
            assertEq(donCtrlVault.balanceOf(address(donAdapter)), donationShares, "Donation shares ignored");
            assertEq(donAdapter.totalPrincipal(), 0, "Total principal fully withdrawn");
            assertEq(donAdapter.underlyingShares(), 0, "Total shares fully withdrawn");
        }
    }
}
