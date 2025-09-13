// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./interfaces/IRebaseToken.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PriceConverter} from "./libs/PriceConverter.sol";

//TODO
//interest accrual automation ?
//chainlink cross chain logic integration ...

/// @notice Struct for borrowing data associated per user, per collateral token address
/// @param debt Amount of debt the user owes associated with specific token includes
/// @param lockedCollateral Amount of collateral locked for user's borrowed ETH that has not yet been repaid
/// @param availableCollateral Amount of collateral user has deposited and can be used to borrow ETH
struct Debt {
    uint256 debt;
    uint256 lockedCollateral;
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
    error Vault__insufficientLiquidity();
    error Vault__transferFailed();
    error Vault__invalidAmount();
    error Vault__collateralTokenNotSupported(address);
    error Vault__insufficientAllowance();
    error Vault__invalidTransfer();
    error Vault__noDebtForCollateral(address);
    error Vault__collateralAlreadyExists();
    error Vault__collateralDoesNotExist();
    error Vault__invalidCollateralParams();
    error Vault__notEnoughLiquidity(uint256 totalEthAvailable);
    error Vault__notEnoughCollateral(uint256 totalCollateralAvailable);
    error Vault__userNotUnderCollaterlized();

    uint256 private constant WAD = 1e18;
    bytes32 public constant BORROW_INTEREST_MANAGER_ROLE = keccak256("BORROW_INTEREST_MANAGER_ROLE");
    bytes32 public constant REBASETOKEN_INTEREST_MANAGER_ROLE = keccak256("REBASETOKEN_INTEREST_MANAGER_ROLE");
    bytes32 public constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    bytes32 public constant LIQUIDATOR_MANAGER_ROLE = keccak256("LIQUIDATOR_MANAGER_ROLE");
    uint256 private constant MIN_LIQUIDITY_THRESHOLD = 1e17;
    uint256 private constant MIN_LIQUIDITY_HEALTH_RATE = 4e17;
    /// @dev how soon you get liquidated (in WAD)
    uint256 private liquidityThreshold;
    /// @dev rewards from debt interests for liqborrowDebtIndexuidators (in WAD)
    uint256 private liquidityPrecision;
    /// @dev total amount of ETH available in the vault (in WAD)
    uint256 private totalLiquidity;
    /// @dev total amount of borrowed ETH scaled (scaled by borrowDebtIndex) in WAD
    uint256 private totalBorrowScaled;
    /// @dev current global rate of interest for user debt
    uint256 private borrowDebtIndex;

    /// @dev rebase token contract to mint in exchange for lending
    IRebaseToken private immutable i_rebaseToken;

    /// @dev collateral data (LVM, pricefeed) per supported token
    mapping(address => Collateral) public collateralPerToken;
    /// @dev amount of debt per user per token
    mapping(address => mapping(address => Debt)) public debtPerTokenPerUser;
    // /// @dev list of supported collateral tokens
    // address[] supportedCollateral;

    /// @notice Emitted when a user borrows ETH
    event UserBorrowedEth(address indexed user, address indexed token, uint256 amount, uint256 borrowedEth);
    /// @notice Emitted when a user repays ETH
    event UserRepaidEth(address indexed user, address indexed token, uint256 repaidAmount, uint256 returnedCollateral);

