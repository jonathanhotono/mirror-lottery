// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MirrorLottery} from "./MirrorLottery.sol";

/// @title Mirror Syndicate
/// @notice A single-draw, fixed-price share pool. The captain can spend pooled
///         funds only by purchasing tickets for the immutable target draw.
///         Members pull their pro-rata distribution after the draw is closed.
contract MirrorSyndicate is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_SHARES = 100;
    uint16 public constant MAX_SYNDICATE_TICKETS = 250;

    error ZeroAddress();
    error InvalidConfiguration();
    error JoinWindowClosed();
    error ShareCapExceeded();
    error OnlyCaptain();
    error TransferAmountMismatch();
    error UnknownSyndicateTicket();
    error TicketAlreadyRefunded();
    error DistributionNotReady();
    error DistributionAlreadyFinalized();
    error DistributionNotFinalized();
    error NothingToClaim();
    error AlreadyClaimed();

    event SharesPurchased(
        address indexed member,
        uint32 quantity,
        uint256 cost
    );
    event TicketsPurchased(
        address indexed captain,
        uint64[] ticketIds,
        uint256 cost
    );
    event SyndicateTicketRegistered(uint64 indexed ticketId);
    event SyndicatePrizeCollected(
        uint64 indexed ticketId,
        uint256 amount
    );
    event SyndicateTicketRefunded(
        uint64 indexed ticketId,
        uint256 amount
    );
    event DistributionFinalized(
        uint256 distributable,
        uint256 payoutPerShare,
        uint256 dust
    );
    event DistributionClaimed(
        address indexed member,
        address indexed recipient,
        uint32 shares,
        uint256 amount
    );

    MirrorLottery public immutable lottery;
    IERC20 public immutable paymentToken;
    uint64 public immutable drawId;
    address public immutable captain;
    uint96 public immutable sharePrice;
    uint16 public immutable maxShares;
    uint40 public immutable joinDeadline;
    bytes32 public immutable metadataHash;

    uint32 public totalShares;
    uint16 public refundedTicketCount;
    bool public distributionFinalized;
    uint256 public distributableAmount;
    uint256 public payoutPerShare;
    uint256 public distributionDust;

    uint64[] private s_ticketIds;
    mapping(uint64 ticketId => bool isOwned) public isSyndicateTicket;
    mapping(uint64 ticketId => bool refunded) public ticketRefunded;
    mapping(address member => uint32 shareCount) public shares;
    mapping(address member => bool claimed) public distributionClaimed;

    constructor(
        MirrorLottery lottery_,
        uint64 drawId_,
        address captain_,
        uint96 sharePrice_,
        uint16 maxShares_,
        uint40 joinDeadline_,
        bytes32 metadataHash_
    ) {
        if (address(lottery_) == address(0) || captain_ == address(0)) {
            revert ZeroAddress();
        }
        if (
            sharePrice_ == 0
                || maxShares_ < 2
                || maxShares_ > MAX_SHARES
                || joinDeadline_ <= block.timestamp
        ) {
            revert InvalidConfiguration();
        }

        (,, MirrorLottery.DrawState state) =
            lottery_.getDrawTiming(drawId_);
        (, uint40 closesAt,) = lottery_.getDrawTiming(drawId_);
        if (
            state != MirrorLottery.DrawState.OPEN
                || joinDeadline_ >= closesAt
        ) {
            revert InvalidConfiguration();
        }

        lottery = lottery_;
        paymentToken = lottery_.paymentToken();
        drawId = drawId_;
        captain = captain_;
        sharePrice = sharePrice_;
        maxShares = maxShares_;
        joinDeadline = joinDeadline_;
        metadataHash = metadataHash_;
    }

    function buyShares(uint16 quantity) external nonReentrant {
        if (block.timestamp >= joinDeadline) revert JoinWindowClosed();
        if (
            quantity == 0
                || uint256(totalShares) + quantity > maxShares
        ) {
            revert ShareCapExceeded();
        }

        uint256 cost = uint256(sharePrice) * quantity;
        uint256 balanceBefore = paymentToken.balanceOf(address(this));
        paymentToken.safeTransferFrom(msg.sender, address(this), cost);
        uint256 received =
            paymentToken.balanceOf(address(this)) - balanceBefore;
        if (received != cost) revert TransferAmountMismatch();

        shares[msg.sender] += quantity;
        totalShares += quantity;
        emit SharesPurchased(msg.sender, quantity, cost);
    }

    function buyTickets(uint256[] calldata packedTickets)
        external
        nonReentrant
        returns (uint64[] memory purchasedTicketIds)
    {
        if (msg.sender != captain) revert OnlyCaptain();
        if (
            packedTickets.length == 0
                || s_ticketIds.length + packedTickets.length
                    > MAX_SYNDICATE_TICKETS
        ) {
            revert InvalidConfiguration();
        }

        uint256 cost =
            lottery.quoteTickets(drawId, packedTickets.length);
        paymentToken.forceApprove(address(lottery), cost);
        purchasedTicketIds = lottery.buyTickets(drawId, packedTickets);
        paymentToken.forceApprove(address(lottery), 0);

        for (uint256 i; i < purchasedTicketIds.length; ++i) {
            uint64 ticketId = purchasedTicketIds[i];
            s_ticketIds.push(ticketId);
            isSyndicateTicket[ticketId] = true;
        }

        emit TicketsPurchased(msg.sender, purchasedTicketIds, cost);
    }

    function registerTicket(uint64 ticketId) external {
        if (!isSyndicateTicket[ticketId]) {
            revert UnknownSyndicateTicket();
        }
        lottery.registerTicket(ticketId);
        emit SyndicateTicketRegistered(ticketId);
    }

    function collectPrize(uint64 ticketId)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (!isSyndicateTicket[ticketId]) {
            revert UnknownSyndicateTicket();
        }
        amount = lottery.claimTo(ticketId, address(this));
        emit SyndicatePrizeCollected(ticketId, amount);
    }

    function refundTicket(uint64 ticketId)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (!isSyndicateTicket[ticketId]) {
            revert UnknownSyndicateTicket();
        }
        if (ticketRefunded[ticketId]) revert TicketAlreadyRefunded();

        amount = lottery.refundTo(ticketId, address(this));
        ticketRefunded[ticketId] = true;
        unchecked {
            ++refundedTicketCount;
        }
        emit SyndicateTicketRefunded(ticketId, amount);
    }

    function finalizeDistribution() external {
        if (distributionFinalized) {
            revert DistributionAlreadyFinalized();
        }
        if (totalShares == 0) revert DistributionNotReady();

        MirrorLottery.DrawState state = lottery.drawState(drawId);
        if (state == MirrorLottery.DrawState.CANCELLED) {
            if (refundedTicketCount != s_ticketIds.length) {
                revert DistributionNotReady();
            }
        } else if (state != MirrorLottery.DrawState.CLOSED) {
            revert DistributionNotReady();
        }

        uint256 balance = paymentToken.balanceOf(address(this));
        distributableAmount = balance;
        payoutPerShare = balance / totalShares;
        distributionDust = balance - payoutPerShare * totalShares;
        distributionFinalized = true;

        emit DistributionFinalized(
            balance,
            payoutPerShare,
            distributionDust
        );
    }

    function claimDistributionTo(address recipient)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (!distributionFinalized) {
            revert DistributionNotFinalized();
        }
        if (recipient == address(0)) revert ZeroAddress();
        if (distributionClaimed[msg.sender]) revert AlreadyClaimed();

        uint32 memberShares = shares[msg.sender];
        if (memberShares == 0) revert NothingToClaim();
        distributionClaimed[msg.sender] = true;
        amount = uint256(memberShares) * payoutPerShare;
        if (amount > 0) {
            paymentToken.safeTransfer(recipient, amount);
        }

        emit DistributionClaimed(
            msg.sender,
            recipient,
            memberShares,
            amount
        );
    }

    function ticketIds() external view returns (uint64[] memory) {
        return s_ticketIds;
    }
}

