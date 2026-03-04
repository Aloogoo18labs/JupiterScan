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
        uint256 minConf = thresholdConfig[keccak256("min.confidence")];
        if (minConf != 0 && confidenceScore < minConf) revert JS_ConfidenceTooLow();

        p.confirmed = true;
        p.confidenceScore = confidenceScore;
        p.confirmBlock = block.number;

        ScannerProfile storage prof = scanners[p.scanner];
        prof.confirmedPulses++;

        emit PulseConfirmed(pulseId, confidenceScore, block.number);
    }

    function rejectPulse(uint256 pulseId, bytes32 reasonCode) external onlyOracle nonReentrant whenNotPaused {
        if (pulseId == 0 || pulseId > pulseCounter) revert JS_InvalidPulseId();
        Pulse storage p = pulses[pulseId];
        if (p.confirmed) revert JS_AlreadyConfirmed();
        if (p.rejected) revert JS_AlreadyRejected();

        p.rejected = true;
        emit PulseRejected(pulseId, msg.sender, reasonCode);
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: CLOSE SLOT (operator)
    // -------------------------------------------------------------------------

    function closeSlot(uint256 slotIndex) external onlyOperator nonReentrant whenNotPaused {
        SlotData storage s = slots[slotIndex];
        require(s.startBlock != 0, "slot not started");
        if (block.number <= s.endBlock) revert JS_InvalidSlot();
        if (s.closed) return;

        s.closed = true;
        uint256 snapIdx = slotCounter;
        trendSnapshots[snapIdx] = TrendSnapshot({
            slotIndex: slotIndex,
            totalMagnitudeInSlot: s.totalMagnitude,
            pulseCountInSlot: s.pulseCount,
            blockWhenClosed: block.number
        });
        slotToSnapshotIndex[slotIndex] = snapIdx;
        emit SlotClosed(slotIndex, s.pulseCount, s.winningMagnitude);
    }

    function ensureSlot(uint256 slotIndex) external onlyOperator {
        SlotData storage s = slots[slotIndex];
        if (s.startBlock != 0) return;
        if (slotIndex == 0) {
            s.startBlock = block.number;
            s.endBlock = block.number + SCAN_SLOT_DURATION;
        } else {
            SlotData storage prev = slots[slotIndex - 1];
            require(prev.endBlock != 0, "prev slot not set");
            s.startBlock = prev.endBlock + 1;
            s.endBlock = s.startBlock + SCAN_SLOT_DURATION;
        }
        slotCounter = slotIndex + 1;
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: CLAIM REWARD
    // -------------------------------------------------------------------------

    function claimReward(uint256 pulseId) external nonReentrant whenNotPaused {
        if (pulseId == 0 || pulseId > pulseCounter) revert JS_InvalidPulseId();
        Pulse storage p = pulses[pulseId];
        if (p.scanner != msg.sender) revert JS_Unauthorized();
        if (!p.confirmed) revert JS_ConfidenceTooLow();
        if (claimTracker[pulseId][msg.sender]) revert JS_NothingToClaim();

        uint256 confirmBlock = p.confirmBlock;
        uint256 claimWindow = thresholdConfig[keccak256("reward.claim.blocks")] != 0
            ? thresholdConfig[keccak256("reward.claim.blocks")]
            : REWARD_CLAIM_BLOCKS;
        if (block.number > confirmBlock + claimWindow) revert JS_ClaimWindowClosed();

        uint256 reward = _computeReward(pulseId);
        if (reward == 0) revert JS_NothingToClaim();

        claimTracker[pulseId][msg.sender] = true;
        pulseMetadata[pulseId].rewardClaimed = true;
        totalRewardsPaid += reward;
        scanners[msg.sender].totalRewardsClaimed += reward;

        (bool ok, ) = msg.sender.call{ value: reward }("");
        if (!ok) revert JS_TransferFailed();
        emit RewardDistributed(msg.sender, reward, pulseId);
    }

    function _computeReward(uint256 pulseId) internal view returns (uint256) {
        Pulse storage p = pulses[pulseId];
        uint256 mag = p.magnitude;
        uint256 conf = p.confidenceScore;
        if (conf < 5000) return 0;
        uint256 base = (mag * conf) / 10000;
        uint256 cap = 0.01 ether;
        return base > cap ? cap : base;
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: FEES (payable)
    // -------------------------------------------------------------------------

    function depositFee(uint256 pulseId) external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert JS_ZeroAmount();
        if (pulseId > pulseCounter) revert JS_InvalidPulseId();
        totalFeesCollected += msg.value;
        emit FeeCollected(msg.sender, msg.value, pulseId);
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: RELAY (allowed relays only)
    // -------------------------------------------------------------------------

    function forwardRelay(bytes calldata payload) external nonReentrant whenNotPaused {
        if (!allowedRelays[msg.sender]) revert JS_RelayNotAllowed();
        if (payload.length > MAX_PAYLOAD_BYTES) revert JS_PayloadTooLarge();
        bytes32 payloadHash = keccak256(payload);
        emit RelayForwarded(msg.sender, payloadHash, block.number);
    }

    function setRelayAllowed(address relay, bool allowed) external onlyOperator {
        if (relay == address(0)) revert JS_ZeroAddress();
        allowedRelays[relay] = allowed;
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: CONFIG (operator)
    // -------------------------------------------------------------------------

    function setThreshold(bytes32 key, uint256 value) external onlyOperator {
        uint256 oldVal = thresholdConfig[key];
        thresholdConfig[key] = value;
        emit ThresholdUpdated(key, oldVal, value);
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: SLASH / BAN (operator)
    // -------------------------------------------------------------------------

    function slashScanner(address scanner, uint256 amount, bytes32 reasonCode) external onlyOperator nonReentrant {
        if (scanner == address(0)) revert JS_ZeroAddress();
        ScannerProfile storage p = scanners[scanner];
        if (amount > p.stake) amount = p.stake;
        if (amount == 0) return;
        p.stake -= amount;
        (bool ok, ) = trendTreasury.call{ value: amount }("");
        if (!ok) revert JS_TransferFailed();
        emit ScannerSlashed(scanner, amount, reasonCode);
    }

    function setScannerBanned(address scanner, bool banned) external onlyOperator {
        if (scanner == address(0)) revert JS_ZeroAddress();
        scanners[scanner].banned = banned;
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: EMERGENCY
    // -------------------------------------------------------------------------

    function togglePause() external onlyOperator {
        emergencyPaused = !emergencyPaused;
        emit EmergencyPauseToggled(emergencyPaused, msg.sender);
    }

    function withdrawToTreasury(uint256 amount) external onlyOperator nonReentrant whenPaused {
        if (amount == 0) revert JS_ZeroAmount();
        uint256 balance = address(this).balance;
        if (amount > balance) amount = balance;
        (bool ok, ) = trendTreasury.call{ value: amount }("");
        if (!ok) revert JS_TransferFailed();
    }

    // -------------------------------------------------------------------------
    // VIEWS: PULSES
    // -------------------------------------------------------------------------

    function getPulse(uint256 pulseId) external view returns (
        address scanner_,
        bytes32 trendHash_,
        uint256 magnitude_,
        uint256 slotIndex_,
        uint256 submitBlock_,
        bool confirmed_,
        bool rejected_,
        uint256 confidenceScore_,
        uint256 confirmBlock_
    ) {
        if (pulseId == 0 || pulseId > pulseCounter) {
            return (address(0), bytes32(0), 0, 0, 0, false, false, 0, 0);
        }
        Pulse storage p = pulses[pulseId];
        return (
            p.scanner,
            p.trendHash,
            p.magnitude,
            p.slotIndex,
            p.submitBlock,
            p.confirmed,
            p.rejected,
            p.confidenceScore,
            p.confirmBlock
        );
    }

    function getPulseCount() external view returns (uint256) {
        return pulseCounter;
    }

    function isPulseConfirmed(uint256 pulseId) external view returns (bool) {
        if (pulseId == 0 || pulseId > pulseCounter) return false;
        return pulses[pulseId].confirmed;
    }

    function isPulseRejected(uint256 pulseId) external view returns (bool) {
        if (pulseId == 0 || pulseId > pulseCounter) return false;
        return pulses[pulseId].rejected;
    }

    function getRewardForPulse(uint256 pulseId) external view returns (uint256) {
        if (pulseId == 0 || pulseId > pulseCounter) return 0;
        Pulse storage p = pulses[pulseId];
        if (!p.confirmed || claimTracker[pulseId][p.scanner]) return 0;
        uint256 claimWindow = thresholdConfig[keccak256("reward.claim.blocks")] != 0
            ? thresholdConfig[keccak256("reward.claim.blocks")]
            : REWARD_CLAIM_BLOCKS;
        if (block.number > p.confirmBlock + claimWindow) return 0;
        return _computeReward(pulseId);
    }

    // -------------------------------------------------------------------------
    // VIEWS: SLOTS
    // -------------------------------------------------------------------------

    function getSlot(uint256 slotIndex) external view returns (
        uint256 startBlock_,
        uint256 endBlock_,
        uint256 pulseCount_,
        uint256 totalMagnitude_,
        uint256 winningMagnitude_,
        bool closed_
    ) {
        SlotData storage s = slots[slotIndex];
        return (
            s.startBlock,
            s.endBlock,
            s.pulseCount,
            s.totalMagnitude,
            s.winningMagnitude,
            s.closed
        );
    }

    function getCurrentSlotIndex() external view returns (uint256) {
        if (slotCounter == 0) return 0;
        SlotData storage last = slots[slotCounter - 1];
        if (block.number <= last.endBlock) return slotCounter - 1;
        return slotCounter;
    }

    function getSlotBounds(uint256 slotIndex) external view returns (uint256 startBlock, uint256 endBlock, bool closed) {
        return _getSlotBounds(slotIndex);
    }

    // -------------------------------------------------------------------------
    // VIEWS: SCANNERS
    // -------------------------------------------------------------------------

    function getScanner(address scanner) external view returns (
        uint256 stake_,
        uint256 totalPulses_,
        uint256 confirmedPulses_,
        uint256 lastSubmitBlock_,
        bool banned_,
        uint256 totalRewardsClaimed_
    ) {
        ScannerProfile storage p = scanners[scanner];
        return (
            p.stake,
            p.totalPulses,
            p.confirmedPulses,
            p.lastSubmitBlock,
            p.banned,
            p.totalRewardsClaimed
        );
    }

    function canSubmit(address scanner, uint256 slotIndex) external view returns (bool) {
        ScannerProfile storage p = scanners[scanner];
        if (p.stake < MIN_SCANNER_STAKE || p.banned) return false;
        if (scannerPulseInSlot[scanner][slotIndex]) return false;
        (uint256 startBlock, uint256 endBlock, bool closed) = _getSlotBounds(slotIndex);
        if (closed || block.number < startBlock || block.number > endBlock) return false;
        if (block.number <= p.lastSubmitBlock + COOLDOWN_BLOCKS) return false;
        return true;
    }

    function hasClaimed(uint256 pulseId, address account) external view returns (bool) {
        return claimTracker[pulseId][account];
    }

    // -------------------------------------------------------------------------
    // VIEWS: CONFIG & GLOBAL
    // -------------------------------------------------------------------------

    function getThreshold(bytes32 key) external view returns (uint256) {
        return thresholdConfig[key];
    }

    function getDomainSeal() external pure returns (bytes32) {
        return JUPITER_DOMAIN_SEAL;
    }

    function getProtocolVersion() external pure returns (uint256) {
        return PROTOCOL_VERSION;
    }

    function getSlotLabel() external pure returns (bytes32) {
        return SLOT_LABEL;
    }

    function getTotalFeesCollected() external view returns (uint256) {
        return totalFeesCollected;
    }

    function getTotalRewardsPaid() external view returns (uint256) {
        return totalRewardsPaid;
    }

    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getOracle() external view returns (address) {
        return pulseOracle;
    }

    function getTrendTreasury() external view returns (address) {
        return trendTreasury;
    }

    function getScanOperator() external view returns (address) {
        return scanOperator;
    }

    function getRelayHub() external view returns (address) {
        return relayHub;
    }

    function getFallbackReceiver() external view returns (address) {
        return fallbackReceiver;
    }

    function isRelayAllowed(address relay) external view returns (bool) {
        return allowedRelays[relay];
    }

    function isPaused() external view returns (bool) {
        return emergencyPaused;
    }

    // -------------------------------------------------------------------------
    // BATCH / AGGREGATE VIEWS
    // -------------------------------------------------------------------------

    function getPulseIdsInRange(uint256 fromId, uint256 toId) external view returns (uint256[] memory ids) {
        if (fromId > toId || toId > pulseCounter) return new uint256[](0);
        uint256 len = toId - fromId + 1;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            ids[i] = fromId + i;
        }
    }

    function getConfirmedPulseCount() external view returns (uint256 count) {
        for (uint256 i = 1; i <= pulseCounter; i++) {
            if (pulses[i].confirmed) count++;
        }
    }

    function getRejectedPulseCount() external view returns (uint256 count) {
        for (uint256 i = 1; i <= pulseCounter; i++) {
            if (pulses[i].rejected) count++;
        }
    }

    function getSlotPulseCount(uint256 slotIndex) external view returns (uint256) {
        return slots[slotIndex].pulseCount;
    }

    function getScannerConfirmationRate(address scanner) external view returns (uint256 rateBps) {
        ScannerProfile storage p = scanners[scanner];
        if (p.totalPulses == 0) return 0;
        return (p.confirmedPulses * 10000) / p.totalPulses;
    }

    function getSnapshot() external view returns (
        uint256 pulseCount_,
        uint256 slotCount_,
        uint256 totalFees_,
        uint256 totalRewards_,
        uint256 balance_,
        bool paused_
    ) {
        return (
            pulseCounter,
            slotCounter,
            totalFeesCollected,
            totalRewardsPaid,
            address(this).balance,
            emergencyPaused
        );
    }

    // -------------------------------------------------------------------------
    // INTERNAL HELPERS
    // -------------------------------------------------------------------------

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _safeRewardCap(uint256 rawReward) internal pure returns (uint256) {
        return rawReward > REWARD_CAP_PER_PULSE ? REWARD_CAP_PER_PULSE : rawReward;
    }

    function _isSlotActive(uint256 slotIndex) internal view returns (bool) {
        SlotData storage s = slots[slotIndex];
        if (s.startBlock == 0 || s.closed) return false;
        return block.number >= s.startBlock && block.number <= s.endBlock;
    }

    function _blocksRemainingInSlot(uint256 slotIndex) internal view returns (uint256) {
        SlotData storage s = slots[slotIndex];
        if (s.endBlock == 0 || block.number >= s.endBlock) return 0;
        return s.endBlock - block.number;
    }

    function _magnitudeToTier(uint256 magnitude) internal pure returns (uint256) {
        if (magnitude >= 1e17) return 3;
        if (magnitude >= 1e16) return 2;
        return 1;
    }

    // -------------------------------------------------------------------------
    // EXTENDED VIEWS: PULSE METADATA & CATEGORIES
    // -------------------------------------------------------------------------

    function getPulseMetadata(uint256 pulseId) external view returns (
        bytes32 categoryHash_,
        uint256 submittedAtBlock_,
        uint256 magnitudeTier_,
        bool rewardClaimed_
    ) {
        if (pulseId == 0 || pulseId > pulseCounter) {
            return (bytes32(0), 0, 0, false);
        }
        PulseMetadata storage m = pulseMetadata[pulseId];
        return (m.categoryHash, m.submittedAtBlock, m.magnitudeTier, m.rewardClaimed);
    }

    function getTrendSnapshot(uint256 snapshotIndex) external view returns (
        uint256 slotIndex_,
        uint256 totalMagnitudeInSlot_,
        uint256 pulseCountInSlot_,
        uint256 blockWhenClosed_
    ) {
        TrendSnapshot storage t = trendSnapshots[snapshotIndex];
        return (
            t.slotIndex,
            t.totalMagnitudeInSlot,
            t.pulseCountInSlot,
            t.blockWhenClosed
        );
    }

    function getCategoryPulseCount(bytes32 categoryHash) external view returns (uint256) {
        return categoryPulseCount[categoryHash];
    }

    function getScannerPulseIds(address scanner, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256[] storage arr = scannerPulseIds[scanner];
        uint256 len = arr.length;
        if (offset >= len) return new uint256[](0);
        uint256 take = _min(limit, len - offset);
        ids = new uint256[](take);
        for (uint256 i = 0; i < take; i++) {
            ids[i] = arr[offset + i];
        }
    }

    function getScannerPulseCount(address scanner) external view returns (uint256) {
        return scannerPulseIds[scanner].length;
    }

    function getSlotSnapshotIndex(uint256 slotIndex) external view returns (uint256) {
        return slotToSnapshotIndex[slotIndex];
    }

    // -------------------------------------------------------------------------
    // ANALYTICS VIEWS
    // -------------------------------------------------------------------------

    function getTotalMagnitudeBySlot(uint256 slotIndex) external view returns (uint256) {
        return slots[slotIndex].totalMagnitude;
    }

    function getWinningMagnitudeBySlot(uint256 slotIndex) external view returns (uint256) {
        return slots[slotIndex].winningMagnitude;
    }

    function getOpenSlotsCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < slotCounter; i++) {
            if (_isSlotActive(i)) count++;
        }
    }

    function getClosedSlotsCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < slotCounter; i++) {
            if (slots[i].closed) count++;
        }
    }

    function getPulsesInSlot(uint256 slotIndex, uint256 maxCount) external view returns (uint256[] memory pulseIds) {
        uint256[] memory all = new uint256[](pulseCounter);
        uint256 found = 0;
        for (uint256 i = 1; i <= pulseCounter && found < maxCount; i++) {
            if (pulses[i].slotIndex == slotIndex) {
                all[found] = i;
                found++;
            }
        }
        pulseIds = new uint256[](found);
        for (uint256 j = 0; j < found; j++) {
            pulseIds[j] = all[j];
        }
    }

    function getAverageConfidence() external view returns (uint256 sum, uint256 count) {
        for (uint256 i = 1; i <= pulseCounter; i++) {
            if (pulses[i].confirmed) {
                sum += pulses[i].confidenceScore;
                count++;
            }
        }
    }

    function getAverageMagnitude() external view returns (uint256 sum, uint256 count) {
        for (uint256 i = 1; i <= pulseCounter; i++) {
            sum += pulses[i].magnitude;
            count++;
        }
    }

    function getConfirmationRateBps() external view returns (uint256) {
        if (pulseCounter == 0) return 0;
        uint256 confirmed = 0;
        for (uint256 i = 1; i <= pulseCounter; i++) {
            if (pulses[i].confirmed) confirmed++;
        }
        return (confirmed * 10000) / pulseCounter;
    }

    function getRejectionRateBps() external view returns (uint256) {
        if (pulseCounter == 0) return 0;
        uint256 rejected = 0;
        for (uint256 i = 1; i <= pulseCounter; i++) {
            if (pulses[i].rejected) rejected++;
        }
        return (rejected * 10000) / pulseCounter;
    }

    function getPendingPulseCount() external view returns (uint256 count) {
        for (uint256 i = 1; i <= pulseCounter; i++) {
            if (!pulses[i].confirmed && !pulses[i].rejected) count++;
        }
    }

    function getClaimableRewardTotal(address scanner) external view returns (uint256 total) {
        uint256[] storage ids = scannerPulseIds[scanner];
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (pulses[id].scanner != scanner || !pulses[id].confirmed || claimTracker[id][scanner]) continue;
            uint256 claimWindow = thresholdConfig[keccak256("reward.claim.blocks")] != 0
                ? thresholdConfig[keccak256("reward.claim.blocks")]
                : REWARD_CLAIM_BLOCKS;
            if (block.number <= pulses[id].confirmBlock + claimWindow) {
                total += _computeReward(id);
            }
        }
    }

    function getScannerRankByConfirmed(address scanner) external view returns (uint256 rank, uint256 totalScanners) {
        uint256 myConfirmed = scanners[scanner].confirmedPulses;
        uint256 above = 0;
        totalScanners = 0;
        return (above, totalScanners);
    }

    function isSlotClosed(uint256 slotIndex) external view returns (bool) {
        return slots[slotIndex].closed;
    }

    function blocksUntilSlotEnd(uint256 slotIndex) external view returns (uint256) {
        return _blocksRemainingInSlot(slotIndex);
    }

    function getPulseIdsPaginated(uint256 page, uint256 pageSize) external view returns (uint256[] memory ids) {
        uint256 start = page * pageSize;
        if (start >= pulseCounter) return new uint256[](0);
        uint256 end = start + pageSize;
        if (end > pulseCounter) end = pulseCounter;
        uint256 len = end - start;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            ids[i] = start + i + 1;
        }
    }

    function getRecentPulseIds(uint256 count) external view returns (uint256[] memory ids) {
        if (pulseCounter == 0) return new uint256[](0);
        uint256 take = _min(count, pulseCounter);
        ids = new uint256[](take);
        for (uint256 i = 0; i < take; i++) {
            ids[i] = pulseCounter - i;
        }
    }

    function getPulseSummary(uint256 pulseId) external view returns (
        address scanner_,
        uint256 magnitude_,
        uint256 slotIndex_,
        bool confirmed_,
        bool rejected_,
        uint256 rewardAmount_
    ) {
        if (pulseId == 0 || pulseId > pulseCounter) {
            return (address(0), 0, 0, false, false, 0);
        }
        Pulse storage p = pulses[pulseId];
        uint256 rewardAmount_ = 0;
        if (p.confirmed && !claimTracker[pulseId][p.scanner]) {
            uint256 claimWindow = thresholdConfig[keccak256("reward.claim.blocks")] != 0
                ? thresholdConfig[keccak256("reward.claim.blocks")]
                : REWARD_CLAIM_BLOCKS;
            if (block.number <= p.confirmBlock + claimWindow) rewardAmount_ = _computeReward(pulseId);
        }
        return (
            p.scanner,
            p.magnitude,
            p.slotIndex,
            p.confirmed,
            p.rejected,
            rewardAmount_
        );
    }

    function getSlotSummary(uint256 slotIndex) external view returns (
        uint256 startBlock_,
        uint256 endBlock_,
        uint256 pulseCount_,
        uint256 totalMagnitude_,
        uint256 winningMagnitude_,
        bool closed_,
        uint256 blocksRemaining_
    ) {
        SlotData storage s = slots[slotIndex];
        blocksRemaining_ = _blocksRemainingInSlot(slotIndex);
        return (
            s.startBlock,
            s.endBlock,
            s.pulseCount,
            s.totalMagnitude,
            s.winningMagnitude,
            s.closed,
            blocksRemaining_
        );
    }

    function getGlobalStats() external view returns (
        uint256 totalPulses_,
        uint256 confirmedPulses_,
        uint256 rejectedPulses_,
        uint256 pendingPulses_,
        uint256 totalSlots_,
        uint256 totalFees_,
        uint256 totalRewards_
    ) {
        uint256 conf = 0;
        uint256 rej = 0;
        for (uint256 i = 1; i <= pulseCounter; i++) {
            if (pulses[i].confirmed) conf++;
            else if (pulses[i].rejected) rej++;
        }
        return (
            pulseCounter,
            conf,
            rej,
            pulseCounter - conf - rej,
            slotCounter,
            totalFeesCollected,
            totalRewardsPaid
        );
    }

    function getConstants() external pure returns (
        uint256 scanSlotDuration_,
        uint256 maxPulseMagnitude_,
        uint256 minScannerStake_,
        uint256 confirmationThresholdBps_,
        uint256 rewardClaimBlocks_,
        uint256 cooldownBlocks_,
        uint256 maxPayloadBytes_,
        uint256 protocolVersion_
    ) {
        return (
            SCAN_SLOT_DURATION,
            MAX_PULSE_MAGNITUDE,
            MIN_SCANNER_STAKE,
            CONFIRMATION_THRESHOLD_BPS,
            REWARD_CLAIM_BLOCKS,
            COOLDOWN_BLOCKS,
            MAX_PAYLOAD_BYTES,
            PROTOCOL_VERSION
        );
    }

    function getImmutableAddresses() external view returns (
        address pulseOracle_,
        address trendTreasury_,
        address scanOperator_,
        address relayHub_,
        address fallbackReceiver_
    ) {
        return (pulseOracle, trendTreasury, scanOperator, relayHub, fallbackReceiver);
    }

    function supportsPulse(uint256 pulseId) external pure returns (bool) {
        return pulseId > 0;
    }

    function getMagnitudeTier(uint256 magnitude) external pure returns (uint256) {
        return _magnitudeToTier(magnitude);
    }

    function getRewardCap() external pure returns (uint256) {
        return REWARD_CAP_PER_PULSE;
    }

    function getMinConfidenceBps() external pure returns (uint256) {
        return MIN_CONFIDENCE_BPS;
    }

    function getTrendCategoryDefi() external pure returns (bytes32) {
        return TREND_CATEGORY_DEFI;
    }

    function getTrendCategoryNft() external pure returns (bytes32) {
        return TREND_CATEGORY_NFT;
    }

    function getTrendCategoryMeme() external pure returns (bytes32) {
        return TREND_CATEGORY_MEME;
    }

    function getTrendCategoryGaming() external pure returns (bytes32) {
        return TREND_CATEGORY_GAMING;
    }

    function getTrendCategoryOther() external pure returns (bytes32) {
        return TREND_CATEGORY_OTHER;
    }

    function getMaxSlotsOpen() external pure returns (uint256) {
        return MAX_SLOTS_OPEN;
    }

    function getScanEpochLength() external pure returns (uint256) {
        return SCAN_EPOCH_LENGTH;
    }

    function getMagnitudeDecimals() external pure returns (uint256) {
        return MAGNITUDE_DECIMALS;
    }

    // -------------------------------------------------------------------------
    // BATCH GETTERS FOR UI
    // -------------------------------------------------------------------------

    function getPulsesBatch(uint256[] calldata pulseIds) external view returns (
        address[] memory scanners_,
        bytes32[] memory trendHashes_,
        uint256[] memory magnitudes_,
        uint256[] memory slotIndices_,
        bool[] memory confirmed_,
        bool[] memory rejected_,
        uint256[] memory confidenceScores_
    ) {
        uint256 len = pulseIds.length;
        scanners_ = new address[](len);
        trendHashes_ = new bytes32[](len);
        magnitudes_ = new uint256[](len);
        slotIndices_ = new uint256[](len);
        confirmed_ = new bool[](len);
        rejected_ = new bool[](len);
        confidenceScores_ = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 id = pulseIds[i];
            if (id > 0 && id <= pulseCounter) {
                Pulse storage p = pulses[id];
                scanners_[i] = p.scanner;
                trendHashes_[i] = p.trendHash;
                magnitudes_[i] = p.magnitude;
                slotIndices_[i] = p.slotIndex;
                confirmed_[i] = p.confirmed;
                rejected_[i] = p.rejected;
                confidenceScores_[i] = p.confidenceScore;
            }
        }
    }

    function getSlotsBatch(uint256[] calldata slotIndices) external view returns (
        uint256[] memory startBlocks_,
        uint256[] memory endBlocks_,
        uint256[] memory pulseCounts_,
        uint256[] memory totalMagnitudes_,
        uint256[] memory winningMagnitudes_,
        bool[] memory closed_
    ) {
        uint256 len = slotIndices.length;
        startBlocks_ = new uint256[](len);
        endBlocks_ = new uint256[](len);
        pulseCounts_ = new uint256[](len);
        totalMagnitudes_ = new uint256[](len);
        winningMagnitudes_ = new uint256[](len);
        closed_ = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 idx = slotIndices[i];
            SlotData storage s = slots[idx];
            startBlocks_[i] = s.startBlock;
            endBlocks_[i] = s.endBlock;
            pulseCounts_[i] = s.pulseCount;
            totalMagnitudes_[i] = s.totalMagnitude;
            winningMagnitudes_[i] = s.winningMagnitude;
            closed_[i] = s.closed;
        }
    }

    function getClaimStatusBatch(uint256[] calldata pulseIds, address account) external view returns (bool[] memory claimed_) {
        uint256 len = pulseIds.length;
        claimed_ = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            claimed_[i] = claimTracker[pulseIds[i]][account];
        }
    }

    function getRewardsForPulses(uint256[] calldata pulseIds) external view returns (uint256[] memory rewards_) {
        uint256 len = pulseIds.length;
        rewards_ = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 id = pulseIds[i];
            if (id > 0 && id <= pulseCounter) {
                Pulse storage p = pulses[id];
                if (p.confirmed && !claimTracker[id][p.scanner]) {
                    uint256 claimWindow = thresholdConfig[keccak256("reward.claim.blocks")] != 0
                        ? thresholdConfig[keccak256("reward.claim.blocks")]
                        : REWARD_CLAIM_BLOCKS;
                    if (block.number <= p.confirmBlock + claimWindow) {
                        rewards_[i] = _computeReward(id);
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // SUBMIT PULSE WITH CATEGORY
    // -------------------------------------------------------------------------

    function submitPulseWithCategory(bytes32 trendHash, uint256 magnitude, uint256 slotIndex, bytes32 categoryHash) external nonReentrant whenNotPaused {
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
        uint256 tier = _magnitudeToTier(magnitude);
        pulseMetadata[id] = PulseMetadata({
            categoryHash: categoryHash,
            submittedAtBlock: block.number,
            magnitudeTier: tier,
            rewardClaimed: false
