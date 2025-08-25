// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../script/DeployRebaseToken.sol";
import "../src/Vault.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20Mock is ERC20 {
    constructor() ERC20("ERC20Mock", "E20M") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function _approve(address owner, address spender, uint256 amount, bool) internal virtual override {
        super._approve(owner, spender, amount, true);
    }
}

contract BorrowTest is Test {
    uint256 public constant FUND_AMOUNT = 2 ether;
    uint256 public constant DEPOSIT_AMOUNT = 10 ether;
    uint256 public constant COLLATERAL_TOKEN_FUND_AMOUNT = 1e24;
    address public user = address(0x1);
    address public admin = address(0x2);
    address public interestManager = address(0x3);
    address public collateralManager = address(0x4);
    address public depositer = address(0x5);

    Vault private borrow;
    ERC20Mock public token;

    function setUp() public {
        DeployRebaseToken deployed = new DeployRebaseToken();
        deployed.run("Rebase Token", "RBT", admin);
        borrow = deployed.vault();
        // fund users with ETH for testing
        vm.deal(user, FUND_AMOUNT);
        vm.deal(interestManager, FUND_AMOUNT);
        vm.deal(collateralManager, FUND_AMOUNT);
        //grant roles
        vm.startPrank(admin);
        borrow.grantRole(borrow.INTEREST_MANAGER_ROLE(), interestManager);
        borrow.grantRole(borrow.COLLATERAL_MANAGER_ROLE(), collateralManager);
        vm.stopPrank();
        //mock collateral token :
        token = new ERC20Mock();
        token.mint(user, COLLATERAL_TOKEN_FUND_AMOUNT);
        vm.prank(user);
        token.approve(address(borrow), type(uint256).max);
        vm.prank(collateralManager);
        borrow.modifyCollateral(address(token), address(0xfeed), 2e18);
        //deposit eth
        vm.deal(depositer, DEPOSIT_AMOUNT);
        vm.prank(depositer);
        borrow.deposit{value: DEPOSIT_AMOUNT}();
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

    function testRepayZeroReverts() public {
        vm.startPrank(user);
        vm.expectRevert(Vault.Borrow__invalidAmount.selector);
        borrow.repay{value: 0}(address(token));
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
}
