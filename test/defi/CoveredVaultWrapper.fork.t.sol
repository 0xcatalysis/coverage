// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";
import {IVaultV2} from "../../src/defi/interfaces/Morpho/IVaultV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";

import {MockPolicyManager, MockCoverPool} from "./mocks/Mocks.sol";
import {ForkClaimManager} from "./mocks/ForkClaimManager.sol";

/// @notice Minimal interface for Morpho VaultV2Factory
interface IVaultV2Factory {
    function createVaultV2(address owner, address asset, bytes32 salt) external returns (address);
}

/// @title CoveredVaultWrapperForkTest
/// @notice Fork tests for CoveredVaultWrapper on top of a real Morpho V2 vault
/// @dev Run with: FOUNDRY_PROFILE=fork forge test --match-contract CoveredVaultWrapperForkTest -vvv
///
///      Architecture under test:
///        User -> CoveredVaultWrapper (ERC-4626, UUPS) -> Morpho V2 vault (idle, no adapter)
///
///      The setUp() deploys a fresh V2 vault via the on-chain factory, deploys a CoveredVaultWrapper
///      pointing to it, binds a policy, and funds test users with real USDC.
///      The V2 vault runs in idle mode (no MorphoVaultV1Adapter) -- assets sit in the vault directly.
///      This is sufficient for testing the wrapper's ERC-4626 interaction with a real V2 vault.
contract CoveredVaultWrapperForkTest is Test {
    /*//////////////////////////////////////////////////////////////
                        MAINNET ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /// @dev Morpho Vault V2 Factory
    address constant VAULT_V2_FACTORY = 0xA1D94F746dEfa1928926b84fB2596c06926C0405;

    /// @dev USDC token
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev Pinned block for deterministic & cached fork
    uint256 constant FORK_BLOCK = 24_430_000;

    uint256 constant MAX_MAX_RATE = 200e16 / uint256(365 days);

    /*//////////////////////////////////////////////////////////////
                            STATE
    //////////////////////////////////////////////////////////////*/

    IVaultV2 morphoVault;
    CoveredVaultWrapper wrapper;

    MockPolicyManager policyManager;
    ForkClaimManager claimManager;
    MockCoverPool coverPool;

    address owner;
    address curator;
    address user1;
    address user2;
    address underlyingFeeRecipient;
    address premiumRecipientAddr;

    uint96 constant POLICY_ID = 1;
    uint16 constant MAX_COVERABLE_LOSS_BPS = 1000; // 10%
    uint16 constant DEDUCTIBLE_BPS = 100; // 1%
    uint256 constant COVERAGE_LIMIT = 100_000e6; // 100k USDC

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
        curator = makeAddr("curator");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        underlyingFeeRecipient = makeAddr("feeRecipient");
        premiumRecipientAddr = makeAddr("premiumRecipient");

        // -- 1. Create V2 vault via on-chain factory --
        vm.prank(owner);
        address vault = IVaultV2Factory(VAULT_V2_FACTORY).createVaultV2(owner, USDC, bytes32(uint256(block.timestamp)));
        morphoVault = IVaultV2(vault);
        vm.prank(owner);
        morphoVault.setCurator(curator);

        // -- 2. Deploy mock policy infrastructure --
        policyManager = new MockPolicyManager();
        claimManager = new ForkClaimManager(address(policyManager), USDC);
        coverPool = new MockCoverPool();

        // Fund claim manager with USDC for insurance payouts
        deal(USDC, address(claimManager), 1_000_000e6);

        // -- 3. Deploy CoveredVaultWrapper (UUPS proxy) --
        wrapper = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS,
            DEDUCTIBLE_BPS,
            premiumRecipientAddr,
            owner,
            "Covered USDC",
            "cvUSDC"
        );

        // -- 4. Setup mock policy (must satisfy onPolicyBound validations) --
        //       buyer = owner (wrapper.owner()), pool = coverPool,
        //       beneficiary = wrapper (mock sets claimer = beneficiary), payoutToken = USDC
        policyManager.setPolicy(
            POLICY_ID,
            owner, // buyer = wrapper.owner()
            address(coverPool), // pool
            address(wrapper), // beneficiary (and claimer via mock)
            USDC, // payoutToken = wrapper.asset()
            COVERAGE_LIMIT,
            uint32(block.timestamp),
            uint32(block.timestamp + 5 * 365 days)
        );

        // -- 5. Trigger onPolicyBound (sets policyId, depositCap) --
        policyManager.callOnPolicyBound(address(wrapper), POLICY_ID, COVERAGE_LIMIT);

        vm.prank(user1);
        IERC20(USDC).approve(address(wrapper), type(uint256).max);
        vm.prank(user2);
        IERC20(USDC).approve(address(wrapper), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyFork() {
        if (!forkActive) {
            vm.skip(true);
            return;
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploy CoveredVaultWrapper behind a UUPS proxy
    function _deployWrapperProxy(
        address morphoVault_,
        address claimManager_,
        address coverPool_,
        uint16 maxCoverableLossBps_,
        uint16 deductibleBps_,
        address premiumRecipient_,
        address owner_,
        string memory name_,
        string memory symbol_
    )
        internal
        returns (CoveredVaultWrapper)
    {
        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "CoveredVaultWrapper.sol",
            abi.encodeCall(
                CoveredVaultWrapper.initialize,
                (
                    morphoVault_,
                    claimManager_,
                    coverPool_,
                    maxCoverableLossBps_,
                    deductibleBps_,
                    premiumRecipient_,
                    owner_,
                    name_,
                    symbol_
                )
            ),
            deployOpts
        );
        return CoveredVaultWrapper(proxy);
    }

    /// @dev Deal USDC to user, deposit into wrapper
    function _userDeposit(address user, uint256 amount) internal returns (uint256 shares) {
        deal(USDC, user, IERC20(USDC).balanceOf(user) + amount);
        vm.startPrank(user);
        IERC20(USDC).approve(address(wrapper), amount);
        shares = wrapper.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev User redeems all wrapper shares
    function _userRedeemAll(address user) internal returns (uint256 assets) {
        uint256 shares = wrapper.balanceOf(user);
        vm.prank(user);
        assets = wrapper.redeem(shares, user, user);
    }

    function _curatorSubmitExec(bytes memory data) internal {
        vm.prank(curator);
        (bool ok,) = address(morphoVault).call(abi.encodeWithSignature("submit(bytes)", data));
        require(ok, "submit failed");
        vm.prank(curator);
        (ok,) = address(morphoVault).call(data);
        require(ok, "execute failed");
    }

    function test_fork_UnderlyingVaultFee_LossCount() public onlyFork {
        // Setup management fee for Underlying Morpho Vault
        uint256 feePerSec = uint256(0.02e18) / uint256(365 days); // ~2% annual
        _curatorSubmitExec(abi.encodeWithSignature("setManagementFeeRecipient(address)", underlyingFeeRecipient));
        _curatorSubmitExec(abi.encodeWithSignature("setManagementFee(uint256)", feePerSec));

        // User1 deposit
        uint256 depositAmount = 1000e6;
        _userDeposit(user1, depositAmount);

        // Skip one year to accrue 2% Morpho management fee.
        // Premium accrual is 0 in wrapper (premium rate already includes expected loss component).
        skip(365 days);

        // User redeem
        _userRedeemAll(user1);

        // The 2% Morpho management fee is taken from underlying assets.
        // Morpho returns ~980e6 after the fee.
        // Since the premium rate already accounts for expected loss, no separate EL deduction occurs.
        // insuredBasis = 1000e6 - 0 (no wrapper premium) = 1000e6.
        // shortfall = max(0, 1000e6 - 980e6) = 20e6 (the fee is a real loss).
        //   maxInsurable = 10% of 1000e6 = 100e6, capped to 20e6
        //   claimAmount = 20e6 * 99% (1% deductible) = 19.8e6
        // User receives: ~980 (Morpho) + ~19.8 (insurance) ≈ 999.8 USDC
        assertEq(IERC20(USDC).balanceOf(user1), 999_800_000, "User received Morpho proceeds + insurance");
        assertEq(claimManager.policyClaim(POLICY_ID).totalPaidOut, 19_799_999, "Insurance covers fee loss");
    }

    function test_fork_UnderlyingVaultFee_ProfitCoversFee() public onlyFork {
        // Setup management fee for Underlying Morpho Vault
        uint256 feePerSec = uint256(0.02e18) / uint256(365 days); // ~2% annual
        _curatorSubmitExec(abi.encodeWithSignature("setIsAllocator(address,bool)", curator, true));
        vm.prank(curator);
        morphoVault.setMaxRate(MAX_MAX_RATE);
        _curatorSubmitExec(abi.encodeWithSignature("setManagementFeeRecipient(address)", underlyingFeeRecipient));
        _curatorSubmitExec(abi.encodeWithSignature("setManagementFee(uint256)", feePerSec));

        // User1 deposit
        uint256 depositAmount = 1000e6;
        _userDeposit(user1, depositAmount);

        // Add 5% Value to the Underlying Vault
        // This should cover underlying fee and not trigger insurance payout
        deal(USDC, address(morphoVault), depositAmount + depositAmount * 5 / 100);

        // Skip one year to accrue 2% Morpho management fee
        skip(365 days);

        // User redeem
        _userRedeemAll(user1);

        // Check received amount
        assertGt(IERC20(USDC).balanceOf(user1), depositAmount, "User received profit from underlying vault");
        assertEq(claimManager.policyClaim(POLICY_ID).totalPaidOut, 0, "Insurance payout wasn't triggered");
    }

    function test_fork_UnderlyingVaultFee_OnlyLossCovered() public onlyFork {
        // Setup management fee for Underlying Morpho Vault
        uint256 feePerSec = uint256(0.02e18) / uint256(365 days); // ~2% annual
        _curatorSubmitExec(abi.encodeWithSignature("setIsAllocator(address,bool)", curator, true));
        vm.prank(curator);
        morphoVault.setMaxRate(MAX_MAX_RATE);
        _curatorSubmitExec(abi.encodeWithSignature("setManagementFeeRecipient(address)", underlyingFeeRecipient));
        _curatorSubmitExec(abi.encodeWithSignature("setManagementFee(uint256)", feePerSec));

        // User1 deposit
        uint256 depositAmount = 1000e6;
        _userDeposit(user1, depositAmount);

        // Skip one year to accrue 2% Morpho management fee
        skip(365 days);

        // Simulate 1% hack loss on top of the fee
        deal(USDC, address(morphoVault), depositAmount - depositAmount * 1 / 100);

        // User redeem
        _userRedeemAll(user1);

        // After 2% Morpho fee + 1% hack loss, Morpho returns ~970.2 USDC.
        // Premium rate already includes the expected loss component, so no separate EL deduction.
        // insuredBasis = 1000e6 - 0 (no wrapper premium) = 1000e6.
        // shortfall = max(0, 1000e6 - 970.2e6) = 29.8e6 (fee + hack loss are both real losses).
        //   maxInsurable = 10% of 1000e6 = 100e6, capped to 29.8e6
        //   claimAmount = 29.8e6 * 99% (1% deductible) ≈ 29.50e6
        // User receives: ~970.2 (Morpho) + ~29.50 (insurance) ≈ 999.7 USDC
        assertEq(IERC20(USDC).balanceOf(user1), 999_702_000, "User received insurance for fee + hack loss");
        assertEq(claimManager.policyClaim(POLICY_ID).totalPaidOut, 29_501_999, "Insurance covers fee + hack shortfall");
    }
}
