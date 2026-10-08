// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;
    bool public broken;
    string public description = "mock";

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
    }

    function set(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
        roundId++;
        answeredInRound = roundId;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function setRounds(uint80 r, uint80 ar) external {
        roundId = r;
        answeredInRound = ar;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "broken");
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}
