// SPDX-License-Identifier: LGPL-3.0-only
//
// This file is provided WITHOUT ANY WARRANTY;
// without even the implied warranty of MERCHANTABILITY
// or FITNESS FOR A PARTICULAR PURPOSE.

pragma solidity >=0.8.27;

/// @title ICRISP
interface ICRISP {
    /// @notice Decode the tally for a given e3Id
    /// @param e3Id The identifier for the e3 instance
    /// @return The decoded tally results as an array of uint256
    function decodeTally(uint256 e3Id) external view returns (uint256[] memory);

    /// @notice Enum to represent credit modes
    enum CreditMode {
        /// @notice Everyone has constant credits
        CONSTANT,
        /// @notice Credits are custom (can be based on token balance, etc)
        CUSTOM
    }

    /// @notice Where the eligible voter set for a round comes from. Mirrors CRISPProgram.CensusMode
    /// — the program range-checks this value and stores it, so the ordering must match exactly.
    enum CensusMode {
        /// @notice Derived from token balances by the coordinator.
        TOKEN,
        /// @notice Supplied by the requester via `getCensus(uint256 e3Id) returns (address[])`.
        BY_REQUESTER
    }
}
