// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The subset of Chainlink's AggregatorV3Interface that Aegis relies on.
/// @dev Declared here rather than pulled in as a dependency: two functions is not worth another
///      submodule, and a security-relevant interface is better read in-repo than looked up.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    /// @return roundId The round the answer belongs to
    /// @return answer The price, scaled by `decimals()`
    /// @return startedAt When the round started
    /// @return updatedAt When the answer was last written — the field that matters for staleness
    /// @return answeredInRound The round the answer was computed in
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