    /// @param _rebaseToken The token used to represent deposits
    /// @param admin Admin account to manage roles
    constructor(address _rebaseToken, address admin) {
        i_rebaseToken = IRebaseToken(_rebaseToken);
        borrowDebtIndex = WAD;
        liquidityThreshold = MIN_LIQUIDITY_THRESHOLD;
        if (admin == address(0)) {
            admin = msg.sender;
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Deposit ETH into the vault for the sender
    function deposit() external payable {
        depositTo(msg.sender);
    }

    /// @notice Withdraw ETH by burning rebase tokens
    /// @param amount Amount of ETH to withdraw
    /// if amount is max uint we will take the total of the users balance
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert Vault__invalidAmount();
        if (amount == type(uint256).max) {
            amount = i_rebaseToken.balanceOf(msg.sender);
        }
        if (totalLiquidity < amount) revert Vault__insufficientLiquidity();
        //TODO!

        totalLiquidity -= amount;

        i_rebaseToken.burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert Vault__transferFailed();
    }

    /// @notice Repay borrowed ETH and retrieve proportional collateral
    /// @param _token Collateral token to repay against
    function repay(address _token) external payable nonReentrant {
        if (msg.value == 0) revert Vault__invalidAmount();

        Debt storage userDebt = debtPerTokenPerUser[msg.sender][_token];
        if (userDebt.debt == 0) revert Vault__noDebtForCollateral(_token);

        uint256 refund;
        uint256 principalDebt = userDebt.debt;
        uint256 accruedDebt = principalDebt * borrowDebtIndex / WAD;

        //amount the user has paid back
        uint256 repaid = msg.value;

        //if the user pays back more than he owes, mark how much to refund
        if (repaid > accruedDebt) {
            refund = repaid - accruedDebt;
            repaid = accruedDebt;
        }

        //"original debt" (without interest), the user is repaying
        uint256 scaledRepaid = repaid * WAD / borrowDebtIndex;
        //total locked collateral
        uint256 userCollat = userDebt.lockedCollateral;
        //collateral to return to user in exchange for paying back
        uint256 returnCollateral;

        //if user has paid all his debt, all his collateral is returned
        if (scaledRepaid >= principalDebt) {
            returnCollateral = userCollat;
            scaledRepaid = principalDebt;
        } else {
            returnCollateral = userCollat * scaledRepaid / principalDebt;
        }

        userDebt.debt = principalDebt - scaledRepaid;
        userDebt.lockedCollateral = userCollat - returnCollateral;

        totalBorrowScaled -= scaledRepaid;
        totalLiquidity += repaid;

        IERC20(_token).safeTransfer(msg.sender, returnCollateral);
        if (refund != 0) {
            (bool success,) = payable(msg.sender).call{value: refund}("");
            if (!success) revert Vault__invalidTransfer();
        }

        emit UserRepaidEth(msg.sender, _token, repaid, returnCollateral);
    }

    /// @notice Accrue interest on all debts by updating global index
    /// @param rate Interest rate to apply (in WAD units, e.g., 1e16 = 1%)
    function accrueBorrowDebtInterest(uint256 rate) external onlyRole(BORROW_INTEREST_MANAGER_ROLE) {
        borrowDebtIndex = borrowDebtIndex * (WAD + rate) / WAD;
    }

    /// @notice Liquidates a user’s position if undercollateralized
    /// @dev The liquidator must send ETH to cover part or all of the user’s debt
    ///      Collateral is seized proportionally to the ETH paid
    /// @param _user The address of the user being liquidated
    /// @param _token The collateral token used by the user
    function liquidate(address _user, address _token) external payable nonReentrant onlyRole(LIQUIDATOR_ROLE) {
        if (msg.value == 0) revert Vault__invalidAmount();

        Debt storage userDebt = debtPerTokenPerUser[_user][_token];
        uint256 accruedDebt = userDebt.debt * borrowDebtIndex / WAD;

        if (isHealthy(_user, _token)) revert Vault__userNotUnderCollaterlized();

        uint256 refund;
        uint256 repaid = msg.value;
        if (repaid > accruedDebt) {
            refund = repaid - accruedDebt;
            repaid = accruedDebt; // cap at total debt
        }

        uint256 seizedCollateral = userDebt.lockedCollateral * repaid / accruedDebt;
        uint256 scaledPaid = repaid * WAD / borrowDebtIndex;
        userDebt.debt -= scaledPaid;
        userDebt.lockedCollateral -= seizedCollateral;

        totalLiquidity += repaid;

        IERC20(_token).safeTransfer(msg.sender, seizedCollateral);

        //calculate reward..
        if (liquidityPrecision > 0) {
            uint256 precisionReward = scaledPaid * liquidityPrecision / accruedDebt;
            uint256 interests = repaid - scaledPaid;
            refund += interests * precisionReward / WAD;
        }

        if (refund != 0) {
            (bool success,) = payable(msg.sender).call{value: refund}("");
            if (!success) revert Vault__invalidTransfer();
        }
    }

    /// @notice Liquidator Manager can update the liquidityThreshold
    /// @dev threshold refers to the minimum collateral ratio a user must maintain to avoid liquidity
    /// @param _threshold is the new liquidityThreshold
    function setLiquidityThreshold(uint256 _threshold) external onlyRole(LIQUIDATOR_MANAGER_ROLE) {
        if (_threshold < MIN_LIQUIDITY_THRESHOLD || _threshold > WAD) revert Vault__invalidAmount();
        liquidityThreshold = _threshold;
    }

    /// @notice Liquidator Manager can update the liquidityPrecision
    /// @dev precision refers to the percentage reward they can keep
    /// @param _precision is the new liquidityPrecision
    function setLiquidityPrecision(uint256 _precision) external onlyRole(LIQUIDATOR_MANAGER_ROLE) {
        if (_precision > WAD) revert Vault__invalidAmount();
        liquidityPrecision = _precision;
    }

    /// @notice Update the rebase tokens interest based on total deposits and total interests
    /// function should be called periodically and this contracts address needs to be granted role
    /// to access the rebase token function of INDEX_MANAGER_ROLE by the rebasetoken contract
    function updateRebaseTokenInterest() external onlyRole(REBASETOKEN_INTEREST_MANAGER_ROLE) {
        uint256 rawSupply = i_rebaseToken.totalSupply();
        if (rawSupply == 0) return;
        uint256 totalAssets = totalLiquidity + (totalBorrowScaled * borrowDebtIndex / WAD);
        uint256 interestRate = WAD * totalAssets / rawSupply;
        i_rebaseToken.updateGlobalIndex(interestRate);
    }

    //GETTERS:
    function getBorrowDebtIndex() external view returns (uint256) {
        return borrowDebtIndex;
    }

    function getTotalLiquidity() external view returns (uint256) {
        return totalLiquidity;
    }

    function getLiquidityThreshold() external view returns (uint256) {
        return liquidityThreshold;
    }

    function getLiquidityPrecision() external view returns (uint256) {
        return liquidityPrecision;
    }

    /// @notice Deposit ETH on behalf of an account
    /// @param account Address to receive minted rebase tokens
    function depositTo(address account) public payable {
        if (msg.value == 0) revert Vault__invalidAmount();

        totalLiquidity += msg.value;

        i_rebaseToken.mint(account, msg.value);
    }

    /// @notice Deposit token as collateral to borrow ETH
    /// @param amountToDeposit Amount of collateral to deposit
    /// @param token Address of the collateral token
    function depositCollateral(uint256 amountToDeposit, address token) public nonReentrant {
        if (amountToDeposit == 0) revert Vault__invalidAmount();
        if (collateralPerToken[token].priceFeed == address(0)) revert Vault__collateralTokenNotSupported(token);
        if (IERC20(token).allowance(msg.sender, address(this)) < amountToDeposit) {
            revert Vault__insufficientAllowance();
        }

        debtPerTokenPerUser[msg.sender][token].availableCollateral += amountToDeposit;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountToDeposit);
    }

