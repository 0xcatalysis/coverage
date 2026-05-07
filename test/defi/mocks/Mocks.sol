// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ISpec} from "coverage/interfaces/ISpec.sol";
import {IPolicyManager} from "coverage/interfaces/IPolicyManager.sol";

/// @title MockERC20
/// @notice Minimal ERC20 mock for testing
contract MockERC20 is IERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }
}

/// @title MockERC6
/// @notice 6-decimal ERC20 mock (e.g. USDC / USDT)
contract MockERC6 is MockERC20 {
    constructor() {
        decimals = 6;
    }
}

/// @title MockVault
/// @notice Minimal ERC4626 vault mock for testing
contract MockVault is IERC4626 {
    MockERC20 private _asset;
    string public name = "Mock Vault";
    string public symbol = "vMOCK";
    uint8 public decimals = 18;

    mapping(address => uint256) private _shares;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalShares;
    uint256 private _totalAssets;

    // For simulating losses
    uint256 public lossPercent = 0;

    constructor(address asset_) {
        _asset = MockERC20(asset_);
    }

    function setLoss(uint256 percent) external {
        require(percent <= 100, "Loss > 100%");
        lossPercent = percent;
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function totalSupply() external view returns (uint256) {
        return _totalShares;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _shares[account];
    }

    function totalAssets() public view returns (uint256) {
        // Simulate loss
        return _totalAssets * (100 - lossPercent) / 100;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (_totalShares == 0 || _totalAssets == 0) return assets;
        return assets * _totalShares / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (_totalShares == 0) return shares;
        return shares * totalAssets() / _totalShares;
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(_shares[owner]);
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return _shares[owner];
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        if (_totalShares == 0) return shares;
        return shares * totalAssets() / _totalShares;
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        if (shares == 0 && assets > 0) shares = assets; // 1:1 for first deposit

        require(_asset.transferFrom(msg.sender, address(this), assets));
        _shares[receiver] += shares;
        _totalShares += shares;
        _totalAssets += assets;

        return shares;
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = _totalShares == 0 ? shares : shares * totalAssets() / _totalShares;

        require(_asset.transferFrom(msg.sender, address(this), assets));
        _shares[receiver] += shares;
        _totalShares += shares;
        _totalAssets += assets;

        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = convertToShares(assets);

        if (msg.sender != owner) {
            _allowances[owner][msg.sender] -= shares;
        }

        _shares[owner] -= shares;
        _totalShares -= shares;
        _totalAssets -= assets;

        require(_asset.transfer(receiver, assets));

        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = convertToAssets(shares);

        if (msg.sender != owner) {
            _allowances[owner][msg.sender] -= shares;
        }

        _shares[owner] -= shares;
        _totalShares -= shares;
        _totalAssets -= assets;

        require(_asset.transfer(receiver, assets));

        return assets;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _shares[msg.sender] -= amount;
        _shares[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            _allowances[from][msg.sender] -= amount;
        }
        _shares[from] -= amount;
        _shares[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }
}

/// @title MockPolicyManager
/// @notice Minimal PolicyManager mock that stores policy metadata directly
contract MockPolicyManager {
    mapping(uint96 => IPolicyManager.PolicyMetadata) private _policyMetadata;

    function setPolicy(
        uint96 _policyId,
        address buyer,
        address pool,
        address beneficiary,
        address payoutToken,
        uint256 coverageLimit,
        uint32 startTime,
        uint32 maturityTime
    )
        external
    {
        _policyMetadata[_policyId].buyer = buyer;
        _policyMetadata[_policyId].policyId = _policyId;
        _policyMetadata[_policyId].beneficiary = beneficiary;
        _policyMetadata[_policyId].claimer = beneficiary;
        _policyMetadata[_policyId].startTime = startTime;
        _policyMetadata[_policyId].maturityTime = maturityTime;
        _policyMetadata[_policyId].payoutToken = payoutToken;
        _policyMetadata[_policyId].pool = pool;
        _policyMetadata[_policyId].coverageLimit = coverageLimit;
    }

    function policyMetadata(uint96 _policyId) external view returns (IPolicyManager.PolicyMetadata memory) {
        return _policyMetadata[_policyId];
    }

    function policyManager() external view returns (address) {
        return address(this);
    }

    function bindPolicy(bytes calldata) external pure returns (uint256) {
        return 1;
    }

    /// @notice Helper to call onPolicyBound on a target adapter as PolicyManager
    function callOnPolicyBound(address target, uint96 _policyId, uint256 coverageLimit) external {
        (bool ok, bytes memory ret) =
            target.call(abi.encodeWithSignature("onPolicyBound(uint96,uint256)", _policyId, coverageLimit));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @title MockClaimManager
/// @notice Minimal ClaimManager mock that calls evaluate() on the spec
contract MockClaimManager {
    address public policyManager;

    struct PolicyClaim {
        uint256 totalPaidOut;
        uint256 claimCount;
    }

    mapping(uint96 => PolicyClaim) private _policyClaims;
    mapping(uint96 => bool) private _claimApprovalRequired;

    constructor(address policyManager_) {
        policyManager = policyManager_;
    }

    function claimApprovalRequired(uint96 policyId) external view returns (bool) {
        return _claimApprovalRequired[policyId];
    }

    function policyClaim(uint96 policyId) external view returns (PolicyClaim memory) {
        return _policyClaims[policyId];
    }

    function validateAndLockCollateralRoutes(
        uint96,
        address,
        uint256,
        address[] calldata,
        uint256[] calldata
    )
        external {}

    function fileClaim(
        uint96 policyId,
        uint256, /* claimAmount */
        bytes32 evidenceHash,
        bytes memory additionalData
    )
        external
        returns (uint256)
    {
        IPolicyManager.PolicyMetadata memory meta = MockPolicyManager(policyManager).policyMetadata(policyId);

        ISpec.EvaluationContext memory context = ISpec.EvaluationContext({
            policyId: policyId,
            pool: meta.pool,
            coverageLimit: meta.coverageLimit,
            startTime: meta.startTime,
            maturityTime: meta.maturityTime,
            evaluationTime: uint32(block.timestamp),
            evidenceHash: evidenceHash,
            additionalData: additionalData
        });

        ISpec spec = ISpec(meta.beneficiary);
        ISpec.EvaluationResult memory result = spec.evaluate(context);

        if (result.isPayable) {
            (, uint256 claimedAmount) = abi.decode(additionalData, (address, uint256));
            address payoutToken = meta.payoutToken;
            MockERC20(payoutToken).mint(meta.beneficiary, claimedAmount);

            _policyClaims[policyId].totalPaidOut += claimedAmount;
            _policyClaims[policyId].claimCount++;
            _claimApprovalRequired[policyId] = true;
        }

        return result.isPayable ? 1 : 0;
    }
}

/// @title MockPolicy
/// @notice Minimal Policy mock using IPolicyManager.PolicyMetadata. Sets claimer = beneficiary.
/// @dev Kept for backward compatibility; MockPolicyManager is preferred
contract MockPolicy {
    mapping(uint96 => IPolicyManager.PolicyMetadata) private _policies;

    function setPolicy(
        uint96 policyId,
        address buyer,
        address pool,
        address beneficiary,
        address payoutToken,
        uint256 coverageLimit,
        uint32 startTime,
        uint32 maturityTime
    )
        external
    {
        _policies[policyId].buyer = buyer;
        _policies[policyId].policyId = policyId;
        _policies[policyId].beneficiary = beneficiary;
        _policies[policyId].claimer = beneficiary;
        _policies[policyId].pool = pool;
        _policies[policyId].payoutToken = payoutToken;
        _policies[policyId].coverageLimit = coverageLimit;
        _policies[policyId].startTime = startTime;
        _policies[policyId].maturityTime = maturityTime;
    }

    function policyMetadata(uint96 policyId) external view returns (IPolicyManager.PolicyMetadata memory) {
        return _policies[policyId];
    }
}

/// @title MockCoverPool
/// @notice Minimal CoverPool mock
contract MockCoverPool {
    function quoteDomainSeparator() external pure returns (bytes32) {
        return keccak256("TEST_DOMAIN");
    }
}

/// @title MockVaultV2
/// @notice Morpho Vault V2 mock for testing covered vault wrappers
contract MockVaultV2 {
    MockERC20 private _asset;
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    address public curator;
    address public owner;
    address public managementFeeRecipient;

    mapping(address => uint256) private _shares;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) public isAllocator;
    mapping(address => bool) public isAdapter;
    mapping(bytes32 => uint256) private _allocations;

    uint256 private _totalShares;
    uint256 private _totalAssets;
    uint256 public lossPercent = 0;
    uint256 public profitPercent = 0;

    constructor(address asset_, string memory name_, string memory symbol_) {
        _asset = MockERC20(asset_);
        name = name_;
        symbol = symbol_;
        curator = msg.sender;
        owner = msg.sender;
    }

    function setCurator(address _curator) external {
        curator = _curator;
    }

    function setOwner(address _owner) external {
        owner = _owner;
    }

    function setManagementFeeRecipient(address _managementFeeRecipient) external {
        managementFeeRecipient = _managementFeeRecipient;
    }

    function setAllocator(address account, bool status) external {
        isAllocator[account] = status;
    }

    function setAdapter(address account, bool status) external {
        isAdapter[account] = status;
    }

    function setAllocation(bytes32 id, uint256 amount) external {
        _allocations[id] = amount;
    }

    // ── Absolute cap support for onPolicyBound hook ──

    mapping(bytes32 => uint256) private _absoluteCaps;
    bytes private _lastSubmitData;

    function submit(bytes memory data) external {
        _lastSubmitData = data;
    }

    function increaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external {
        bytes32 id = keccak256(idData);
        _absoluteCaps[id] = newAbsoluteCap;
    }

    function absoluteCap(bytes32 id) external view returns (uint256) {
        return _absoluteCaps[id];
    }

    function lastSubmitData() external view returns (bytes memory) {
        return _lastSubmitData;
    }

    function setLoss(uint256 percent) external {
        require(percent <= 100, "Loss > 100%");
        lossPercent = percent;
        profitPercent = 0; // Reset profit when setting loss
    }

    function setProfit(uint256 percent) external {
        profitPercent = percent;
        lossPercent = 0; // Reset loss when setting profit
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function totalSupply() external view returns (uint256) {
        return _totalShares;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _shares[account];
    }

    function totalAssets() public view returns (uint256) {
        if (profitPercent > 0) {
            return _totalAssets * (100 + profitPercent) / 100;
        }
        return _totalAssets * (100 - lossPercent) / 100;
    }

    function allocation(bytes32 id) external view returns (uint256) {
        return _allocations[id];
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (_totalShares == 0 || _totalAssets == 0) return assets;
        return assets * _totalShares / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (_totalShares == 0) return shares;
        return shares * totalAssets() / _totalShares;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        if (shares == 0 && assets > 0) shares = assets;

        require(_asset.transferFrom(msg.sender, address(this), assets));
        _shares[receiver] += shares;
        _totalShares += shares;
        _totalAssets += assets;

        return shares;
    }

    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        shares = convertToShares(assets);

        if (msg.sender != owner_) {
            _allowances[owner_][msg.sender] -= shares;
        }

        _shares[owner_] -= shares;
        _totalShares -= shares;
        _totalAssets -= assets;

        require(_asset.transfer(receiver, assets));

        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner_) public virtual returns (uint256 assets) {
        assets = convertToAssets(shares);

        if (msg.sender != owner_) {
            _allowances[owner_][msg.sender] -= shares;
        }

        _shares[owner_] -= shares;
        _totalShares -= shares;
        // Safe subtraction: with simulated profit, convertToAssets can exceed _totalAssets
        _totalAssets = assets >= _totalAssets ? 0 : _totalAssets - assets;

        require(_asset.transfer(receiver, assets));

        return assets;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _shares[msg.sender] -= amount;
        _shares[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            _allowances[from][msg.sender] -= amount;
        }
        _shares[from] -= amount;
        _shares[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    // Simulate allocate call from parent vault
    function allocate(address adapter, uint256 assets) external {
        require(_asset.transfer(adapter, assets));
    }

    // ERC4626-like interface for underlying vault compatibility
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function maxWithdraw(address owner_) external view returns (uint256) {
        return convertToAssets(_shares[owner_]);
    }

    function maxRedeem(address owner_) external view returns (uint256) {
        return _shares[owner_];
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }
}
