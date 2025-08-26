// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract PriceFeedMock {
    int256 public immutable rate;
    //pre scaled ratio, 1 2 200 ...

    constructor(int256 _rate) {
        rate = _rate;
    }

    function decimals() external view returns (uint8) {
        return 8;
    }

    function description() external view returns (string memory) {
        return "description";
    }

    function version() external view returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = _roundId + 1;
        answer = 1;
        startedAt = 1;
        updatedAt = 1;
        answeredInRound = 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = 1;
        answer = rate * int256(10 ** uint256(this.decimals()));
        startedAt = 1;
        updatedAt = 1;
        answeredInRound = 1;
    }
}
