// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Vault.sol";
import {VaultBorrowBase} from "./TestVaultBorrow.sol";

contract VaultLiquidatorBase is Test, VaultBorrowBase {
    address public liquidator = address(0x6);
    address public liquidityManager = address(0x6);

    function setUpLiquidator() internal {
        // fund users with ETH for testing
        vm.deal(liquidator, FUND_AMOUNT);
        vm.deal(liquidityManager, FUND_AMOUNT);

        //grant permission
        vm.startPrank(admin);
        vault.grantRole(vault.LIQUIDATOR_ROLE(), liquidator);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), liquidityManager);
        vm.stopPrank();
    }
}

contract TestVaultBorrow is Test, VaultLiquidatorBase {
    function setUp() public {
        setUpLend();
        setUpCollateral();
        setUpBorrow();
        setUpLiquidator();
    }

    //------- LIQUIDATOR TESTS -------//
    function testCannotLiquidateUnsupportedToken() public {
        address unsupportedToken = vm.addr(404);
        borrow(user, WAD, true, false);

        vm.prank(interestManager);
        vault.accrueBorrowDebtInterest(10e17);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__collateralTokenNotSupported.selector, unsupportedToken));
        vault.liquidate{value: WAD}(user, unsupportedToken);
    }

    function testCannotLiquidateNoDebtUser() public {
        vm.prank(interestManager);
        vault.accrueBorrowDebtInterest(10e17);

        vm.prank(liquidator);
        vm.expectRevert(PriceConverter.PriceConverter__InvalidAmount.selector);
        vault.liquidate{value: WAD}(user, address(collateralToken));
    }

    function testCannotLiquidateHealthyUser() public {
        borrow(user, 1e18, true, false);

        vm.prank(liquidator);
        vm.expectRevert(Vault.Vault__userNotUnderCollaterlized.selector);
        vault.liquidate{value: WAD}(user, address(collateralToken));
    }

    function testLiquidatorMustSendETH() public {
        borrow(user, 100 * WAD, true, false);

        vm.prank(interestManager);
        vault.accrueBorrowDebtInterest(10e17);

        vm.prank(liquidator);
        vm.expectRevert(Vault.Vault__invalidAmount.selector);
        vault.liquidate(user, address(collateralToken));
    }

    function testFullliquidity() public {
        borrow(user, WAD, true, false);

        vm.prank(interestManager);
        vault.accrueBorrowDebtInterest(10e17);

        // Pay full debt
        (uint256 realDebt,,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        uint256 ethToPay = realDebt * vault.getBorrowDebtIndex() / WAD;

        vm.prank(liquidator);
        vault.liquidate{value: ethToPay}(user, address(collateralToken));

        (uint256 debt, uint256 collat,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        assertEq(debt, 0, "Debt should be zero after full liquidity");
        assertEq(collat, 0, "Collateral should be zero after full liquidity");

        uint256 liquidatorBal = collateralToken.balanceOf(liquidator);
        assertTrue(liquidatorBal > 0, "Liquidator should receive all collateral");
    }

    function testExcessETHRefund() public {
        borrow(user, WAD, true, false);

        vm.prank(interestManager);
        vault.accrueBorrowDebtInterest(55e16);

        (uint256 realDebt,,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        uint256 ethToPay = realDebt * vault.getBorrowDebtIndex() / WAD;

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
        borrow(user, WAD, true, false);
        vm.prank(interestManager);
        vault.accrueBorrowDebtInterest(55e16);

        (uint256 realDebt,,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        uint256 ethToPay = realDebt * vault.getBorrowDebtIndex() / WAD;

        // Send extra ETH
        uint256 excess = 5 ether;

        //grant rejector liquidator role
        vm.startPrank(admin);
        vault.grantRole(vault.LIQUIDATOR_ROLE(), address(rejector));
        vm.stopPrank();

        vm.deal(address(rejector), 10 ether);
        uint256 initialBal = address(rejector).balance;
        vm.prank(address(rejector));
        vm.expectRevert(Vault.Vault__invalidTransfer.selector);
        vault.liquidate{value: ethToPay + excess}(user, address(collateralToken));

        uint256 finalBal = address(rejector).balance;
        assertEq(initialBal, finalBal, "ETH should not be transferred");
    }

    //------- LIQUIDATOR MANAGEMENT TESTS -------//
    function testsetLiquidityThresholdWrongRole() public {
        uint256 initialAmount = vault.getLiquidityThreshold();
        vm.prank(user);
        vm.expectRevert();
        vault.setLiquidityThreshold(WAD);
        assertEq(initialAmount, vault.getLiquidityThreshold());
    }

    function testsetLiquidityThresholdWrongAmount() public {
        uint256 initialAmount = vault.getLiquidityPrecision();

        vm.prank(liquidityManager);
        vm.expectRevert(Vault.Vault__invalidAmount.selector);
        vault.setLiquidityThreshold(WAD + 1);
        assertEq(initialAmount, vault.getLiquidityPrecision());

        vm.prank(liquidityManager);
        vm.expectRevert(Vault.Vault__invalidAmount.selector);
        vault.setLiquidityThreshold(1e17 - 1);
        assertEq(initialAmount, vault.getLiquidityPrecision());
    }

    function testsetLiquidityThresholdOk() public {
        uint256 initialAmount = vault.getLiquidityThreshold();
        uint256 newAmount = WAD / 2;
        assertNotEq(initialAmount, newAmount);
        vm.prank(liquidityManager);
        vault.setLiquidityThreshold(newAmount);
        assertEq(newAmount, vault.getLiquidityThreshold());
    }

    function testsetLiquidityPrecisionWrongRole() public {
        uint256 initialAmount = vault.getLiquidityPrecision();
        vm.prank(user);
        vm.expectRevert();
        vault.setLiquidityPrecision(WAD);
        assertEq(initialAmount, vault.getLiquidityPrecision());
    }

    function testsetLiquidityPrecisionWrongAmount() public {
        uint256 initialAmount = vault.getLiquidityPrecision();

        vm.prank(liquidityManager);
        vm.expectRevert(Vault.Vault__invalidAmount.selector);
        vault.setLiquidityPrecision(WAD + 1);
        assertEq(initialAmount, vault.getLiquidityPrecision());
    }

    function testsetLiquidityPrecisionOk() public {
        uint256 initialAmount = vault.getLiquidityPrecision();
        uint256 newAmount = WAD / 2;
        assertNotEq(initialAmount, newAmount);
        vm.prank(liquidityManager);
        vault.setLiquidityPrecision(newAmount);
        assertEq(newAmount, vault.getLiquidityPrecision());
    }

    function testUserHealthy() public {
        borrow(user, 2e18, true, false);

        console.log("interest a          : ", vault.getBorrowDebtIndex());

        vm.prank(liquidityManager);
        vault.setLiquidityThreshold(2e17);

        vm.prank(interestManager);
        vault.accrueBorrowDebtInterest(1e17);
        console.log("interest b          : ", vault.getBorrowDebtIndex());
        console.log("liquidity threshold : ", vault.getLiquidityThreshold());
        (uint256 debt,,) = vault.debtPerTokenPerUser(user, address(collateralToken));

        console.log("debt                : ", debt);
        console.log("debt accrued        : ", debt * vault.getBorrowDebtIndex() / WAD);

        // uint256 maxDebtCovered = vault.ethFrom(address(collateralToken), lockedCollateral);
        // console.log("debt max            : ", maxDebtCovered);
        // console.log("limit               : ", maxDebtCovered * (WAD - vault.getLiquidityThreshold()) / WAD );

        vm.prank(liquidator);
        vm.expectRevert(Vault.Vault__userNotUnderCollaterlized.selector);
        vault.liquidate{value: WAD}(user, address(collateralToken));
        // bool healthy = vault.isHealthy(user, address(collateralToken));
        // assertEq(healthy, true, "User should be healthy");
    }

    function testUserUnhealthy() public {
        borrow(user, 2e18, true, false);

        console.log("interest a          : ", vault.getBorrowDebtIndex());

        vm.prank(liquidityManager);
        vault.setLiquidityThreshold(3e17);

        vm.prank(interestManager);
        vault.accrueBorrowDebtInterest(2e17);
        console.log("interest b          : ", vault.getBorrowDebtIndex());
        console.log("liquidity threshold : ", vault.getLiquidityThreshold());
        (uint256 debt,,) = vault.debtPerTokenPerUser(user, address(collateralToken));

        console.log("debt                : ", debt);
        console.log("debt accrued        : ", debt * vault.getBorrowDebtIndex() / WAD);

        // uint256 maxDebtCovered = vault.ethFrom(address(collateralToken), lockedCollateral);
        // console.log("debt max            : ", maxDebtCovered);
        // console.log("limit               : ", maxDebtCovered * (WAD - vault.getLiquidityThreshold()) / WAD );

        vm.prank(liquidator);
        vault.liquidate{value: WAD}(user, address(collateralToken));
        // bool healthy = vault.isHealthy(user, address(collateralToken));
        // assertEq(healthy, false, "User should be unhealthy");
    }

    function testLiquidateReward() public {
        uint256 repayment = WAD * 3;

        borrow(user, WAD, true, false);
        vm.prank(interestManager);
        vault.accrueBorrowDebtInterest(2 * WAD);
        hoax(liquidator, repayment);
        vault.liquidate{value: repayment}(user, address(collateralToken));
        uint256 noRewardBalance = liquidator.balance;

        // hoax(user, WAD * 100);
        // vault.repay{value : WAD * 100}(address(collateralToken));
        // (uint256 debt, ,) = vault.debtPerTokenPerUser(user, address(collateralToken));
        // assertEq(debt, 0);

        borrow(user, WAD, true, false);
        vm.prank(interestManager);
        vault.accrueBorrowDebtInterest(2 * WAD);
        vm.prank(liquidityManager);
        vault.setLiquidityPrecision(2e17);
        hoax(liquidator, repayment);
        vault.liquidate{value: repayment}(user, address(collateralToken));
        uint256 rewardBalance = liquidator.balance;
        assertGt(rewardBalance, noRewardBalance);
    }
}
