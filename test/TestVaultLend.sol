// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../script/DeployRebaseToken.sol";
import "../src/Vault.sol";
import "../src/RebaseToken.sol";
import {RejectEth} from "./mocks/RejectEth.sol";

contract VaultLendBase is Test {
    uint256 public constant WAD = 1e18;
    uint256 internal constant FUND_AMOUNT = 10 ether;
    uint256 internal constant DEPOSIT_AMOUNT = 2 ether;
    uint256 internal constant INVALID_WITHDRAWAL_AMOUNT = 3 ether;
    uint256 internal constant VALID_WITHDRAWAL_AMOUNT = 1 ether;
    uint256 internal initialShares;
    uint256 internal initialLiquidity;
    uint256 internal initialSrcBalance;
    uint256 internal initialDstBalance;
    address internal srcAddress;
    address internal dstAddress;
    address public user = address(0x1);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public admin = address(0x3);
    RejectEth public rejector = new RejectEth();
    address public userRejector = address(rejector);
    Vault internal vault;
    RebaseToken internal rebaseToken;

    function setUpLend() internal {
        DeployRebaseToken deployed = new DeployRebaseToken();
        deployed.run("Rebase Token", "RBT", admin);
        rebaseToken = deployed.rebaseToken();
        vault = deployed.vault();
        // fund users with ETH for testing
        vm.deal(user, FUND_AMOUNT);
        vm.deal(user1, FUND_AMOUNT);
        vm.deal(user2, FUND_AMOUNT);
        vm.deal(userRejector, FUND_AMOUNT);
    }

    //DEPOSIT :
    function preCheckDeposit(address userDepositFrom, address userDepositTo) internal {
        initialShares = vault.getTotalShares();
        initialLiquidity = vault.getTotalLiquidity();
        initialSrcBalance = userDepositFrom.balance;
        srcAddress = userDepositFrom;
        initialDstBalance = rebaseToken.balanceOf(userDepositTo);
        dstAddress = userDepositTo;
    }

    function checkDeposit(uint256 amount) internal view {
        assertEq(initialShares + amount, vault.getTotalShares());
        assertEq(initialLiquidity + amount, vault.getTotalLiquidity());
        assertEq(initialSrcBalance - amount, srcAddress.balance);
        assertEq(initialDstBalance + amount, rebaseToken.balanceOf(dstAddress));
    }

    function validDeposit(address from, address to, uint256 amount) internal {
        preCheckDeposit(from, to);
        vm.prank(from);
        vault.depositTo{value: amount}(to);
        checkDeposit(amount);
    }

    //withdraw

    function preCheckWithdraw(address userWithdraws) internal {
        initialShares = vault.getTotalShares();
        initialLiquidity = vault.getTotalLiquidity();
        initialSrcBalance = userWithdraws.balance;
        srcAddress = userWithdraws;
        initialDstBalance = rebaseToken.balanceOf(userWithdraws);
        dstAddress = userWithdraws;
    }

    function checkWithdraw(uint256 amount) internal view {
        assertEq(initialShares - amount, vault.getTotalShares());
        assertEq(initialLiquidity - amount, vault.getTotalLiquidity());
        assertEq(initialSrcBalance + amount, srcAddress.balance);
        assertEq(initialDstBalance - amount, rebaseToken.balanceOf(dstAddress));
    }

    function validWithdraw(address userWithdrawing, uint256 amount) internal {
        preCheckWithdraw(userWithdrawing);
        console.log("balance: ", userWithdrawing.balance);
        console.log("tokens: ", rebaseToken.balanceOf(userWithdrawing));
        vm.prank(userWithdrawing);
        vault.withdraw(amount);
        checkWithdraw(amount);
    }
}

contract TestVaultLend is Test, VaultLendBase {
    function setUp() public virtual {
        setUpLend();
    }
    //BASE TESTS

    function testInitialGlobalIndex() external view {
        assertEq(vault.getGlobalIndex(), 1e18);
    }

    function testAdminIsGrantedProperly() external view {
        assertTrue(vault.hasRole(rebaseToken.DEFAULT_ADMIN_ROLE(), admin));
    }

    function testNoAdminInConstructorDefaultsToMsgSender() external {
        Vault newVault = new Vault(address(new RebaseToken("X", "X", address(0))), address(0));
        assertTrue(newVault.hasRole(newVault.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    //DEPOSIT

    function testDepositToSelf() external {
        validDeposit(user1, user1, DEPOSIT_AMOUNT);
    }

    function testDepositToOther() external {
        validDeposit(user1, user2, DEPOSIT_AMOUNT);
    }

    function testTotalDepositMultipleDeposits() external {
        validDeposit(user1, user2, DEPOSIT_AMOUNT);
        validDeposit(user2, user2, DEPOSIT_AMOUNT);
    }

    function testDepositRevertOnZero() external {
        preCheckDeposit(user1, user1);
        vm.prank(user1);
        vm.expectRevert(Vault.Vault__insufficientAmount.selector);
        vault.deposit{value: 0}();
        checkDeposit(0);
    }

    function testDepositToRevertOnZero() external {
        preCheckDeposit(user1, user2);
        vm.prank(user1);
        vm.expectRevert(Vault.Vault__insufficientAmount.selector);
        vault.depositTo{value: 0}(user2);
        checkDeposit(0);
    }
    //withdraw

    function testWithdrawOk() external {
        validDeposit(user1, user1, DEPOSIT_AMOUNT);
        validWithdraw(user1, DEPOSIT_AMOUNT);
    }

    function testWithdrawRevertOnZero() external {
        validDeposit(user1, user1, DEPOSIT_AMOUNT);
        preCheckWithdraw(user1);

        vm.startPrank(user1);
        vm.expectRevert(Vault.Vault__insufficientAmount.selector);
        vault.withdraw(0);
        vm.stopPrank();

        checkWithdraw(0);
    }

    function testWithdrawRevertOnInsufficientBalance() external {
        validDeposit(user1, user1, DEPOSIT_AMOUNT);
        preCheckWithdraw(user1);

        vm.startPrank(user1);
        vm.expectRevert(Vault.Vault__insufficientLiquidity.selector);
        vault.withdraw(INVALID_WITHDRAWAL_AMOUNT);
        vm.stopPrank();

        checkWithdraw(0);
    }

    function testWithdrawRevertOnNoDeposit() external {
        preCheckWithdraw(user1);

        vm.startPrank(user1);
        vm.expectRevert(Vault.Vault__insufficientLiquidity.selector);
        vault.withdraw(VALID_WITHDRAWAL_AMOUNT);
        vm.stopPrank();

        checkWithdraw(0);
    }

    function testWithdrawalUserRejectsEth() external {
        validDeposit(userRejector, userRejector, DEPOSIT_AMOUNT);
        preCheckWithdraw(userRejector);

        vm.startPrank(userRejector);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__transferFailed.selector));
        vault.withdraw(DEPOSIT_AMOUNT);
        vm.stopPrank();

        checkWithdraw(0);
    }

    function testWithdrawMax() external {
        validDeposit(user1, user1, DEPOSIT_AMOUNT);
        preCheckWithdraw(user1);
        vm.prank(user1);
        vault.withdraw(type(uint256).max);
        checkWithdraw(DEPOSIT_AMOUNT);
    }
}
