// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../script/DeployRebaseToken.sol";
import "../code/Vault.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {RejectEth} from "./mocks/RejectEth.sol";
import {PriceFeedMock} from "./mocks/PriceFeedMock.sol";
import {PriceConverter} from "../code/libs/PriceConverter.sol";
import {RebaseToken} from "../code/RebaseToken.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

contract BorrowTest is Test {
    uint256 public constant FUND_AMOUNT = 100 ether;
    uint256 public constant DEPOSIT_AMOUNT = 500 ether;
    uint256 public constant COLLATERAL_TOKEN_FUND_AMOUNT = 1e24;
    address public user = address(0x1);
    address public admin = address(0x2);
    address public interestManager = address(0x3);
    address public collateralManager = address(0x4);
    address public depositer = address(0x5);
    address public liquidator = address(0x6);
    address public rebaseTokenIndexManager = address(0x7);
    uint256 public constant WAD = 1e18;
    RebaseToken public rebaseToken;
    PriceFeedMock public mockPriceFeed = new PriceFeedMock(1);
    RejectEth public rejector = new RejectEth();

    Vault private borrow;
    ERC20Mock public token;

    function setUp() public {
        DeployRebaseToken deployed = new DeployRebaseToken();
        deployed.run("Rebase Token", "RBT", admin);
        borrow = deployed.vault();
        rebaseToken = deployed.rebaseToken();
        // fund users with ETH for testing
        vm.deal(user, FUND_AMOUNT);
        vm.deal(interestManager, FUND_AMOUNT);
        vm.deal(collateralManager, FUND_AMOUNT);
        vm.deal(address(rejector), FUND_AMOUNT);
        vm.deal(liquidator, FUND_AMOUNT);
        vm.deal(admin, FUND_AMOUNT);
        vm.deal(rebaseTokenIndexManager, FUND_AMOUNT);
        //grant roles
        vm.startPrank(admin);
        borrow.grantRole(borrow.INTEREST_MANAGER_ROLE(), interestManager);
        borrow.grantRole(borrow.COLLATERAL_MANAGER_ROLE(), collateralManager);
        borrow.grantRole(borrow.LIQUIDATOR_ROLE(), liquidator);
        rebaseToken.grantRole(rebaseToken.INDEX_MANAGER_ROLE(), address(borrow));
        vm.stopPrank();
        //mock collateral token :
        token = new ERC20Mock();
        vm.prank(collateralManager);
        borrow.modifyCollateral(address(token), address(mockPriceFeed), 1e18);
        //give collateral token to users and set allowance
        token.mint(user, COLLATERAL_TOKEN_FUND_AMOUNT);
        vm.prank(user);
        token.approve(address(borrow), type(uint256).max);
        token.mint(address(rejector), COLLATERAL_TOKEN_FUND_AMOUNT);
        vm.prank(address(rejector));
        token.approve(address(borrow), type(uint256).max);
        //deposit eth
        vm.deal(depositer, DEPOSIT_AMOUNT);
        vm.prank(depositer);
        borrow.deposit{value: DEPOSIT_AMOUNT}();
        //add rebase token interest manager role
        // rebaseToken = deployed.rebaseToken();
        // vm.prank(admin);
        // rebaseToken.grantRole(rebaseToken.INDEX_MANAGER_ROLE(), rebaseTokenIndexManager);
    }

    // ---------- BORROW TESTS ----------

    function testBorrowRecordsDebtAndCollateral() public {
        vm.startPrank(user);
        borrow.borrow(address(token), 1e18);
        (uint256 debt, uint256 collateral) = borrow.debtPerTokenPerUser(user, address(token));
        assertEq(collateral, 1e18);
        assertGt(debt, 0);
        vm.stopPrank();
    }

    function testBorrowZeroReverts() public {
        vm.startPrank(user);
        vm.expectRevert(Vault.Borrow__invalidAmount.selector);
        borrow.borrow(address(token), 0);
        vm.stopPrank();
    }

    function testBorrowUnsupportedTokenReverts() public {
        address unsupportedToken = address(0x999);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__collateralTokenNotSupported.selector, unsupportedToken));
        borrow.borrow(unsupportedToken, 1e18);
        vm.stopPrank();
    }

    function testBorrowInsufficientAllowance() public {
        ERC20Mock tokenNoAllowance = new ERC20Mock();
        tokenNoAllowance.mint(user, COLLATERAL_TOKEN_FUND_AMOUNT);
        vm.prank(collateralManager);
        borrow.modifyCollateral(address(tokenNoAllowance), address(0xfeed), 2e18);
        vm.startPrank(user);
        vm.expectRevert(Vault.Borrow__insufficientAllowance.selector);
        borrow.borrow(address(tokenNoAllowance), 1e18);
        vm.stopPrank();
    }

    function testNotEnoughEthToBorrow() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__notEnoughEthToBorrow.selector, DEPOSIT_AMOUNT));
        borrow.borrow(address(token), DEPOSIT_AMOUNT * 2);
        vm.stopPrank();
    }

    function testBorrowerRejectsEthBorrowed() public {
        vm.startPrank(address(rejector));
        vm.expectRevert(Vault.Borrow__invalidTransfer.selector);
        borrow.borrow(address(token), 1e18);
        vm.stopPrank();
    }
    // ---------- REPAY TESTS ----------

    function testPartialRepayUpdatesDebtAndCollateral() public {
        vm.prank(user);
        borrow.borrow(address(token), 1e18);

        // accrue interest
        vm.prank(interestManager);
        borrow.accrueInterest(1e17); // 10%

        vm.startPrank(user);
        (uint256 debtBefore,) = borrow.debtPerTokenPerUser(user, address(token));
        borrow.repay{value: 0.5 ether}(address(token));
        (uint256 debt, uint256 collateral) = borrow.debtPerTokenPerUser(user, address(token));

        assertLt(debt, debtBefore);
        assertLt(collateral, 1e18);
        vm.stopPrank();
    }

    function testFullRepayReturnsCollateralAndRefundsExcess() public {
        vm.prank(user);
        borrow.borrow(address(token), 1e18);

        // accrue interest
        vm.prank(interestManager);
        borrow.accrueInterest(1e17); // 10%

        vm.startPrank(user);
        uint256 balBefore = token.balanceOf(user);
        borrow.repay{value: 2 ether}(address(token));
        uint256 balAfter = token.balanceOf(user);

        (uint256 debt, uint256 collateral) = borrow.debtPerTokenPerUser(user, address(token));
        assertEq(debt, 0);
        assertEq(collateral, 0);
        assertGt(balAfter, balBefore); // user got refund
        vm.stopPrank();
    }

    function testRefundsExcessInvalidTransfer() public {
        rejector.acceptPayment();
        vm.prank(address(rejector));
        borrow.borrow(address(token), 1e18);

        rejector.rejectPayment();
        vm.startPrank(address(rejector));
        uint256 balBefore = token.balanceOf(address(rejector));
        vm.expectRevert(Vault.Borrow__invalidTransfer.selector);
        borrow.repay{value: 2 ether}(address(token));
        uint256 balAfter = token.balanceOf(address(rejector));
        vm.stopPrank();
        assertEq(balBefore, balAfter);
    }

    function testRepayZeroReverts() public {
        vm.startPrank(user);
        vm.expectRevert(Vault.Borrow__invalidAmount.selector);
        borrow.repay{value: 0}(address(token));
        vm.stopPrank();
    }

    function testRepayNoDebtForCollateral() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__noDebtForCollateral.selector, address(token)));
        borrow.repay{value: 1}(address(token));
        vm.stopPrank();
    }

    // ---------- INTEREST TESTS ----------

    function testAccrueInterestOnlyRole() public {
        vm.startPrank(interestManager);
        borrow.accrueInterest(1e17); // 10%
        vm.stopPrank();
    }

    function testAccrueInterestRevertsForUnauthorized() public {
        vm.startPrank(user);
        vm.expectRevert();
        borrow.accrueInterest(1e17);
        vm.stopPrank();
    }

    function testTotalInterestsUpdatedAfterRepay() public {
        vm.prank(user);
        borrow.borrow(address(token), 1e18);

        vm.prank(interestManager);
        borrow.accrueInterest(1e17); // 10%

        vm.startPrank(user);
        uint256 totalBefore = borrow.getTotalInterests();
        borrow.repay{value: 1 ether}(address(token));
        uint256 totalAfter = borrow.getTotalInterests();
        assertGt(totalAfter, totalBefore);
        vm.stopPrank();
    }

    // ---------- COLLATERAL MANAGEMENT TESTS ----------

    function testModifyCollateralOnlyRole() public {
        vm.startPrank(collateralManager);
        borrow.modifyCollateral(address(token), address(0x1234), 3e18);
        (address priceFeed, uint256 LVM) = borrow.collateralPerToken(address(token));
        assertEq(LVM, 3e18);
        assertEq(priceFeed, address(0x1234));
        vm.stopPrank();
    }

    function testModifyCollateralRevertsUnauthorized() public {
        vm.startPrank(user);
        vm.expectRevert();
        borrow.modifyCollateral(address(token), address(0x1234), 3e18);
        vm.stopPrank();
    }

    function testAddCollateral_RevertIfAlreadyExists() public {
        // token already added in setUp()
        vm.startPrank(collateralManager);
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__collateralAlreadyExists.selector));
        borrow.addCollateral(address(token), address(0xfeed), 2e18);
        vm.stopPrank();
    }

    function testAddCollateral_SuccessForNewToken() public {
        ERC20Mock newToken = new ERC20Mock();
        console.log(address(newToken), address(token));
        vm.startPrank(collateralManager);
        borrow.addCollateral(address(newToken), address(0xbeef), 3e18);
        vm.stopPrank();

        (address priceFeed, uint256 lvm) = borrow.collateralPerToken(address(newToken));
        assertEq(priceFeed, address(0xbeef));
        assertEq(lvm, 3e18);
    }

    function testAddCollateral_RevertsIfNotCollateralManager() public {
        ERC20Mock newToken = new ERC20Mock();

        vm.startPrank(user);
        vm.expectRevert(); // AccessControl revert
        borrow.addCollateral(address(newToken), address(0xbeef), 3e18);
        vm.stopPrank();
    }

    function testModifyCollateral_Success() public {
        vm.startPrank(collateralManager);
        borrow.modifyCollateral(address(token), address(0x1234), 4e18);
        vm.stopPrank();

        (address priceFeed, uint256 lvm) = borrow.collateralPerToken(address(token));
        assertEq(priceFeed, address(0x1234));
        assertEq(lvm, 4e18);
    }

    function testModifyCollateral_RevertIfInvalidParams() public {
        vm.startPrank(collateralManager);

        // zero token
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__invalidCollateralParams.selector));
        borrow.modifyCollateral(address(0), address(0x1234), 3e18);

        // zero priceFeed
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__invalidCollateralParams.selector));
        borrow.modifyCollateral(address(token), address(0), 3e18);

        // too low LVM
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__invalidCollateralParams.selector));
        borrow.modifyCollateral(address(token), address(0x1234), 0.5e18);

        vm.stopPrank();
    }

    function testModifyCollateral_RevertsIfNotCollateralManager() public {
        vm.startPrank(user);
        vm.expectRevert(); // AccessControl revert
        borrow.modifyCollateral(address(token), address(0x1234), 3e18);
        vm.stopPrank();
    }

    function testModifyCollateralPriceFeed_Success() public {
        vm.startPrank(collateralManager);
        borrow.modifyCollateralPriceFeed(address(token), address(0xdead));
        vm.stopPrank();

        (address priceFeed,) = borrow.collateralPerToken(address(token));
        assertEq(priceFeed, address(0xdead));
    }

    function testModifyCollateralPriceFeed_RevertIfZeroFeed() public {
        vm.startPrank(collateralManager);
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__invalidCollateralParams.selector));
        borrow.modifyCollateralPriceFeed(address(token), address(0));
        vm.stopPrank();
    }

    function testModifyCollateralPriceFeed_RevertIfCollateralDoesNotExist() public {
        ERC20Mock newToken = new ERC20Mock();
        vm.startPrank(collateralManager);
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__collateralDoesNotExist.selector));
        borrow.modifyCollateralPriceFeed(address(newToken), address(0x1234));
        vm.stopPrank();
    }

    function testModifyCollateralPriceFeed_RevertIfNotCollateralManager() public {
        vm.startPrank(user);
        vm.expectRevert(); // AccessControl revert
        borrow.modifyCollateralPriceFeed(address(token), address(0x1234));
        vm.stopPrank();
    }

    function testModifyCollateralLVM_Success() public {
        vm.startPrank(collateralManager);
        borrow.modifyCollateralLVM(address(token), 5e18);
        vm.stopPrank();

        (, uint256 lvm) = borrow.collateralPerToken(address(token));
        assertEq(lvm, 5e18);
    }

    function testModifyCollateralLVM_RevertIfTooLow() public {
        vm.startPrank(collateralManager);
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__invalidCollateralParams.selector));
        borrow.modifyCollateralLVM(address(token), 0.5e18);
        vm.stopPrank();
    }

    function testModifyCollateralLVM_RevertIfCollateralDoesNotExist() public {
        ERC20Mock newToken = new ERC20Mock();
        vm.startPrank(collateralManager);
        vm.expectRevert(abi.encodeWithSelector(Vault.Borrow__collateralDoesNotExist.selector));
        borrow.modifyCollateralLVM(address(newToken), 2e18);
        vm.stopPrank();
    }

    function testModifyCollateralLVM_RevertIfNotCollateralManager() public {
        vm.startPrank(user);
        vm.expectRevert(); // AccessControl revert
        borrow.modifyCollateralLVM(address(token), 2e18);
        vm.stopPrank();
    }

    function testCannotLiquidateNoDebtUser() public {
        vm.prank(liquidator);
        vm.expectRevert(PriceConverter.PriceConverter__InvalidAmount.selector);
        borrow.liquidate(user, address(token));
    }

    function testCannotLiquidateHealthyUser() public {
        vm.prank(user);
        borrow.borrow(address(token), 1e18);
        vm.prank(interestManager);
        borrow.accrueInterest(1e17);
        vm.prank(liquidator);
        vm.expectRevert(Vault.Borrow__invalidAmount.selector);
        borrow.liquidate(user, address(token));
    }

    function testLiquidatorMustSendETH() public {
        // Simulate undercollateralized user
        vm.prank(user);
        token.approve(address(borrow), 100 * WAD);
        vm.prank(user);
        borrow.borrow(address(token), 100 * WAD);

        vm.prank(liquidator);
        vm.expectRevert(Vault.Borrow__userNotUnderCollaterlized.selector);
        borrow.liquidate(user, address(token));
    }

    function testFullLiquidation() public {

        vm.prank(user);
        borrow.borrow(address(token), 1);

        vm.prank(interestManager);
        borrow.accrueInterest(10e17);       

        // Pay full debt
        (uint256 realDebt, ) = borrow.debtPerTokenPerUser(user, address(token));
        uint256 ethToPay = realDebt * borrow.getGlobalIndex() / WAD;

        vm.prank(liquidator);
        borrow.liquidate{value: ethToPay}(user, address(token));

        (uint256 debt, uint256 collat) = borrow.debtPerTokenPerUser(user, address(token));
        assertEq(debt, 0, "Debt should be zero after full liquidation");
        assertEq(collat, 0, "Collateral should be zero after full liquidation");

        uint256 liquidatorBal = token.balanceOf(liquidator);
        assertTrue(liquidatorBal > 0, "Liquidator should receive all collateral");
    }

    function testExcessETHRefund() public {
        vm.prank(user);
        borrow.borrow(address(token), 1 * WAD);

        vm.prank(interestManager);
        borrow.accrueInterest(5e17); 

        (uint256 realDebt, ) = borrow.debtPerTokenPerUser(user, address(token));
        uint256 ethToPay = realDebt * borrow.getGlobalIndex() / WAD;


        // Send extra ETH
        uint256 excess = 5 ether;

        vm.deal(liquidator, 10 ether);
        uint256 initialBal = liquidator.balance;
        vm.prank(liquidator);
        borrow.liquidate{value: ethToPay + excess}(user, address(token));

        uint256 finalBal = liquidator.balance;
        assertEq(initialBal - ethToPay, finalBal, "Excess ETH should be refunded");
    }

//interest of rebase token:
    function testUpdateRebaseTokenInterest_NotAuthorized() public {
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, borrow.INTEREST_MANAGER_ROLE())
        );
        borrow.updateRebaseTokenInterest();
        vm.stopPrank();
    }

    function testUpdateRebaseTokenInterest_NoInterests() public {
        vm.prank(interestManager);
        borrow.updateRebaseTokenInterest();

        uint256 globalIndex = rebaseToken.getGlobalIndex();
        assertEq(globalIndex, WAD, "Index should remain 1.0 if no interest");
    }

    function testUpdateRebaseTokenInterest_WithBorrow() public {
        testFullRepayReturnsCollateralAndRefundsExcess();
        vm.prank(interestManager);
        borrow.updateRebaseTokenInterest();
        uint256 globalIndex = rebaseToken.getGlobalIndex();
        assertGt(globalIndex, WAD, "Index should grow with interest");
    }

}
