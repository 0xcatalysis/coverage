// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISlashingManager} from "coverage/interfaces/ISlashingManager.sol";
import {IStakeManager} from "coverage/interfaces/IStakeManager.sol";
import {IChainlinkPriceFeed} from "coverage/interfaces/IChainlinkPriceFeed.sol";
import {ICoverPoolFactory} from "coverage/interfaces/ICoverPoolFactory.sol";
import {ISpecRegistry} from "coverage/interfaces/ISpecRegistry.sol";
import {ISpec} from "coverage/interfaces/ISpec.sol";
import {IBindPolicyHook} from "coverage/interfaces/IBindPolicyHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IChainlinkPriceFeed} from "coverage/interfaces/IChainlinkPriceFeed.sol";

/// @title MockStakeManager
/// @notice Minimal StakeManager mock for testing with real PolicyManager and CoverPool
contract MockStakeManager {
    mapping(uint96 => address[]) private _committeeVaults;

    function createCommittee(uint96, address, uint32) external {
        // No-op: just accept the call from PolicyManager.requestCoverage
    }

    function addOperatorToCommittee(address, uint96) external {
        // No-op: just accept the call from PolicyManager.requestCoverage
    }

    function removeOperatorFromCommittee(address, uint96) external {
        // No-op
    }

    function addCommitteeVaults(uint96 committeeId, address[] calldata vaults) external {
        for (uint256 i = 0; i < vaults.length; i++) {
            _committeeVaults[committeeId].push(vaults[i]);
        }
    }

    function getCommitteeVaults(uint96 committeeId) external view returns (address[] memory) {
        return _committeeVaults[committeeId];
    }

    function getCommitteeTokenStakes(uint96 committeeId)
        external
        view
        returns (address[] memory vaults, address[] memory tokens, uint256[] memory tokenStakes)
    {
        vaults = _committeeVaults[committeeId];
        tokens = new address[](vaults.length);
        tokenStakes = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            tokenStakes[i] = type(uint256).max / vaults.length; // Large enough to never fail stake check
        }
    }
}

/// @title MockSlashingManager
/// @notice Minimal SlashingManager mock for defi tests
contract MockSlashingManagerDefi {
    function previewSlashing(
        uint96, /*committeeId*/
        address /*operator*/
    )
        external
        pure
        returns (address[] memory vaults, address[] memory tokens, uint256[] memory tokenStakes)
    {
        vaults = new address[](0);
        tokens = new address[](0);
        tokenStakes = new uint256[](0);
    }

    function executeSlashing(
        uint96, /*committeeId*/
        address, /*operator*/
        ISlashingManager.VaultSlash[] calldata, /*vaultSlashes*/
        bytes32 /*taskId*/
    )
        external
        pure
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = new address[](0);
        amounts = new uint256[](0);
    }
}

/// @title MockChainlinkPriceFeedDefi
/// @notice Returns input amount as USD value (1:1 identity) so stake checks always pass when stakes >= coverageLimit
contract MockChainlinkPriceFeedDefi is IChainlinkPriceFeed {
    function getUSDValue(address, uint256 amount) external pure override returns (uint256) {
        return amount;
    }

    function getTokenAmount(address, uint256 usdValue) external pure override returns (uint256) {
        return usdValue;
    }
}

/// @title MockCoverPoolFactory
/// @notice Minimal CoverPoolFactory mock that tracks registered pools
contract MockCoverPoolFactory {
    mapping(address => bool) private _pools;

    function coverPoolExists(address pool) external view returns (bool) {
        return _pools[pool];
    }

    /// @notice Test helper to register a pool
    function register(address pool) external {
        _pools[pool] = true;
    }
}

/// @title MockSpecRegistry
/// @notice Minimal SpecRegistry mock that accepts registerSpec calls
contract MockSpecRegistry {
    mapping(bytes32 => mapping(address => address)) private _specs;

    function registerSpec(bytes32 specId, ISpec spec) external {
        _specs[specId][msg.sender] = address(spec);
    }

    function resolveSpec(address coverPool, bytes32 specId) external view returns (ISpec) {
        return ISpec(_specs[specId][coverPool]);
    }
}

/// @title MockChainlinkPriceFeed
/// @notice Minimal ChainlinkPriceFeed mock that always approves stake validation
/// @dev Returns type(uint256).max for getUSDValue so the stake check always passes when
///      MockStakeManager.getCommitteeTotalStakeUSD also returns type(uint256).max.
contract MockChainlinkPriceFeed is IChainlinkPriceFeed {
    function getUSDValue(address, uint256) external pure override returns (uint256) {
        return 0; // 0 <= type(uint256).max always passes the InsufficientStake check
    }

    function getTokenAmount(address, uint256) external pure override returns (uint256) {
        return 0;
    }
}

/// @title MockBindPolicyHook
/// @notice Minimal IBindPolicyHook mock for the chicken-and-egg problem
/// @dev Used as the hook during requestCoverage since the real adapter doesn't exist yet
contract MockBindPolicyHook is IBindPolicyHook {
    function onPolicyBound(uint96, uint256) external override {
        // No-op
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBindPolicyHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
