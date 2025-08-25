// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {RebaseToken} from "../src/RebaseToken.sol";
import {Vault} from "../src/Vault.sol";

contract DeployRebaseToken is Script {
    error DeployRebaseToken__mustCallRunRebaseTokenFirst();

    address private admin;
    RebaseToken public rebaseToken;
    Vault public vault;

    function setUp() public {}

    function run(string memory _name, string memory _symbol, address _admin) public returns (RebaseToken) {
        //deploy token and vault:

        vm.startBroadcast();
        admin = _admin;
        rebaseToken = new RebaseToken(_name, _symbol, admin);
        vault = new Vault(address(rebaseToken));
        vm.stopBroadcast();

        //grant vault mint and burning roles:
        vm.startBroadcast(admin);
        rebaseToken.grantRole(rebaseToken.MINTER_ROLE(), address(vault));
        rebaseToken.grantRole(rebaseToken.BURNER_ROLE(), address(vault));
        vm.stopBroadcast();
    }
}
