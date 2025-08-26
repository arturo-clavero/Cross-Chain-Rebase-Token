// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../script/DeployRebaseToken.sol";
import "../code/Vault.sol";
import "../code/RebaseToken.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RejectEth} from "./mocks/RejectEth.sol";

contract VaultTest is Test {
    uint256 private constant FUND_AMOUNT = 10 ether;
    uint256 private constant DEPOSIT_AMOUNT = 2 ether;
    uint256 private constant INVALID_WITHDRAWAL_AMOUNT = 3 ether;
    uint256 private constant VALID_WITHDRAWAL_AMOUNT = 1 ether;
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public admin = address(0x3);
    address public userRejector = address(new RejectEth());
    Vault private vault;
    RebaseToken private token;

    function setUp() public {
        DeployRebaseToken deployed = new DeployRebaseToken();
        deployed.run("Rebase Token", "RBT", admin);
        token = deployed.rebaseToken();
        vault = deployed.vault();
        // fund users with ETH for testing
        vm.deal(user1, FUND_AMOUNT);
        vm.deal(user2, FUND_AMOUNT);
        vm.deal(userRejector, FUND_AMOUNT);
    }

    function testInitialGlobalIndex() public view {
        assertEq(vault.getGlobalIndex(), 1e18);
    }

    function testAdminIsGrantedProperly() public view {
        assertTrue(vault.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    }

    function testNoAdminInConstructorDefaultsToMsgSender() public {
        Vault newVault = new Vault(address(new RebaseToken("X", "X", address(0))), address(0));
        assertTrue(newVault.hasRole(newVault.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function testDepositToSelf() public {
        vm.prank(user1);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        assertEq(token.balanceOf(user1), DEPOSIT_AMOUNT, "user1 should have minted tokens");
    }

    function testDepositToOther() public {
        vm.prank(user1);
        vault.depositTo{value: DEPOSIT_AMOUNT}(user2);

        assertEq(token.balanceOf(user2), DEPOSIT_AMOUNT, "user2 should have minted tokens");
        assertEq(token.balanceOf(user1), 0, "user1 should have 0 tokens");
    }

    function testTotalDepositMultipleDeposits() public {
        vm.prank(user1);
        vault.depositTo{value: DEPOSIT_AMOUNT}(user2);
        assertEq(vault.getTotalDeposits(), DEPOSIT_AMOUNT);
        vm.prank(user2);
        vault.deposit{value: DEPOSIT_AMOUNT}();
        assertEq(vault.getTotalDeposits(), DEPOSIT_AMOUNT * 2);
    }

    function testDepositRevertOnZero() public {
        vm.prank(user1);
        vm.expectRevert(Vault.Vault__innsuficientAmount.selector);
        vault.deposit{value: 0}();
    }

    function testDepositToRevertOnZero() public {
        vm.prank(user1);
        vm.expectRevert(Vault.Vault__innsuficientAmount.selector);
        vault.depositTo{value: 0}(user1);
    }

    function testWithdraw() public {
        // deposit first
        vm.prank(user1);
        vault.deposit{value: DEPOSIT_AMOUNT}();
        assertEq(token.balanceOf(user1), DEPOSIT_AMOUNT);

        // withdraw
        uint256 prevBalance = user1.balance;
        vm.prank(user1);
        vault.withdraw(VALID_WITHDRAWAL_AMOUNT);

        // check token burned and ETH sent
        assertEq(token.balanceOf(user1), DEPOSIT_AMOUNT - VALID_WITHDRAWAL_AMOUNT, "2 tokens should be burned");
        assertEq(user1.balance, prevBalance + VALID_WITHDRAWAL_AMOUNT, "user1 should receive 2 ETH back");
    }

    function testWithdrawRevertOnZero() public {
        vm.prank(user1);
        vm.expectRevert(Vault.Vault__innsuficientAmount.selector);
        vault.withdraw(0);
    }

    function testWithdrawRevertOnInsufficientBalance() public {
        vm.prank(user1);
        vault.deposit{value: DEPOSIT_AMOUNT}();
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, user1, token.balanceOf(user1), INVALID_WITHDRAWAL_AMOUNT
            )
        ); // mock token will revert if burn > balance
        vault.withdraw(INVALID_WITHDRAWAL_AMOUNT);
        vm.stopPrank();
    }

    function testWithdrawalUserRejectsEth() public {
        vm.prank(userRejector);
        vault.deposit{value: DEPOSIT_AMOUNT}();
        vm.prank(userRejector);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__transferFailed.selector));
        vault.withdraw(DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(userRejector), DEPOSIT_AMOUNT);
    }
}
