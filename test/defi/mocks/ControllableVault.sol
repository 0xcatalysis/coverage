// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ControllableVault
 * @notice A minimal ERC-4626 vault backed by physical IERC20 balance.
 *
 * @dev Share price is derived entirely from the vault's real asset balance, so
 *      `simulateLoss()` immediately deflates `convertToAssets()` without any
 *      virtual accounting — this avoids rounding mismatches in tests and makes
 *      the shortfall detectable by CatalysisCoverAdapter on the very next withdrawal.
 *
 *      Profit can be simulated by transferring assets directly to the contract
 *      (e.g. via `vm.deal` / `deal()` in tests) or via `simulateProfit()` on mainnet.
 *
 *      Access control: `admin` (defaults to deployer) is the only address permitted
 *      to call `simulateLoss()`. Admin rotation uses a two-step accept pattern to
 *      prevent accidental loss of control on mainnet.
 *
 *      `decimals()` mirrors the underlying asset so the vault is compatible with
 *      both USDC (6 decimals) and WETH (18 decimals) without reconfiguration.
 */
contract ControllableVault is IERC4626 {
    using SafeERC20 for IERC20;

    IERC20 private _assetToken;
    uint256 private _totalShares;

    address public admin;
    address public pendingAdmin;

    mapping(address => uint256) private _shares;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ── Events ────────────────────────────────────────────────────────────────

    /**
     * @notice Emitted when assets are drained to simulate a loss event.
     * @param caller The admin address that triggered the loss.
     * @param amount The amount of underlying asset drained.
     * @param totalAssetsAfter The vault's total asset balance after the drain.
     */
    event LossSimulated(address indexed caller, uint256 amount, uint256 totalAssetsAfter);

    /**
     * @notice Emitted when assets are injected to simulate a yield/profit event.
     * @param caller The address that injected assets.
     * @param amount The amount of underlying asset injected.
     * @param totalAssetsAfter The vault's total asset balance after injection.
     */
    event ProfitSimulated(address indexed caller, uint256 amount, uint256 totalAssetsAfter);

    /**
     * @notice Emitted when a new admin is nominated.
     * @param currentAdmin The current admin initiating the transfer.
     * @param newAdmin The nominated pending admin.
     */
    event AdminTransferInitiated(address indexed currentAdmin, address indexed newAdmin);

    /**
     * @notice Emitted when the pending admin accepts the role.
     * @param newAdmin The address that accepted the admin role.
     */
    event AdminTransferAccepted(address indexed newAdmin);

    // ── Errors ────────────────────────────────────────────────────────────────

    /// @notice Thrown when caller is not the admin.
    error NotAdmin();

    /// @notice Thrown when caller is not the pending admin.
    error NotPendingAdmin();

    /// @notice Thrown when a zero address is provided where one is not allowed.
    error ZeroAddress();

    /// @notice Thrown when a zero amount is provided.
    error ZeroAmount();

    /// @notice Thrown when the requested loss amount exceeds available assets.
    error InsufficientAssets(uint256 requested, uint256 available);

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    /**
     * @notice Deploy a new ControllableVault.
     * @dev Admin defaults to the deployer. In tests this is the test contract itself,
     *      preserving the existing `ctrlVault.simulateLoss(amount)` call pattern.
     *      On mainnet, call `transferAdmin` + `acceptAdmin` to rotate to a multisig.
     * @param asset_ The underlying ERC-20 token (e.g. USDC or WETH).
     */
    constructor(address asset_) {
        _assetToken = IERC20(asset_);
        admin = msg.sender;
    }

    // ── Loss / profit controls ─────────────────────────────────────────────────

    /**
     * @notice Drain `amount` of the underlying asset to simulate a hack or loss event.
     * @dev Tokens are sent to the admin address. After this call `totalAssets()` decreases,
     *      `convertToAssets(shares)` returns less than the original deposit value, and any
     *      subsequent CatalysisCoverAdapter withdrawal triggers a shortfall → insurance claim.
     * @param amount The quantity of underlying asset to drain.
     */
    function simulateLoss(uint256 amount) external onlyAdmin {
        if (amount == 0) revert ZeroAmount();
        uint256 available = totalAssets();
        if (amount > available) revert InsufficientAssets(amount, available);
        _assetToken.safeTransfer(admin, amount);
        emit LossSimulated(msg.sender, amount, totalAssets());
    }

    /**
     * @notice Inject `amount` of the underlying asset to simulate yield or a profit event.
     * @dev Caller must approve this vault to spend `amount` of the underlying asset beforehand.
     *      After this call `totalAssets()` increases and existing share holders see a higher
     *      `convertToAssets()` value — useful for verifying that profitable withdrawals do not
     *      incorrectly file insurance claims (test scenarios HP-10, CC-11, CC-12).
     * @param amount The quantity of underlying asset to inject.
     */
    function simulateProfit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _assetToken.safeTransferFrom(msg.sender, address(this), amount);
        emit ProfitSimulated(msg.sender, amount, totalAssets());
    }

    // ── Admin rotation ────────────────────────────────────────────────────────

    /**
     * @notice Nominate a new admin. The nominee must call `acceptAdmin()` to take effect.
     * @dev Two-step rotation prevents accidental loss of control on mainnet. The current
     *      admin retains all privileges until `acceptAdmin()` is called.
     * @param newAdmin The address to nominate as the next admin.
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        pendingAdmin = newAdmin;
        emit AdminTransferInitiated(admin, newAdmin);
    }

    /**
     * @notice Accept the pending admin nomination. Must be called by the pending admin.
     */
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferAccepted(msg.sender);
    }

    // ── ERC-4626 ──────────────────────────────────────────────────────────────

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

    function name() external view override returns (string memory) {
        return string.concat("Controllable ", IERC20Metadata(address(_assetToken)).symbol(), " Vault");
    }

    function symbol() external view override returns (string memory) {
        return string.concat("ctrl", IERC20Metadata(address(_assetToken)).symbol());
    }

    /// @notice Mirrors the underlying asset's decimals for compatibility with USDC (6) and WETH (18).
    function decimals() external view override returns (uint8) {
        return IERC20Metadata(address(_assetToken)).decimals();
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
        _assetToken.safeTransferFrom(msg.sender, address(this), assets);
        _shares[receiver] += shares_;
        _totalShares += shares_;
        emit Deposit(msg.sender, receiver, assets, shares_);
    }

    function mint(uint256 shares_, address receiver) external override returns (uint256 assets) {
        assets = _totalShares == 0 ? shares_ : shares_ * totalAssets() / _totalShares;
        _assetToken.safeTransferFrom(msg.sender, address(this), assets);
        _shares[receiver] += shares_;
        _totalShares += shares_;
        emit Deposit(msg.sender, receiver, assets, shares_);
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
        _assetToken.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner_, assets, shares_);
    }

    function redeem(
        uint256 shares_,
        address receiver,
        address owner_
    )
        external
        override
        returns (uint256 assets)
    {
        assets = convertToAssets(shares_);
        if (msg.sender != owner_) _allowances[owner_][msg.sender] -= shares_;
        _shares[owner_] -= shares_;
        _totalShares -= shares_;
        _assetToken.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner_, assets, shares_);
    }

    // ── ERC-20 (share token) ──────────────────────────────────────────────────

    function transfer(address to, uint256 amount) external override returns (bool) {
        _shares[msg.sender] -= amount;
        _shares[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        if (msg.sender != from) _allowances[from][msg.sender] -= amount;
        _shares[from] -= amount;
        _shares[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function allowance(address owner_, address spender) external view override returns (uint256) {
        return _allowances[owner_][spender];
    }
}
