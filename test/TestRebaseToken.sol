// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {DeployRebaseToken} from "../script/DeployRebaseToken.sol";
import {RebaseToken} from "../src/RebaseToken.sol";

contract RebaseTokenTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant ONE_PERCENT_INCREASE = 1e16;
    string constant NAME = "My Rebase Token";
    string constant SYMBOL = "XXX";
    address private user1;
    address private user2;
    RebaseToken private token;

    function setUp() external {
        DeployRebaseToken deployRebaseToken = new DeployRebaseToken();
        token = deployRebaseToken.run(NAME, SYMBOL);
        user1 = vm.addr(12);
        user2 = vm.addr(13);
    }

    function testConstructorParameters() external view {
        assertEq(keccak256(abi.encodePacked(token.name())), keccak256(abi.encodePacked(NAME)));
        assertEq(keccak256(abi.encodePacked(token.symbol())), keccak256(abi.encodePacked(SYMBOL)));
        assertEq(token.getGlobalIndex(), WAD);
    }

    function testUpdateGlobalIndex() external {
        
    }

    function increaseGlobalRate() private {
        uint256 newRate = token.getGlobalIndex() * ONE_PERCENT_INCREASE / WAD;
        token.updateGlobalIndex(newRate);
    }

    function testMintAndBalance() public {
        token.mint(user1, 2 ether); // 2 ETH
        uint256 balance = token.balanceOf(user1);
        assertEq(balance, 2 ether);
    }

    function testBurn() public {
        token.mint(user1, 5 ether);
        token.burn(user1, 2 ether);
        uint256 balance = token.balanceOf(user1);
        assertEq(balance, 3 ether);
    }

    function testTransfer() public {
        token.mint(user1, 3 ether);
        vm.prank(user1);
        token.transfer(user2, 1 ether);
        assertEq(token.balanceOf(user1), 2 ether);
        assertEq(token.balanceOf(user2), 1 ether);
    }

    function testTransferFrom() public {
        token.mint(user1, 4 ether);
        vm.prank(user1);
        token.approve(address(this), 2 ether);
        token.transferFrom(user1, user2, 2 ether);
        assertEq(token.balanceOf(user1), 2 ether);
        assertEq(token.balanceOf(user2), 2 ether);
    }

    function testGlobalIndexChangeAffectsBalance() public {
        token.mint(user1, 2 ether);
        token.updateGlobalIndex(2e18); // double index
        uint256 balance = token.balanceOf(user1);
        assertEq(balance, 4 ether); // should reflect new globalIndex
    }

}
