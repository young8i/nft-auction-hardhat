// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract MockV3Aggregator is AggregatorV3Interface {
    uint8 public immutable override decimals;
    string public override description;
    uint256 public override version = 1;

    int256 private _answer;
    uint256 private _timestamp;

    constructor(uint8 decimals_, int256 initialAnswer) {
        decimals = decimals_;
        description = "Mock";
        _answer = initialAnswer;
        _timestamp = block.timestamp;
    }

    function latestRoundData() external view override returns (
        uint80, int256 answer, uint256, uint256 updatedAt, uint80
    ) {
        return (0, _answer, 0, _timestamp, 0);
    }

    // Unused methods for brevity
    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, 0, _timestamp, 0);
    }
}
