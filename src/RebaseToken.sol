// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

//this coin is "pegged" to eth, but it is a rebase token as its value will grow with the interest rate
//interest rate can be upgraded to be dynamic from borrowers acrrued interest
contract RebaseToken is ERC20{
    uint256 private constant WAD = 1e18;
    uint256 private globalIndex;

    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol){
        globalIndex = WAD;
    }

//make only index yield access role
    function updateGlobalIndex(uint256 newValue) external{
        globalIndex = newValue;
    }

//make only minter access role
    //value is expected in eth
    function mint(address account, uint256 value) external {
        _mint(account, ethToRaw(value));
    }

//make only burner access role
    //value is expected in eth
    function burn(address account, uint256 value) external {
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