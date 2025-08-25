// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./interfaces/IRebaseToken.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Vault is ReentrancyGuard {
    error Vault__innsuficientAmount();
    error Vault__transferFailed();

    uint256 private totalDeposits;
    IRebaseToken private immutable i_rebaseToken;

    constructor(address _rebaseToken) {
        i_rebaseToken = IRebaseToken(_rebaseToken);
    }

    function deposit() external payable {
        depositTo(msg.sender);
    }

    function depositTo(address account) public payable {
        if (msg.value == 0) {
            revert Vault__innsuficientAmount();
        }

        i_rebaseToken.mint(account, msg.value);
        totalDeposits += msg.value;
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert Vault__innsuficientAmount();
        }

        i_rebaseToken.burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) {
            revert Vault__transferFailed();
        }
        totalDeposits -= amount;
    }

    function getTotalDeposits() external view returns (uint256) {
        return totalDeposits;
    }
}
