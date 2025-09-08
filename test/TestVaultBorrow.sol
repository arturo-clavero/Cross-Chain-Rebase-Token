// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../script/DeployRebaseToken.sol";
import "../src/Vault.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {RejectEth} from "./mocks/RejectEth.sol";
import {PriceFeedMock} from "./mocks/PriceFeedMock.sol";
import {PriceConverter} from "../src/libs/PriceConverter.sol";
import {RebaseToken} from "../src/RebaseToken.sol";
// import {VaultLendBase} from "./TestVaultLend.sol";
import {VaultCollateralBase} from "./TestVaultCollateral.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
// fund users with ETH for testing
// vm.deal(rebaseTokenIndexManager, FUND_AMOUNT);
// //grant roles
// vm.startPrank(admin);
// borrow.grantRole(borrow.INTEREST_MANAGER_ROLE(), rebaseTokenIndexManager);
// rebaseToken.grantRole(rebaseToken.INDEX_MANAGER_ROLE(), address(borrow));
// vm.stopPrank();

contract VaultBorrowBase is Test, VaultCollateralBase {
    using SafeERC20 for IERC20;

    uint256 public constant BORROW_AMOUNT = 5e23;

    address public interestManager = address(0x3);
    address public liquidator = address(0x6);
    uint256 internal initialUserBalance;
    uint256 internal initialTotalLiquidity;

    function setUpBorrow() internal {
        // fund users with ETH for testing
        vm.deal(interestManager, FUND_AMOUNT);
        vm.deal(liquidator, FUND_AMOUNT);

        //grant permission
        vm.startPrank(admin);
        vault.grantRole(vault.COLLATERAL_INTEREST_MANAGER_ROLE(), interestManager);
        vault.grantRole(vault.LIQUIDATOR_ROLE(), liquidator);
        vm.stopPrank();
    }

    // ---------- BORROW ----------
    function preCheckBorrow(address _user) internal {
        srcAddress = _user;
        initialUserBalance = _user.balance;
        initialTotalLiquidity = vault.getTotalLiquidity();
        (,, initialSrcBalance) = vault.debtPerTokenPerUser(_user, address(collateralToken));
        (, initialDstBalance,) = vault.debtPerTokenPerUser(_user, address(collateralToken));
    }

    function checkBorrow(uint256 amount) internal {
        console.log(amount);
        assertEq(initialUserBalance + amount, srcAddress.balance);
        assertEq(initialTotalLiquidity - amount, vault.getTotalLiquidity());
        (,, uint256 srcBalance) = vault.debtPerTokenPerUser(srcAddress, address(collateralToken));
        (, uint256 dstBalance,) = vault.debtPerTokenPerUser(srcAddress, address(collateralToken));
        if (amount == 0) {
            assertEq(initialSrcBalance, srcBalance);
            assertEq(initialDstBalance, dstBalance);
        } else {
            assertGt(initialSrcBalance, srcBalance);
            assertGt(dstBalance, initialDstBalance);
        }
    }

    function borrow(address _user, uint256 amount, bool shouldDeposit) internal {
        if (shouldDeposit) {
            depositCollateral(_user, amount * 2, true);
        }
        vm.prank(_user);
        vault.borrow(amount, address(collateralToken), false);
    }
}

