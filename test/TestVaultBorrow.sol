// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Vault.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {VaultCollateralBase} from "./TestVaultCollateral.sol";

contract VaultBorrowBase is Test, VaultCollateralBase {
    using SafeERC20 for IERC20;

    uint256 public constant BORROW_AMOUNT = 4e23;

    address public interestManager = address(0x32);
    address public rebaseTokenIndexManager = address(0x33);
    uint256 internal initialUserBalance;
    uint256 internal initialTotalLiquidity;
    uint256 internal initiallockedCollateral;
    uint256 internal initialDebt;

    function setUpBorrow() internal {
        // fund users with ETH for testing
        vm.deal(interestManager, FUND_AMOUNT);
        vm.deal(rebaseTokenIndexManager, FUND_AMOUNT);

        //grant permission
        vm.startPrank(admin);
        vault.grantRole(vault.BORROW_INTEREST_MANAGER_ROLE(), interestManager);
        vault.grantRole(vault.REBASETOKEN_INTEREST_MANAGER_ROLE(), rebaseTokenIndexManager);
        vm.stopPrank();
    }

    // ---------- BORROW ---------- //
    function preCheckBorrow(address _user) internal {
        srcAddress = _user;
        initialUserBalance = _user.balance;
        initialTotalLiquidity = vault.getTotalLiquidity();
        (,, initialSrcBalance) = vault.debtPerTokenPerUser(_user, address(collateralToken));
        (, initialDstBalance,) = vault.debtPerTokenPerUser(_user, address(collateralToken));
        (initialDebt,,) = vault.debtPerTokenPerUser(srcAddress, address(collateralToken));
    }

    function checkBorrow(uint256 amount) internal view {
        console.log(amount);
        (,, uint256 srcBalance) = vault.debtPerTokenPerUser(srcAddress, address(collateralToken));
        (, uint256 dstBalance,) = vault.debtPerTokenPerUser(srcAddress, address(collateralToken));
        (uint256 debt,,) = vault.debtPerTokenPerUser(srcAddress, address(collateralToken));
        if (amount == 0) {
            assertEq(srcAddress.balance, initialUserBalance, "user balance unchanged");
            assertEq(vault.getTotalLiquidity(), initialTotalLiquidity, "total liquidity unchanged");
            assertEq(initialSrcBalance, srcBalance, "0 borrow amount, no change in available collateral");
            assertEq(initialDstBalance, dstBalance, "0 borrow amount, no change in used collateral");
            assertEq(initialDebt, debt, "0 borrow amount, no change in debt balance");
        } else {
            assertGt(srcAddress.balance, initialUserBalance, "user balance increased");
            assertLt(vault.getTotalLiquidity(), initialTotalLiquidity, "total liquidity decreased");
            assertLt(srcBalance, initialSrcBalance, "available collateral should decrease");
            assertGt(dstBalance, initialDstBalance, "used collateral should increase");
            assertGt(debt, initialDebt, "debt should increase");
        }
    }

    function borrow(address _user, uint256 amount, bool shouldDeposit) internal {
        if (shouldDeposit) {
            depositCollateral(_user, amount * 2, true);
        }
        vm.prank(_user);
        vault.borrow(amount, address(collateralToken), false);
    }

    // ---------- REPAY ---------- //
    function preCheckRepay(address _user) internal {
        srcAddress = _user;
        initialTotalLiquidity = vault.getTotalLiquidity();
        (initialDebt,,) = vault.debtPerTokenPerUser(_user, address(collateralToken));
        (, initiallockedCollateral,) = vault.debtPerTokenPerUser(_user, address(collateralToken));
        initialUserBalance = _user.balance;
        initialDstBalance = collateralToken.balanceOf(_user);
    }

    function checkRepay(uint256 amount) internal view {
        uint256 debtIndex = vault.getBorrowDebtIndex();
        uint256 scaledDebt = initialDebt * debtIndex / WAD;
        uint256 overpayment;
        uint256 scaledDebtLeft;
        if (amount >= scaledDebt) {
            overpayment = amount - scaledDebt;
        } else {
            scaledDebtLeft = scaledDebt - amount;
        }
        uint256 scaledDebtPaid = overpayment > 0 ? scaledDebt : amount;

        assertEq(initialTotalLiquidity + scaledDebtPaid, vault.getTotalLiquidity(), "liquidity increases by debt paid");
        (uint256 finalDebt,,) = vault.debtPerTokenPerUser(srcAddress, address(collateralToken));
        (, uint256 finallockedCollateral,) = vault.debtPerTokenPerUser(srcAddress, address(collateralToken));
        if (scaledDebtLeft == 0) {
            assertEq(finalDebt, 0, "all is paid, final debt is 0");
            assertEq(finallockedCollateral, 0, "all is paid final used colalteral is 0");
            if (overpayment > 0) {
                assertLt(initialUserBalance - amount, srcAddress.balance, "should be returned overpayment");
            }
        } else {
            assertLt(finalDebt, initialDebt, "partial payment, debt decreases");
            assertLt(finallockedCollateral, initiallockedCollateral, "partial payment, collateral used decreases");
        }
        assertEq(initialUserBalance - amount + overpayment, srcAddress.balance, "user balance decreases");
        assertEq(
            collateralToken.balanceOf(srcAddress),
            initialDstBalance + initiallockedCollateral - finallockedCollateral,
            "collateral balance increases"
        );
    }
}

