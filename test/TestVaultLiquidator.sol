// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Vault.sol";
import {VaultBorrowBase} from "./TestVaultBorrow.sol";

contract VaultLiquidatorBase is Test, VaultBorrowBase {
    address public liquidator = address(0x6);

    function setUpLiquidator() internal {
        // fund users with ETH for testing
        vm.deal(liquidator, FUND_AMOUNT);

        //grant permission
        vm.startPrank(admin);
        vault.grantRole(vault.LIQUIDATOR_ROLE(), liquidator);
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
}
