// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract RejectEth {
    error UnwantedMoney(bool rejects);

    bool private rejects;

    constructor() {
        rejectPayment();
    }

    function acceptPayment() public {
        rejects = false;
    }

    function rejectPayment() public {
        rejects = true;
    }


    fallback() external payable {
        if (rejects) {
            revert UnwantedMoney(rejects);
        }
    }
}