contract TestVaultBorrow is Test, VaultBorrowBase {
    function setUp() public {
        setUpLend();
        setUpCollateral();
        setUpBorrow();
    }
    //------- BORROW TESTS -------//

    function testBorrowOk() public {
        depositCollateral(user, BORROW_AMOUNT, false);
        preCheckBorrow(user);
        borrow(user, BORROW_AMOUNT, true);
        checkBorrow(BORROW_AMOUNT);
    }

    function testBorrowEvent() public {
        depositCollateral(user, COLLATERAL_TOKEN_FUND_AMOUNT, false);
        vm.prank(user);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Vault.userBorrowedEth(user, address(collateralToken), BORROW_AMOUNT, BORROW_AMOUNT);
        vault.borrow(BORROW_AMOUNT, address(collateralToken), true);
    }

    function testBorrowInvalidAmount() public {
        depositCollateral(user, COLLATERAL_TOKEN_FUND_AMOUNT, false);
        preCheckBorrow(user);
        vm.prank(user);
        vm.expectRevert(Vault.Borrow__invalidAmount.selector);
        vault.borrow(0, address(collateralToken), true);
        checkBorrow(0);
    }

    function testBorrowNotEnoughLiquidity() public {
        //consume all liquidity
        uint256 totalLiquidity = vault.getTotalLiquidity();
        deal(user, totalLiquidity);
        borrow(user, totalLiquidity, true);
        uint256 newTotalLiquidity = vault.getTotalLiquidity();
        assertEq(newTotalLiquidity, 0);
        //borrow attempt
        depositCollateral(user, COLLATERAL_TOKEN_FUND_AMOUNT, false);
        preCheckBorrow(user);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__notEnoughLiquidity.selector, 0));
        vault.borrow(BORROW_AMOUNT, address(collateralToken), true);
        vm.stopPrank();
        checkBorrow(0);
    }

    function testBorrowNotEnoughCollateral() public {
        preCheckBorrow(user);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__notEnoughCollateral.selector, 0));
        vault.borrow(BORROW_AMOUNT, address(collateralToken), true);
        vm.stopPrank();
        checkBorrow(0);
    }

    function testBorrowNoMaxAvailableNotEnoughCollateral() public {
        uint256 smallAmount = COLLATERAL_TOKEN_FUND_AMOUNT / 10;
        depositCollateral(user, smallAmount, false);
        preCheckBorrow(user);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__notEnoughCollateral.selector, smallAmount));
        vault.borrow(type(uint256).max, address(collateralToken), false);
        vm.stopPrank();
        checkBorrow(0);
    }

    function testBorrowWithMaxAvailableNotEnoughCollateral() public {
        uint256 smallAmount = COLLATERAL_TOKEN_FUND_AMOUNT / 10;
        depositCollateral(user, smallAmount, false);
        preCheckBorrow(user);
        vm.prank(user);
        vault.borrow(type(uint256).max, address(collateralToken), true);
        checkBorrow(smallAmount); //heh?
    }

    function testBorrowUserRejects() public {
        depositCollateral(userRejector, COLLATERAL_TOKEN_FUND_AMOUNT, false);
        preCheckBorrow(userRejector);
        vm.prank(userRejector);
        vm.expectRevert(Vault.Borrow__invalidTransfer.selector);
        vault.borrow(BORROW_AMOUNT, address(collateralToken), true);
        checkBorrow(0);
    }

    //------- DEPOSIT-BORROW TESTS -------//
    function testDepositCollateralAmountBorrowMax() public {
        uint256 initialTokenBalance = collateralToken.balanceOf(user);
        initialTotalLiquidity = vault.getTotalLiquidity();
        initialUserBalance = user.balance;
        (,, initialSrcBalance) = vault.debtPerTokenPerUser(user, address(collateralToken));
        (, initialDstBalance,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        vm.prank(user);
        vault.depositCollateralAmountAndBorrowMax(COLLATERAL_TOKEN_FUND_AMOUNT, address(collateralToken));
        (,, uint256 srcBalance) = vault.debtPerTokenPerUser(user, address(collateralToken));
        (, uint256 dstBalance,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        assertGt(user.balance, initialUserBalance);
        assertEq(srcBalance, initialSrcBalance);
        assertEq(dstBalance, initialDstBalance + COLLATERAL_TOKEN_FUND_AMOUNT);
        assertEq(initialTokenBalance - COLLATERAL_TOKEN_FUND_AMOUNT, collateralToken.balanceOf(user));
        assertGt(initialTotalLiquidity, vault.getTotalLiquidity());
    }

    function testDepositCollateralAmountBorrowMaxOverflow() public {
        vm.prank(user);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        vault.depositCollateralAmountAndBorrowMax(type(uint256).max, address(collateralToken));
    }

    function testDepositCollateralMaxAndBorrowAmount() public {
        uint256 initialTokenBalance = collateralToken.balanceOf(user);
        initialTotalLiquidity = vault.getTotalLiquidity();
        initialUserBalance = user.balance;
        (,, initialSrcBalance) = vault.debtPerTokenPerUser(user, address(collateralToken));
        (, initialDstBalance,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        vm.prank(user);
        vault.depositCollateralMaxAndBorrowAmount(BORROW_AMOUNT, address(collateralToken));
        (,, uint256 srcBalance) = vault.debtPerTokenPerUser(user, address(collateralToken));
        (, uint256 dstBalance,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        assertGt(user.balance, initialUserBalance);
        assertEq(srcBalance, initialSrcBalance);
        assertGt(dstBalance, initialDstBalance);
        assertGt(initialTokenBalance, collateralToken.balanceOf(user));
        assertEq(initialTotalLiquidity - BORROW_AMOUNT, vault.getTotalLiquidity());
    }

    //------- REPAYMENT TESTS -------//
    function testPartialRepayUpdatesDebtAndCollateral() public {
        borrow(user, 1e18, true);
        vm.prank(interestManager);
        vault.accrueInterest(1e17); // 10%
        vm.startPrank(user);
        (uint256 debtBefore,,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        vault.repay{value: 0.5 ether}(address(collateralToken));
        (uint256 debt, uint256 collateral,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        assertLt(debt, debtBefore);
        assertLt(collateral, 1e18);
        vm.stopPrank();
    }

    function testFullRepayReturnsCollateralAndRefundsExcess() public {
        borrow(user, 1e18, true);
        vm.prank(interestManager);
        vault.accrueInterest(1e17); // 10%
        vm.startPrank(user);
        uint256 balBefore = collateralToken.balanceOf(user);
        vault.repay{value: 2 ether}(address(collateralToken));
        uint256 balAfter = collateralToken.balanceOf(user);
        (uint256 debt, uint256 collateral,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        assertEq(debt, 0);
        assertEq(collateral, 0);
        assertGt(balAfter, balBefore); // user got refund
        vm.stopPrank();
    }

    function testRefundsExcessInvalidTransfer() public {
        rejector.acceptPayment();
        borrow(address(rejector), 1e18, true);
        rejector.rejectPayment();
        vm.startPrank(address(rejector));
        uint256 balBefore = collateralToken.balanceOf(address(rejector));
        vm.expectRevert(Vault.Borrow__invalidTransfer.selector);
        vault.repay{value: 2 ether}(address(collateralToken));
        uint256 balAfter = collateralToken.balanceOf(address(rejector));
        vm.stopPrank();
        assertEq(balBefore, balAfter);
    }

    function testRepayZeroReverts() public {
        vm.startPrank(user);
        vm.expectRevert(Vault.Borrow__invalidAmount.selector);
        vault.repay{value: 0}(address(collateralToken));
        vm.stopPrank();
    }

    function testRepayNoDebtForCollateral() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__noDebtForCollateral.selector, address(collateralToken)));
        vault.repay{value: 1}(address(collateralToken));
        vm.stopPrank();
    }

    // ---------- INTEREST TESTS ----------
    function testAccrueInterestOnlyRole() public {
        vm.startPrank(interestManager);
        vault.accrueInterest(1e17); // 10%
        vm.stopPrank();
    }

    function testAccrueInterestRevertsForUnauthorized() public {
        vm.startPrank(user);
        vm.expectRevert();
        vault.accrueInterest(1e17);
        vm.stopPrank();
    }

    function testTotalInterestsUpdatedAfterRepay() public {
        borrow(user, 1e18, true);

        vm.prank(interestManager);
        vault.accrueInterest(1e17); // 10%

        vm.startPrank(user);
        uint256 totalBefore = vault.getTotalInterests();
        vault.repay{value: 1 ether}(address(collateralToken));
        uint256 totalAfter = vault.getTotalInterests();
        assertGt(totalAfter, totalBefore);
        vm.stopPrank();
    }

    //------- LIQUIDATOR MANAGEMENT TESTS -------//
    function testCannotLiquidateNoDebtUser() public {
        vm.prank(liquidator);
        vm.expectRevert(PriceConverter.PriceConverter__InvalidAmount.selector);
        vault.liquidate(user, address(collateralToken));
    }

    function testCannotLiquidateHealthyUser() public {
        borrow(user, 1e18, true);
        vm.prank(interestManager);
        vault.accrueInterest(1e17);
        vm.prank(liquidator);
        vm.expectRevert(Vault.Borrow__invalidAmount.selector);
        vault.liquidate(user, address(collateralToken));
    }

    function testLiquidatorMustSendETH() public {
        // Simulate undercollateralized user
        borrow(user, 100 * WAD, true);

        vm.prank(liquidator);
        vm.expectRevert(Vault.Borrow__userNotUnderCollaterlized.selector);
        vault.liquidate(user, address(collateralToken));
    }

    function testFullLiquidation() public {
        borrow(user, WAD, true);

        vm.prank(interestManager);
        vault.accrueInterest(10e17);

        // Pay full debt
        (uint256 realDebt,,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        uint256 ethToPay = realDebt * vault.getGlobalIndex() / WAD;

        vm.prank(liquidator);
        vault.liquidate{value: ethToPay}(user, address(collateralToken));

        (uint256 debt, uint256 collat,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        assertEq(debt, 0, "Debt should be zero after full liquidation");
        assertEq(collat, 0, "Collateral should be zero after full liquidation");

        uint256 liquidatorBal = collateralToken.balanceOf(liquidator);
        assertTrue(liquidatorBal > 0, "Liquidator should receive all collateral");
    }

    function testExcessETHRefund() public {
        borrow(user, WAD, true);

        vm.prank(interestManager);
        vault.accrueInterest(5e17);

        (uint256 realDebt,,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        uint256 ethToPay = realDebt * vault.getGlobalIndex() / WAD;

        // Send extra ETH
        uint256 excess = 5 ether;

        vm.deal(liquidator, 10 ether);
        uint256 initialBal = liquidator.balance;
        vm.prank(liquidator);
        vault.liquidate{value: ethToPay + excess}(user, address(collateralToken));

        uint256 finalBal = liquidator.balance;
        assertEq(initialBal - ethToPay, finalBal, "Excess ETH should be refunded");
    }

    function testExcessETHInvalidTransfer() public {
        borrow(user, WAD, true);

        vm.prank(interestManager);
        vault.accrueInterest(5e17);

        (uint256 realDebt,,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        uint256 ethToPay = realDebt * vault.getGlobalIndex() / WAD;

        // Send extra ETH
        uint256 excess = 5 ether;

        //grant rejector liquidator role
        vm.startPrank(admin);
        vault.grantRole(vault.LIQUIDATOR_ROLE(), address(rejector));
        vm.stopPrank();

        vm.deal(address(rejector), 10 ether);
        uint256 initialBal = address(rejector).balance;
        vm.prank(address(rejector));
        vm.expectRevert(Vault.Borrow__invalidTransfer.selector);
        vault.liquidate{value: ethToPay + excess}(user, address(collateralToken));

        uint256 finalBal = address(rejector).balance;
        assertEq(initialBal, finalBal, "ETH should not be transferred");
    }

    //------- REBASE TOKEN INTEREST RATES -------//
}

// //interest of rebase token:
//     function testUpdateRebaseTokenInterest_NotAuthorized() public {
//         vm.startPrank(user);
//         vm.expectRevert(
//             abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, borrow.INTEREST_MANAGER_ROLE())
//         );
//         borrow.updateRebaseTokenInterest();
//         vm.stopPrank();
//     }

//     function testUpdateRebaseTokenInterest_NoInterests() public {
//         vm.prank(interestManager);
//         borrow.updateRebaseTokenInterest();

//         uint256 globalIndex = rebaseToken.getGlobalIndex();
//         assertEq(globalIndex, WAD, "Index should remain 1.0 if no interest");
//     }

//     function testUpdateRebaseTokenInterest_WithBorrow() public {
//         testFullRepayReturnsCollateralAndRefundsExcess();
//         vm.prank(interestManager);
//         borrow.updateRebaseTokenInterest();
//         uint256 globalIndex = rebaseToken.getGlobalIndex();
//         assertGt(globalIndex, WAD, "Index should grow with interest");
//     }

// }
