// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./interfaces/IRebaseToken.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PriceConverter} from "./libs/PriceConverter.sol";

/// @title Vault contract for borrowing ETH against ERC20 collateral
/// @notice Users can deposit ETH, borrow against supported ERC20 tokens, and repay with interest
/// @dev Uses AccessControl for role management and ReentrancyGuard for safety
struct Debt {
    uint256 debt;
    uint256 collateral;
}

struct Collateral {
    address priceFeed;
    uint256 LVM;
}

contract Vault is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Custom errors for vault operations
    error Vault__innsuficientAmount();
    error Vault__transferFailed();
    error Borrow__invalidAmount();
    error Borrow__collateralTokenNotSupported(address);
    error Borrow__insufficientAllowance();
    error Borrow__invalidTransfer();
    error Borrow__noDebtForCollateral(address);
    error Borrow__collateralAlreadyExists();
    error Borrow__collateralDoesNotExist();
    error Borrow__invalidCollateralParams();
    error Borrow__notEnoughEthToBorrow(uint256 totalEthAvailable);
    error Borrow__userNotUnderCollaterlized();

    uint256 private constant WAD = 1e18;
    bytes32 public constant INTEREST_MANAGER_ROLE = keccak256("INTEREST_MANAGER_ROLE");
    bytes32 public constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    uint256 private totalDeposits;
    uint256 private totalInterests;
    uint256 private globalIndex;

    IRebaseToken private immutable i_rebaseToken;

    mapping(address => Collateral) public collateralPerToken;
    mapping(address => mapping(address => Debt)) public debtPerTokenPerUser;

    /// @notice Emitted when a user borrows ETH
    event userBorrowedEth(address indexed user, address indexed token, uint256 amount, uint256 borrowedEth);
    /// @notice Emitted when a user repays ETH
    event userRepaidEth(address indexed user, address indexed token, uint256 repaidAmount, uint256 returnedCollateral);

    /// @param _rebaseToken The token used to represent deposits
    /// @param admin Admin account to manage roles
    constructor(address _rebaseToken, address admin) {
        i_rebaseToken = IRebaseToken(_rebaseToken);
        globalIndex = WAD;
        if (admin == address(0)) {
            admin = msg.sender;
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Deposit ETH into the vault for the sender
    function deposit() external payable {
        depositTo(msg.sender);
    }

    /// @notice Deposit ETH on behalf of an account
    /// @param account Address to receive minted rebase tokens
    function depositTo(address account) public payable {
        if (msg.value == 0) revert Vault__innsuficientAmount();
        i_rebaseToken.mint(account, msg.value);
        totalDeposits += msg.value;
    }

    /// @notice Withdraw ETH by burning rebase tokens
    /// @param amount Amount of rebase tokens to burn
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert Vault__innsuficientAmount();
        i_rebaseToken.burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert Vault__transferFailed();
        totalDeposits -= amount;
    }

    /// @notice Borrow ETH using a supported ERC20 token as collateral
    /// @param token Address of the collateral token
    /// @param amount Amount of collateral to deposit
    function borrow(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert Borrow__invalidAmount();
        if (collateralPerToken[token].priceFeed == address(0)) revert Borrow__collateralTokenNotSupported(token);
        if (IERC20(token).allowance(msg.sender, address(this)) < amount) revert Borrow__insufficientAllowance();

        uint256 borrowedEth = maxEthFrom(token, amount);
        if (borrowedEth > totalDeposits) revert Borrow__notEnoughEthToBorrow(totalDeposits);

        uint256 scaledEth = borrowedEth * WAD / globalIndex;
        debtPerTokenPerUser[msg.sender][token].debt += scaledEth;
        debtPerTokenPerUser[msg.sender][token].collateral += amount;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        (bool success,) = payable(msg.sender).call{value: borrowedEth}("");
        if (!success) revert Borrow__invalidTransfer();
        emit userBorrowedEth(msg.sender, token, amount, borrowedEth);
    }

    /// @notice Repay borrowed ETH and retrieve proportional collateral
    /// @param token Collateral token to repay against
    function repay(address token) external payable nonReentrant {
        if (msg.value == 0) revert Borrow__invalidAmount();
        if (debtPerTokenPerUser[msg.sender][token].debt == 0) revert Borrow__noDebtForCollateral(token);

        uint256 refund;
        uint256 userScaled = debtPerTokenPerUser[msg.sender][token].debt;
        uint256 realDebt = userScaled * globalIndex / WAD;
        uint256 payETH = msg.value;

        if (payETH > realDebt) {
            refund = payETH - realDebt;
            payETH = realDebt;
        }

        uint256 scaledRepaid = payETH * WAD / globalIndex;
        uint256 userCollat = debtPerTokenPerUser[msg.sender][token].collateral;
        uint256 returnedCollateral;

        if (scaledRepaid >= userScaled) {
            returnedCollateral = userCollat;
            scaledRepaid = userScaled;
        } else {
            returnedCollateral = userCollat * scaledRepaid / userScaled;
        }

        debtPerTokenPerUser[msg.sender][token].debt = userScaled - scaledRepaid;
        debtPerTokenPerUser[msg.sender][token].collateral = userCollat - returnedCollateral;

        uint256 interest = payETH - scaledRepaid;
        totalInterests += interest;

        IERC20(token).safeTransfer(msg.sender, returnedCollateral);
        if (refund != 0) {
            (bool success,) = payable(msg.sender).call{value: refund}("");
            if (!success) revert Borrow__invalidTransfer();
        }

        emit userRepaidEth(msg.sender, token, payETH, returnedCollateral);
    }

    /// @notice Accrue interest on all debts by updating global index
    /// @param rate Interest rate to apply (in WAD units, e.g., 1e16 = 1%)
    function accrueInterest(uint256 rate) external onlyRole(INTEREST_MANAGER_ROLE) {
        globalIndex = globalIndex * (WAD + rate) / WAD;
    }

    /// @notice Get total ETH interest collected
    function getTotalInterests() external view returns (uint256) {
        return totalInterests;
    }

    /// @notice Get total ETH deposits in the vault
    function getTotalDeposits() external view returns (uint256) {
        return totalDeposits;
    }

    /// @notice Add a new collateral type
    /// @param _token ERC20 token address
    /// @param _priceFeed Chainlink price feed for token
    /// @param _LVM Loan-to-value multiplier in WAD
    function addCollateral(address _token, address _priceFeed, uint256 _LVM)
        external
        onlyRole(COLLATERAL_MANAGER_ROLE)
    {
        if (collateralPerToken[_token].LVM != 0) revert Borrow__collateralAlreadyExists();
        modifyCollateral(_token, _priceFeed, _LVM);
    }

    /// @notice Update price feed for a collateral token
    /// @param _token Token address
    /// @param _priceFeed New price feed address
    function modifyCollateralPriceFeed(address _token, address _priceFeed) external onlyRole(COLLATERAL_MANAGER_ROLE) {
        if (_priceFeed == address(0)) revert Borrow__invalidCollateralParams();
        if (collateralPerToken[_token].LVM == 0) revert Borrow__collateralDoesNotExist();
        collateralPerToken[_token].priceFeed = _priceFeed;
    }

    /// @notice Update LVM for a collateral token
    /// @param _token Token address
    /// @param _LVM New LVM value (in WAD)
    function modifyCollateralLVM(address _token, uint256 _LVM) external onlyRole(COLLATERAL_MANAGER_ROLE) {
        if (_LVM < WAD) revert Borrow__invalidCollateralParams();
        if (collateralPerToken[_token].LVM == 0) revert Borrow__collateralDoesNotExist();
        collateralPerToken[_token].LVM = _LVM;
    }

 /// @notice Liquidates a user’s position if undercollateralized
/// @dev The liquidator must send ETH to cover part or all of the user’s debt
///      Collateral is seized proportionally to the ETH paid
/// @param user The address of the user being liquidated
/// @param _token The collateral token used by the user
function liquidate(address user, address _token) external payable onlyRole(LIQUIDATOR_ROLE) {
    Debt storage userDebt = debtPerTokenPerUser[user][_token];
    Collateral memory collateral = collateralPerToken[_token];

    uint256 realDebt = userDebt.debt * globalIndex / WAD;
    uint256 maxBorrow = maxEthFrom(_token, userDebt.collateral);

    if (realDebt <= maxBorrow) revert Borrow__userNotUnderCollaterlized();
    if (msg.value == 0) revert Borrow__invalidAmount();

    uint256 payETH = msg.value;
    if (payETH > realDebt) {
        payETH = realDebt; // cap at total debt
    }

    uint256 seizedCollateral = userDebt.collateral * payETH / realDebt;
    uint256 scaledPaid = payETH * WAD / globalIndex;
    userDebt.debt -= scaledPaid;
    userDebt.collateral -= seizedCollateral;

    totalDeposits += payETH;

    IERC20(_token).safeTransfer(msg.sender, seizedCollateral);

    if (msg.value > payETH) {
        (bool success,) = payable(msg.sender).call{value: msg.value - payETH}("");
        if (!success)
            revert Borrow__invalidTransfer();
    }
}

/// @notice Update the rebase tokens interest based on total deposits and total interests
/// function should be called periodically and this contracts address needs to be granted role
/// to access the rebase token function of INDEX_MANAGER_ROLE by the rebasetoken contract 
function updateRebaseTokenInterest() external onlyRole(INTEREST_MANAGER_ROLE) {
    uint256 interest = WAD * (totalDeposits + totalInterests) / totalDeposits;
    i_rebaseToken.updateGlobalIndex(interest);
}

    /// @notice Get the current global interest index
    function getGlobalIndex() external view returns (uint256) {
        return globalIndex;
    }

    /// @notice Internal helper to add or modify collateral parameters
    function modifyCollateral(address _token, address _priceFeed, uint256 _LVM)
        public
        onlyRole(COLLATERAL_MANAGER_ROLE)
    {
        if (_token == address(0) || _priceFeed == address(0) || _LVM < WAD) {
            revert Borrow__invalidCollateralParams();
        }
        collateralPerToken[_token] = Collateral({priceFeed: _priceFeed, LVM: _LVM});
    }

    /// @notice Compute max ETH borrowable from a given collateral amount
    /// @param token Collateral token address
    /// @param amount Amount of collateral
    /// @return amountInEth Maximum ETH that can be borrowed
    function maxEthFrom(address token, uint256 amount) internal view returns (uint256) {
        Collateral memory collateral = collateralPerToken[token];
        if (collateral.priceFeed == address(0)) revert Borrow__collateralTokenNotSupported(token);
        uint256 amountInEth = PriceConverter.getRates(amount, collateral.priceFeed);
        return amountInEth * WAD / collateral.LVM;
    }

}
