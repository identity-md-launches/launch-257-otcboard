// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OTCBoard} from "../../src/OTCBoard.sol";
import {IHookReceiver} from "./MockTokens.sol";

/// @dev A maker that refuses ETH. Used to prove that fills are never blocked by the maker and
///      that its own withdraw reverts cleanly without losing the credit.
contract EthRejectingMaker {
    OTCBoard public immutable board;

    constructor(OTCBoard board_) {
        board = board_;
    }

    function post(address token, uint256 amount, uint256 price, uint256 expiry) external returns (uint256) {
        return board.post(token, amount, price, expiry);
    }

    function withdraw() external {
        board.withdraw();
    }

    receive() external payable {
        revert("no ETH");
    }
}

/// @dev Reenters withdraw() from the ETH receive hook and records whether it succeeded.
contract ReentrantWithdrawer {
    OTCBoard public immutable board;
    bool public reentered;
    bool public reentrySucceeded;

    constructor(OTCBoard board_) {
        board = board_;
    }

    function post(address token, uint256 amount, uint256 price, uint256 expiry) external returns (uint256) {
        return board.post(token, amount, price, expiry);
    }

    function withdraw() external {
        board.withdraw();
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            (bool ok,) = address(board).call(abi.encodeCall(OTCBoard.withdraw, ()));
            reentrySucceeded = ok;
        }
    }
}

/// @dev Taker that receives a callback token and tries to reenter fill() during the transfer.
contract ReentrantTaker is IHookReceiver {
    OTCBoard public immutable board;
    uint256 public targetOrder;
    uint256 public reentryAmount;
    uint256 public reentryValue;
    bool public attacked;
    bool public reentrySucceeded;
    bytes public reentryError;

    constructor(OTCBoard board_) {
        board = board_;
    }

    function arm(uint256 orderId, uint256 amount, uint256 value) external {
        targetOrder = orderId;
        reentryAmount = amount;
        reentryValue = value;
    }

    function fill(uint256 orderId, uint256 amount) external payable {
        board.fill{value: msg.value}(orderId, amount);
    }

    function onTokenTransfer(address, uint256) external override {
        if (!attacked) {
            attacked = true;
            (bool ok, bytes memory err) =
                address(board).call{value: reentryValue}(abi.encodeCall(OTCBoard.fill, (targetOrder, reentryAmount)));
            reentrySucceeded = ok;
            reentryError = err;
        }
    }

    receive() external payable {}
}

/// @dev Maker that receives a callback token on cancel and tries to reenter cancel() and fill().
contract ReentrantMaker is IHookReceiver {
    OTCBoard public immutable board;
    uint256 public targetOrder;
    bool public attacked;
    bool public cancelReentrySucceeded;
    bytes public cancelReentryError;

    constructor(OTCBoard board_) {
        board = board_;
    }

    function post(address token, uint256 amount, uint256 price, uint256 expiry) external returns (uint256 id) {
        id = board.post(token, amount, price, expiry);
        targetOrder = id;
    }

    function cancel() external {
        board.cancel(targetOrder);
    }

    function onTokenTransfer(address, uint256) external override {
        // Ignore the mint and the escrow return happening as part of post.
        if (msg.sender != address(0) && !attacked && targetOrder != 0) {
            attacked = true;
            (bool ok, bytes memory err) = address(board).call(abi.encodeCall(OTCBoard.cancel, (targetOrder)));
            cancelReentrySucceeded = ok;
            cancelReentryError = err;
        }
    }
}
