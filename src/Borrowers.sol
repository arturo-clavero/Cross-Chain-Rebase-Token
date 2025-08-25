// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

struct Debt {
    uint256 debt;
    uint256 collateral;
}

struct Collateral {
    address priceFeed;
    uint256 LVM;
}

contract Borrow is AccessControl, ReentrancyGuard {
    error Borrow__invalidAmount();
    error Borrow__collateralTokenNotSupported(address);
    error Borrow__insufficientAllowance();
    error Borrow__invalidTransfer();
    error Borrow__noDebtForCollateral(address);
    error Borrow__collateralAlreadyExists();
    error Borrow__collateralDoesNotExist();
    error Borrow__invalidCollateralParams();

    uint256 private constant WAD = 1e18;
    bytes32 public constant INTEREST_MANAGER_ROLE = keccak256("INTEREST_MANAGER_ROLE");
    bytes32 public constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER_ROLE");
    uint256 private totalInterests;
    uint256 private globalIndex;
    mapping(address => Collateral) collateralPerToken;
    mapping(address => mapping(address => Debt)) debtPerTokenPerUser;

    event borrowedEth(address indexed user, address indexed token, uint256 amount, uint256 borrowedEth);
    event repaidEth(address indexed user, address indexed token, uint256 repaidAmount, uint256 returnedCollateral);

    using SafeERC20 for IERC20;

    constructor(address admin) {
        globalIndex = WAD;
        if (admin == address(0)) {
            admin = msg.sender;
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    //collateral of X amount of tokens address token
    //calc max eth borrawable from priceFeed + LVM
    //store collateral and amount borrowed compounded;
    //transfer borrowableETH
    function borrow(address token, uint256 amount) external nonReentrant {
        //CHECK:
        if (amount == 0) {
            revert Borrow__invalidAmount();
        }
        if (collateralPerToken[token].priceFeed == address(0)) {
            revert Borrow__collateralTokenNotSupported(token);
        }
        if (IERC20(token).allowance(msg.sender, address(this)) < amount) {
            revert Borrow__insufficientAllowance();
        }

        //EFFECT:
        uint256 borrowedEth = maxEthFrom(token, amount);
        uint256 scaledEth = borrowedEth * WAD / globalIndex;
        debtPerTokenPerUser[msg.sender][token].debt += scaledEth;
        debtPerTokenPerUser[msg.sender][token].collateral += amount;

        //INTERACTIONS
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        (bool success,) = payable(msg.sender).call{value: borrowedEth}();
        if (!success) {
            revert Borrow__invalidTransfer();
        }
        emit borrowedEth(msg.sender, token, amount, borrowedEth);
    }

    //receives ETH and token to repay
    //update debt and collateral
    //repay proportioanl / full colateral
    function repay(address token) external payable nonReentrant {
        //CHECKS
        if (msg.value == 0) {
            revert Borrow__insufficientAmount();
        }
        if (debtPerTokenPerUser[msg.sender][token].debt == 0) {
            revert Borrow__noDebtForCollateral(token);
        }

        //EFFECTS:
        uint256 refund;
        uint256 userScaled = debtPerTokenPerUser[msg.sender][token].debt;
        uint256 realDebt = userScaled * globalIndex / WAD;
        uint256 payETH = msg.value;
        if (payETH > realDebt) {
            refund = payETH - realDebt;
            payETH = realDebt;
        }
        uint256 scaledRepaid = payETH * WAD / globalIndex;

        // proportional collateral to return
        uint256 userCollat = debtPerTokenPerUser[msg.sender][token].collateral;
        uint256 returnedCollateral;
        if (scaledRepaid >= userScaled) {
            returnedCollateral = userCollat; // full close
            scaledRepaid = userScaled; // don’t underflow
        } else {
            returnedCollateral = userCollat * scaledRepaid / userScaled;
        }

        debtPerTokenPerUser[msg.sender][token].debt = userScaled - scaledRepaid;
        debtPerTokenPerUser[msg.sender][token].collateral = userCollat - returnedCollateral;

        uint256 interest = payETH - scaledRepaid;
        totalInterests += interest;

        //INTERACT:
        IERC20(token).safeTransfer(msg.sender, returnedCollateral);
        if (refund) {
            (bool success,) = payable(msg.sender).call{value: refund}();
            if (!success) {
                revert Borrow__invalidTransfer();
            }
        }
        emit repaidEth(msg.sender, token, payETH, returnedCollateral);
    }

    function accrueInterest(uint256 rate) external onlyRole(INTEREST_MANAGER_ROLE) {
        globalIndex = globalIndex * (WAD + rate) / WAD;
    }

    function getTotalInterests() external view returns (uint256) {
        return totalInterests;
    }

    //COLLATERAL MANGEMENT
    function addCollateral(address _token, address _priceFeed, uint256 _LVM)
        external
        onlyRole(COLLATERAL_MANAGER_ROLE)
    {
        if (collateralPerToken[_token].LVM == 0) {
            revert Borrow__collateralAlreadyExists();
        }
        modifyCollateral(_token, _priceFeed, _LVM);
    }

    function modifyCollateralPriceFeed(address _token, address _priceFeed) external onlyRole(COLLATERAL_MANAGER_ROLE) {
        if (_priceFeed == address(0)) {
            revert Borrow__invalidCollateralParams();
        }
        if (collateralPerToken[_token].LVM == 0) {
            revert Borrow__collateralDoestNotexist();
        }
        collateralPerToken[_token].priceFeed = _priceFeed;
    }

    function modifyCollateralLVM(address _token, uint256 _LVM) external onlyRole(COLLATERAL_MANAGER_ROLE) {
        if (_LVM < WAD) {
            revert Borrow__invalidCollateralParams();
        }
        if (collateralPerToken[_token].LVM == 0) {
            revert Borrow__collateralDoestNotexist();
        }
        collateralPerToken[_token].LVM = _LVM;
    }

    function modifyCollateral(address _token, address _priceFeed, uint256 _LVM)
        public
        onlyRole(COLLATERAL_MANAGER_ROLE)
    {
        if (_token == address(0) || _priceFeed == address(0) || _LVM < WAD) {
            revert Borrow__invalidCollateralParams();
        }
        collateralPerToken[_token] = Collateral({priceFeed: _priceFeed, LVM: _LVM});
    }

    //MATH HELPER
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
