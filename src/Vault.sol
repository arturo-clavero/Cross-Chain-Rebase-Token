// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./RebaseToken.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Vault is ReentrancyGuard{

    error Vault__innsuficientAmount();
    error Vault__transferFailed();

    RebaseToken private rebaseToken;

    constructor (RebaseToken _rebaseToken){
        rebaseToken = _rebaseToken;

    }

    function deposit() external payable{
        depositTo(msg.sender);
    }

    function depositTo(address account) public payable{
        if (msg.value == 0)
            revert Vault__innsuficientAmount();
        rebaseToken.mint(account, msg.value);
    }

    function withdraw(uint256 amount) external nonReentrant{
        if (amount == 0)
            revert Vault__innsuficientAmount();

        rebaseToken.burn(msg.sender, amount);
        (bool success, ) = msg.sender.call{value: amount}("");
        if(!success)
            revert Vault__transferFailed();
    }
}