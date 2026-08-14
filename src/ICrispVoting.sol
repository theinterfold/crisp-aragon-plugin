// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IPlugin} from "@aragon/osx-commons-contracts/src/plugin/IPlugin.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {IInterfold} from "./IInterfold.sol";
import {ICRISP} from "./ICRISP.sol";

/// @notice Interface for the Crisp Voting plugin
interface ICrispVoting {
    /// @notice Thrown if the address is zero.
    error ZeroAddress();
    /// @notice Thrown if the proposal with same actions and metadata already exists.
    /// @param proposalId The id of the proposal.
    error ProposalAlreadyExists(uint256 proposalId);
    /// @notice Thrown when a sender is not allowed to create a proposal.
    /// @param _address The sender address.
    error ProposalCreationForbidden(address _address);
    /// @notice Thrown if the proposal execution is forbidden.
    /// @param proposalId The ID of the proposal.
    error ProposalExecutionForbidden(uint256 proposalId);
    /// @notice Thrown when a proposal doesn't exist.
    /// @param proposalId The ID of the proposal which doesn't exist.
    error NonexistentProposal(uint256 proposalId);
    /// @notice Thrown when the number of options is less than 2.
    /// @param numOptions The number of options provided.
    error InvalidOptionCount(uint256 numOptions);
    /// @notice Thrown when attempting to execute a signaling-only proposal. A proposal is
    /// signaling-only (poll) if it has more than 3 options or uses CONSTANT credits, and therefore
    /// has no binding execution semantics.
    /// @param proposalId The ID of the proposal.
    error ProposalNotExecutable(uint256 proposalId);
    /// @notice Thrown when a proposal date is outside the allowed bounds.
    /// @param limit The bound limit (earliest allowed start or end date).
    /// @param actual The provided date.
    error DateOutOfBounds(uint64 limit, uint64 actual);
    /// @notice Thrown when a ratio value (e.g. `minParticipation`) exceeds the ratio base.
    /// @param limit The maximum allowed value.
    /// @param actual The provided value.
    error RatioOutOfBounds(uint256 limit, uint256 actual);

    /// @notice Thrown when the resolved fee payer has not escrowed enough credit for the E3 fee.
    /// @param payer The account whose credit was short.
    /// @param required The fee the E3 request costs.
    /// @param available The payer's escrowed credit.
    error InsufficientFeeCredit(address payer, uint256 required, uint256 available);

    /// @notice Thrown when SPP-shaped metadata names an SPP proposal with no creator.
    error InvalidSppMetadata();

    /// @notice Emitted when the voting settings are updated.
    /// @param minProposerVotingPower The minimum voting power needed to create a proposal.
    /// @param minParticipation The minimum participation required for quorum.
    /// @param minDuration The minimum duration of a vote.
    event VotingSettingsUpdated(uint256 minProposerVotingPower, uint32 minParticipation, uint64 minDuration);

    /// @notice Emitted when fee-token credit is escrowed for a creator.
    event FeeDeposited(address indexed payer, uint256 amount);

    /// @notice Emitted when unused fee-token credit is withdrawn.
    event FeeWithdrawn(address indexed payer, uint256 amount);

    /// @notice Emitted when a failed E3's requester refund is credited back to the payer.
    event RefundClaimed(uint256 indexed proposalId, uint256 indexed e3Id, address indexed payer, uint256 amount);

    /// @notice A struct for the voting settings.
    /// @param minProposerVotingPower The minimum voting power needed to propose a vote.
    /// @param minParticipation The minimum participation needed to vote.
    /// @param minDuration The minimum duration of the vote.
    struct VotingSettings {
        uint256 minProposerVotingPower;
        uint32 minParticipation;
        uint64 minDuration;
    }

    /// @notice Stores the decoded tally results for all options.
    /// @param counts An array where counts[i] is the total votes for option i.
    ///        For a 2-option vote: [yes, no].
    ///        For a 3-option vote: [yes, no, abstain].
    ///        For N options: [option0, option1, ..., optionN-1].
    struct TallyResults {
        uint256[] counts;
    }

    /// @notice A struct for the proposal parameters at the time of proposal creation.
    /// @param numOptions The number of options for the vote.
    /// @param startDate The start date of the proposal vote.
    /// @param endDate The end date of the proposal vote.
    /// @param snapshotBlock The timepoint the voting power census is taken at, one tick before
    ///        proposal creation, in the voting token's ERC-6372 clock units — a block number for
    ///        the OZ default clock, a UNIX timestamp for a `CLOCK_MODE=timestamp` token. Named
    ///        `snapshotBlock` for compatibility with Aragon's TokenVoting parameters.
    /// @param minVotingPower The minimum voting power needed.
    /// @param minParticipation The minimum participation needed.
    /// @param creditMode The credit mode for the vote. CONSTANT proposals are signaling-only.
    struct ProposalParameters {
        uint256 numOptions;
        uint64 startDate;
        uint64 endDate;
        uint256 snapshotBlock;
        uint256 minVotingPower;
        uint256 minParticipation;
        ICRISP.CreditMode creditMode;
    }

