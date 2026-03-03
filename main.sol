// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title JupiterScan
/// @notice Cross-chain trend pulse scanner: submit momentum signals, aggregate confidence, claim scan rewards. Stay ahead of moves.

contract JupiterScan {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event PulseSubmitted(uint256 indexed pulseId, address indexed scanner, bytes32 trendHash, uint256 magnitude, uint256 slot);
    event PulseConfirmed(uint256 indexed pulseId, uint256 confidenceScore, uint256 confirmBlock);
    event PulseRejected(uint256 indexed pulseId, address indexed aggregator, bytes32 reasonCode);
    event RewardDistributed(address indexed recipient, uint256 amount, uint256 pulseId);
    event ScannerRegistered(address indexed scanner, uint256 stakeAmount, uint256 atBlock);
    event ScannerSlashed(address indexed scanner, uint256 amount, bytes32 reasonCode);
    event ThresholdUpdated(bytes32 key, uint256 oldVal, uint256 newVal);
    event FeeCollected(address indexed from, uint256 amount, uint256 pulseId);
    event RelayForwarded(address indexed relay, bytes32 payloadHash, uint256 atBlock);
    event EmergencyPauseToggled(bool paused, address indexed by);
    event SlotClosed(uint256 slotIndex, uint256 totalPulses, uint256 winningMagnitude);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error JS_Unauthorized();
    error JS_InvalidPulseId();
    error JS_InvalidMagnitude();
    error JS_InvalidSlot();
    error JS_SlotClosed();
    error JS_AlreadyConfirmed();
    error JS_AlreadyRejected();
    error JS_ConfidenceTooLow();
    error JS_StakeInsufficient();
    error JS_TransferFailed();
    error JS_Reentrancy();
    error JS_ZeroAddress();
    error JS_ZeroAmount();
    error JS_Paused();
    error JS_NotPaused();
    error JS_ClaimWindowClosed();
    error JS_NothingToClaim();
    error JS_DuplicateSubmission();
    error JS_ThresholdOutOfRange();
    error JS_RelayNotAllowed();
    error JS_PayloadTooLarge();
    error JS_ScannerBanned();
    error JS_CooldownActive();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant SCAN_SLOT_DURATION = 6471;
    uint256 public constant MAX_PULSE_MAGNITUDE = 1e18;
    uint256 public constant MIN_SCANNER_STAKE = 0.05 ether;
    uint256 public constant CONFIRMATION_THRESHOLD_BPS = 7500;
    uint256 public constant REWARD_CLAIM_BLOCKS = 4032;
    uint256 public constant COOLDOWN_BLOCKS = 12;
    uint256 public constant MAX_PAYLOAD_BYTES = 512;
    uint256 public constant PROTOCOL_VERSION = 304;
    bytes32 public constant JUPITER_DOMAIN_SEAL = keccak256("JupiterScan.trend.v304");
    bytes32 public constant SLOT_LABEL = keccak256("JupiterScan.slot");
    uint256 public constant REWARD_CAP_PER_PULSE = 0.01 ether;
    uint256 public constant MIN_CONFIDENCE_BPS = 5000;
    uint256 public constant MAX_SLOTS_OPEN = 128;
    uint256 public constant MAGNITUDE_DECIMALS = 18;
    uint256 public constant SCAN_EPOCH_LENGTH = 2016;
    bytes32 public constant TREND_CATEGORY_DEFI = keccak256("trend.defi");
    bytes32 public constant TREND_CATEGORY_NFT = keccak256("trend.nft");
    bytes32 public constant TREND_CATEGORY_MEME = keccak256("trend.meme");
    bytes32 public constant TREND_CATEGORY_GAMING = keccak256("trend.gaming");
    bytes32 public constant TREND_CATEGORY_OTHER = keccak256("trend.other");

    // -------------------------------------------------------------------------
    // IMMUTABLES
    // -------------------------------------------------------------------------

    address public immutable pulseOracle;
    address public immutable trendTreasury;
    address public immutable scanOperator;
    address public immutable relayHub;
    address public immutable fallbackReceiver;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    struct Pulse {
        address scanner;
        bytes32 trendHash;
        uint256 magnitude;
        uint256 slotIndex;
        uint256 submitBlock;
        bool confirmed;
        bool rejected;
        uint256 confidenceScore;
        uint256 confirmBlock;
    }

    struct SlotData {
        uint256 startBlock;
        uint256 endBlock;
        uint256 pulseCount;
        uint256 totalMagnitude;
        uint256 winningMagnitude;
        bool closed;
    }

    struct ScannerProfile {
        uint256 stake;
        uint256 totalPulses;
        uint256 confirmedPulses;
        uint256 lastSubmitBlock;
        bool banned;
        uint256 totalRewardsClaimed;
    }

    struct PulseMetadata {