/// @title Mirror Syndicate Factory
/// @notice Deploys immutable single-draw syndicates and indexes them by captain.
contract MirrorSyndicateFactory {
    error ZeroAddress();
    error SyndicateAlreadyExists();

    event SyndicateCreated(
        address indexed syndicate,
        address indexed captain,
        uint64 indexed drawId,
        uint96 sharePrice,
        uint16 maxShares,
        uint40 joinDeadline,
        bytes32 metadataHash
    );

    MirrorLottery public immutable lottery;
    address[] private s_allSyndicates;
    mapping(uint64 drawId => mapping(address captain => address syndicate))
        public syndicateByCaptain;

    constructor(MirrorLottery lottery_) {
        if (address(lottery_) == address(0)) revert ZeroAddress();
        lottery = lottery_;
    }

    function createSyndicate(
        uint64 drawId,
        uint96 sharePrice,
        uint16 maxShares,
        uint40 joinDeadline,
        bytes32 metadataHash
    ) external returns (address syndicate) {
        if (syndicateByCaptain[drawId][msg.sender] != address(0)) {
            revert SyndicateAlreadyExists();
        }

        syndicate = address(
            new MirrorSyndicate(
                lottery,
                drawId,
                msg.sender,
                sharePrice,
                maxShares,
                joinDeadline,
                metadataHash
            )
        );
        syndicateByCaptain[drawId][msg.sender] = syndicate;
        s_allSyndicates.push(syndicate);

        emit SyndicateCreated(
            syndicate,
            msg.sender,
            drawId,
            sharePrice,
            maxShares,
            joinDeadline,
            metadataHash
        );
    }

    function allSyndicates() external view returns (address[] memory) {
        return s_allSyndicates;
    }
}
