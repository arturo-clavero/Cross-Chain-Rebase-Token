// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {RebaseToken} from "../src/RebaseToken.sol";

contract DeployRebaseToken is Script {
    RebaseToken public rebaseToken;

    function setUp() public {}

    function run(string memory _name, string memory _symbol, address admin) public returns(RebaseToken) {
        vm.startBroadcast();

        rebaseToken = new RebaseToken(_name, _symbol, admin);

        vm.stopBroadcast();

        return rebaseToken;
    }
}
