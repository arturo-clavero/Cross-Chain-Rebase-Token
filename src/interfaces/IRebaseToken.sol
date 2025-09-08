// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IRebaseToken {
    function updateGlobalIndex(uint256 newValue) external;

    function mint(address account, uint256 value) external;

    function burn(address account, uint256 value) external;

    function getGlobalIndex() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(address from, address to, uint256 value) external returns (bool);

    function rawToEth(uint256 raw) external view returns (uint256);

    function ethToRaw(uint256 ETH) external view returns (uint256 raw);
}
