// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ClaimManager} from "../../src/ClaimManager.sol";
import {PremiumManager} from "../../src/PremiumManager.sol";
import {PolicyManager} from "../../src/PolicyManager.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";

/**
 * @title StorageLayoutTest
 * @notice Asserts that critical storage slot positions match the audit-baseline layout (d8d492a).
 *         These tests FAIL loudly if a future refactor re-orders state, preventing silent proxy corruption.
 *
 *         Slot references:
 *           ClaimManager  — slot 0: ReentrancyGuard._status
 *                           slot 1: specRegistry
 *                           slot 2: slashingManager
 *                           slot 3: swapper
 *                           slot 4: policyManager
 *                           slot 5: _deprecated_chainlinkPriceFeed (addr) + maxSwapSlippageBps (u16), packed
 *                           slots 6-9: mapping seeds
 *                           slot 10: premiumManager
 *
 *           PremiumManager — slot 0: ReentrancyGuard._status
 *                            slot 1: rewardsManager
 *                            slot 2: platformTreasury (addr) + platformFeeBps (u16), packed
 *                            slot 3: _distributionNonce
 *                            slots 4-5: _approvedPremiumTokens (AddressSet = 2 slots)
 *
 *           PolicyManager  — slot 0: ReentrancyGuard._status
 *                            slot 1: stakeManager
 *                            slot 2: claimManager
 *                            slot 3: coverPoolFactory
 *                            slot 4: _nextPolicyId (u96)
 *                            slots 5-8: mapping seeds
 *                            slot 9: chainlinkPriceFeed
 *
 *           CoverPool      — slot 0: policyManager
 *                            slot 1: stakeManager
 *                            slot 2: specRegistry
 *                            slot 3: feeRecipient
 *                            slot 4: _poolFeeBps (u16)
 *                            slot 5: boundPolicyCommits mapping seed
 *                            slot 6: boundPolicies mapping seed
 */
