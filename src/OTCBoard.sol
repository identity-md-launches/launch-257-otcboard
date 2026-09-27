// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OTCBoard
/// @notice A fixed-price order board where makers sell any ERC-20 for native ETH.
///
///         Makers post an order by escrowing tokens with a wei price per whole token and an
///         expiry. Takers fill any part of an order by sending exactly the quoted ETH; the
///         tokens go to the taker immediately and the ETH is credited to the maker, who pulls
///         it with {withdraw}. Makers may cancel before or after expiry to recover the
///         unfilled remainder.
///
///         There is no owner, admin, fee, pause or upgrade path, and the contract has no
///         receive or fallback function: ETH only enters through {fill}.
///
///         Token assumptions: decimals() is read once at post time and must be <= 30.
///         Fee-on-transfer tokens are supported on a best-effort basis (the order records the
///         amount actually received; a fill delivers less than `amount` to the taker).
///         Rebasing tokens are unsupported: a negative rebase can make the escrow insufficient
///         for the recorded remainders.
contract OTCBoard is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ----------------------------------------------------------------------------------------
    // Types
    // ----------------------------------------------------------------------------------------

    struct Order {
        /// @dev Account that posted the order and receives the ETH proceeds.
        address maker;
        /// @dev ERC-20 being sold.
        address token;
        /// @dev Token decimals read once at post time; the price denominator is 10**decimals.
        uint8 decimals;
        /// @dev True once the maker has cancelled; the order can never be filled again.
        bool cancelled;
        /// @dev Amount of base units actually received at post time.
        uint256 amount;
        /// @dev Base units still available to fill.
        uint256 remaining;
        /// @dev Wei per whole token (per 10**decimals base units).
        uint256 pricePerToken;
        /// @dev Unix timestamp after which the order can no longer be filled.
        uint256 expiry;
    }

    // ----------------------------------------------------------------------------------------
    // Constants and immutables
    // ----------------------------------------------------------------------------------------

    /// @notice Longest allowed order lifetime measured from the posting block.
    uint256 public constant MAX_DURATION = 90 days;

    /// @notice Largest supported token decimals; 10**30 keeps every quote within uint256.
    uint8 public constant MAX_DECIMALS = 30;

    /// @dev Token the site lists by default. Set once by the factory; the board holds none of it.
    address private immutable _featuredToken;

    // ----------------------------------------------------------------------------------------
    // Storage
    // ----------------------------------------------------------------------------------------

    /// @dev Orders by id. Ids start at 1; slot 0 is never populated.
    mapping(uint256 => Order) private _orders;

    /// @notice Number of orders ever posted; also the id of the most recent order.
    uint256 public orderCount;

    /// @dev ETH credited to makers by fills, withdrawable with {withdraw}.
    mapping(address => uint256) private _withdrawable;

    // ----------------------------------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------------------------------

    event Posted(
        uint256 indexed id,
        address indexed maker,
        address indexed token,
        uint256 amount,
        uint256 pricePerToken,
        uint256 expiry
    );
    event Filled(uint256 indexed id, address indexed maker, address indexed taker, uint256 amount, uint256 cost);
    event Cancelled(uint256 indexed id, address indexed maker, uint256 remainder);
    event Withdrawn(address indexed account, uint256 amount);

    // ----------------------------------------------------------------------------------------
    // Errors
    // ----------------------------------------------------------------------------------------

    error ZeroAddress();
    error UnknownOrder(uint256 id);
    error ZeroAmount();
    error ZeroPrice();
    error InvalidExpiry(uint256 expiry);
    error UnsupportedToken(address token);
    error NothingReceived();
    error OrderCancelled(uint256 id);
    error OrderExpired(uint256 id);
    error MakerCannotFill(uint256 id);
    error AmountExceedsRemaining(uint256 requested, uint256 remaining);
    error IncorrectPayment(uint256 sent, uint256 required);
    error NotMaker(uint256 id);
    error NothingToCancel(uint256 id);
    error NothingToWithdraw();
    error EthTransferFailed();

    // ----------------------------------------------------------------------------------------
    // Constructor
    // ----------------------------------------------------------------------------------------

    /// @param featuredToken_ The launch token (DESK) the site shows by default. It receives no
    ///        special treatment on the board; any ERC-20 may be posted.
    constructor(address featuredToken_) {
        if (featuredToken_ == address(0)) revert ZeroAddress();
        _featuredToken = featuredToken_;
    }

    // ----------------------------------------------------------------------------------------
    // Maker actions
    // ----------------------------------------------------------------------------------------

    /// @notice Escrow `amount` base units of `token` for sale at `pricePerToken` wei per whole token.
    /// @dev Pulls the tokens with SafeERC20 and records the balance delta, so a fee-on-transfer
    ///      token is recorded net. The caller must have approved this contract for `amount`.
    /// @param token ERC-20 to sell. Its decimals() must succeed and return at most 30.
    /// @param amount Base units to escrow; must be > 0 and something must actually arrive.
    /// @param pricePerToken Wei per 10**decimals base units; must be > 0.
    /// @param expiry Unix timestamp; must satisfy now < expiry <= now + 90 days.
    /// @return id The new order id (starting from 1).
    function post(address token, uint256 amount, uint256 pricePerToken, uint256 expiry)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (amount == 0) revert ZeroAmount();
        if (pricePerToken == 0) revert ZeroPrice();
        if (expiry <= block.timestamp || expiry > block.timestamp + MAX_DURATION) revert InvalidExpiry(expiry);

        uint8 tokenDecimals = _readDecimals(token);

        // Effects: reserve the id and write everything except the received amount.
        id = ++orderCount;
        Order storage o = _orders[id];
        o.maker = msg.sender;
        o.token = token;
        o.decimals = tokenDecimals;
        o.pricePerToken = pricePerToken;
        o.expiry = expiry;

        // Interaction: pull the tokens and measure what actually arrived.
        IERC20 erc20 = IERC20(token);
        uint256 balanceBefore = erc20.balanceOf(address(this));
        erc20.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = erc20.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert NothingReceived();

        o.amount = received;
        o.remaining = received;

        emit Posted(id, msg.sender, token, received, pricePerToken, expiry);
    }

    /// @notice Cancel an order and return its unfilled remainder to the maker.
    /// @dev Allowed before or after expiry, as long as something remains and it was not
    ///      already cancelled. Only the maker may cancel.
    function cancel(uint256 orderId) external nonReentrant {
        Order storage o = _getOrder(orderId);
        if (o.maker != msg.sender) revert NotMaker(orderId);
        if (o.cancelled || o.remaining == 0) revert NothingToCancel(orderId);

        uint256 remainder = o.remaining;
        o.cancelled = true;
        o.remaining = 0;

        // forge-lint: disable-next-line(reentrancy-events)
        emit Cancelled(orderId, msg.sender, remainder);

        IERC20(o.token).safeTransfer(msg.sender, remainder);
    }

    /// @notice Send the caller's whole ETH credit to the caller.
    function withdraw() external nonReentrant {
        uint256 amount = _withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        _withdrawable[msg.sender] = 0;
        // forge-lint: disable-next-line(reentrancy-events)
        emit Withdrawn(msg.sender, amount);

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    // ----------------------------------------------------------------------------------------
    // Taker actions
    // ----------------------------------------------------------------------------------------

    /// @notice Buy `amount` base units from order `orderId`, paying exactly the quoted ETH.
    /// @dev cost = ceil(amount * pricePerToken / 10**decimals). msg.value must equal cost.
    ///      Tokens are pushed to the taker; ETH is credited to the maker for later withdrawal
    ///      so that a maker who rejects ETH cannot block fills.
    function fill(uint256 orderId, uint256 amount) external payable nonReentrant {
        Order storage o = _getOrder(orderId);
        if (o.cancelled) revert OrderCancelled(orderId);
        if (block.timestamp >= o.expiry) revert OrderExpired(orderId);
        if (msg.sender == o.maker) revert MakerCannotFill(orderId);
        if (amount == 0) revert ZeroAmount();
        uint256 remaining = o.remaining;
        if (amount > remaining) revert AmountExceedsRemaining(amount, remaining);

        uint256 cost = _cost(amount, o.pricePerToken, o.decimals);
        if (msg.value != cost) revert IncorrectPayment(msg.value, cost);

        address maker = o.maker;
        o.remaining = remaining - amount;
        _withdrawable[maker] += cost;

        // forge-lint: disable-next-line(reentrancy-events)
        emit Filled(orderId, maker, msg.sender, amount, cost);

        IERC20(o.token).safeTransfer(msg.sender, amount);
    }

    // ----------------------------------------------------------------------------------------
    // Views
    // ----------------------------------------------------------------------------------------

    /// @notice The launch token the site lists by default.
    function featuredToken() external view returns (address) {
        return _featuredToken;
    }

    /// @notice Full record of order `id`. Reverts for unknown ids.
    function order(uint256 id) external view returns (Order memory) {
        return _getOrder(id);
    }

    /// @notice ETH cost in wei to fill `amount` base units of order `id`, rounded up.
    /// @dev Reverts for unknown ids. Does not check expiry, cancellation or remaining; use
    ///      {order} for those. Reverts if `amount` is zero so the quote is never misread as free.
    function quote(uint256 id, uint256 amount) external view returns (uint256) {
        Order storage o = _getOrder(id);
        if (amount == 0) revert ZeroAmount();
        return _cost(amount, o.pricePerToken, o.decimals);
    }

    /// @notice ETH credited to `account` from fills and not yet withdrawn.
    function withdrawable(address account) external view returns (uint256) {
        return _withdrawable[account];
    }

    // ----------------------------------------------------------------------------------------
    // Internals
    // ----------------------------------------------------------------------------------------

    function _getOrder(uint256 id) private view returns (Order storage o) {
        if (id == 0 || id > orderCount) revert UnknownOrder(id);
        o = _orders[id];
    }

    function _cost(uint256 amount, uint256 pricePerToken, uint8 tokenDecimals) private pure returns (uint256) {
        return Math.mulDiv(amount, pricePerToken, 10 ** uint256(tokenDecimals), Math.Rounding.Ceil);
    }

    /// @dev Reads decimals() with a staticcall so a token without the function, or one that
    ///      reverts, is rejected instead of bubbling an opaque error. Rejects values above 30.
    function _readDecimals(address token) private view returns (uint8) {
        if (token == address(0)) revert ZeroAddress();
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (!ok || data.length < 32) revert UnsupportedToken(token);
        uint256 raw = abi.decode(data, (uint256));
        if (raw > MAX_DECIMALS) revert UnsupportedToken(token);
        // casting to 'uint8' is safe because raw <= MAX_DECIMALS (30) was just checked
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(raw);
    }
}
