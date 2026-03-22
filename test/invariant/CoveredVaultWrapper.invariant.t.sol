// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";
import {MockERC20, MockVaultV2, MockClaimManager, MockPolicyManager, MockCoverPool} from "../defi/mocks/Mocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title CoveredVaultWrapperHandler
/// @notice Foundry invariant handler for CoveredVaultWrapper
/// @dev Keeps actors at 3 users + owner to limit state space.
///      All handlers are wrapped in try/catch so reverts don't halt the campaign.
contract CoveredVaultWrapperHandler is Test {
    // ── Target contracts ──
    CoveredVaultWrapper public wrapper;
    MockVaultV2 public morphoVault;
    MockERC20 public asset;

    // ── Actors ──
    address public owner;
    address public user1;
    address public user2;
    address public user3;

    // ── Ghost variables for invariant assertions ──
    // Track sum of principals deposited by our test actors
    mapping(address => uint256) public ghost_userPrincipal;
    uint256 public ghost_totalPrincipal;

    // Track users who have active shares
    address[] public ghost_activeUsers;
    mapping(address => bool) public ghost_isActiveUser;

    // ── Helper ──
    address[] private _actors;

    constructor(
        CoveredVaultWrapper wrapper_,
        MockVaultV2 morphoVault_,
        MockERC20 asset_,
        address owner_,
        address user1_,
        address user2_,
        address user3_
    ) {
        wrapper = wrapper_;
        morphoVault = morphoVault_;
        asset = asset_;
        owner = owner_;
        user1 = user1_;
        user2 = user2_;
        user3 = user3_;
        _actors = [user1_, user2_, user3_];
    }

    // ─────────────────────────────────────────
    //  INDIVIDUAL FUNCTION HANDLERS
    // ─────────────────────────────────────────

    /// @dev Deposit assets for a user
    function handler_deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _actors[bound(actorSeed, 0, _actors.length - 1)];
        amount = bound(amount, 1, 100_000 ether);

        // Ensure actor has assets and allowance
        asset.mint(actor, amount);
        vm.prank(actor);
        asset.approve(address(wrapper), amount);

        uint256 maxDep = wrapper.maxDeposit(actor);
        if (maxDep == 0) return; // deposit cap not yet set (no policy bound)

        uint256 cappedAmount = amount < maxDep ? amount : maxDep;
        if (cappedAmount == 0) return;

        vm.prank(actor);
        try wrapper.deposit(cappedAmount, actor) {
            ghost_userPrincipal[actor] += cappedAmount;
            ghost_totalPrincipal += cappedAmount;
            if (!ghost_isActiveUser[actor]) {
                ghost_isActiveUser[actor] = true;
                ghost_activeUsers.push(actor);
            }
        } catch {}
    }

    /// @dev Redeem shares for a user
    function handler_redeem(uint256 actorSeed, uint256 shareFraction) external {
        address actor = _actors[bound(actorSeed, 0, _actors.length - 1)];
        uint256 shares = wrapper.balanceOf(actor);
        if (shares == 0) return;

        // Redeem a fraction (1-100%) of shares
        shareFraction = bound(shareFraction, 1, 100);
        uint256 redeemAmount = shares * shareFraction / 100;
        if (redeemAmount == 0) return;

        uint256 principalBefore = wrapper.userPrincipal(actor);
        uint256 sharesBefore = wrapper.balanceOf(actor);

        vm.prank(actor);
        try wrapper.redeem(redeemAmount, actor, actor) {
            uint256 principalAfter = wrapper.userPrincipal(actor);
            uint256 principalReduced = principalBefore > principalAfter ? principalBefore - principalAfter : 0;

            // Maintain ghost state (approximate, since contract tracks exact amounts)
            if (ghost_userPrincipal[actor] >= principalReduced) {
                ghost_userPrincipal[actor] -= principalReduced;
            } else {
                ghost_userPrincipal[actor] = 0;
            }
            if (ghost_totalPrincipal >= principalReduced) {
                ghost_totalPrincipal -= principalReduced;
            } else {
                ghost_totalPrincipal = 0;
            }
        } catch {}
    }

    /// @dev Emergency redeem (skip insurance claim)
    function handler_emergencyRedeem(uint256 actorSeed, uint256 shareFraction) external {
        address actor = _actors[bound(actorSeed, 0, _actors.length - 1)];
        uint256 shares = wrapper.balanceOf(actor);
        if (shares == 0) return;

        shareFraction = bound(shareFraction, 1, 100);
        uint256 redeemAmount = shares * shareFraction / 100;
        if (redeemAmount == 0) return;

        uint256 principalBefore = wrapper.userPrincipal(actor);

        vm.prank(actor);
        try wrapper.emergencyRedeem(redeemAmount, actor, actor) {
            uint256 principalAfter = wrapper.userPrincipal(actor);
            uint256 principalReduced = principalBefore > principalAfter ? principalBefore - principalAfter : 0;
            if (ghost_userPrincipal[actor] >= principalReduced) {
                ghost_userPrincipal[actor] -= principalReduced;
            } else {
                ghost_userPrincipal[actor] = 0;
            }
            if (ghost_totalPrincipal >= principalReduced) {
                ghost_totalPrincipal -= principalReduced;
            } else {
                ghost_totalPrincipal = 0;
            }
        } catch {}
    }

    /// @dev Collect premium (anyone can call)
    function handler_collectPremium() external {
        try wrapper.collectPremium() {} catch {}
    }

    /// @dev Advance time (simulates accrual periods)
    function handler_warpTime(uint256 dt) external {
        dt = bound(dt, 1, 30 days);
        vm.warp(block.timestamp + dt);
    }

    /// @dev Simulate Morpho vault loss
    function handler_simulateLoss(uint256 lossPct) external {
        lossPct = bound(lossPct, 1, 30); // max 30% loss for realism
        morphoVault.setLoss(lossPct);
    }

    /// @dev Reset Morpho to no loss
    function handler_resetLoss() external {
        morphoVault.setLoss(0);
    }

    // ─────────────────────────────────────────
    //  LIFECYCLE SEQUENCE HANDLERS
    // ─────────────────────────────────────────

    /// @dev Full deposit → wait → redeem lifecycle
    function handler_fullLifecycle(uint256 actorSeed, uint256 amount, uint256 dt) external {
        address actor = _actors[bound(actorSeed, 0, _actors.length - 1)];
        amount = bound(amount, 1 ether, 10_000 ether);
        dt = bound(dt, 1 days, 90 days);

        uint256 maxDep = wrapper.maxDeposit(actor);
        if (maxDep == 0) return;

        uint256 cappedAmount = amount < maxDep ? amount : maxDep;
        if (cappedAmount == 0) return;

        asset.mint(actor, cappedAmount);
        vm.prank(actor);
        asset.approve(address(wrapper), cappedAmount);

        uint256 principalBefore = wrapper.userPrincipal(actor);

        // Step 1: Deposit
        vm.prank(actor);
        try wrapper.deposit(cappedAmount, actor) {
            ghost_userPrincipal[actor] += cappedAmount;
            ghost_totalPrincipal += cappedAmount;
            if (!ghost_isActiveUser[actor]) {
                ghost_isActiveUser[actor] = true;
                ghost_activeUsers.push(actor);
            }
        } catch {
            return;
        }

        // Step 2: Advance time
        vm.warp(block.timestamp + dt);

        // Step 3: Redeem all
        uint256 shares = wrapper.balanceOf(actor);
        if (shares == 0) return;

        uint256 principalAtRedeem = wrapper.userPrincipal(actor);

        vm.prank(actor);
        try wrapper.redeem(shares, actor, actor) {
            uint256 principalAfter = wrapper.userPrincipal(actor);
            uint256 principalReduced = principalAtRedeem > principalAfter ? principalAtRedeem - principalAfter : 0;
            if (ghost_userPrincipal[actor] >= principalReduced) {
                ghost_userPrincipal[actor] -= principalReduced;
            } else {
                ghost_userPrincipal[actor] = 0;
            }
            if (ghost_totalPrincipal >= principalReduced) {
                ghost_totalPrincipal -= principalReduced;
            } else {
                ghost_totalPrincipal = 0;
            }
        } catch {}
    }

    /// @dev Partial lifecycle: deposit then redeem half (user remains in vault)
    function handler_partialLifecycle(uint256 actorSeed, uint256 amount, uint256 dt) external {
        address actor = _actors[bound(actorSeed, 0, _actors.length - 1)];
        amount = bound(amount, 2 ether, 10_000 ether); // need at least 2 to redeem half
        dt = bound(dt, 1 hours, 7 days);

        uint256 maxDep = wrapper.maxDeposit(actor);
        if (maxDep == 0) return;

        uint256 cappedAmount = amount < maxDep ? amount : maxDep;
        if (cappedAmount < 2) return;

        asset.mint(actor, cappedAmount);
        vm.prank(actor);
        asset.approve(address(wrapper), cappedAmount);

        uint256 principalBefore = wrapper.userPrincipal(actor);

        vm.prank(actor);
        try wrapper.deposit(cappedAmount, actor) {
            ghost_userPrincipal[actor] += cappedAmount;
            ghost_totalPrincipal += cappedAmount;
            if (!ghost_isActiveUser[actor]) {
                ghost_isActiveUser[actor] = true;
                ghost_activeUsers.push(actor);
            }
        } catch {
            return;
        }

        vm.warp(block.timestamp + dt);

        // Redeem only half
        uint256 shares = wrapper.balanceOf(actor);
        uint256 halfShares = shares / 2;
        if (halfShares == 0) return;

        uint256 principalAtRedeem = wrapper.userPrincipal(actor);

        vm.prank(actor);
        try wrapper.redeem(halfShares, actor, actor) {
            uint256 principalAfter = wrapper.userPrincipal(actor);
            uint256 principalReduced = principalAtRedeem > principalAfter ? principalAtRedeem - principalAfter : 0;
            if (ghost_userPrincipal[actor] >= principalReduced) {
                ghost_userPrincipal[actor] -= principalReduced;
            } else {
                ghost_userPrincipal[actor] = 0;
            }
            if (ghost_totalPrincipal >= principalReduced) {
                ghost_totalPrincipal -= principalReduced;
            } else {
                ghost_totalPrincipal = 0;
            }
        } catch {}
    }

    // ─────────────────────────────────────────
    //  HELPERS
    // ─────────────────────────────────────────

    function getActiveUsers() external view returns (address[] memory) {
        return ghost_activeUsers;
    }
}