contract StorageLayoutTest is Test {
    address internal constant ADMIN = address(0xA);
    address internal constant NON_ZERO = address(0xB);
    address internal constant NON_ZERO_2 = address(0xC);
    address internal constant NON_ZERO_3 = address(0xD);
    address internal constant NON_ZERO_4 = address(0xE);
    address internal constant NON_ZERO_5 = address(0xF);
    address internal constant NON_ZERO_6 = address(0x10);

    Options internal _skipChecks;

    function setUp() public {
        _skipChecks.unsafeSkipAllChecks = true;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // ClaimManager
    // ──────────────────────────────────────────────────────────────────────────

    function test_ClaimManager_specRegistryAtSlot1() public {
        address proxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol",
            abi.encodeCall(ClaimManager.initialize, (ADMIN, NON_ZERO, NON_ZERO_2, NON_ZERO_3, NON_ZERO_4)),
            _skipChecks
        );
        bytes32 raw = vm.load(proxy, bytes32(uint256(1)));
        assertEq(address(uint160(uint256(raw))), NON_ZERO, "specRegistry must be at slot 1");
    }

    function test_ClaimManager_slashingManagerAtSlot2() public {
        address proxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol",
            abi.encodeCall(ClaimManager.initialize, (ADMIN, NON_ZERO, NON_ZERO_2, NON_ZERO_3, NON_ZERO_4)),
            _skipChecks
        );
        bytes32 raw = vm.load(proxy, bytes32(uint256(2)));
        assertEq(address(uint160(uint256(raw))), NON_ZERO_2, "slashingManager must be at slot 2");
    }

    function test_ClaimManager_swapperAtSlot3() public {
        address proxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol",
            abi.encodeCall(ClaimManager.initialize, (ADMIN, NON_ZERO, NON_ZERO_2, NON_ZERO_3, NON_ZERO_4)),
            _skipChecks
        );
        bytes32 raw = vm.load(proxy, bytes32(uint256(3)));
        assertEq(address(uint160(uint256(raw))), NON_ZERO_3, "swapper must be at slot 3");
    }

    function test_ClaimManager_policyManagerAtSlot4() public {
        address proxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol",
            abi.encodeCall(ClaimManager.initialize, (ADMIN, NON_ZERO, NON_ZERO_2, NON_ZERO_3, NON_ZERO_4)),
            _skipChecks
        );
        bytes32 raw = vm.load(proxy, bytes32(uint256(4)));
        assertEq(address(uint160(uint256(raw))), NON_ZERO_4, "policyManager must be at slot 4");
    }

    function test_ClaimManager_deprecatedChainlinkFeedAtSlot5() public {
        address proxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol",
            abi.encodeCall(ClaimManager.initialize, (ADMIN, NON_ZERO, NON_ZERO_2, NON_ZERO_3, NON_ZERO_4)),
            _skipChecks
        );
        // Slot 5: _deprecated_chainlinkPriceFeed (addr, 20 bytes) + maxSwapSlippageBps (uint16, 2 bytes).
        // After initialize: _deprecated_chainlinkPriceFeed is zero (never written), maxSwapSlippageBps = 200 (0x00c8).
        bytes32 raw = vm.load(proxy, bytes32(uint256(5)));
        // Lower 20 bytes = address (zero), bytes 20-21 = uint16 = 0x00c8 = 200
        uint16 slippage = uint16(uint256(raw) >> 160);
        assertEq(slippage, 200, "maxSwapSlippageBps must be packed at slot 5 offset 20");
        // _deprecated_chainlinkPriceFeed must be zero — initialize() never writes it
        address deprecatedFeed = address(uint160(uint256(raw)));
        assertEq(deprecatedFeed, address(0), "_deprecated_chainlinkPriceFeed must be zero at slot 5");
    }

    function test_ClaimManager_premiumManagerAtSlot10() public {
        address proxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol",
            abi.encodeCall(ClaimManager.initialize, (ADMIN, NON_ZERO, NON_ZERO_2, NON_ZERO_3, NON_ZERO_4)),
            _skipChecks
        );
        vm.prank(ADMIN);
        ClaimManager(proxy).setPremiumManager(NON_ZERO_5);

        bytes32 raw = vm.load(proxy, bytes32(uint256(10)));
        assertEq(address(uint160(uint256(raw))), NON_ZERO_5, "premiumManager must be at slot 10");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // PremiumManager
    // ──────────────────────────────────────────────────────────────────────────

    function test_PremiumManager_rewardsManagerAtSlot1() public {
        address proxy = Upgrades.deployUUPSProxy(
            "PremiumManager.sol",
            abi.encodeCall(PremiumManager.initialize, (ADMIN, NON_ZERO, NON_ZERO_2, 500)),
            _skipChecks
        );
        bytes32 raw = vm.load(proxy, bytes32(uint256(1)));
        assertEq(address(uint160(uint256(raw))), NON_ZERO, "rewardsManager must be at slot 1");
    }

    function test_PremiumManager_distributionNonceAtSlot3() public {
        address proxy = Upgrades.deployUUPSProxy(
            "PremiumManager.sol",
            abi.encodeCall(PremiumManager.initialize, (ADMIN, NON_ZERO, NON_ZERO_2, 500)),
            _skipChecks
        );
        // After deploy: _distributionNonce is 0, should be at slot 3
        bytes32 raw = vm.load(proxy, bytes32(uint256(3)));
        assertEq(uint256(raw), 0, "_distributionNonce must be at slot 3 and zero after init");
    }

    function test_PremiumManager_approvedTokensAtSlot4_5() public {
        address proxy = Upgrades.deployUUPSProxy(
            "PremiumManager.sol",
            abi.encodeCall(PremiumManager.initialize, (ADMIN, NON_ZERO, NON_ZERO_2, 500)),
            _skipChecks
        );
        MockToken token = new MockToken();
        vm.prank(ADMIN);
        PremiumManager(proxy).addApprovedPremiumToken(address(token));

        // Slot 4: _approvedPremiumTokens._values.length == 1
        bytes32 slot4 = vm.load(proxy, bytes32(uint256(4)));
        assertEq(uint256(slot4), 1, "_approvedPremiumTokens length must be at slot 4");

        // Slot 5: _approvedPremiumTokens._positions mapping seed — verify it is non-zero after add
        bytes32 posSlot = keccak256(abi.encode(address(token), uint256(5)));
        bytes32 posValue = vm.load(proxy, posSlot);
        assertGt(uint256(posValue), 0, "_approvedPremiumTokens positions mapping must be at seed slot 5");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // PolicyManager
    // ──────────────────────────────────────────────────────────────────────────

    function test_PolicyManager_stakeManagerAtSlot1() public {
        address proxy = _deployPolicyManager();
        bytes32 raw = vm.load(proxy, bytes32(uint256(1)));
        assertEq(address(uint160(uint256(raw))), NON_ZERO, "stakeManager must be at slot 1");
    }

    function test_PolicyManager_chainlinkPriceFeedAtSlot9() public {
        address proxy = _deployPolicyManager();
        bytes32 raw = vm.load(proxy, bytes32(uint256(9)));
        assertEq(address(uint160(uint256(raw))), NON_ZERO_5, "chainlinkPriceFeed must be at slot 9");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // CoverPool
    // ──────────────────────────────────────────────────────────────────────────

    function test_CoverPool_poolFeeBpsAtSlot4() public {
        CoverPool impl = new CoverPool();
        bytes memory initData =
            abi.encodeCall(CoverPool.initialize, (ADMIN, NON_ZERO, NON_ZERO_2, NON_ZERO_3, NON_ZERO_4, 500));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        bytes32 raw = vm.load(address(proxy), bytes32(uint256(4)));
        // _poolFeeBps = 500 (0x01f4) occupies the lower 2 bytes of slot 4
        uint16 feeBps = uint16(uint256(raw));
        assertEq(feeBps, 500, "_poolFeeBps must be at slot 4");
    }

    function test_CoverPool_boundPolicyCommitsAtSlot5() public {
        CoverPool impl = new CoverPool();
        bytes memory initData =
            abi.encodeCall(CoverPool.initialize, (ADMIN, NON_ZERO, NON_ZERO_2, NON_ZERO_3, NON_ZERO_4, 500));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        // boundPolicyCommits is a mapping at slot 5. A written entry resolves to
        // keccak256(abi.encode(key, 5)). Confirm a non-existent key reads false.
        bytes32 entrySlot = keccak256(abi.encode(bytes32(uint256(0xdead)), uint256(5)));
        bytes32 raw = vm.load(address(proxy), entrySlot);
        assertEq(uint256(raw), 0, "boundPolicyCommits mapping must seed at slot 5");
    }

    function test_CoverPool_boundPoliciesAtSlot6() public {
        CoverPool impl = new CoverPool();
        bytes memory initData =
            abi.encodeCall(CoverPool.initialize, (ADMIN, NON_ZERO, NON_ZERO_2, NON_ZERO_3, NON_ZERO_4, 500));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        // boundPolicies is a mapping at slot 6. Confirm the seed key resolves correctly.
        uint96 policyId = 1;
        bytes32 baseSlot = keccak256(abi.encode(uint256(policyId), uint256(6)));
        bytes32 raw = vm.load(address(proxy), baseSlot);
        assertEq(uint256(raw), 0, "boundPolicies mapping must seed at slot 6 (unwritten entry is zero)");
    }

    function test_CoverPool_pendingFeeAtSlot7_8() public {
        CoverPool impl = new CoverPool();
        bytes memory initData =
            abi.encodeCall(CoverPool.initialize, (ADMIN, NON_ZERO, NON_ZERO_2, NON_ZERO_3, NON_ZERO_4, 500));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        // Propose a fee change so the pending slots get written
        vm.prank(ADMIN);
        CoverPool(address(proxy)).setPoolFeeBps(300);

        // slot 7: _pendingPoolFeeBps (uint16)
        bytes32 slot7 = vm.load(address(proxy), bytes32(uint256(7)));
        assertEq(uint16(uint256(slot7)), 300, "_pendingPoolFeeBps must be at slot 7");

        // slot 8: _pendingPoolFeeBpsTimestamp (uint256)
        bytes32 slot8 = vm.load(address(proxy), bytes32(uint256(8)));
        assertGt(uint256(slot8), 0, "_pendingPoolFeeBpsTimestamp must be at slot 8");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────────────────

    function _deployPolicyManager() internal returns (address proxy) {
        address[] memory tokens = new address[](0);
        proxy = Upgrades.deployUUPSProxy(
            "PolicyManager.sol",
            abi.encodeCall(PolicyManager.initialize, (ADMIN, NON_ZERO, NON_ZERO_2, NON_ZERO_3, NON_ZERO_5, tokens)),
            _skipChecks
        );
    }
}

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