    /// @notice The parameters for initializing the plugin
    /// @param dao The DAO contract address
    /// @param token The token contract address
    /// @param interfold The interfold contract address
    /// @param committeeSize The size of the committee.
    /// @param paramSet The parameter set to use.
    /// @param e3Program The address of the E3 Program.
    /// @param e3ProgramParams The ABI encoded computation parameters.
    /// @param votingSettings The initial voting settings (quorum, proposer power, duration).
    struct PluginInitParams {
        IDAO dao;
        address token;
        address interfold;
        IInterfold.CommitteeSize committeeSize;
        uint8 paramSet;
        address crispProgramAddress;
        bytes computeProviderParams;
        VotingSettings votingSettings;
    }

    /// @notice A struct for proposal-related information.
    /// @param executed Whether the proposal is executed or not.
    /// @param parameters The proposal parameters at the time of the proposal creation.
    /// @param actions The actions to be executed when the proposal passes.
    /// @param allowFailureMap A bitmap allowing the proposal to succeed, even if individual
    /// actions might revert. If the bit at index `i` is 1, the proposal succeeds even if the `i`th
    /// action reverts. A failure map value of 0 requires every action to not revert.
    /// @param targetConfig Configuration for the execution target, specifying the target address
    /// and operation type (either `Call` or `DelegateCall`). Defined by `TargetConfig` in the
    /// `IPlugin` interface,
    ///     part of the `osx-commons-contracts` package, added in build 3.
    /// @param e3Id The ID of the E3 request ID
    struct Proposal {
        bool executed;
        ProposalParameters parameters;
        TallyResults tally;
        Action[] actions;
        uint256 allowFailureMap;
        IPlugin.TargetConfig targetConfig;
        uint256 e3Id;
    }

    /// @notice Quotes the Interfold E3 fee a proposal with these parameters would cost.
    /// @dev Takes the same dates and encoded data as `createProposal` and runs them through the
    /// same request construction, so a caller can escrow exactly the right credit before creating
    /// rather than discovering the price from a reverted transaction. Reverts identically to
    /// `createProposal` on invalid dates or option counts.
    ///
    /// The quote is only as stable as its inputs: passing `0` for a date normalises it to
    /// `block.timestamp`, so the window — and therefore the fee — shifts between the quote and the
    /// transaction that uses it. Pass explicit dates for a figure that will still hold when the
    /// proposal is created.
    /// @param _startDate The proposal start date, or 0 for `block.timestamp`.
    /// @param _endDate The proposal end date, or 0 for the earliest date `minDuration` allows.
    /// @param _data The same ABI-encoded `(allowFailureMap, numOptions, creditMode, credits)` that
    /// would be passed to `createProposal`.
    /// @return fee The E3 fee, denominated in the Interfold fee token.
    function quoteFee(uint64 _startDate, uint64 _endDate, bytes calldata _data)
        external
        view
        returns (uint256 fee);

    /// @notice Returns the minimum voting power needed to propose a vote.
    /// @return The minimum voting power needed to propose a vote.
    function minProposerVotingPower() external view returns (uint256);

    /// @notice Returns the total voting power of the DAO at a given block number.
    /// @param _blockNumber The block number to get the total voting power at.
    /// @return The total voting power of the DAO at the given block number.
    function totalVotingPower(uint256 _blockNumber) external view returns (uint256);

    /// @notice Returns the voting token interface.
    /// @return The voting token interface.
    function getVotingToken() external view returns (IVotesUpgradeable);

    /// @notice Returns the minimum participation needed to vote.
    /// @return The minimum participation needed to vote.
    function minParticipation() external view returns (uint32);

    /// @notice Returns the minimum duration of the vote.
    /// @return The minimum duration of the vote.
    function minDuration() external view returns (uint64);

    /// @notice Updates the voting settings. Requires the `MANAGER_PERMISSION`.
    /// @param _votingSettings The new voting settings.
    function updateVotingSettings(VotingSettings calldata _votingSettings) external;

    /// @notice Returns the proposal data for a given proposal ID.
    /// @param _proposalId The id of the proposal.
    /// @return The proposal data.
    function getProposal(uint256 _proposalId) external view returns (Proposal memory);

    /// @notice Get the tally result
    /// @param _proposalId The id of the proposal
    /// @return The tally result
    function getTally(uint256 _proposalId) external view returns (TallyResults memory);

    /// @notice Returns the index of the option with the most votes.
    /// @dev On a tie, or when no votes have been cast, the lowest index (0) is returned. Callers
    /// should not treat a return value of 0 as a definitive winner without inspecting the tally.
    /// @param _proposalId The id of the proposal.
    /// @return The winning option index.
    function getWinningOption(uint256 _proposalId) external view returns (uint256);
}