    /// @notice helper to add or modify collateral parameters
    function modifyCollateral(address _token, address _priceFeed, uint256 _LVM)
        public
        onlyRole(COLLATERAL_MANAGER_ROLE)
    {
        if (_token == address(0) || _priceFeed == address(0) || _LVM < WAD) {
            revert Vault__invalidCollateralParams();
        }
        collateralPerToken[_token] = Collateral({priceFeed: _priceFeed, LVM: _LVM});
    }

    /// @notice Borrow ETH using available deposited collateral
    /// @param amountToBorrow Amount of ETH to borrow
    /// @param token Address of the collateral token
    /// @param takeMaxAvailable Bool to take max ETH borrowable if not enough collateral
    function borrow(uint256 amountToBorrow, address token, bool takeMaxAvailable) public nonReentrant {
        if (amountToBorrow == 0) {
            revert Vault__invalidAmount();
        }
        uint256 availableCollateral = debtPerTokenPerUser[msg.sender][token].availableCollateral;
        if (availableCollateral == 0) {
            revert Vault__notEnoughCollateral(availableCollateral);
        }

        uint256 lockedCollateral = collateralToBorrow(token, amountToBorrow);
        if (lockedCollateral > availableCollateral) {
            if (takeMaxAvailable == false) {
                revert Vault__notEnoughCollateral(availableCollateral);
            }
            lockedCollateral = availableCollateral;
            amountToBorrow = maxEthFrom(token, availableCollateral);
        }

        uint256 maxAmount = maxExtractableLiquidity();
        if (maxAmount == 0)
            revert Vault__notEnoughLiquidity(maxAmount);
        if (amountToBorrow > maxAmount){
            if (takeMaxAvailable == false) {
                revert Vault__notEnoughLiquidity(maxAmount);
            }
            amountToBorrow = maxAmount;
        }
        totalLiquidity -= amountToBorrow;

        uint256 scaledEth = amountToBorrow * WAD / borrowDebtIndex;
        totalBorrowScaled += scaledEth;
        debtPerTokenPerUser[msg.sender][token].debt += scaledEth;
        debtPerTokenPerUser[msg.sender][token].availableCollateral -= lockedCollateral;
        debtPerTokenPerUser[msg.sender][token].lockedCollateral += lockedCollateral;

        (bool success,) = payable(msg.sender).call{value: amountToBorrow}("");
        if (!success) revert Vault__invalidTransfer();
        emit UserBorrowedEth(msg.sender, token, amountToBorrow, amountToBorrow);
    }

