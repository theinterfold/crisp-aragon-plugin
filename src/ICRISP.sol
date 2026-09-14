// SPDX-License-Identifier: LGPL-3.0-only
//
// This file is provided WITHOUT ANY WARRANTY;
// without even the implied warranty of MERCHANTABILITY
// or FITNESS FOR A PARTICULAR PURPOSE.

pragma solidity >=0.8.27;

/// @title ICRISP
interface ICRISP {
    /// @notice Earliest voting start under the current committee timeouts.
    function earliestVotingStart() external view returns (uint256);

    /// @notice Time reserved after ballots close for availability finalization.
    function availabilityFinalizationWindow() external view returns (uint256);

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

    /// @notice How the eligible voter set for a round is determined. Mirrors
    /// CRISPProgram.CensusMode — the program range-checks this value and stores it, so the
    /// ordering must match exactly.
    enum CensusMode {
        /// @notice The coordinator derives the electorate from holders of the voting token.
        TOKEN,
        /// @notice Supplied by the requester via `getCensus(uint256 e3Id) returns (address[])`.
        /// For electorates that are not a token balance — a subset of players, a jury — and
        /// therefore cannot be discovered.
        BY_REQUESTER,
        /// @notice No census at all. `CRISPProgram.publishInput` reads each voter's power
        /// straight from the token at the round's snapshot and hands it to the circuit, so
        /// nothing has to build or publish a Merkle tree. This is what removes the coordinator
        /// from the eligibility path.
        ONCHAIN
    }
}
