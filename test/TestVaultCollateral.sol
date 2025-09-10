// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Vault.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {PriceFeedMock} from "./mocks/PriceFeedMock.sol";
import {VaultLendBase} from "./TestVaultLend.sol";

contract VaultCollateralBase is Test, VaultLendBase {
    using SafeERC20 for IERC20;

    uint256 public constant COLLATERAL_TOKEN_FUND_AMOUNT = 1e24;
    uint256 public constant LIQUIDITY_AMOUNT = 1e28;

    address public userWithoutTokens = address(0x2);
    address public depositer = address(0x5);
    address public collateralManager = address(0x4);
    PriceFeedMock public mockPriceFeed = new PriceFeedMock(1);
    ERC20Mock public collateralToken;

    function setUpCollateral() internal {
        // fund users with ETH for testing
        vm.deal(depositer, DEPOSIT_AMOUNT);
        vm.deal(userWithoutTokens, FUND_AMOUNT);
        vm.deal(collateralManager, FUND_AMOUNT);

        //grant permission
        vm.startPrank(admin);
        vault.grantRole(vault.COLLATERAL_MANAGER_ROLE(), collateralManager);
        vm.stopPrank();
        //collateral token
        collateralToken = newCollateralToken();
        mintAndApproveCollateral(collateralToken, user);
        mintAndApproveCollateral(collateralToken, userRejector);
        //deposit eth
        hoax(depositer, LIQUIDITY_AMOUNT);
        vault.deposit{value: LIQUIDITY_AMOUNT}();
    }

    function newCollateralToken() internal returns (ERC20Mock) {
        ERC20Mock _token = new ERC20Mock();
        vm.prank(collateralManager);
        vault.modifyCollateral(address(_token), address(mockPriceFeed), 15e17);
        return _token;
    }

    function mintAndApproveCollateral(ERC20Mock _token, address _user) internal {
        _token.mint(_user, COLLATERAL_TOKEN_FUND_AMOUNT);
        vm.prank(_user);
        collateralToken.approve(address(vault), type(uint256).max);
    }

    // ---------- DEPOSIT COLLATERAL ----------
    function preCheckCollateral(address _user) internal {
        srcAddress = _user;
        initialSrcBalance = collateralToken.balanceOf(_user);
        (,, initialDstBalance) = vault.debtPerTokenPerUser(_user, address(collateralToken));
    }

    function checkCollateral(uint256 amount) internal view {
        assertEq(initialSrcBalance - amount, collateralToken.balanceOf(srcAddress), "token balanceOf user");
        (,, uint256 newDstBalance) = vault.debtPerTokenPerUser(srcAddress, address(collateralToken));
        assertEq(initialDstBalance + amount, newDstBalance, "availableCollateral in DebtPerUserPerToken");
    }

    function depositCollateral(address _user, uint256 amount, bool shouldMint) internal {
        if (shouldMint) {
            collateralToken.mint(_user, amount);
        }
        vm.prank(_user);
        vault.depositCollateral(amount, address(collateralToken));
    }
}

