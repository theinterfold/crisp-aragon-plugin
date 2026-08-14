// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.29;

import {Action} from "@aragon/osx/core/dao/DAO.sol";
import {PluginUUPSUpgradeable} from "@aragon/osx/framework/plugin/setup/PluginSetupProcessor.sol";
import {
    ProposalUpgradeable
} from "@aragon/osx-commons-contracts/src/plugin/extensions/proposal/ProposalUpgradeable.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
import {IERC6372Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC6372Upgradeable.sol";
import {
    IERC20MetadataUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {IProposal} from "@aragon/osx-commons-contracts/src/plugin/extensions/proposal/IProposal.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IInterfold} from "./IInterfold.sol";
import {E3, IE3Program} from "./IE3.sol";
import {ICrispVoting} from "./ICrispVoting.sol";
import {ICRISP} from "./ICRISP.sol";
import {IStagedProposalProcessor} from "./IStagedProposalProcessor.sol";
import {IE3RefundManager} from "./IE3RefundManager.sol";

/// @title CrispVoting
/// @notice An Aragon OSx governance plugin that runs private, encrypted votes through Interfold's
/// CRISP E3 program. Proposal creation registers an E3 request with Interfold; once the tally is
/// decrypted and published by the CRISP program, the proposal can be executed if it meets the
/// quorum and winning-option criteria.
/// @dev In order for executed actions to run, the plugin needs to hold EXECUTE_PERMISSION_ID on the DAO.
/// @notice This plugin is inspired by MACI's voting plugin - https://github.com/privacy-ethereum/maci-voting-plugin-aragon/blob/main/src/MaciVoting.sol
contract CrispVoting is PluginUUPSUpgradeable, ProposalUpgradeable, ICrispVoting {
    /// @notice used to perform safe ERC20 operations
    using SafeERC20 for IERC20;

    /// @notice The manager permission id
    bytes32 public constant MANAGER_PERMISSION_ID = keccak256("MANAGER_PERMISSION");

    /// @notice The denominator for ratio calculations.
    uint256 internal constant RATIO_BASE = 100;

    /// @notice The interface id for the Crisp Voting plugin
    bytes4 internal constant CRISP_VOTING_INTERFACE_ID = this.initialize.selector ^ this.minProposerVotingPower.selector
        ^ this.totalVotingPower.selector ^ this.getVotingToken.selector ^ this.minParticipation.selector
        ^ this.minDuration.selector ^ this.getProposal.selector;

    /// @notice The interfold contract reference
    IInterfold public interfold;

    /// @notice The token used to pay for Interfold fees
    IERC20 public interfoldFeeToken;

    /// @notice An
    /// [OpenZeppelin `Votes`](https://docs.openzeppelin.com/contracts/4.x/api/governance#Votes)
    /// compatible contract referencing the token being used for voting.
    IVotesUpgradeable private votingToken;

    /// @notice The voting settings
    VotingSettings private votingSettings;

    /// @notice A mapping between proposal IDs and proposal information.
    mapping(uint256 => Proposal) internal proposals;

    /// @notice The ciphernode threshold
    IInterfold.CommitteeSize private committeeSize;
    /// @notice The parameter set to use
    uint8 private paramSet;
    /// @notice The address of the E3 Program
    address private crispProgramAddress;
    /// @notice The ABI encoded compute provider parameters
    bytes private computeProviderParams;

    /// @notice Disables the initializers on the implementation contract to prevent
    /// it from being left uninitialized.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the plugin
    /// @param _params The plugin initialization parameters
    function initialize(PluginInitParams calldata _params) external initializer {
        __PluginUUPSUpgradeable_init(_params.dao);

        if (_params.interfold == address(0)) {
            revert ZeroAddress();
        }
        interfold = IInterfold(_params.interfold);
        votingToken = IVotesUpgradeable(_params.token);
        interfoldFeeToken = IERC20(interfold.feeToken());
        committeeSize = _params.committeeSize;
        paramSet = _params.paramSet;
        crispProgramAddress = _params.crispProgramAddress;
        computeProviderParams = _params.computeProviderParams;

        _updateVotingSettings(_params.votingSettings);
    }

    /// @inheritdoc ICrispVoting
    function updateVotingSettings(VotingSettings calldata _votingSettings) external auth(MANAGER_PERMISSION_ID) {
        _updateVotingSettings(_votingSettings);
    }

    /// @notice Creates a new E3 request in Interfold
    /// @dev This is a wrapper around the createProposal function as we need it to be payable
    /// as there will be charges for the E3 request in Interfold.
    /// @param _metadata The metadata of the proposal
    /// @param _actions The actions that will be executed if the proposal passes
    /// @param _startDate The start date of the proposal
    /// @param _endDate The end date of the proposal
    /// @param _data The additional abi-encoded data to include more necessary fields
    /// This includes whether to allow failures, and the interfold request start window details
    /// @return proposalId The id of the proposal
    function createProposal(
        bytes memory _metadata,
        Action[] memory _actions,
        uint64 _startDate,
        uint64 _endDate,
        bytes memory _data
    ) external returns (uint256 proposalId) {
        /// @notice Create a deterministic proposal id
        proposalId = _createProposalId(keccak256(abi.encode(_actions, _metadata)));

        /// @notice Get the proposal storage variable
        Proposal storage proposal = proposals[proposalId];

        {
            /// @notice Check if the proposal already exists first
            if (_proposalExists(proposalId)) {
                revert ProposalAlreadyExists(proposalId);
            }

            /// @notice Resolve and record who pays for this proposal's E3. In the DIRECT shape
            /// that is the caller, and their proposer eligibility is enforced here. In the STAGED
            /// (SPP) shape the caller is the SPP contract — which holds no tokens and no voting
            /// power — so the payer is the creator of the parent SPP proposal instead.
            proposalPayer[proposalId] = _resolvePayer(_metadata);
        }

        /// @notice Validate and normalise the dates, enforcing the configured minimum duration.
        /// The validated values feed both the Interfold input window and the stored parameters.
        (_startDate, _endDate) = _validateProposalDates(_startDate, _endDate);

        {
            /// @notice Decode the data
            (uint256 _allowFailureMap, uint256 numOptions, uint256 creditMode, uint256 credits) =
                abi.decode(_data, (uint256, uint256, uint256, uint256));

            IInterfold.E3RequestParams memory requestParams =
                _buildRequestParams(_startDate, _endDate, numOptions, creditMode, credits);

            // calculate the E3 fee
            uint256 fee = interfold.getE3Quote(requestParams);
            // Debit the recorded payer's escrowed credit. Pulling from `_msgSender()` would be
            // wrong under the SPP, where the caller is the SPP contract rather than the creator.
            _chargeFee(proposalId, fee);
            // approve the interfold contract to take the fee
            interfoldFeeToken.forceApprove(address(interfold), fee);

            // send the request to Interfold
            (uint256 e3Id,) = interfold.request(requestParams);

            /// @notice Store the data
            proposal.tally.counts = new uint256[](numOptions);
            proposal.parameters = ProposalParameters({
                numOptions: numOptions,
                startDate: _startDate,
                endDate: _endDate,
                // Snapshot one tick before now, so voting power is read from a finalized
                // timepoint. This is `_tokenClock()`, NOT `block.number`: the units must be
                // the voting token's ERC-6372 clock or every `getPastVotes` /
                // `getPastTotalSupply` read against this value is meaningless.
                snapshotBlock: _tokenClock() - 1,
                minVotingPower: votingSettings.minProposerVotingPower,
                minParticipation: votingSettings.minParticipation,
                creditMode: ICRISP.CreditMode(creditMode)
            });
            proposal.allowFailureMap = _allowFailureMap;
            proposal.targetConfig = getTargetConfig();
            proposal.e3Id = e3Id;
        }

        for (uint256 i = 0; i < _actions.length;) {
            proposal.actions.push(_actions[i]);
            unchecked {
                ++i;
            }
        }

        emit ProposalCreated(
            proposalId, _msgSender(), _startDate, _endDate, _metadata, _actions, proposal.allowFailureMap
        );
    }

    /// @inheritdoc IProposal
    function execute(uint256 _proposalId) external {
        if (!_proposalExists(_proposalId)) {
            revert NonexistentProposal(_proposalId);
        }

        Proposal storage proposal = proposals[_proposalId];

        // signaling-only proposals (polls) cannot be executed
        if (_isSignalingOnly(proposal.parameters)) {
            revert ProposalNotExecutable(_proposalId);
        }

        // the voting window must have closed before a proposal can be executed
        if (block.timestamp < proposal.parameters.endDate) {
            revert ProposalExecutionForbidden(_proposalId);
        }

        uint256[] memory tallyCounts = ICRISP(crispProgramAddress).decodeTally(proposal.e3Id);

        // check if we can execute it using the freshly decoded tally
        if (!_canExecute(_proposalId, tallyCounts)) {
            revert ProposalExecutionForbidden(_proposalId);
        }

        /// @notice store the final tally
        proposal.tally.counts = tallyCounts;

        /// @notice we set the proposal as executed so it cannot be executed again
        proposal.executed = true;

        // just execute it
        _execute(
            proposal.targetConfig.target,
            bytes32(_proposalId),
            proposal.actions,
            proposal.allowFailureMap,
            proposal.targetConfig.operation
        );

        emit ProposalExecuted(_proposalId);
    }

    /// @notice Returns whether the proposal has succeeded or not.
    /// @dev A proposal has succeeded if it has already been executed or if it currently meets the
    /// execution criteria (quorum and the winning-option rules). This is independent of whether the
    /// proposal has actually been executed.
    /// @param _proposalId The id of the proposal.
    /// @return Whether the proposal has succeeded or not.
    function hasSucceeded(uint256 _proposalId) external view returns (bool) {
        if (!_proposalExists(_proposalId)) {
            revert NonexistentProposal(_proposalId);
        }

        if (proposals[_proposalId].executed) {
            return true;
        }

        return _canExecute(_proposalId);
    }

    /// @notice Returns the proposal data for a given proposal ID.
    /// @param _proposalId The ID of the proposal to retrieve.
    /// @return proposal_ The proposal data including execution status, parameters, tally results,
    /// actions, and other metadata.
    function getProposal(uint256 _proposalId) external view returns (Proposal memory proposal_) {
        proposal_ = proposals[_proposalId];
    }

    /// @notice Checks if this or the parent contract supports an interface by its ID.
    /// @param _interfaceId The ID of the interface.
    /// @return Returns `true` if the interface is supported.
    function supportsInterface(bytes4 _interfaceId)
        public
        view
        override(PluginUUPSUpgradeable, ProposalUpgradeable)
        returns (bool)
    {
        return _interfaceId == CRISP_VOTING_INTERFACE_ID || super.supportsInterface(_interfaceId);
    }

    /// @inheritdoc ICrispVoting
    function getVotingToken() public view returns (IVotesUpgradeable) {
        return votingToken;
    }

    /// @inheritdoc ICrispVoting
    function minParticipation() public view returns (uint32) {
        return votingSettings.minParticipation;
    }

    /// @inheritdoc ICrispVoting
    function minDuration() public view returns (uint64) {
        return votingSettings.minDuration;
    }

    /// @inheritdoc ICrispVoting
    function minProposerVotingPower() public view returns (uint256) {
        return votingSettings.minProposerVotingPower;
    }

    /// @inheritdoc ICrispVoting
    function totalVotingPower(uint256 _blockNumber) public view returns (uint256) {
        return votingToken.getPastTotalSupply(_blockNumber);
    }

    /// @inheritdoc IProposal
    function canExecute(uint256 _proposalId) public view returns (bool) {
        if (!_proposalExists(_proposalId)) {
            revert NonexistentProposal(_proposalId);
        }

        return _canExecute(_proposalId);
    }

    /// @notice Get the custom proposal parameters ABI.
    /// @dev Mirrors the `_data` payload decoded in `createProposal`.
    function customProposalParamsABI() external pure returns (string memory) {
        return "(uint256 allowFailureMap, uint256 numOptions, uint256 creditMode, uint256 credits)";
    }

    /// @notice Get the tally result
    /// @param _proposalId The id of the proposal
    /// @return The tally result
    function getTally(uint256 _proposalId) external view returns (TallyResults memory) {
        Proposal memory proposal = proposals[_proposalId];

        // if it's not executed then we wouldn't have saved the result
        if (!proposal.executed) {
            uint256[] memory counts = ICRISP(crispProgramAddress).decodeTally(proposal.e3Id);
            return TallyResults({counts: counts});
        }

        return proposals[_proposalId].tally;
    }

    /// @inheritdoc ICrispVoting
    function getWinningOption(uint256 _proposalId) external view returns (uint256) {
        uint256[] memory counts;

        if (proposals[_proposalId].executed) {
            counts = proposals[_proposalId].tally.counts;
        } else {
            counts = ICRISP(crispProgramAddress).decodeTally(proposals[_proposalId].e3Id);
        }

        uint256 maxCount = 0;
        uint256 winnerIndex = 0;

        for (uint256 i = 0; i < counts.length;) {
            if (counts[i] > maxCount) {
                maxCount = counts[i];
                winnerIndex = i;
            }
            unchecked {
                ++i;
            }
        }

        return winnerIndex;
    }

    /// @notice Validates and stores the voting settings.
    /// @dev `minParticipation` is a ratio expressed against `RATIO_BASE`, so it cannot exceed it.
    /// @param _votingSettings The voting settings to store.
    function _updateVotingSettings(VotingSettings memory _votingSettings) internal {
        if (_votingSettings.minParticipation > RATIO_BASE) {
            revert RatioOutOfBounds({limit: RATIO_BASE, actual: _votingSettings.minParticipation});
        }

        votingSettings = _votingSettings;

        emit VotingSettingsUpdated(
            _votingSettings.minProposerVotingPower, _votingSettings.minParticipation, _votingSettings.minDuration
        );
    }

    /// @inheritdoc ICrispVoting
    function quoteFee(uint64 _startDate, uint64 _endDate, bytes calldata _data)
        external
        view
        returns (uint256 fee)
    {
        (uint64 startDate, uint64 endDate) = _validateProposalDates(_startDate, _endDate);
        (, uint256 numOptions, uint256 creditMode, uint256 credits) =
            abi.decode(_data, (uint256, uint256, uint256, uint256));

        fee = interfold.getE3Quote(_buildRequestParams(startDate, endDate, numOptions, creditMode, credits));
    }

    /// @notice Builds the Interfold request for a proposal's parameters.
    /// @dev Shared by `createProposal` and `quoteFee` so a quote can never drift from the fee
    /// creation actually charges — a second copy of this encoding would be a silent way for the
    /// two to disagree.
    /// @param _startDate The validated proposal start date.
    /// @param _endDate The validated proposal end date.
    /// @param _numOptions The number of ballot options.
    /// @param _creditMode The `ICRISP.CreditMode` to run the round under.
    /// @param _credits The credits allocated per voter.
    function _buildRequestParams(
        uint64 _startDate,
        uint64 _endDate,
        uint256 _numOptions,
        uint256 _creditMode,
        uint256 _credits
    ) internal view returns (IInterfold.E3RequestParams memory) {
        if (_numOptions < 2) {
            revert InvalidOptionCount(_numOptions);
        }

        /// @notice The exact tuple `CRISPProgram.validate` decodes — all six fields are
        /// required, and it reverts on a short encoding.
        /// The census is always TOKEN: the electorate is whoever holds `votingToken` at the
        /// snapshot, which the coordinator enumerates. BY_REQUESTER would need this plugin to
        /// expose `getCensus(uint256) returns (address[])` — it has no membership roster to
        /// answer that with.
        bytes memory customParams = abi.encode(
            address(votingToken),
            votingSettings.minProposerVotingPower,
            _numOptions,
            ICRISP.CreditMode(_creditMode),
            _credits,
            ICRISP.CensusMode.TOKEN
        );

        return IInterfold.E3RequestParams({
            committeeSize: committeeSize,
            inputWindow: [uint256(_startDate), uint256(_endDate)],
            e3Program: IE3Program(crispProgramAddress),
            computeProviderParams: computeProviderParams,
            customParams: customParams,
            paramSet: paramSet
        });
    }

    /// @notice Validates and returns the proposal vote dates, enforcing the minimum duration.
    /// @param _start The start date of the proposal vote. If 0, the current timestamp is used
    /// and the vote starts immediately.
    /// @param _end The end date of the proposal vote. If 0, `_start + minDuration` is used.
    /// @return startDate The validated start date of the proposal vote.
    /// @return endDate The validated end date of the proposal vote.
    function _validateProposalDates(uint64 _start, uint64 _end)
        internal
        view
        returns (uint64 startDate, uint64 endDate)
    {
        // block.timestamp cannot exceed uint64 for ~580 billion years, so the cast is safe.
        uint64 currentTimestamp = uint64(block.timestamp);

        if (_start == 0) {
            startDate = currentTimestamp;
        } else {
            startDate = _start;

            // the vote cannot start in the past, otherwise the minimum duration is meaningless
            if (startDate < currentTimestamp) {
                revert DateOutOfBounds({limit: currentTimestamp, actual: startDate});
            }
        }

        // checked arithmetic: an absurdly large `minDuration` simply reverts here, and the caller
        // can pick another date. Bounding `minDuration` on update would tighten this further.
        uint64 earliestEndDate = startDate + votingSettings.minDuration;

        if (_end == 0) {
            endDate = earliestEndDate;
        } else {
            endDate = _end;

            if (endDate < earliestEndDate) {
                revert DateOutOfBounds({limit: earliestEndDate, actual: endDate});
            }
        }
    }

    /// @notice Internal checks to determine whether a proposal can be executed or not.
    /// @dev Fetches the tally from the CRISP program before delegating to the counts-based check.
    /// @param _proposalId The ID of the proposal to be checked
    /// @return Returns `true` if the proposal can be executed, otherwise false
    function _canExecute(uint256 _proposalId) internal view returns (bool) {
        uint256[] memory counts = ICRISP(crispProgramAddress).decodeTally(proposals[_proposalId].e3Id);
        return _canExecute(_proposalId, counts);
    }

    /// @notice Internal checks to determine whether a proposal can be executed or not, given an
    /// already-decoded tally. Avoids a redundant `decodeTally` call on the execution path.
    /// @param _proposalId The ID of the proposal to be checked
    /// @param counts The decoded tally counts for the proposal
    /// @return Returns `true` if the proposal can be executed, otherwise false
    function _canExecute(uint256 _proposalId, uint256[] memory counts) internal view returns (bool) {
        Proposal memory proposal = proposals[_proposalId];

        // can't execute twice
        if (proposal.executed) {
            return false;
        }

        // signaling-only proposals (polls) are never executable
        if (_isSignalingOnly(proposal.parameters)) {
            return false;
        }

        // Sum all votes for quorum check
        uint256 totalVotes = 0;
        for (uint256 i = 0; i < counts.length;) {
            totalVotes += counts[i];
            unchecked {
                ++i;
            }
        }

        // Check quorum: turnout (totalVotes) vs. minParticipation% of total voting power.
        // The tally is recorded in scaled vote units (each voter's power is divided by
        // `_voteScale()` before being submitted to CRISP so it fits the plaintext vote vector),
        // whereas `totalVotingPower` is the raw token supply. We therefore scale `totalVotes`
        // back up rather than dividing the supply down, which avoids any truncation:
        //   totalVotes * scale * RATIO_BASE >= minParticipation * totalSupply
        uint256 _totalVotingPower = totalVotingPower(proposal.parameters.snapshotBlock);
        if (_totalVotingPower == 0) {
            return false;
        }

        bool quorumReached =
            totalVotes * _voteScale() * RATIO_BASE >= uint256(votingSettings.minParticipation) * _totalVotingPower;
        if (!quorumReached) {
            return false;
        }

        // For 2-3 options: yes (index 0) must strictly beat no (index 1)
        return counts[0] > counts[1];
    }

    /// @notice The factor by which each voter's power is divided before being submitted to CRISP.
    /// @dev Vote weights must fit inside the CRISP plaintext vote vector, so the producer keeps ONE
    /// decimal of precision — `balance / 10 ** (decimals - 1)` — before encrypting. The recorded
    /// tally is therefore in those units, and the quorum check scales `totalVotes` back up by the
    /// same factor to compare like with like against the raw token supply.
    ///
    /// This MUST stay in sync with the producer. The authority is the CRISP SDK's `getScaledBalance`:
    ///     const precision = decimals > 1n ? decimals - 1n : 0n;
    ///     return balance / 10n ** precision;
    ///
    /// It previously returned `10 ** (decimals / 2)`, which for an 18-decimal token is 10**9 against
    /// the producer's 10**17 — understating turnout by 10**8, and so making any non-zero
    /// `minParticipation` effectively unreachable.
    ///
    /// `decimals()` is not part of `IVotesUpgradeable` and the setup accepts bare IVotes tokens, so a
    /// missing `decimals()` must not brick `hasSucceeded`/`canExecute`/`execute` after install: those
    /// tokens, and 0/1-decimal tokens, are treated as unscaled.
    /// @return The scaling factor applied to vote weights.
    function _voteScale() internal view returns (uint256) {
        try IERC20MetadataUpgradeable(address(votingToken)).decimals() returns (uint8 tokenDecimals) {
            return tokenDecimals > 1 ? 10 ** (uint256(tokenDecimals) - 1) : 1;
        } catch {
            return 1;
        }
    }

    /// @notice The current timepoint in the voting token's ERC-6372 clock units.
    /// @dev `snapshotBlock` is fed straight to `getPastVotes` / `getPastTotalSupply`, so it MUST be
    /// expressed in whatever clock the token keeps its checkpoints in. This previously recorded
    /// `block.number - 1`, which is only correct for the OZ default clock. Against a token with
    /// `CLOCK_MODE=timestamp` a block number is a timepoint decades in the past: the lookup does
    /// not revert, it returns 0 — so every holder reads as having no voting power, the whole DAO
    /// looks ineligible, and `_canExecute` bails on `_totalVotingPower == 0`, making every proposal
    /// permanently unexecutable.
    ///
    /// Tokens predating ERC-6372 have no `clock()`; the setup also accepts bare IVotes tokens. Both
    /// fall back to `block.number`, which is what OZ's own default `clock()` returns.
    /// @return The current timepoint, in the token's clock units.
    function _tokenClock() internal view returns (uint256) {
        try IERC6372Upgradeable(address(votingToken)).clock() returns (uint48 timepoint) {
            return timepoint;
        } catch {
            return block.number;
        }
    }

    /// @notice Whether a proposal is signaling-only (a poll) and therefore cannot be executed.
    /// @dev Only binary-style votes are executable: at most 3 options (yes/no/abstain) and CUSTOM
    /// credits (so the token-supply quorum denominator is meaningful). Proposals with more than 3
    /// options, or CONSTANT credits, are polls whose tally is informational only.
    /// @param _parameters The stored parameters of the proposal.
    /// @return Returns `true` if the proposal is signaling-only, otherwise false.
    function _isSignalingOnly(ProposalParameters memory _parameters) internal pure returns (bool) {
        return _parameters.numOptions > 3 || _parameters.creditMode == ICRISP.CreditMode.CONSTANT;
    }

    /// @notice Checks if proposal exists or not.
    /// @param _proposalId The ID of the proposal.
    /// @return Returns `true` if proposal exists, otherwise false.
    function _proposalExists(uint256 _proposalId) private view returns (bool) {
        return proposals[_proposalId].parameters.snapshotBlock != 0;
    }

    /// @notice This empty reserved space is put in place to allow future versions to add new variables
    ///         without shifting down storage in the inheritance chain
    ///         (see [OpenZeppelin's guide about storage gaps](https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps)).
    /// @notice Deposits fee-token credit for `msg.sender`, consumed by proposals they create.
    /// @dev Requires a prior ERC20 approval to this plugin.
    /// @param _amount The fee-token amount to deposit.
    function deposit(uint256 _amount) external {
        interfoldFeeToken.safeTransferFrom(_msgSender(), address(this), _amount);
        feeCredits[_msgSender()] += _amount;

        emit FeeDeposited(_msgSender(), _amount);
    }

    /// @notice Withdraws unused fee-token credit back to `msg.sender`.
    /// @param _amount The fee-token amount to withdraw.
    function withdraw(uint256 _amount) external {
        // checked arithmetic reverts on over-withdrawal
        feeCredits[_msgSender()] -= _amount;
        interfoldFeeToken.safeTransfer(_msgSender(), _amount);

        emit FeeWithdrawn(_msgSender(), _amount);
    }

    /// @notice Claims the requester refund for a proposal whose E3 failed, crediting it back to
    /// the recorded fee payer.
    /// @dev Permissionless: the refund manager only ever pays the requester (this plugin), and
    /// the credit always goes to the recorded payer — the caller gets nothing. The refund manager
    /// enforces that the E3 actually failed and that it is not double-claimed.
    /// @param _proposalId The id of the proposal whose E3 failed.
    /// @return amount The refunded fee-token amount.
    function claimRefund(uint256 _proposalId) external returns (uint256 amount) {
        if (!_proposalExists(_proposalId)) {
            revert NonexistentProposal(_proposalId);
        }

        uint256 e3Id = proposals[_proposalId].e3Id;
        address payer = proposalPayer[_proposalId];
        amount = IE3RefundManager(interfold.e3RefundManager()).claimRequesterRefund(e3Id);
        feeCredits[payer] += amount;

        emit RefundClaimed(_proposalId, e3Id, payer, amount);
    }

    /// @notice Resolves who pays for a proposal's E3.
    /// @dev Two shapes:
    ///   STAGED — the SPP calls this plugin, and passes `abi.encode(spp, sppProposalId, stageId)`
    ///            as metadata. The payer is the parent proposal's creator. Only treated as staged
    ///            when the caller IS the SPP it names, so a direct caller cannot forge 96-byte
    ///            metadata naming someone else's SPP proposal and spend THEIR credit.
    ///   DIRECT — the caller pays, and must meet `minProposerVotingPower`.
    /// @param _metadata The proposal metadata as supplied by the caller.
    /// @return payer The account whose escrowed credit funds the E3.
    function _resolvePayer(bytes memory _metadata) internal view returns (address payer) {
        if (_metadata.length == 96) {
            (address spp, uint256 sppProposalId,) = abi.decode(_metadata, (address, uint256, uint16));

            if (spp == _msgSender()) {
                payer = IStagedProposalProcessor(spp).getProposal(sppProposalId).creator;
                if (payer == address(0)) {
                    revert InvalidSppMetadata();
                }
                return payer;
            }
        }

        payer = _msgSender();

        uint256 _minProposerVotingPower = minProposerVotingPower();
        if (_minProposerVotingPower != 0) {
            if (votingToken.getVotes(payer) < _minProposerVotingPower) {
                revert ProposalCreationForbidden(payer);
            }
        }
    }

    /// @notice Debits the recorded payer's escrowed credit for the Interfold E3 fee.
    /// @param _proposalId The proposal whose payer was recorded by `createProposal`.
    /// @param _fee The Interfold E3 fee to charge.
    function _chargeFee(uint256 _proposalId, uint256 _fee) internal {
        address payer = proposalPayer[_proposalId];

        uint256 credit = feeCredits[payer];
        if (credit < _fee) {
            revert InsufficientFeeCredit(payer, _fee, credit);
        }

        unchecked {
            feeCredits[payer] = credit - _fee;
        }
    }

    /// @notice Escrowed fee-token credit per creator. Creators `deposit` before creating a
    /// proposal; `createProposal` debits the resolved payer's credit rather than pulling from
    /// the caller — the caller is the SPP in the staged shape, and it holds no tokens.
    mapping(address => uint256) public feeCredits;

    /// @notice The fee payer recorded for each proposal, used to route failed-E3 refunds back
    /// to whoever actually paid.
    mapping(uint256 => address) public proposalPayer;

    /// @dev Reduced from 49 to 47 to account for the two mappings appended above.
    uint256[47] private __gap;
}
