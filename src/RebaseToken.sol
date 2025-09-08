// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title RebaseToken pegged to ETH with interest accrual
/// @notice This token represents ETH deposits in the vault and grows in value according to a global index
/// @dev Only accounts with specific roles can mint, burn, or update the index
contract RebaseToken is ERC20, AccessControl {
    uint256 private constant WAD = 1e18;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant INDEX_MANAGER_ROLE = keccak256("INDEX_MANAGER_ROLE");

    uint256 private globalIndex;

    /// @param _name Token name
    /// @param _symbol Token symbol
    /// @param admin Address to grant admin role (defaults to deployer)
    constructor(string memory _name, string memory _symbol, address admin) ERC20(_name, _symbol) {
        globalIndex = WAD;
        if (admin == address(0)) {
            admin = msg.sender;
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Update the global index, used to scale balances according to interest
    /// @param newValue New global index (in WAD units)
    function updateGlobalIndex(uint256 newValue) external onlyRole(INDEX_MANAGER_ROLE) {
        globalIndex = newValue;
    }

    /// @notice Mint tokens representing ETH deposits
    /// @param account Recipient address
    /// @param value Amount in ETH units
    function mint(address account, uint256 value) external onlyRole(MINTER_ROLE) {
        _mint(account, ethToRaw(value));
    }

    /// @notice Burn tokens when ETH is withdrawn
    /// @param account Target address
    /// @param value Amount in ETH units
    function burn(address account, uint256 value) external onlyRole(BURNER_ROLE) {
        _burn(account, ethToRaw(value));
    }

    /// @notice Get the current global index
    /// @return The global index (WAD)
    function getGlobalIndex() external view returns (uint256) {
        return globalIndex;
    }

    /// @notice Get balance of account in ETH units
    /// @param account Address to query
    /// @return Balance scaled by global index (ETH units)
    function balanceOf(address account) public view override returns (uint256) {
        return rawToEth(super.balanceOf(account));
    }

    /// @notice Transfer tokens in ETH units
    /// @param to Recipient address
    /// @param value Amount to transfer in ETH units
    /// @return True if successful
    function transfer(address to, uint256 value) public override returns (bool) {
        return super.transfer(to, ethToRaw(value));
    }

    /// @notice Transfer tokens on behalf of another address in ETH units
    /// @param from Sender address
    /// @param to Recipient address
    /// @param value Amount to transfer in ETH units
    /// @return True if successful
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        return super.transferFrom(from, to, ethToRaw(value));
    }

    /// @notice Convert raw token units to ETH units based on global index
    /// @param raw Raw token amount
    /// @return Equivalent value in ETH units
    function rawToEth(uint256 raw) public view returns (uint256) {
        return raw * globalIndex / WAD;
    }

    /// @notice Convert ETH units to raw token units
    /// @param ETH Amount in ETH units
    /// @return raw equivalent value in raw token units
    function ethToRaw(uint256 ETH) public view returns (uint256 raw) {
        return ETH * WAD / globalIndex;
    }
}
