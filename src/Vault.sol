// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./interfaces/IRebaseToken.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PriceConverter} from "./libs/PriceConverter.sol";

// Consider renaming globalIndex → borrowIndex or debtIndex
//to avoid confusion with the rebase token's own index.

/// @notice Struct for borrowing data associated per user, per collateral token address
/// @param debt Amount of debt the user owes associated with specific token includes
/// @param usedCollateral Amount of collateral locked for user's borrowed ETH that has not yet been repaid
/// @param availableCollateral Amount of collateral user has deposited and can be used to borrow ETH
struct Debt {
    uint256 debt;
    uint256 usedCollateral;
    uint256 availableCollateral;
}

/// @notice Struct for each Collateral token supported by the protocol
/// @param priceFeed is the address for exchanging collateral token to ETH (in collateral amount -> out ETH amount)
/// @param LVM Loan-to-value multiplier in WAD for the collateral must be >= WAD
struct Collateral {
    address priceFeed;
    uint256 LVM;
}

/// @title Vault contract for borrowing ETH against ERC20 collateral
/// @notice Users can deposit ETH, borrow against supported ERC20 tokens, and repay with interest
/// @dev Uses AccessControl for role management and ReentrancyGuard for safety
contract Vault is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Custom errors for vault operations
    error Vault__insufficientAmount();
    error Vault__insufficientLiquidity();
    error Vault__transferFailed();
    error Borrow__invalidAmount();
    error Borrow__collateralTokenNotSupported(address);
    error Borrow__insufficientAllowance();
    error Borrow__invalidTransfer();
    error Borrow__noDebtForCollateral(address);
    error Borrow__collateralAlreadyExists();
    error Borrow__collateralDoesNotExist();
    error Borrow__invalidCollateralParams();
    error Borrow__notEnoughLiquidity(uint256 totalEthAvailable);
    error Borrow__notEnoughCollateral(uint256 totalCollateralAvailable);
    error Borrow__userNotUnderCollaterlized();

    uint256 private constant WAD = 1e18;
    bytes32 public constant COLLATERAL_INTEREST_MANAGER_ROLE = keccak256("COLLATERAL_INTEREST_MANAGER_ROLE");
    bytes32 public constant REBASETOKEN_INTEREST_MANAGER_ROLE = keccak256("REBASETOKEN_INTEREST_MANAGER_ROLE");
    bytes32 public constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    uint256 private totalLiquidity; //REAL ETH -> unchanged by globalIndex
    uint256 private totalBorrowScaled; //SCALED ETH -> dependes on globalIndex
    // uint256 private totalInterests;
    uint256 private globalIndex;

    IRebaseToken private immutable i_rebaseToken;

    mapping(address => Collateral) public collateralPerToken;
    mapping(address => mapping(address => Debt)) public debtPerTokenPerUser;

    /// @notice Emitted when a user borrows ETH
    event UserBorrowedEth(address indexed user, address indexed token, uint256 amount, uint256 borrowedEth);
    /// @notice Emitted when a user repays ETH
    event UserRepaidEth(address indexed user, address indexed token, uint256 repaidAmount, uint256 returnedCollateral);

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
        if (msg.value == 0) revert Vault__insufficientAmount();

        totalLiquidity += msg.value;

        i_rebaseToken.mint(account, msg.value);
    }

    /// @notice Withdraw ETH by burning rebase tokens
    /// @param amount Amount of ETH to withdraw
    /// if amount is max uint we will take the total of the users balance
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert Vault__insufficientAmount();
        if (amount == type(uint256).max) {
            amount = i_rebaseToken.balanceOf(msg.sender);
        }
        if (totalLiquidity < amount) revert Vault__insufficientLiquidity();

        totalLiquidity -= amount;

        i_rebaseToken.burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert Vault__transferFailed();
    }

    /// @notice Deposit token as collateral to borrow ETH
    /// @param amountToDeposit Amount of collateral to deposit
    /// @param token Address of the collateral token
    function depositCollateral(uint256 amountToDeposit, address token) public nonReentrant {
        if (amountToDeposit == 0) revert Borrow__invalidAmount();
        if (collateralPerToken[token].priceFeed == address(0)) revert Borrow__collateralTokenNotSupported(token);
        if (IERC20(token).allowance(msg.sender, address(this)) < amountToDeposit) {
            revert Borrow__insufficientAllowance();
        }

        debtPerTokenPerUser[msg.sender][token].availableCollateral += amountToDeposit;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountToDeposit);
    }

    /// @notice Borrow ETH using available deposited collateral
    /// @param amountToBorrow Amount of ETH to borrow
    /// @param token Address of the collateral token
    /// @param takeMaxAvailable Bool to take max ETH borrowable if not enough collateral
    function borrow(uint256 amountToBorrow, address token, bool takeMaxAvailable) public nonReentrant {
        if (amountToBorrow == 0) {
            revert Borrow__invalidAmount();
        }
        uint256 availableCollateral = debtPerTokenPerUser[msg.sender][token].availableCollateral;
        if (availableCollateral == 0) {
            revert Borrow__notEnoughCollateral(availableCollateral);
        }

        uint256 lockedCollateral = collateralToBorrow(token, amountToBorrow);
        if (lockedCollateral > availableCollateral) {
            if (takeMaxAvailable == false) {
                revert Borrow__notEnoughCollateral(availableCollateral);
            }
            lockedCollateral = availableCollateral;
            amountToBorrow = maxEthFrom(token, availableCollateral);
        }

        if (totalLiquidity == 0 || (amountToBorrow > totalLiquidity)) {
            revert Borrow__notEnoughLiquidity(totalLiquidity);
        }

        totalLiquidity -= amountToBorrow;
        uint256 scaledEth = amountToBorrow * WAD / globalIndex;
        totalBorrowScaled += scaledEth;
        debtPerTokenPerUser[msg.sender][token].debt += scaledEth;
        debtPerTokenPerUser[msg.sender][token].availableCollateral -= lockedCollateral;
        debtPerTokenPerUser[msg.sender][token].usedCollateral += lockedCollateral;

        (bool success,) = payable(msg.sender).call{value: amountToBorrow}("");
        if (!success) revert Borrow__invalidTransfer();
        emit UserBorrowedEth(msg.sender, token, amountToBorrow, amountToBorrow);
    }

    /// @notice Get the amount of collateral needed to borrow ETH
    /// @param token Address of collateral token
    /// @param amountToBorrow Amount of ETH user wants to borrow
    function collateralToBorrow(address token, uint256 amountToBorrow) internal view returns (uint256) {
        if (amountToBorrow == type(uint256).max) {
            return amountToBorrow;
        }
        uint256 ETHforSingleCollateral = maxEthFrom(token, WAD);
        return ETHforSingleCollateral * amountToBorrow / WAD;
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

    /// @notice Deposit specific collateral amount and borrow as much ETH as possible
    /// @param amountToDeposit Amount of collateral user wants to deposit
    /// @param token Address of the collateral token
    function depositCollateralAmountAndBorrowMax(uint256 amountToDeposit, address token) external {
        depositCollateral(amountToDeposit, token);
        borrow(type(uint256).max, token, true);
    }

    /// @notice Deposit as much collateral needed to borrow specific amount of ETH
    /// @param amountToBorrow Amount of ETH to borrow
    /// @param token Address of the collateral token
    function depositCollateralMaxAndBorrowAmount(uint256 amountToBorrow, address token) external {
        uint256 necessaryCollateral = collateralToBorrow(token, amountToBorrow);
        uint256 availableCollateral = debtPerTokenPerUser[msg.sender][token].availableCollateral;
        if (availableCollateral < necessaryCollateral) {
            depositCollateral(necessaryCollateral - availableCollateral, token);
        }
        borrow(type(uint256).max, token, true);
    }

    /// @notice Repay borrowed ETH and retrieve proportional collateral
    /// @param token Collateral token to repay against
    function repay(address token) external payable nonReentrant {
        if (msg.value == 0) revert Borrow__invalidAmount();
        if (debtPerTokenPerUser[msg.sender][token].debt == 0) revert Borrow__noDebtForCollateral(token);

        uint256 refund;
        uint256 principalDebt = debtPerTokenPerUser[msg.sender][token].debt;
        uint256 accruedDebt = principalDebt * globalIndex / WAD;
        //amount the user has paid back
        uint256 repaid = msg.value;

        //if the user pays back more than he owes, mark how much to refund
        if (repaid > accruedDebt) {
            refund = repaid - accruedDebt;
            repaid = accruedDebt;
        }

        //"original debt" (without interest), the user is repaying
        uint256 scaledRepaid = repaid * WAD / globalIndex;
        //total locked collateral
        uint256 userCollat = debtPerTokenPerUser[msg.sender][token].usedCollateral;
        //collateral to return to user in exchange for paying back
        uint256 returnCollateral;

        //if user has paid all his debt, all his collateral is returned
        if (scaledRepaid > principalDebt) {
            returnCollateral = userCollat;
            scaledRepaid = principalDebt;
        } else {
            returnCollateral = userCollat * scaledRepaid / principalDebt;
        }

        debtPerTokenPerUser[msg.sender][token].debt = principalDebt - scaledRepaid;
        debtPerTokenPerUser[msg.sender][token].usedCollateral = userCollat - returnCollateral;

        // totalInterests += repaid - scaledRepaid;
        totalBorrowScaled -= scaledRepaid;
        totalLiquidity += repaid;

        IERC20(token).safeTransfer(msg.sender, returnCollateral);
        if (refund != 0) {
            (bool success,) = payable(msg.sender).call{value: refund}("");
            if (!success) revert Borrow__invalidTransfer();
        }

        emit UserRepaidEth(msg.sender, token, repaid, returnCollateral);
    }

    /// @notice Accrue interest on all debts by updating global index
    /// @param rate Interest rate to apply (in WAD units, e.g., 1e16 = 1%)
    function accrueInterest(uint256 rate) external onlyRole(COLLATERAL_INTEREST_MANAGER_ROLE) {
        //calculate inflation
        // uint256 totalBorrows = totalBorrowScaled * globalIndex / WAD;
        // uint256 inflation = totalBorrows * WAD / totalLiquidity + totalBorrows;
        // if (inflation > maxBaseRate)
        //     rate += inflationRate * inflation / WAD;
        globalIndex = globalIndex * (WAD + rate) / WAD;
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
        // Collateral memory collateral = collateralPerToken[_token];

        uint256 realDebt = userDebt.debt * globalIndex / WAD;
        uint256 maxBorrow = maxEthFrom(_token, userDebt.usedCollateral);

        if (realDebt <= maxBorrow) revert Borrow__userNotUnderCollaterlized();
        if (msg.value == 0) revert Borrow__invalidAmount();

        uint256 payETH = msg.value;
        if (payETH > realDebt) {
            payETH = realDebt; // cap at total debt
        }

        uint256 seizedCollateral = userDebt.usedCollateral * payETH / realDebt;
        uint256 scaledPaid = payETH * WAD / globalIndex;
        userDebt.debt -= scaledPaid;
        userDebt.usedCollateral -= seizedCollateral;

        totalLiquidity += payETH;

        IERC20(_token).safeTransfer(msg.sender, seizedCollateral);

        if (msg.value > payETH) {
            (bool success,) = payable(msg.sender).call{value: msg.value - payETH}("");
            if (!success) {
                revert Borrow__invalidTransfer();
            }
        }
    }

    // /// @notice Update the rebase tokens interest based on total deposits and total interests
    // /// function should be called periodically and this contracts address needs to be granted role
    // /// to access the rebase token function of INDEX_MANAGER_ROLE by the rebasetoken contract
    function updateRebaseTokenInterest() external onlyRole(REBASETOKEN_INTEREST_MANAGER_ROLE) {
        uint256 rawSupply = i_rebaseToken.totalSupply();
        if (rawSupply == 0) return;
        uint256 totalAssets = totalLiquidity + (totalBorrowScaled * globalIndex / WAD);
        uint256 interestRate = WAD * totalAssets / rawSupply;
        i_rebaseToken.updateGlobalIndex(interestRate);
    }

    //GETTERS:

    /// @notice Get the current global interest index
    function getGlobalIndex() external view returns (uint256) {
        return globalIndex;
    }

    /// @notice Get total ETH deposits in the vault
    function getTotalLiquidity() external view returns (uint256) {
        return totalLiquidity;
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
}
