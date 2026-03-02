// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title ControllableVault
/// @notice A minimal ERC4626 vault backed by physical IERC20 balance.
///         Profit is simulated by dealing extra USDC to this contract.
///         Loss is simulated via simulateLoss() which drains USDC out.
///         This avoids rounding mismatches caused by virtual multipliers.
contract ControllableVault is IERC4626 {
    IERC20 private _assetToken;
    uint256 private _totalShares;

    mapping(address => uint256) private _shares;
    mapping(address => mapping(address => uint256)) private _allowances;

    constructor(address asset_) {
        _assetToken = IERC20(asset_);
    }

    // Test helper: drain USDC to simulate a hack/loss
    function simulateLoss(uint256 amount) external {
        _assetToken.transfer(msg.sender, amount);
    }

    // ── ERC4626
    // ──────────────────────────────────────────────────────────

    function asset() external view override returns (address) {
        return address(_assetToken);
    }

    function totalAssets() public view override returns (uint256) {
        return _assetToken.balanceOf(address(this));
    }

    function totalSupply() external view override returns (uint256) {
        return _totalShares;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _shares[account];
    }

    function name() external pure override returns (string memory) {
        return "Controllable Vault";
    }

    function symbol() external pure override returns (string memory) {
        return "ctrlV";
    }

    function decimals() external pure override returns (uint8) {
        return 6;
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 ta = totalAssets();
        if (_totalShares == 0 || ta == 0) return assets;
        return assets * _totalShares / ta;
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        if (_totalShares == 0) return shares;
        return shares * totalAssets() / _totalShares;
    }

    function maxDeposit(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner_) external view override returns (uint256) {
        return convertToAssets(_shares[owner_]);
    }

    function maxRedeem(address owner_) external view override returns (uint256) {
        return _shares[owner_];
    }

    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares_) external view override returns (uint256) {
        if (_totalShares == 0) return shares_;
        return shares_ * totalAssets() / _totalShares;
    }

    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares_) external view override returns (uint256) {
        return convertToAssets(shares_);
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares_) {
        shares_ = convertToShares(assets);
        if (shares_ == 0 && assets > 0) shares_ = assets;
        _assetToken.transferFrom(msg.sender, address(this), assets);
        _shares[receiver] += shares_;
        _totalShares += shares_;
    }

    function mint(uint256 shares_, address receiver) external override returns (uint256 assets) {
        assets = _totalShares == 0 ? shares_ : shares_ * totalAssets() / _totalShares;
        _assetToken.transferFrom(msg.sender, address(this), assets);
        _shares[receiver] += shares_;
        _totalShares += shares_;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner_
    )
        external
        override
        returns (uint256 shares_)
    {
        shares_ = convertToShares(assets);
        if (msg.sender != owner_) _allowances[owner_][msg.sender] -= shares_;
        _shares[owner_] -= shares_;
        _totalShares -= shares_;
        _assetToken.transfer(receiver, assets);
    }

    function redeem(uint256 shares_, address receiver, address owner_) external override returns (uint256 assets) {
        assets = convertToAssets(shares_);
        if (msg.sender != owner_) _allowances[owner_][msg.sender] -= shares_;
        _shares[owner_] -= shares_;
        _totalShares -= shares_;
        _assetToken.transfer(receiver, assets);
    }

    // ── ERC20 (share token)
    // ──────────────────────────────────────────────

    function transfer(address to, uint256 amount) external override returns (bool) {
        _shares[msg.sender] -= amount;
        _shares[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        if (msg.sender != from) _allowances[from][msg.sender] -= amount;
        _shares[from] -= amount;
        _shares[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address owner_, address spender) external view override returns (uint256) {
        return _allowances[owner_][spender];
    }
}
