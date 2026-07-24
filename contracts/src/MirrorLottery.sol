// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {AccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IVrfCoordinatorV2Plus,
    VrfV2PlusClient
} from "./interfaces/IVrfCoordinatorV2Plus.sol";

/// @title Mirror Lottery
/// @notice Testnet-first lottery supporting Chainlink VRF and dual-attested
///         mirrored results. Every potentially large participant operation is
///         a bounded batch or a pull-based claim/refund.
/// @dev The contract is intentionally non-upgradeable. Mirrored draws carry a
///      different trust model from VRF draws and expose that state on-chain.
contract MirrorLottery is
    AccessControlDefaultAdminRules,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 500;
    uint8 public constant PICK_COUNT = 6;
    uint8 public constant MIN_MAX_NUMBER = 7;
    uint8 public constant MAX_MAX_NUMBER = 64;
    uint8 public constant MAX_BATCH_SIZE = 50;

    bytes32 public constant DRAW_MANAGER_ROLE = keccak256("DRAW_MANAGER_ROLE");
    bytes32 public constant RESULT_PUBLISHER_ROLE =
        keccak256("RESULT_PUBLISHER_ROLE");
    bytes32 public constant RESULT_VERIFIER_ROLE =
        keccak256("RESULT_VERIFIER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    enum DrawMode {
        VRF,
        MIRROR
    }

    enum DrawState {
        NONE,
        OPEN,
        AWAITING_VRF,
        MIRROR_PROPOSED,
        RESULT_READY,
        REGISTRATION,
        SETTLED,
        CLOSED,
        CANCELLED
    }

    struct VrfConfig {
        address coordinator;
        uint32 callbackGasLimit;
        uint16 requestConfirmations;
        uint256 subscriptionId;
        bytes32 keyHash;
    }

    struct TimingConfig {
        uint40 mirrorChallengePeriod;
        uint40 resultTimeout;
        uint40 registrationPeriod;
        uint40 claimPeriod;
    }

    struct RoleConfig {
        address admin;
        address drawManager;
        address resultPublisher;
        address resultVerifier;
        address guardian;
        address treasurer;
        address treasury;
    }

    struct DrawConfig {
        DrawMode mode;
        uint40 opensAt;
        uint40 closesAt;
        uint96 ticketPrice;
        uint8 maxNumber;
        uint16[5] tierBps;
        uint128 rolloverAmount;
    }

    struct Draw {
        DrawMode mode;
        DrawState state;
        uint40 opensAt;
        uint40 closesAt;
        uint40 resultProposedAt;
        uint40 resultConfirmedAt;
        uint40 registrationDeadline;
        uint40 claimDeadline;
        uint96 ticketPrice;
        uint8 maxNumber;
        uint16[5] tierBps;
        uint128 sales;
        uint128 sponsorPool;
        uint128 claimedPrize;
        uint128[5] prizePerWinner;
        uint32 ticketCount;
        uint32[5] winnerCount;
        uint32[5] claimedWinnerCount;
        uint256 requestId;
        uint256 randomWord;
        uint256 winningNumbers;
        bytes32 sourceHash;
        address proposedBy;
    }

    struct Ticket {
        address owner;
        uint64 drawId;
        uint8 tier;
        bool registered;
        bool claimed;
        bool refunded;
        uint256 packedNumbers;
    }

    error ZeroAddress();
    error InvalidConfiguration();
    error InvalidDraw(uint64 drawId);
    error InvalidTicket(uint64 ticketId);
    error InvalidState(DrawState expected, DrawState actual);
    error InvalidTime();
    error InvalidNumbers();
    error InvalidAmount();
    error BatchTooLarge();
    error DrawNotOpen();
    error ResultWindowExpired();
    error ResultMismatch();
    error SameAttestor();
    error ChallengePeriodActive();
    error RegistrationClosed();
    error ClaimWindowClosed();
    error NotTicketOwner();
    error AlreadyRegistered();
    error AlreadyClaimed();
    error AlreadyRefunded();
    error NotWinningTicket();
    error TransferAmountMismatch();
    error InsufficientRollover();
    error InsufficientFees();
    error OnlyCoordinator(address caller);
    error UnsupportedRecovery();

    event DrawCreated(
        uint64 indexed drawId,
        DrawMode indexed mode,
        uint40 opensAt,
        uint40 closesAt,
        uint96 ticketPrice,
        uint8 maxNumber,
        uint128 rolloverAmount
    );
    event DrawFunded(
        uint64 indexed drawId,
        address indexed funder,
        uint256 amount
    );
    event TicketPurchased(
        uint64 indexed drawId,
        uint64 indexed ticketId,
        address indexed owner,
        uint256 packedNumbers
    );
    event RandomnessRequested(
        uint64 indexed drawId,
        uint256 indexed requestId
    );
    event RandomnessReceived(
        uint64 indexed drawId,
        uint256 indexed requestId,
        uint256 randomWord
    );
    event RandomnessIgnored(uint256 indexed requestId);
    event MirrorResultProposed(
        uint64 indexed drawId,
        address indexed publisher,
        uint256 winningNumbers,
        bytes32 indexed sourceHash
    );
    event MirrorResultConfirmed(
        uint64 indexed drawId,
        address indexed verifier,
        bytes32 indexed sourceHash
    );
    event MirrorResultChallenged(
        uint64 indexed drawId,
        address indexed guardian,
        bytes32 indexed reasonHash
    );
    event RegistrationOpened(
        uint64 indexed drawId,
        uint256 winningNumbers,
        uint40 registrationDeadline
    );
    event TicketRegistered(
        uint64 indexed drawId,
        uint64 indexed ticketId,
        uint8 tier
    );
    event DrawSettled(
        uint64 indexed drawId,
        uint256 netPrizePool,
        uint256 protocolFee,
        uint256 rolloverAdded,
        uint40 claimDeadline
    );
    event PrizeClaimed(
        uint64 indexed drawId,
        uint64 indexed ticketId,
        address indexed recipient,
        uint256 amount
    );
    event DrawClosed(uint64 indexed drawId, uint256 rolloverAdded);
    event DrawCancelled(uint64 indexed drawId, uint256 rolloverAdded);
    event TicketRefunded(
        uint64 indexed drawId,
        uint64 indexed ticketId,
        address indexed recipient,
        uint256 amount
    );
    event ProtocolFeesWithdrawn(
        address indexed treasury,
        uint256 amount
    );
    event TreasuryUpdated(
        address indexed previousTreasury,
        address indexed newTreasury
    );

    IERC20 public immutable paymentToken;
    IVrfCoordinatorV2Plus public immutable vrfCoordinator;
    uint256 public immutable vrfSubscriptionId;
    bytes32 public immutable vrfKeyHash;
    uint32 public immutable vrfCallbackGasLimit;
    uint16 public immutable vrfRequestConfirmations;

    uint16 public immutable protocolFeeBps;
    uint40 public immutable mirrorChallengePeriod;
    uint40 public immutable resultTimeout;
    uint40 public immutable registrationPeriod;
    uint40 public immutable claimPeriod;

    address public treasury;
    uint64 public drawCount;
    uint64 public ticketCount;
    uint256 public rolloverPool;
    uint256 public protocolFeesAccrued;

    mapping(uint64 drawId => Draw draw) private s_draws;
    mapping(uint64 ticketId => Ticket ticket) private s_tickets;
    mapping(uint256 requestId => uint64 drawId) private s_requestToDraw;

    constructor(
        address paymentToken_,
        VrfConfig memory vrf_,
        TimingConfig memory timing_,
        uint16 protocolFeeBps_,
        uint48 adminTransferDelay_,
        RoleConfig memory roles_
    )
        AccessControlDefaultAdminRules(adminTransferDelay_, roles_.admin)
    {
        if (
            paymentToken_ == address(0)
                || vrf_.coordinator == address(0)
                || roles_.admin == address(0)
                || roles_.drawManager == address(0)
                || roles_.resultPublisher == address(0)
                || roles_.resultVerifier == address(0)
                || roles_.guardian == address(0)
                || roles_.treasurer == address(0)
                || roles_.treasury == address(0)
        ) {
            revert ZeroAddress();
        }
        if (
            paymentToken_.code.length == 0
                || vrf_.coordinator.code.length == 0
        ) {
            revert InvalidConfiguration();
        }
        if (
            vrf_.subscriptionId == 0
                || vrf_.keyHash == bytes32(0)
                || vrf_.callbackGasLimit < 100_000
                || vrf_.requestConfirmations < 3
                || vrf_.requestConfirmations > 200
                || protocolFeeBps_ > MAX_PROTOCOL_FEE_BPS
                || timing_.mirrorChallengePeriod == 0
                || timing_.resultTimeout
                    <= timing_.mirrorChallengePeriod
                || timing_.registrationPeriod == 0
                || timing_.claimPeriod == 0
        ) {
            revert InvalidConfiguration();
        }

        paymentToken = IERC20(paymentToken_);
        vrfCoordinator = IVrfCoordinatorV2Plus(vrf_.coordinator);
        vrfSubscriptionId = vrf_.subscriptionId;
        vrfKeyHash = vrf_.keyHash;
        vrfCallbackGasLimit = vrf_.callbackGasLimit;
        vrfRequestConfirmations = vrf_.requestConfirmations;

        protocolFeeBps = protocolFeeBps_;
        mirrorChallengePeriod = timing_.mirrorChallengePeriod;
        resultTimeout = timing_.resultTimeout;
        registrationPeriod = timing_.registrationPeriod;
        claimPeriod = timing_.claimPeriod;
        treasury = roles_.treasury;

        _grantRole(DRAW_MANAGER_ROLE, roles_.drawManager);
        _grantRole(RESULT_PUBLISHER_ROLE, roles_.resultPublisher);
        _grantRole(RESULT_VERIFIER_ROLE, roles_.resultVerifier);
        _grantRole(GUARDIAN_ROLE, roles_.guardian);
        _grantRole(TREASURER_ROLE, roles_.treasurer);
    }

    function createDraw(DrawConfig calldata config)
        external
        onlyRole(DRAW_MANAGER_ROLE)
        whenNotPaused
        returns (uint64 drawId)
    {
        if (
            config.ticketPrice == 0
                || config.maxNumber < MIN_MAX_NUMBER
                || config.maxNumber > MAX_MAX_NUMBER
                || config.closesAt <= config.opensAt
                || config.closesAt <= block.timestamp
        ) {
            revert InvalidConfiguration();
        }

        uint256 tierTotal;
        for (uint256 i; i < 5; ++i) {
            tierTotal += config.tierBps[i];
        }
        if (tierTotal != BPS_DENOMINATOR) {
            revert InvalidConfiguration();
        }
        if (config.rolloverAmount > rolloverPool) {
            revert InsufficientRollover();
        }

        unchecked {
            drawId = ++drawCount;
        }
        rolloverPool -= config.rolloverAmount;

        Draw storage draw = s_draws[drawId];
        draw.mode = config.mode;
        draw.state = DrawState.OPEN;
        draw.opensAt = config.opensAt;
        draw.closesAt = config.closesAt;
        draw.ticketPrice = config.ticketPrice;
        draw.maxNumber = config.maxNumber;
        draw.tierBps = config.tierBps;
        draw.sponsorPool = config.rolloverAmount;

        emit DrawCreated(
            drawId,
            config.mode,
            config.opensAt,
            config.closesAt,
            config.ticketPrice,
            config.maxNumber,
            config.rolloverAmount
        );
    }

    function fundDraw(uint64 drawId, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        Draw storage draw = _draw(drawId);
        if (
            draw.state != DrawState.OPEN
                || block.timestamp >= draw.closesAt
        ) {
            revert DrawNotOpen();
        }
        if (amount == 0) revert InvalidAmount();

        uint256 updatedPool = uint256(draw.sponsorPool) + amount;
        if (updatedPool > type(uint128).max) revert InvalidAmount();
        draw.sponsorPool = uint128(updatedPool);
        _pullExact(msg.sender, amount);

        emit DrawFunded(drawId, msg.sender, amount);
    }

    function buyTickets(
        uint64 drawId,
        uint256[] calldata packedTickets
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint64[] memory ticketIds)
    {
        uint256 length = packedTickets.length;
        if (length == 0 || length > MAX_BATCH_SIZE) {
            revert BatchTooLarge();
        }

        Draw storage draw = _draw(drawId);
        if (
            draw.state != DrawState.OPEN
                || block.timestamp < draw.opensAt
                || block.timestamp >= draw.closesAt
        ) {
            revert DrawNotOpen();
        }

        uint256 cost = uint256(draw.ticketPrice) * length;
        uint256 updatedSales = uint256(draw.sales) + cost;
        if (updatedSales > type(uint128).max) revert InvalidAmount();

        ticketIds = new uint64[](length);
        for (uint256 i; i < length; ++i) {
            _validateTicketNumbers(packedTickets[i], draw.maxNumber);

            uint64 ticketId;
            unchecked {
                ticketId = ++ticketCount;
                ++draw.ticketCount;
            }
            s_tickets[ticketId] = Ticket({
                owner: msg.sender,
                drawId: drawId,
                tier: 0,
                registered: false,
                claimed: false,
                refunded: false,
                packedNumbers: packedTickets[i]
            });
            ticketIds[i] = ticketId;

            emit TicketPurchased(
                drawId,
                ticketId,
                msg.sender,
                packedTickets[i]
            );
        }

        draw.sales = uint128(updatedSales);
        _pullExact(msg.sender, cost);
    }

    function requestRandomness(uint64 drawId)
        external
        onlyRole(DRAW_MANAGER_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        Draw storage draw = _draw(drawId);
        _requireResultRequestWindow(draw, DrawMode.VRF);
        draw.state = DrawState.AWAITING_VRF;

        requestId = vrfCoordinator.requestRandomWords(
            VrfV2PlusClient.RandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: vrfRequestConfirmations,
                callbackGasLimit: vrfCallbackGasLimit,
                numWords: 1,
                extraArgs: VrfV2PlusClient.argsToBytes(
                    VrfV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        draw.requestId = requestId;
        s_requestToDraw[requestId] = drawId;
        emit RandomnessRequested(drawId, requestId);
    }

    /// @notice Chainlink VRF coordinator callback. It stores one word and never
    ///         loops over tickets or transfers funds.
    function rawFulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external {
        if (msg.sender != address(vrfCoordinator)) {
            revert OnlyCoordinator(msg.sender);
        }

        uint64 drawId = s_requestToDraw[requestId];
        if (drawId == 0 || randomWords.length == 0) {
            emit RandomnessIgnored(requestId);
            return;
        }

        delete s_requestToDraw[requestId];
        Draw storage draw = s_draws[drawId];
        if (draw.state != DrawState.AWAITING_VRF) {
            emit RandomnessIgnored(requestId);
            return;
        }

        draw.randomWord = randomWords[0];
        draw.state = DrawState.RESULT_READY;
        emit RandomnessReceived(drawId, requestId, randomWords[0]);
    }

    function finalizeVrfResult(uint64 drawId)
        external
        whenNotPaused
    {
        Draw storage draw = _draw(drawId);
        if (draw.mode != DrawMode.VRF) {
            revert InvalidConfiguration();
        }
        if (draw.state != DrawState.RESULT_READY) {
            revert InvalidState(DrawState.RESULT_READY, draw.state);
        }

        uint256 winningNumbers =
            _deriveWinningNumbers(draw.randomWord, draw.maxNumber);
        _openRegistration(drawId, draw, winningNumbers);
    }

    function proposeMirrorResult(
        uint64 drawId,
        uint256 winningNumbers,
        bytes32 sourceHash
    )
        external
        onlyRole(RESULT_PUBLISHER_ROLE)
        whenNotPaused
    {
        Draw storage draw = _draw(drawId);
        _requireResultRequestWindow(draw, DrawMode.MIRROR);
        if (sourceHash == bytes32(0)) revert InvalidConfiguration();
        _validateWinningNumbers(winningNumbers, draw.maxNumber);

        draw.winningNumbers = winningNumbers;
        draw.sourceHash = sourceHash;
        draw.proposedBy = msg.sender;
        draw.resultProposedAt = uint40(block.timestamp);
        draw.state = DrawState.MIRROR_PROPOSED;

        emit MirrorResultProposed(
            drawId,
            msg.sender,
            winningNumbers,
            sourceHash
        );
    }

    function confirmMirrorResult(
        uint64 drawId,
        uint256 winningNumbers,
        bytes32 sourceHash
    )
        external
        onlyRole(RESULT_VERIFIER_ROLE)
        whenNotPaused
    {
        Draw storage draw = _draw(drawId);
        if (draw.mode != DrawMode.MIRROR) {
            revert InvalidConfiguration();
        }
        if (draw.state != DrawState.MIRROR_PROPOSED) {
            revert InvalidState(
                DrawState.MIRROR_PROPOSED,
                draw.state
            );
        }
        if (msg.sender == draw.proposedBy) revert SameAttestor();
        if (
            winningNumbers != draw.winningNumbers
                || sourceHash != draw.sourceHash
        ) {
            revert ResultMismatch();
        }

        draw.resultConfirmedAt = uint40(block.timestamp);
        draw.state = DrawState.RESULT_READY;
        emit MirrorResultConfirmed(drawId, msg.sender, sourceHash);
    }

    function challengeMirrorResult(uint64 drawId, bytes32 reasonHash)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        Draw storage draw = _draw(drawId);
        if (draw.mode != DrawMode.MIRROR) {
            revert InvalidConfiguration();
        }
        if (draw.state != DrawState.RESULT_READY) {
            revert InvalidState(DrawState.RESULT_READY, draw.state);
        }
        if (
            block.timestamp
                >= uint256(draw.resultConfirmedAt)
                    + mirrorChallengePeriod
        ) {
            revert ChallengePeriodActive();
        }

        draw.state = DrawState.OPEN;
        draw.resultProposedAt = 0;
        draw.resultConfirmedAt = 0;
        draw.winningNumbers = 0;
        draw.sourceHash = bytes32(0);
        draw.proposedBy = address(0);
        emit MirrorResultChallenged(drawId, msg.sender, reasonHash);
    }

    function finalizeMirrorResult(uint64 drawId)
        external
        whenNotPaused
    {
        Draw storage draw = _draw(drawId);
        if (draw.mode != DrawMode.MIRROR) {
            revert InvalidConfiguration();
        }
        if (draw.state != DrawState.RESULT_READY) {
            revert InvalidState(DrawState.RESULT_READY, draw.state);
        }
        if (
            block.timestamp
                < uint256(draw.resultConfirmedAt)
                    + mirrorChallengePeriod
        ) {
            revert ChallengePeriodActive();
        }

        _openRegistration(drawId, draw, draw.winningNumbers);
    }

    function registerTicket(uint64 ticketId) external {
        _registerTicket(ticketId);
    }

    function registerTickets(uint64[] calldata ticketIds) external {
        uint256 length = ticketIds.length;
        if (length == 0 || length > MAX_BATCH_SIZE) {
            revert BatchTooLarge();
        }
        for (uint256 i; i < length; ++i) {
            _registerTicket(ticketIds[i]);
        }
    }

    function settleDraw(uint64 drawId) external {
        Draw storage draw = _draw(drawId);
        if (draw.state != DrawState.REGISTRATION) {
            revert InvalidState(DrawState.REGISTRATION, draw.state);
        }
        if (block.timestamp <= draw.registrationDeadline) {
            revert RegistrationClosed();
        }

        uint256 protocolFee =
            uint256(draw.sales) * protocolFeeBps / BPS_DENOMINATOR;
        uint256 netPrizePool =
            uint256(draw.sales) + draw.sponsorPool - protocolFee;
        uint256 allocated;
        uint256 rolloverAdded;

        for (uint256 i; i < 5; ++i) {
            uint256 tierAllocation =
                netPrizePool * draw.tierBps[i] / BPS_DENOMINATOR;
            allocated += tierAllocation;

            uint256 winners = draw.winnerCount[i];
            if (winners == 0) {
                rolloverAdded += tierAllocation;
                continue;
            }

            uint256 prizePerWinner = tierAllocation / winners;
            if (prizePerWinner > type(uint128).max) {
                revert InvalidAmount();
            }
            draw.prizePerWinner[i] = uint128(prizePerWinner);
            rolloverAdded += tierAllocation - prizePerWinner * winners;
        }

        rolloverAdded += netPrizePool - allocated;
        protocolFeesAccrued += protocolFee;
        rolloverPool += rolloverAdded;
        draw.claimDeadline = uint40(block.timestamp + claimPeriod);
        draw.state = DrawState.SETTLED;

        emit DrawSettled(
            drawId,
            netPrizePool,
            protocolFee,
            rolloverAdded,
            draw.claimDeadline
        );
    }

    function claimTo(uint64 ticketId, address recipient)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (recipient == address(0)) revert ZeroAddress();
        amount = _claim(ticketId, recipient);
        paymentToken.safeTransfer(recipient, amount);
    }

    function claimTicketsTo(
        uint64[] calldata ticketIds,
        address recipient
    ) external nonReentrant returns (uint256 totalAmount) {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 length = ticketIds.length;
        if (length == 0 || length > MAX_BATCH_SIZE) {
            revert BatchTooLarge();
        }

        for (uint256 i; i < length; ++i) {
            totalAmount += _claim(ticketIds[i], recipient);
        }
        paymentToken.safeTransfer(recipient, totalAmount);
    }

    function sweepExpiredClaims(uint64 drawId) external {
        Draw storage draw = _draw(drawId);
        if (draw.state != DrawState.SETTLED) {
            revert InvalidState(DrawState.SETTLED, draw.state);
        }
        if (block.timestamp <= draw.claimDeadline) {
            revert ClaimWindowClosed();
        }

        uint256 rolloverAdded;
        for (uint256 i; i < 5; ++i) {
            uint256 unclaimedWinners =
                draw.winnerCount[i] - draw.claimedWinnerCount[i];
            rolloverAdded +=
                unclaimedWinners * draw.prizePerWinner[i];
        }

        rolloverPool += rolloverAdded;
        draw.state = DrawState.CLOSED;
        emit DrawClosed(drawId, rolloverAdded);
    }

    function cancelExpiredDraw(uint64 drawId) external {
        Draw storage draw = _draw(drawId);
        if (
            draw.state != DrawState.OPEN
                && draw.state != DrawState.AWAITING_VRF
                && draw.state != DrawState.MIRROR_PROPOSED
        ) {
            revert InvalidState(DrawState.OPEN, draw.state);
        }
        if (
            block.timestamp
                <= uint256(draw.closesAt) + resultTimeout
        ) {
            revert ResultWindowExpired();
        }

        if (draw.requestId != 0) {
            delete s_requestToDraw[draw.requestId];
        }

        uint256 rolloverAdded = draw.sponsorPool;
        rolloverPool += rolloverAdded;
        draw.sponsorPool = 0;
        draw.state = DrawState.CANCELLED;
        emit DrawCancelled(drawId, rolloverAdded);
    }

    function refundTo(uint64 ticketId, address recipient)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (recipient == address(0)) revert ZeroAddress();
        amount = _refund(ticketId, recipient);
        paymentToken.safeTransfer(recipient, amount);
    }

    function refundTicketsTo(
        uint64[] calldata ticketIds,
        address recipient
    ) external nonReentrant returns (uint256 totalAmount) {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 length = ticketIds.length;
        if (length == 0 || length > MAX_BATCH_SIZE) {
            revert BatchTooLarge();
        }

        for (uint256 i; i < length; ++i) {
            totalAmount += _refund(ticketIds[i], recipient);
        }
        paymentToken.safeTransfer(recipient, totalAmount);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function setTreasury(address newTreasury)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newTreasury == address(0)) revert ZeroAddress();
        address previousTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previousTreasury, newTreasury);
    }

    function withdrawProtocolFees(uint256 amount)
        external
        onlyRole(TREASURER_ROLE)
        nonReentrant
    {
        if (amount == 0 || amount > protocolFeesAccrued) {
            revert InsufficientFees();
        }
        protocolFeesAccrued -= amount;
        paymentToken.safeTransfer(treasury, amount);
        emit ProtocolFeesWithdrawn(treasury, amount);
    }

    /// @notice Recovers unrelated tokens accidentally sent to the contract.
    ///         The configured payment token is deliberately not recoverable.
    function recoverUnrelatedToken(
        IERC20 token,
        address recipient,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            address(token) == address(0)
                || address(token) == address(paymentToken)
                || recipient == address(0)
        ) {
            revert UnsupportedRecovery();
        }
        token.safeTransfer(recipient, amount);
    }

    function getDraw(uint64 drawId)
        external
        view
        returns (Draw memory)
    {
        return _drawView(drawId);
    }

    function getTicket(uint64 ticketId)
        external
        view
        returns (Ticket memory)
    {
        Ticket memory ticket = s_tickets[ticketId];
        if (ticket.owner == address(0)) revert InvalidTicket(ticketId);
        return ticket;
    }

    function getDrawTiming(uint64 drawId)
        external
        view
        returns (
            uint40 opensAt,
            uint40 closesAt,
            DrawState state
        )
    {
        Draw storage draw = _draw(drawId);
        return (draw.opensAt, draw.closesAt, draw.state);
    }

    function drawState(uint64 drawId)
        external
        view
        returns (DrawState)
    {
        return _draw(drawId).state;
    }

    function quoteTickets(uint64 drawId, uint256 quantity)
        external
        view
        returns (uint256)
    {
        if (quantity == 0 || quantity > MAX_BATCH_SIZE) {
            revert BatchTooLarge();
        }
        return uint256(_draw(drawId).ticketPrice) * quantity;
    }

    function claimableAmount(uint64 ticketId)
        external
        view
        returns (uint256)
    {
        Ticket storage ticket = s_tickets[ticketId];
        if (
            ticket.owner == address(0)
                || !ticket.registered
                || ticket.claimed
                || ticket.tier == 0
        ) {
            return 0;
        }

        Draw storage draw = s_draws[ticket.drawId];
        if (
            draw.state != DrawState.SETTLED
                || block.timestamp > draw.claimDeadline
        ) {
            return 0;
        }
        return draw.prizePerWinner[ticket.tier - 1];
    }

    function packTicket(uint8[6] calldata mainNumbers)
        external
        pure
        returns (uint256 packed)
    {
        for (uint256 i; i < PICK_COUNT; ++i) {
            if (
                mainNumbers[i] == 0
                    || (i > 0 && mainNumbers[i] <= mainNumbers[i - 1])
            ) {
                revert InvalidNumbers();
            }
            packed |= uint256(mainNumbers[i]) << (i * 8);
        }
    }

    function packWinningNumbers(
        uint8[6] calldata mainNumbers,
        uint8 bonus
    ) external pure returns (uint256 packed) {
        bool bonusMatchesMain;
        for (uint256 i; i < PICK_COUNT; ++i) {
            if (
                mainNumbers[i] == 0
                    || (i > 0 && mainNumbers[i] <= mainNumbers[i - 1])
            ) {
                revert InvalidNumbers();
            }
            if (mainNumbers[i] == bonus) bonusMatchesMain = true;
            packed |= uint256(mainNumbers[i]) << (i * 8);
        }
        if (bonus == 0 || bonusMatchesMain) revert InvalidNumbers();
        packed |= uint256(bonus) << 48;
    }

    function unpackNumbers(uint256 packed)
        external
        pure
        returns (uint8[6] memory mainNumbers, uint8 bonus)
    {
        for (uint256 i; i < PICK_COUNT; ++i) {
            mainNumbers[i] = uint8(packed >> (i * 8));
        }
        bonus = uint8(packed >> 48);
    }

    function _openRegistration(
        uint64 drawId,
        Draw storage draw,
        uint256 winningNumbers
    ) internal {
        _validateWinningNumbers(winningNumbers, draw.maxNumber);
        draw.winningNumbers = winningNumbers;
        draw.registrationDeadline =
            uint40(block.timestamp + registrationPeriod);
        draw.state = DrawState.REGISTRATION;
        emit RegistrationOpened(
            drawId,
            winningNumbers,
            draw.registrationDeadline
        );
    }

    function _registerTicket(uint64 ticketId) internal {
        Ticket storage ticket = s_tickets[ticketId];
        if (ticket.owner == address(0)) revert InvalidTicket(ticketId);
        if (ticket.registered) revert AlreadyRegistered();

        Draw storage draw = s_draws[ticket.drawId];
        if (draw.state != DrawState.REGISTRATION) {
            revert InvalidState(DrawState.REGISTRATION, draw.state);
        }
        if (block.timestamp > draw.registrationDeadline) {
            revert RegistrationClosed();
        }

        uint8 tier = _calculateTier(
            ticket.packedNumbers,
            draw.winningNumbers
        );
        ticket.registered = true;
        ticket.tier = tier;
        if (tier > 0) {
            unchecked {
                ++draw.winnerCount[tier - 1];
            }
        }
        emit TicketRegistered(ticket.drawId, ticketId, tier);
    }

    function _claim(uint64 ticketId, address recipient)
        internal
        returns (uint256 amount)
    {
        Ticket storage ticket = s_tickets[ticketId];
        if (ticket.owner == address(0)) revert InvalidTicket(ticketId);
        if (msg.sender != ticket.owner) revert NotTicketOwner();
        if (!ticket.registered || ticket.tier == 0) {
            revert NotWinningTicket();
        }
        if (ticket.claimed) revert AlreadyClaimed();

        Draw storage draw = s_draws[ticket.drawId];
        if (draw.state != DrawState.SETTLED) {
            revert InvalidState(DrawState.SETTLED, draw.state);
        }
        if (block.timestamp > draw.claimDeadline) {
            revert ClaimWindowClosed();
        }

        amount = draw.prizePerWinner[ticket.tier - 1];
        if (amount == 0) revert NotWinningTicket();
        ticket.claimed = true;
        draw.claimedPrize += uint128(amount);
        unchecked {
            ++draw.claimedWinnerCount[ticket.tier - 1];
        }
        emit PrizeClaimed(
            ticket.drawId,
            ticketId,
            recipient,
            amount
        );
    }

    function _refund(uint64 ticketId, address recipient)
        internal
        returns (uint256 amount)
    {
        Ticket storage ticket = s_tickets[ticketId];
        if (ticket.owner == address(0)) revert InvalidTicket(ticketId);
        if (msg.sender != ticket.owner) revert NotTicketOwner();
        if (ticket.refunded) revert AlreadyRefunded();

        Draw storage draw = s_draws[ticket.drawId];
        if (draw.state != DrawState.CANCELLED) {
            revert InvalidState(DrawState.CANCELLED, draw.state);
        }

        ticket.refunded = true;
        amount = draw.ticketPrice;
        emit TicketRefunded(
            ticket.drawId,
            ticketId,
            recipient,
            amount
        );
    }

    function _requireResultRequestWindow(
        Draw storage draw,
        DrawMode expectedMode
    ) internal view {
        if (draw.mode != expectedMode) revert InvalidConfiguration();
        if (draw.state != DrawState.OPEN) {
            revert InvalidState(DrawState.OPEN, draw.state);
        }
        if (block.timestamp < draw.closesAt) revert InvalidTime();
        if (
            block.timestamp
                > uint256(draw.closesAt) + resultTimeout
        ) {
            revert ResultWindowExpired();
        }
    }

    function _deriveWinningNumbers(
        uint256 seed,
        uint8 maxNumber
    ) internal pure returns (uint256 packed) {
        uint8[6] memory mainNumbers;
        uint256 nonce;

        for (uint256 i; i < PICK_COUNT; ++i) {
            uint8 candidate;
            bool duplicate;
            do {
                (candidate, nonce) = _sample(seed, nonce, maxNumber);
                duplicate = false;
                for (uint256 j; j < i; ++j) {
                    if (mainNumbers[j] == candidate) {
                        duplicate = true;
                        break;
                    }
                }
            } while (duplicate);
            mainNumbers[i] = candidate;
        }

        for (uint256 i = 1; i < PICK_COUNT; ++i) {
            uint8 value = mainNumbers[i];
            uint256 j = i;
            while (j > 0 && mainNumbers[j - 1] > value) {
                mainNumbers[j] = mainNumbers[j - 1];
                unchecked {
                    --j;
                }
            }
            mainNumbers[j] = value;
        }

        uint8 bonus;
        bool bonusDuplicate;
        do {
            (bonus, nonce) = _sample(seed, nonce, maxNumber);
            bonusDuplicate = false;
            for (uint256 i; i < PICK_COUNT; ++i) {
                if (mainNumbers[i] == bonus) {
                    bonusDuplicate = true;
                    break;
                }
            }
        } while (bonusDuplicate);

        for (uint256 i; i < PICK_COUNT; ++i) {
            packed |= uint256(mainNumbers[i]) << (i * 8);
        }
        packed |= uint256(bonus) << 48;
    }

    function _sample(
        uint256 seed,
        uint256 nonce,
        uint8 upperBound
    ) internal pure returns (uint8 value, uint256 nextNonce) {
        uint256 candidate;
        uint256 limit =
            type(uint256).max
                - (type(uint256).max % uint256(upperBound));

        do {
            candidate = uint256(keccak256(abi.encode(seed, nonce)));
            unchecked {
                ++nonce;
            }
        } while (candidate >= limit);

        value = uint8(candidate % upperBound) + 1;
        nextNonce = nonce;
    }

    function _calculateTier(
        uint256 ticketNumbers,
        uint256 winningNumbers
    ) internal pure returns (uint8) {
        uint8 matches;
        bool hasBonus;
        uint8 bonus = uint8(winningNumbers >> 48);

        for (uint256 i; i < PICK_COUNT; ++i) {
            uint8 ticketNumber =
                uint8(ticketNumbers >> (i * 8));
            if (ticketNumber == bonus) hasBonus = true;

            for (uint256 j; j < PICK_COUNT; ++j) {
                if (
                    ticketNumber
                        == uint8(winningNumbers >> (j * 8))
                ) {
                    unchecked {
                        ++matches;
                    }
                    break;
                }
            }
        }

        if (matches == 6) return 5;
        if (matches == 5 && hasBonus) return 4;
        if (matches == 5) return 3;
        if (matches == 4) return 2;
        if (matches == 3) return 1;
        return 0;
    }

    function _validateTicketNumbers(
        uint256 packed,
        uint8 maxNumber
    ) internal pure {
        if (packed >> 48 != 0) revert InvalidNumbers();
        uint8 previous;
        for (uint256 i; i < PICK_COUNT; ++i) {
            uint8 value = uint8(packed >> (i * 8));
            if (
                value == 0
                    || value > maxNumber
                    || (i > 0 && value <= previous)
            ) {
                revert InvalidNumbers();
            }
            previous = value;
        }
    }

    function _validateWinningNumbers(
        uint256 packed,
        uint8 maxNumber
    ) internal pure {
        if (packed >> 56 != 0) revert InvalidNumbers();
        uint256 ticketPortion = packed & ((uint256(1) << 48) - 1);
        _validateTicketNumbers(ticketPortion, maxNumber);

        uint8 bonus = uint8(packed >> 48);
        if (bonus == 0 || bonus > maxNumber) revert InvalidNumbers();
        for (uint256 i; i < PICK_COUNT; ++i) {
            if (uint8(packed >> (i * 8)) == bonus) {
                revert InvalidNumbers();
            }
        }
    }

    function _pullExact(address from, uint256 amount) internal {
        uint256 balanceBefore = paymentToken.balanceOf(address(this));
        paymentToken.safeTransferFrom(from, address(this), amount);
        uint256 received =
            paymentToken.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TransferAmountMismatch();
    }

    function _draw(uint64 drawId)
        internal
        view
        returns (Draw storage draw)
    {
        draw = s_draws[drawId];
        if (draw.state == DrawState.NONE) revert InvalidDraw(drawId);
    }

    function _drawView(uint64 drawId)
        internal
        view
        returns (Draw memory draw)
    {
        draw = s_draws[drawId];
        if (draw.state == DrawState.NONE) revert InvalidDraw(drawId);
    }
}
