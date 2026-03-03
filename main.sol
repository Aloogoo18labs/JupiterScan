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
        bytes32 categoryHash;
        uint256 submittedAtBlock;
        uint256 magnitudeTier;
        bool rewardClaimed;
    }

    struct TrendSnapshot {
        uint256 slotIndex;
        uint256 totalMagnitudeInSlot;
        uint256 pulseCountInSlot;
        uint256 blockWhenClosed;
    }

    uint256 private _guard;
    uint256 public pulseCounter;
    uint256 public slotCounter;
    uint256 public totalFeesCollected;
    uint256 public totalRewardsPaid;
    bool public emergencyPaused;

    mapping(uint256 => Pulse) public pulses;
    mapping(uint256 => SlotData) public slots;
    mapping(address => ScannerProfile) public scanners;
    mapping(address => mapping(uint256 => bool)) public scannerPulseInSlot;
    mapping(bytes32 => uint256) public thresholdConfig;
    mapping(address => bool) public allowedRelays;
    mapping(uint256 => mapping(address => bool)) public claimTracker;
    mapping(uint256 => PulseMetadata) public pulseMetadata;
    mapping(uint256 => TrendSnapshot) public trendSnapshots;
    mapping(bytes32 => uint256) public categoryPulseCount;
    mapping(address => uint256[]) public scannerPulseIds;
    mapping(uint256 => uint256) public slotToSnapshotIndex;

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyOracle() {
        if (msg.sender != pulseOracle) revert JS_Unauthorized();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != scanOperator) revert JS_Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (_guard != 0) revert JS_Reentrancy();
        _guard = 1;
        _;
        _guard = 0;
    }

    modifier whenNotPaused() {
        if (emergencyPaused) revert JS_Paused();
        _;
    }

    modifier whenPaused() {
        if (!emergencyPaused) revert JS_NotPaused();
        _;
    }

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        pulseOracle = 0x8E3c7A1f4B6d9e2C5a8F1b4D7e0A3c6B9d2E5f8a1;
        trendTreasury = 0x1F4b7C0e3A6d9f2B5a8E1c4D7f0A3b6C9e2D5f8aB;
        scanOperator = 0xA2d5F8b1C4e7D0a3F6b9C2e5D8f1A4c7B0d3E6f9;
        relayHub = 0x5E8a1C4d7F0b3E6a9D2f5B8c1E4a7D0b3F6c9E2;
        fallbackReceiver = 0xB3f6C9e2D5a8F1b4E7c0A3d6F9b2C5e8A1d4F7;
        _initThresholds();
    }

    function _initThresholds() internal {
        thresholdConfig[keccak256("min.confidence")] = 5000;
        thresholdConfig[keccak256("max.magnitude")] = MAX_PULSE_MAGNITUDE;
        thresholdConfig[keccak256("slot.duration")] = SCAN_SLOT_DURATION;
        thresholdConfig[keccak256("reward.claim.blocks")] = REWARD_CLAIM_BLOCKS;
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: REGISTER SCANNER (stake)
    // -------------------------------------------------------------------------

    function registerScanner() external payable nonReentrant whenNotPaused {
        if (msg.value < MIN_SCANNER_STAKE) revert JS_StakeInsufficient();
        ScannerProfile storage p = scanners[msg.sender];
        if (p.stake != 0) {
            p.stake += msg.value;
        } else {
            p.stake = msg.value;
            p.totalPulses = 0;
            p.confirmedPulses = 0;
            p.lastSubmitBlock = 0;
            p.banned = false;
            p.totalRewardsClaimed = 0;
        }
        emit ScannerRegistered(msg.sender, msg.value, block.number);
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: SUBMIT PULSE
    // -------------------------------------------------------------------------

    function submitPulse(bytes32 trendHash, uint256 magnitude, uint256 slotIndex) external nonReentrant whenNotPaused {
        if (magnitude == 0 || magnitude > MAX_PULSE_MAGNITUDE) revert JS_InvalidMagnitude();
        ScannerProfile storage prof = scanners[msg.sender];
        if (prof.stake < MIN_SCANNER_STAKE || prof.banned) revert JS_StakeInsufficient();
        if (block.number <= prof.lastSubmitBlock + COOLDOWN_BLOCKS) revert JS_CooldownActive();

        (uint256 startBlock, uint256 endBlock, bool closed) = _getSlotBounds(slotIndex);
        if (block.number < startBlock || block.number > endBlock) revert JS_InvalidSlot();
        if (closed) revert JS_SlotClosed();
        if (scannerPulseInSlot[msg.sender][slotIndex]) revert JS_DuplicateSubmission();

        pulseCounter++;
        uint256 id = pulseCounter;
        pulses[id] = Pulse({
            scanner: msg.sender,
            trendHash: trendHash,
            magnitude: magnitude,
            slotIndex: slotIndex,
            submitBlock: block.number,
            confirmed: false,
            rejected: false,
            confidenceScore: 0,
            confirmBlock: 0
        });

        SlotData storage s = slots[slotIndex];
        s.pulseCount++;
        s.totalMagnitude += magnitude;
        if (magnitude > s.winningMagnitude) s.winningMagnitude = magnitude;

        prof.totalPulses++;
        prof.lastSubmitBlock = block.number;
        scannerPulseInSlot[msg.sender][slotIndex] = true;

        uint256 tier = magnitude >= 1e17 ? 3 : (magnitude >= 1e16 ? 2 : 1);
        pulseMetadata[id] = PulseMetadata({
            categoryHash: keccak256("trend.other"),
            submittedAtBlock: block.number,
            magnitudeTier: tier,
            rewardClaimed: false
        });
        scannerPulseIds[msg.sender].push(id);
        categoryPulseCount[keccak256("trend.other")]++;

        emit PulseSubmitted(id, msg.sender, trendHash, magnitude, slotIndex);
    }

    function _getSlotBounds(uint256 slotIndex) internal view returns (uint256 startBlock, uint256 endBlock, bool closed) {
        SlotData storage s = slots[slotIndex];
        if (s.startBlock == 0) {
            if (slotIndex == 0) {
                startBlock = block.number;
                endBlock = block.number + SCAN_SLOT_DURATION;
            } else {
                SlotData storage prev = slots[slotIndex - 1];
                require(prev.endBlock != 0, "slot not initialized");
                startBlock = prev.endBlock + 1;
                endBlock = startBlock + SCAN_SLOT_DURATION;
            }
        } else {
            startBlock = s.startBlock;
            endBlock = s.endBlock;
            closed = s.closed;
        }
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: CONFIRM / REJECT (oracle)
    // -------------------------------------------------------------------------

    function confirmPulse(uint256 pulseId, uint256 confidenceScore) external onlyOracle nonReentrant whenNotPaused {
        if (pulseId == 0 || pulseId > pulseCounter) revert JS_InvalidPulseId();
        Pulse storage p = pulses[pulseId];
        if (p.confirmed) revert JS_AlreadyConfirmed();
        if (p.rejected) revert JS_AlreadyRejected();
