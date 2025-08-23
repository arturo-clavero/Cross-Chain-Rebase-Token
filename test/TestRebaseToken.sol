// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/RebaseToken.sol";
import "../script/DeployRebaseToken.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

contract RebaseTokenTest is Test {
    RebaseToken token;

    address admin   = address(0xA);
    address minter  = address(0xB);
    address burner  = address(0xC);
    address manager = address(0xD);
    address user1   = address(0x1);
    address user2   = address(0x2);

    function setUp() public {
        DeployRebaseToken deployed = new DeployRebaseToken();
        token = deployed.run("Rebase Token", "RBT", admin);

        // Grant roles
        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        token.grantRole(token.BURNER_ROLE(), burner);
        token.grantRole(token.INDEX_MANAGER_ROLE(), manager);
        vm.stopPrank();
    }

    // -----------------------
    // BASIC PROPERTIES
    // -----------------------
    function testInitialGlobalIndex() public view {
        assertEq(token.getGlobalIndex(), 1e18);
    }

    function testAdminIsGrantedProperly() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    }

    function testNoAdminInConstructorDefaultsToMsgSender() public {
        RebaseToken newToken = new RebaseToken("Rebase Token", "RBT", address(0));
        assertTrue(newToken.hasRole(newToken.DEFAULT_ADMIN_ROLE(), address(this)));
    }

//     // -----------------------
//     // MINT / BURN (roles)
//     // -----------------------
    function testMintWithRole() public {
        vm.prank(minter);
        token.mint(user1, 5 ether);
        assertEq(token.balanceOf(user1), 5 ether);
    }

    function testCanNotMintWithoutRole() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, 
            user1, 
            token.MINTER_ROLE()
            )
        );
        token.mint(user1, 5 ether); // should revert
        vm.stopPrank();
    }

    function testBurnWithRole() public {
        vm.startPrank(minter);
        token.mint(user1, 3 ether);
        vm.stopPrank();

        vm.prank(burner);
        token.burn(user1, 1 ether);

        assertEq(token.balanceOf(user1), 2 ether);
    }

    function testCanNotBurnWithoutRole() public {
        vm.startPrank(minter);
        token.mint(user1, 3 ether);
        vm.stopPrank();
        
        console.log("user 1 is: ", user1);
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, 
            user1, 
            token.BURNER_ROLE()
            )
        );
        token.burn(user1, 1 ether); // should revert
        vm.stopPrank();
    }

//     // -----------------------
//     // INDEX MANAGEMENT (roles)
//     // -----------------------
    function testUpdateGlobalIndexWithRole() public {
        vm.prank(manager);
        token.updateGlobalIndex(2e18);
        assertEq(token.getGlobalIndex(), 2e18);
    }

    function testCanNotUpdateGlobalIndexWithoutRole() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            user1,
            token.INDEX_MANAGER_ROLE()
            )
        );
        token.updateGlobalIndex(2e18); // should revert
        vm.stopPrank();
    }

    function testRebaseEffectOnBalance() public {
        vm.prank(minter);
        token.mint(user1, 2 ether);
        assertEq(token.balanceOf(user1), 2 ether);

        vm.prank(manager);
        token.updateGlobalIndex(2e18); // double index

        assertEq(token.balanceOf(user1), 4 ether); // balance should grow
    }

//     // -----------------------
//     // TRANSFERS
//     // -----------------------
    function testTransfer() public {
        vm.prank(minter);
        token.mint(user1, 3 ether);

        vm.prank(user1);
        token.transfer(user2, 1 ether);

        assertEq(token.balanceOf(user1), 2 ether);
        assertEq(token.balanceOf(user2), 1 ether);
    }

    function testTransferFrom() public {
        vm.prank(minter);
        token.mint(user1, 4 ether);

        vm.prank(user1);
        token.approve(address(this), 2 ether);

        token.transferFrom(user1, user2, 2 ether);

        assertEq(token.balanceOf(user1), 2 ether);
        assertEq(token.balanceOf(user2), 2 ether);
    }

//     // -----------------------
//     // CONVERSION
//     // -----------------------
    function testRawToEthAndEthToRaw() public {
        vm.prank(minter);
        token.mint(user1, 1 ether); // 1 ETH

        uint256 raw = token.ethToRaw(1 ether);
        uint256 eth = token.rawToEth(raw);

        assertEq(eth, 1 ether);
    }

    function testConversionAfterIndexChange() public {
        vm.prank(manager);
        token.updateGlobalIndex(2e18); // double index

        uint256 raw = token.ethToRaw(1 ether);
        uint256 eth = token.rawToEth(raw);

        assertEq(eth, 1 ether); // round trip should still match
    }
}