contract TestVaultCollateral is VaultCollateralBase {
    function setUp() public {
        setUpLend();
        setUpCollateral();
    }

    //------- DEPOSIT COLLATERAL TESTS -------//

    function testDepositCollateralOk() public {
        preCheckCollateral(user);
        depositCollateral(user, COLLATERAL_TOKEN_FUND_AMOUNT, false);
        checkCollateral(COLLATERAL_TOKEN_FUND_AMOUNT);
    }

    function testDepositCollateralRevertZero() public {
        preCheckCollateral(user);
        vm.startPrank(user);
        vm.expectRevert(Vault.Vault__invalidAmount.selector);
        vault.depositCollateral(0, address(collateralToken));
        vm.stopPrank();
        checkCollateral(0);
    }

    function testDepositCollateralRevertInvalidToken() public {
        collateralToken = new ERC20Mock();
        preCheckCollateral(user);
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(Vault.Vault__collateralTokenNotSupported.selector, address(collateralToken))
        );
        vault.depositCollateral(COLLATERAL_TOKEN_FUND_AMOUNT, address(collateralToken));
        vm.stopPrank();
        checkCollateral(0);
    }

    function testDepositCollateralRevertInsufficientAllowance() public {
        collateralToken.mint(userWithoutTokens, COLLATERAL_TOKEN_FUND_AMOUNT);
        preCheckCollateral(userWithoutTokens);
        vm.startPrank(userWithoutTokens);
        vm.expectRevert(Vault.Vault__insufficientAllowance.selector);
        vault.depositCollateral(COLLATERAL_TOKEN_FUND_AMOUNT, address(collateralToken));
        vm.stopPrank();
        checkCollateral(0);
    }

    function testDepositCollateralRevertInsufficientBalance() public {
        preCheckCollateral(userWithoutTokens);
        vm.startPrank(userWithoutTokens);
        collateralToken.approve(address(vault), type(uint256).max);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        vault.depositCollateral(COLLATERAL_TOKEN_FUND_AMOUNT, address(collateralToken));
        vm.stopPrank();
        checkCollateral(0);
    }

    //-------  MODIFY COLLATERAL TESTS -------//

    function testModifyCollateralOnlyRole() public {
        vm.startPrank(collateralManager);
        vault.modifyCollateral(address(collateralToken), address(0x1234), 3e18);
        (address priceFeed, uint256 LVM) = vault.collateralPerToken(address(collateralToken));
        assertEq(LVM, 3e18);
        assertEq(priceFeed, address(0x1234));
        vm.stopPrank();
    }

    function testModifyCollateralRevertsUnauthorized() public {
        vm.startPrank(user);
        vm.expectRevert();
        vault.modifyCollateral(address(collateralToken), address(0x1234), 3e18);
        vm.stopPrank();
    }

    function testAddCollateral_RevertIfAlreadyExists() public {
        vm.startPrank(collateralManager);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__collateralAlreadyExists.selector));
        vault.addCollateral(address(collateralToken), address(0xfeed), 2e18);
        vm.stopPrank();
    }

    function testAddCollateral_SuccessForNewToken() public {
        ERC20Mock newToken = new ERC20Mock();
        vm.startPrank(collateralManager);
        vault.addCollateral(address(newToken), address(0xbeef), 3e18);
        vm.stopPrank();
        (address priceFeed, uint256 lvm) = vault.collateralPerToken(address(newToken));
        assertEq(priceFeed, address(0xbeef));
        assertEq(lvm, 3e18);
    }

    function testAddCollateral_RevertsIfNotCollateralManager() public {
        ERC20Mock newToken = new ERC20Mock();

        vm.startPrank(user);
        vm.expectRevert(); // AccessControl revert
        vault.addCollateral(address(newToken), address(0xbeef), 3e18);
        vm.stopPrank();
    }

    function testModifyCollateral_Success() public {
        vm.startPrank(collateralManager);
        vault.modifyCollateral(address(collateralToken), address(0x1234), 4e18);
        vm.stopPrank();

        (address priceFeed, uint256 lvm) = vault.collateralPerToken(address(collateralToken));
        assertEq(priceFeed, address(0x1234));
        assertEq(lvm, 4e18);
    }

    function testModifyCollateral_RevertIfInvalidParams() public {
        vm.startPrank(collateralManager);

        // zero token
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__invalidCollateralParams.selector));
        vault.modifyCollateral(address(0), address(0x1234), 3e18);

        // zero priceFeed
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__invalidCollateralParams.selector));
        vault.modifyCollateral(address(collateralToken), address(0), 3e18);

        // too low LVM
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__invalidCollateralParams.selector));
        vault.modifyCollateral(address(collateralToken), address(0x1234), 0.5e18);

        vm.stopPrank();
    }

    function testModifyCollateral_RevertsIfNotCollateralManager() public {
        vm.startPrank(user);
        vm.expectRevert(); // AccessControl revert
        vault.modifyCollateral(address(collateralToken), address(0x1234), 3e18);
        vm.stopPrank();
    }

    function testModifyCollateralPriceFeed_Success() public {
        vm.startPrank(collateralManager);
        vault.modifyCollateralPriceFeed(address(collateralToken), address(0xdead));
        vm.stopPrank();

        (address priceFeed,) = vault.collateralPerToken(address(collateralToken));
        assertEq(priceFeed, address(0xdead));
    }

    function testModifyCollateralPriceFeed_RevertIfZeroFeed() public {
        vm.startPrank(collateralManager);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__invalidCollateralParams.selector));
        vault.modifyCollateralPriceFeed(address(collateralToken), address(0));
        vm.stopPrank();
    }

    function testModifyCollateralPriceFeed_RevertIfCollateralDoesNotExist() public {
        ERC20Mock newToken = new ERC20Mock();
        vm.startPrank(collateralManager);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__collateralDoesNotExist.selector));
        vault.modifyCollateralPriceFeed(address(newToken), address(0x1234));
        vm.stopPrank();
    }

    function testModifyCollateralPriceFeed_RevertIfNotCollateralManager() public {
        vm.startPrank(user);
        vm.expectRevert(); // AccessControl revert
        vault.modifyCollateralPriceFeed(address(collateralToken), address(0x1234));
        vm.stopPrank();
    }

    function testModifyCollateralLVM_Success() public {
        vm.startPrank(collateralManager);
        vault.modifyCollateralLVM(address(collateralToken), 5e18);
        vm.stopPrank();

        (, uint256 lvm) = vault.collateralPerToken(address(collateralToken));
        assertEq(lvm, 5e18);
    }

    function testModifyCollateralLVM_RevertIfTooLow() public {
        vm.startPrank(collateralManager);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__invalidCollateralParams.selector));
        vault.modifyCollateralLVM(address(collateralToken), 0.5e18);
        vm.stopPrank();
    }

    function testModifyCollateralLVM_RevertIfCollateralDoesNotExist() public {
        ERC20Mock newToken = new ERC20Mock();
        vm.startPrank(collateralManager);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__collateralDoesNotExist.selector));
        vault.modifyCollateralLVM(address(newToken), 2e18);
        vm.stopPrank();
    }

    function testModifyCollateralLVM_RevertIfNotCollateralManager() public {
        vm.startPrank(user);
        vm.expectRevert(); // AccessControl revert
        vault.modifyCollateralLVM(address(collateralToken), 2e18);
        vm.stopPrank();
    }
}