    function maxExtractableLiquidity() public view returns (uint256) {
        uint256 liquidityHealthRate = getLiquidityHealthRate();
        if (MIN_LIQUIDITY_HEALTH_RATE >= liquidityHealthRate)
            return 0;
        uint256 leftOver = liquidityHealthRate - MIN_LIQUIDITY_HEALTH_RATE;
        return totalLiquidity * leftOver / WAD;
    }

    /// @notice checks health status to evaluate if should liquidate
    /// @dev returns true if liquidity is required, false if no need to liquidate
    /// @param _user user's debt being checked
    /// @param _token user's token's debt being checked
    function isHealthy(address _user, address _token) internal view returns (bool) {
        Debt memory userDebt = debtPerTokenPerUser[_user][_token];
        uint256 accruedDebt = userDebt.debt * borrowDebtIndex / WAD;
        uint256 maxDebtCovered = ethFrom(_token, userDebt.lockedCollateral);
        // return (accruedDebt < maxDebtCovered * (WAD - liquidityThreshold) / WAD);
        //liquiditythreshold can not be WAD?
        return (accruedDebt < maxDebtCovered * (WAD - getLiquidityUpdatedThreshold()) / WAD);
    }

    /// @notice Get the amount of collateral needed to borrow ETH
    /// @param _token Address of collateral token
    /// @param amountToBorrow Amount of ETH user wants to borrow
    function collateralToBorrow(address _token, uint256 amountToBorrow) internal view returns (uint256) {
        if (amountToBorrow == type(uint256).max) {
            return amountToBorrow;
        }
        uint256 ETHforSingleCollateral = maxEthFrom(_token, WAD);
        return amountToBorrow * WAD / ETHforSingleCollateral;
    }

    /// @notice Compute max ETH borrowable from a given collateral amount
    /// @param _token Collateral token address
    /// @param amount Amount of collateral
    /// @return amountInEth Maximum ETH that can be borrowed
    function maxEthFrom(address _token, uint256 amount) internal view returns (uint256) {
        Collateral memory collateral = collateralPerToken[_token];
        uint256 amountInEth = ethFrom(_token, amount);
        return amountInEth * WAD / collateral.LVM;
    }

    /// @notice Compute conversion to ETH from a given collateral amount
    /// @param _token Collateral token address
    /// @param amount Amount of collateral
    function ethFrom(address _token, uint256 amount) internal view returns (uint256) {
        Collateral memory collateral = collateralPerToken[_token];
        if (collateral.priceFeed == address(0)) revert Vault__collateralTokenNotSupported(_token);
        return PriceConverter.getRates(amount, collateral.priceFeed);
    }
//0 bad, WAD very good
//200 / 100 
//should be internal
    function getLiquidityHealthRate() internal view returns (uint256) {
        if (totalLiquidity == 0)
            return 0;
        uint256 totalSupply = i_rebaseToken.totalSupply();
        if (totalSupply == 0)
            return WAD;
        uint256 healthRate = totalLiquidity * WAD/ (totalSupply * i_rebaseToken.getGlobalIndex() / WAD);
        return healthRate > WAD ? WAD : healthRate;
    }
//if liqquidity health rate = bad -> block withdraw, block borrow,
// liquidity threshold increase 1 - healht rate

//should be internal
    function getLiquidityUpdatedThreshold() internal view returns (uint256){
        uint256 liquidityHealth = getLiquidityHealthRate();
        if (liquidityHealth == 0)
            return WAD;

        uint256 idealLiquidityThreshold = WAD - liquidityHealth;
        return idealLiquidityThreshold > liquidityThreshold ? idealLiquidityThreshold : liquidityThreshold;        
        // Xth 0.8 -> hr 0.2 good. 
        // hr 0.1 XTH -> 0.9
        //1 - hr = ideal healthrate
        //0.1 -> 0.9 ideal
        //0.8 -> 0.2 ideal 
        //0
    }
}

//front end:
//LEND:
//buttons :
//deposit
//deposit to
//withdraw

//display
//current total assets + borrows
//current total interests
//users accrued interest ?
//past txs of buttons ?

//BORROW:
//buttons :
//borrow
//repay
//depositCollateral

//display :
//current total assets + borrows
//available liquidity
//supported collateral tokens + LVMs
//past txs of buttons ?
