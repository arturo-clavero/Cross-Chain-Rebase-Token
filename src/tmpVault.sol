// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.13;

// import "./RebaseToken.sol";
// import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

// struct Collateral {
//     address tokenAddress;
//     uint256 LMV;
//     uint256 interestRate;
//     uint256 unhealthyIndex;
// }

// struct Borrowed {
//     address account;
//     address tokenCollateralAddress;
//     uint256 collateralAmount;
//     uint256 payBack;
// }

// contract Vault is ReentrancyGuard, AccessControl{

//     error Vault__innsuficientAmount();
//     error Vault__transferFailed();
//     error Vault__mustCallModifyCollateral();
//     error Vault__unsupportedCollateral();

//     uint256 private constant WAD = 1e18;
//     bytes32 public constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER_ROLE");
//     RebaseToken private rebaseToken;
//     uint256 private id;
//     uint256 private totalInterests;

//     uint256[] borrowesIds = new unit256(0);
//     mapping(address=>uint256) public supportedCollateral;
//     mapping(uint256=>Borrowed) public borrowOrders;

//     constructor (RebaseToken _rebaseToken, address admin){
//         rebaseToken = _rebaseToken;
//         if (admin == address(0))
//             admin = msg.sender;
//         _grantRole(DEFAULT_ADMIN_ROLE, admin);
//     }

// //for lenders :
//     function deposit() external payable{
//         depositTo(msg.sender);
//     }

//     function depositTo(address account) public payable{
//         if (msg.value == 0)
//             revert Vault__innsuficientAmount();
//         rebaseToken.mint(account, msg.value);
//     }

//     function withdraw(uint256 amount) external nonReentrant{
//         if (amount == 0)
//             revert Vault__innsuficientAmount();

//         rebaseToken.burn(msg.sender, amount);
//         (bool success, ) = msg.sender.call{value: amount}("");
//         if(!success)
//             revert Vault__transferFailed();
//     }

// //for borrowers :
//     function borrow(uint256 amount, address collateralToken) external {
//         uint256 LVM = supportedCollateral[collateralToken].LVM;
//         if (LVM == 0)
//             revert Vault__unsupportedCollateral();
//         if (amount == 0)
//             revert Vault__insufficientAmount();
//         //check allowance of transfer...
//         id += 1;
//         borrowOrders[id] = Borrowed({
//             account : msg.sender;
//             tokenCollateralAddress: collateralToken;
//             collateralAmount: amount;
//         });
//         borrowerIds.push(id);
//         //transfer amount to this contract ...
//     }

//     function payBack(uint256 id) external payable{
//         if (msg.value == 0)
//             revert Vault__invalidAmount();
//         Borrower borrowOrder = borrowedOrders[id];
//         if (borrowOrder = Borrower(0))
//             revert Vault__noDebtAssociatedWithThisId();
//         Collateral collateral = supportedCollateral[borrowOrder.collateralToken];
//         uint256 totalPayBack = calculatePayBack(collateral.LVM, collateral.interestRate, borrowOrder.collateralAmount);
//         totalInterest+= msg.value;
//         if (msg.value >= totalPayBack){
//             msg.sender.transfer(borrowOrder.collateralAmount, borrowOrder.collateralToken);
//             //send them their collateral back
//         }
//         else{
//             uint256 leftOverDebt = totalPayBack - msg.value;
//             borrowedOrder.collateralAmount = leftOverDebt * WAD * WAD / collateral.LVM / collateral.interestRate;
//         }
//     }

//     function calculatePayBack(uint256 LVM, uint256 interestRate, uint256 collateralAmount) public returns (uint256){
//             return (collateralAmount * LVM * interestRate / WAD / WAD);
//             //need to apss this to the price feed... to change to eth
//         }

// //VALIDATOR BOTS :

//     function getAllBorrowerIds() external returns (uint256[]) onlyRole(VALIDATOR_ROLE) {
//         return borrowerIds();
//     }

//     function getBorrower(uint256 id) external returns (Borrower) onlyRole(VALIDATOR_ROLE) {
//         return borrowedOrders[id];
//     }

//     function liquidate(uint256 id) external onlyRole(VALIDATOR_ROLE){
//         Borrow order = borrowedOrders[id];
//         CollateralToken collateral = supportedCollateral[order.tokenCollateralAddress]
//         if (calculatePayBackfor(collateral.LVM, collateral.InterestRate, order.colaterallAmount)
//         > order.collateralAmount * collateral.unhealthyIndex / WAD){
//             sellCollateral();//TODO
//             deleteOrder();//TODO
//         }
//     }

// //COLLATERAL MANAGERS :

//     function addCollateral(address collateralToken, uint256 LVM, uint256 interestRate, uint256 unhealthyIndex) external onlyRole(COLLATERAL_MANAGER_ROLE){
//         if (supportedCollateral[collateralToken] != 0)
//             revert Vault__mustCallModifyCollateral();
//         modifyCollateral(collateralToken, LVM, interestRate, unhealthyIndex);
//     }

//     function modifyCollateral(address collateralToken, uint256 LVM, uint256 interestRate, uint256 unhealthyIndex) public onlyRole(COLLATERAL_MANAGER_ROLE){
//         supportedCollateral[collateralToken].LVM = LVM;
//         supportedCollateral[collateralToken].interestRate = interestRate;
//         supportedCollateral[collateralToken].unhealthyIndex = unhealthyIndex;
//     }

//     function modifyCollateralLVM(address collateralToken, uint256 LVM) public onlyRole(COLLATERAL_MANAGER_ROLE){
//         supportedCollateral[collateralToken].LVM = LVM;
//     }

//     function modifyCollateralInterestRate(address collateralToken, uint256 interestRate) public onlyRole(COLLATERAL_MANAGER_ROLE){
//         supportedCollateral[collateralToken].interestRate = interestRate;
//     }

//     function modifyCollateralUnhealthyIndex(address collateralToken, uint256 unhealthyIndex) public onlyRole(COLLATERAL_MANAGER_ROLE){
//         supportedCollateral[collateralToken].unhealthyIndex = unhealthyIndex;
//     }

// }