contract TestVaultBorrow is Test, VaultBorrowBase {
    function setUp() public {
        setUpLend();
        setUpCollateral();
        setUpBorrow();
    }
    //------- BORROW TESTS -------//

    function testBorrowOk(uint256 amountToBorrow) public {
        vm.assume(amountToBorrow > 0);
        vm.assume(amountToBorrow <= vault.getTotalLiquidity());
        depositCollateral(user, amountToBorrow * 2, true);
        preCheckBorrow(user);
        borrow(user, amountToBorrow, false);
        checkBorrow(amountToBorrow);
    }

    function testBorrowEvent() public {
        depositCollateral(user, COLLATERAL_TOKEN_FUND_AMOUNT, false);
        vm.prank(user);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Vault.UserBorrowedEth(user, address(collateralToken), BORROW_AMOUNT, BORROW_AMOUNT);
        vault.borrow(BORROW_AMOUNT, address(collateralToken), true);
    }

    function testBorrowInvalidAmount() public {
        depositCollateral(user, COLLATERAL_TOKEN_FUND_AMOUNT, false);
        preCheckBorrow(user);
        vm.prank(user);
        vm.expectRevert(Vault.Vault__invalidAmount.selector);
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
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__notEnoughLiquidity.selector, 0));
        vault.borrow(BORROW_AMOUNT, address(collateralToken), true);
        vm.stopPrank();
        checkBorrow(0);
    }

    function testBorrowNotEnoughCollateral() public {
        preCheckBorrow(user);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__notEnoughCollateral.selector, 0));
        vault.borrow(BORROW_AMOUNT, address(collateralToken), true);
        vm.stopPrank();
        checkBorrow(0);
    }

    function testBorrowNoMaxAvailableNotEnoughCollateral() public {
        uint256 smallAmount = COLLATERAL_TOKEN_FUND_AMOUNT / 10;
        depositCollateral(user, smallAmount, false);
        preCheckBorrow(user);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__notEnoughCollateral.selector, smallAmount));
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
        vm.expectRevert(Vault.Vault__invalidTransfer.selector);
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
        assertApproxEqAbs(initialTotalLiquidity - BORROW_AMOUNT, vault.getTotalLiquidity(), 1e12);
    }

    //------- REPAYMENT TESTS -------//
    function testPartialRepayUpdatesDebtAndCollateral() public {
        borrow(user, 1e18, true);
        vm.prank(interestManager);
        vault.accrueBorrowDebtInterest(1e17); // 10%
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
        vault.accrueBorrowDebtInterest(1e17); // 10%
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
        vm.expectRevert(Vault.Vault__invalidTransfer.selector);
        vault.repay{value: 2 ether}(address(collateralToken));
        uint256 balAfter = collateralToken.balanceOf(address(rejector));
        vm.stopPrank();
        assertEq(balBefore, balAfter);
    }

    function testRepayZeroReverts() public {
        vm.startPrank(user);
        vm.expectRevert(Vault.Vault__invalidAmount.selector);
        vault.repay{value: 0}(address(collateralToken));
        vm.stopPrank();
    }

    function testRepayNoDebtForCollateral() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__noDebtForCollateral.selector, address(collateralToken)));
        vault.repay{value: 1}(address(collateralToken));
        vm.stopPrank();
    }

    function testRepayOk(uint256 amountToBorrow, uint256 amountToRepay) public {
        uint256 totalLiquidity = vault.getTotalLiquidity();
        vm.assume(amountToBorrow > 0);
        vm.assume(amountToBorrow <= totalLiquidity);
        vm.assume(amountToRepay > 0);
        vm.assume(amountToRepay <= totalLiquidity * 10);
        uint256 extraBalanceForRepayment = amountToRepay > amountToBorrow ? amountToRepay - amountToBorrow : 0;
        vm.deal(user, extraBalanceForRepayment);
        borrow(user, amountToBorrow, true);
        preCheckRepay(user);
        vm.prank(user);
        vault.repay{value: amountToRepay}(address(collateralToken));
        checkRepay(amountToRepay);
    }

    // ---------- INTEREST TESTS ----------
    function testAccrueInterestOnlyRole() public {
        vm.startPrank(interestManager);
        vault.accrueBorrowDebtInterest(1e17); // 10%
        vm.stopPrank();
    }

    function testAccrueInterestRevertsForUnauthorized() public {
        vm.startPrank(user);
        vm.expectRevert();
        vault.accrueBorrowDebtInterest(1e17);
        vm.stopPrank();
    }

    //------- REBASE TOKEN INTEREST RATES -------//
    function testUpdateRebaseTokenInterest_NotAuthorized() public {
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                vault.REBASETOKEN_INTEREST_MANAGER_ROLE()
            )
        );
        vault.updateRebaseTokenInterest();
        vm.stopPrank();
    }

    function testUpdateRebaseTokenInterest_NoInterests() public {
        vm.prank(rebaseTokenIndexManager);
        vault.updateRebaseTokenInterest();

        uint256 globalIndex = rebaseToken.getGlobalIndex();
        assertEq(globalIndex, WAD, "Index should remain 1.0 if no interest");
    }

    function testUpdateRebaseTokenInterest_WithBorrow() public {
        testFullRepayReturnsCollateralAndRefundsExcess();
        vm.prank(rebaseTokenIndexManager);
        vault.updateRebaseTokenInterest();
        uint256 globalIndex = rebaseToken.getGlobalIndex();
        assertGt(globalIndex, WAD, "Index should grow with interest");
    }
}
