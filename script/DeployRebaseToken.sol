// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {RebaseToken} from "../code/RebaseToken.sol";
import {Vault} from "../code/Vault.sol";

contract DeployRebaseToken is Script {
    error DeployRebaseToken__mustCallRunRebaseTokenFirst();

    address private admin;
    RebaseToken public rebaseToken;
    Vault public vault;

    function run(string memory _name, string memory _symbol, address _admin) public {
        //deploy token and vault:
        vm.startBroadcast();
        admin = _admin;
		if (_admin == address(0))
			admin = msg.sender;
        rebaseToken = new RebaseToken(_name, _symbol, admin);
        vault = new Vault(address(rebaseToken), admin);
        vm.stopBroadcast();
		console.log("Deployed Rebase Token: ", address(rebaseToken));
		console.log("Deployed vault: ", address(vault));
        //grant roles:
        vm.startBroadcast(admin);
        rebaseToken.grantRole(rebaseToken.MINTER_ROLE(), address(vault));
        rebaseToken.grantRole(rebaseToken.BURNER_ROLE(), address(vault));
        vm.stopBroadcast();
    }
}

// forge script DeployRebaseToken \
//   --rpc-url $SEPOLIA_RPC_URL \
//   --private-key $PRIVATE_KEY \
//   --broadcast \
//   --verify \
//   --etherscan-api-key $ETHERSCAN_API_KEY \
//   --sig "run(string,string,address)" "42RebaseToken" "42RT" 0x0000000000000000000000000000000000000000

//   Deployed Rebase Token:  0x83c49E13252bf6525C3470b708a3D4A7ba82C99D
//   Deployed vault:  0x1FB9DCb6F219E325C7Fe1D59697a86f96E11DD5e