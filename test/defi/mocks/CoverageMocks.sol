// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStakeManager} from "coverage/interfaces/IStakeManager.sol";
import {ICoverPoolFactory} from "coverage/interfaces/ICoverPoolFactory.sol";
import {ISpecRegistry} from "coverage/interfaces/ISpecRegistry.sol";
import {ISpec} from "coverage/interfaces/ISpec.sol";
import {IBindPolicyHook} from "coverage/interfaces/IBindPolicyHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title MockStakeManager
/// @notice Minimal StakeManager mock for testing with real PolicyManager and CoverPool
contract MockStakeManager {
    mapping(uint96 => address[]) private _committeeVaults;
    mapping(bytes32 => uint256) private _operatorStakes;

    function createCommittee(uint96, uint256, address, uint32) external {
        // No-op: just accept the call from PolicyManager.requestCoverage
    }

    function addOperatorToCommittee(address, uint96) external {
        // No-op: just accept the call from PolicyManager.requestCoverage
    }

    function addCommitteeVaults(uint96 committeeId, address[] calldata vaults) external {
        for (uint256 i = 0; i < vaults.length; i++) {
            _committeeVaults[committeeId].push(vaults[i]);
        }
    }

    function getCommitteeVaults(uint96 committeeId) external view returns (address[] memory) {
        return _committeeVaults[committeeId];
    }

    function getOperatorCommitteeStake(address operator, uint96 committeeId) external view returns (uint256) {
        return _operatorStakes[keccak256(abi.encode(operator, committeeId))];
    }

    function getCommitteeTotalStakeUSD(uint96) external pure returns (uint256) {
        return type(uint256).max; // Return maximum value to avoid InsufficientStake errors
    }

    /// @notice Test helper to set the stake for an operator in a committee
    function setOperatorStake(address operator, uint96 committeeId, uint256 stake) external {
        _operatorStakes[keccak256(abi.encode(operator, committeeId))] = stake;
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
