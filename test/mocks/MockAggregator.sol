// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice A Chainlink-shaped feed the tests drive directly.
/// @dev Also what the demo deploys: no canonical Chainlink feed exists on the testnets Aegis is
///      deployed to, and a controllable feed is in any case the only way to *show* the oracle
///      guard catching a divergence rather than describe it.
contract MockAggregator is IAggregatorV3 {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public round;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        answer = _answer;
        updatedAt = block.timestamp;
        round = 1;
    }

    function set(int256 _answer) external {
        answer = _answer;
        updatedAt = block.timestamp;
        round += 1;
    }

    /// @notice Write an answer while leaving `updatedAt` in the past, to exercise staleness.
    function setStale(int256 _answer, uint256 age) external {
        answer = _answer;
        updatedAt = block.timestamp - age;
        round += 1;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, updatedAt, updatedAt, round);
    }
}
