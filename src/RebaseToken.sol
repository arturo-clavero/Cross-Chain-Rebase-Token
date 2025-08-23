// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

//this coin is "pegged" to eth, but it is a rebase token as its value will grow with the interest rate
//interest rate can be upgraded to be dynamic from borrowers acrrued interest
contract RebaseToken is ERC20, AccessControl{
    uint256 private constant WAD = 1e18;
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant INDEX_MANAGER_ROLE = keccak256("INDEX_MANAGER_ROLE");
    uint256 private globalIndex;

    error RebaseToken__unauthorizedAccess();

    constructor(string memory _name, string memory _symbol, address admin) ERC20(_name, _symbol){
        globalIndex = WAD;
        if (admin == address(0))
            admin = msg.sender;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

//make only index yield access role
    function updateGlobalIndex(uint256 newValue) external onlyRole(INDEX_MANAGER_ROLE){
        globalIndex = newValue;
    }

//make only minter access role
    //value is expected in eth
    function mint(address account, uint256 value) external onlyRole(MINTER_ROLE){
        _mint(account, ethToRaw(value));
    }

//make only burner access role
    //value is expected in eth
    function burn(address account, uint256 value) external onlyRole(BURNER_ROLE) {
        _burn(account, ethToRaw(value));
    }

    function getGlobalIndex() external view returns (uint256){
        return globalIndex;
    }

    //value returned is in eth
    function balanceOf(address account) public view override returns (uint256) {
        return rawToEth(super.balanceOf(account));   
    }

    //value is expected in eth
    function transfer(address to, uint256 value) public override returns (bool) {
        return super.transfer(to, ethToRaw(value));
    }

    //value is expected in eth
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        return super.transferFrom(from, to, ethToRaw(value));
    }

//conversion functions: 
    function rawToEth(uint256 raw) public view returns (uint256){
        return raw * globalIndex / WAD;
    }

    function ethToRaw(uint256 ETH) public view returns (uint256 raw){
        return ETH * WAD / globalIndex;
    }

}