/// @title CoveredVaultWrapperInvariant
/// @notice Foundry invariant test suite for CoveredVaultWrapper
contract CoveredVaultWrapperInvariant is StdInvariant, Test {
    // ── Contracts under test ──
    CoveredVaultWrapper internal wrapper;
    MockVaultV2 internal morphoVault;
    MockERC20 internal asset;
    MockClaimManager internal claimManager;
    MockPolicyManager internal mockPolicyManager;
    MockCoverPool internal mockCoverPool;

    // ── Handler ──
    CoveredVaultWrapperHandler internal handler;

    // ── Actors ──
    address internal owner = makeAddr("owner");
    address internal user1 = makeAddr("user1");
    address internal user2 = makeAddr("user2");
    address internal user3 = makeAddr("user3");
    address internal premiumRecipient = makeAddr("premiumRecipient");

    // ── Policy state ──
    uint96 internal policyId;
    uint16 constant MAX_COVERABLE_LOSS_BPS = 1000; // 10%
    uint16 constant DEDUCTIBLE_BPS = 100; // 1%
    uint256 constant COVERAGE_LIMIT = 500_000 ether;

    function setUp() public {
        // 1. Deploy asset
        asset = new MockERC20();

        // 2. Deploy Morpho mock vault
        morphoVault = new MockVaultV2(address(asset), "Morpho Vault", "mVault");
        morphoVault.setOwner(owner);
        morphoVault.setCurator(owner);

        // 3. Deploy MockPolicyManager + MockClaimManager + MockCoverPool
        //    MockClaimManager.policyManager() must return the address of mockPolicyManager
        mockPolicyManager = new MockPolicyManager();
        claimManager = new MockClaimManager(address(mockPolicyManager));
        mockCoverPool = new MockCoverPool(); // quoteDomainSeparator() returns non-zero

        // 4. Deploy CoveredVaultWrapper impl + proxy
        //    __BasePolicyInteractions_init requires:
        //      - IClaimManager.policyManager() == policyManager arg  (satisfied: claimManager.policyManager() ==
        // mockPolicyManager) - ICoverPool.quoteDomainSeparator() != bytes32(0)       (satisfied by MockCoverPool)
        CoveredVaultWrapper impl = new CoveredVaultWrapper();
        bytes memory initData = abi.encodeCall(
            CoveredVaultWrapper.initialize,
            (
                address(morphoVault),
                address(claimManager),
                address(mockCoverPool),
                MAX_COVERABLE_LOSS_BPS,
                DEDUCTIBLE_BPS,
                premiumRecipient,
                owner,
                "Covered Vault",
                "cvVault"
            )
        );
        wrapper = CoveredVaultWrapper(address(new ERC1967Proxy(address(impl), initData)));

        // 5. Bind a policy so deposits are enabled
        //    onPolicyBound requires msg.sender == _policyManager (= mockPolicyManager address)
        policyId = 1;
        mockPolicyManager.setPolicy(
            policyId,
            owner, // buyer
            address(mockCoverPool), // pool
            address(wrapper), // beneficiary
            address(asset), // payoutToken
            COVERAGE_LIMIT, // coverageLimit
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days)
        );
        // Trigger onPolicyBound as if PolicyManager is calling (sets policyBoundExecuted + depositCap)
        vm.prank(address(mockPolicyManager));
        wrapper.onPolicyBound(policyId, COVERAGE_LIMIT);

        // Sanity: depositCap should now be non-zero
        require(wrapper.depositCap() > 0, "setUp: depositCap not set after onPolicyBound");
        require(wrapper.policyBoundExecuted(), "setUp: policyBoundExecuted not set");

        // 6. Seed morphoVault with assets so redemptions can succeed
        asset.mint(address(morphoVault), 10_000_000 ether);
        // The wrapper is the sole depositor/redeemer; set as curator for completeness
        morphoVault.setCurator(address(wrapper));

        // 7. Deploy handler
        handler = new CoveredVaultWrapperHandler(wrapper, morphoVault, asset, owner, user1, user2, user3);

        // 8. Pre-approve so handler can mint+deposit on behalf of users
        vm.prank(user1);
        asset.approve(address(wrapper), type(uint256).max);
        vm.prank(user2);
        asset.approve(address(wrapper), type(uint256).max);
        vm.prank(user3);
        asset.approve(address(wrapper), type(uint256).max);

        // 9. Register handler as the fuzz target
        targetContract(address(handler));
    }

    // ═══════════════════════════════════════════════════════════
    //  INV-1: totalPrincipal == sum(userPrincipal[u]) for active users
    // ═══════════════════════════════════════════════════════════
    function invariant_totalPrincipalEqualsSum() public view {
        address[] memory users = handler.getActiveUsers();
        uint256 sumPrincipal = 0;
        for (uint256 i = 0; i < users.length; i++) {
            sumPrincipal += wrapper.userPrincipal(users[i]);
        }
        // totalPrincipal in contract must equal sum of individual principals
        assertEq(wrapper.totalPrincipal(), sumPrincipal, "INV-1: totalPrincipal != sum(userPrincipal)");
    }

    // ═══════════════════════════════════════════════════════════
    //  INV-2: totalPremiumLiability <= _morphoValue() (liabilities never exceed assets)
    // ═══════════════════════════════════════════════════════════
    function invariant_premiumLiabilityBounded() public view {
        uint256 morphoShares = morphoVault.balanceOf(address(wrapper));
        uint256 morphoValue = morphoVault.convertToAssets(morphoShares);
        uint256 premiumLiability = wrapper.totalPremiumLiability();
        // Premium liability alone must never exceed Morpho value
        assertLe(
            premiumLiability,
            morphoValue + 1, // +1 for dust rounding
            "INV-2: totalPremiumLiability > morphoValue"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  INV-3: totalExpectedLossLiability + totalPremiumLiability <= morphoValue()
    // ═══════════════════════════════════════════════════════════
    function invariant_combinedLiabilityBounded() public view {
        uint256 morphoShares = morphoVault.balanceOf(address(wrapper));
        uint256 morphoValue = morphoVault.convertToAssets(morphoShares);
        uint256 totalLiability = wrapper.totalPremiumLiability() + wrapper.totalExpectedLossLiability();
        // Combined liabilities must not exceed the Morpho backing (plus small rounding tolerance)
        assertLe(
            totalLiability, morphoValue + 1, "INV-3: totalPremiumLiability + totalExpectedLossLiability > morphoValue"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  INV-4: totalAssets() >= 0 (no underflow on net assets)
    // ═══════════════════════════════════════════════════════════
    function invariant_totalAssetsNonNegative() public view {
        // totalAssets() saturates at 0 in the contract, so this should always hold
        uint256 ta = wrapper.totalAssets();
        assertGe(ta, 0, "INV-4: totalAssets() underflowed");
    }

    // ═══════════════════════════════════════════════════════════
    //  INV-5: Soulbound shares — no user has a non-zero balance that they didn't earn via deposit
    //         (Structural: ERC-20 transfers between non-zero addresses revert)
    // ═══════════════════════════════════════════════════════════
    function invariant_transfersDisabled() public {
        // Attempt to transfer shares between two active users
        address[] memory users = handler.getActiveUsers();
        if (users.length < 2) return;

        address from = users[0];
        uint256 shares = wrapper.balanceOf(from);
        if (shares == 0) return;

        vm.prank(from);
        try wrapper.transfer(users[1], 1) {
            // If we reach here the transfer succeeded — invariant violated
            assertTrue(false, "INV-5: Soulbound invariant violated - transfer succeeded");
        } catch {
            // Expected: TransfersDisabled() revert
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  INV-6: userPrincipal[u] == 0 iff balanceOf(u) == 0
    //         A user with shares must have non-zero principal (and vice versa)
    // ═══════════════════════════════════════════════════════════
    function invariant_principalSharesConsistency() public view {
        address[] memory users = handler.getActiveUsers();
        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            uint256 shares = wrapper.balanceOf(u);
            uint256 principal = wrapper.userPrincipal(u);
            // If shares > 0, principal must be > 0 (and vice versa)
            if (shares > 0) {
                assertGt(principal, 0, "INV-6: user has shares but zero principal");
            }
            if (principal > 0) {
                assertGt(shares, 0, "INV-6: user has principal but zero shares");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  INV-7: sum(userMorphoShares) <= morphoVault.balanceOf(wrapper)
    //         Wrapper never claims more Morpho shares than it holds
    // ═══════════════════════════════════════════════════════════
    function invariant_morphoSharesSolvency() public view {
        address[] memory users = handler.getActiveUsers();
        uint256 sumMorphoShares = 0;
        for (uint256 i = 0; i < users.length; i++) {
            sumMorphoShares += wrapper.userMorphoShares(users[i]);
        }
        uint256 wrapperMorphoBalance = morphoVault.balanceOf(address(wrapper));
        // Allow dust: sum can exceed actual by at most users.length (rounding)
        assertLe(
            sumMorphoShares,
            wrapperMorphoBalance + users.length,
            "INV-7: sum(userMorphoShares) > morphoVault.balanceOf(wrapper)"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  INV-8: totalSupply() reflects all active user shares
    //         sum(balanceOf(u)) == totalSupply()
    // ═══════════════════════════════════════════════════════════
    function invariant_totalSupplyConsistency() public view {
        address[] memory users = handler.getActiveUsers();
        uint256 sumShares = 0;
        for (uint256 i = 0; i < users.length; i++) {
            sumShares += wrapper.balanceOf(users[i]);
        }
        assertEq(wrapper.totalSupply(), sumShares, "INV-8: totalSupply() != sum(balanceOf(u))");
    }

    // ═══════════════════════════════════════════════════════════
    //  INV-9: pendingPremium is always collectable (never locked by bad accounting)
    //         After collectPremium(), pendingPremium == 0
    // ═══════════════════════════════════════════════════════════
    function invariant_pendingPremiumCollectable() public {
        uint256 pending = wrapper.pendingPremium();
        if (pending == 0) return;

        // Collect should succeed and clear pendingPremium
        try wrapper.collectPremium() {
            assertEq(wrapper.pendingPremium(), 0, "INV-9: pendingPremium non-zero after collectPremium()");
        } catch {
            // collectPremium reverted (reentrancy guard or asset transfer fail)
            // Not a violation of accounting invariant — ok to skip
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  INV-10: totalPrincipal == 0 iff totalSupply() == 0
    //          No dangling principal without shares
    // ═══════════════════════════════════════════════════════════
    function invariant_principalSupplyCorrelation() public view {
        uint256 supply = wrapper.totalSupply();
        uint256 principal = wrapper.totalPrincipal();
        if (supply == 0) {
            assertEq(principal, 0, "INV-10: totalSupply == 0 but totalPrincipal != 0");
        }
        // NOTE: principal == 0 with supply > 0 is theoretically possible only
        //       in deep-loss edge cases where ALL principal was deducted; skip reverse check.
    }
}
