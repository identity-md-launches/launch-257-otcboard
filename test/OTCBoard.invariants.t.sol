// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OTCBoard} from "../src/OTCBoard.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MockERC20, FeeOnTransferERC20} from "./mocks/MockTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Drives the board with random posts, fills, cancels, withdraws and time travel across
///      several tokens (18, 6 and 0 decimals plus a fee-on-transfer token) and several actors.
contract BoardHandler is Test {
    OTCBoard public immutable board;
    address[] public tokens;
    address[] public actors;

    uint256 public ghostEthIn;
    uint256 public ghostEthOut;
    uint256 public fills;
    uint256 public cancels;
    uint256 public posts;

    constructor(OTCBoard board_, address[] memory tokens_, address[] memory actors_) {
        board = board_;
        tokens = tokens_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function post(uint256 actorSeed, uint256 tokenSeed, uint256 amount, uint256 price, uint256 life) external {
        address a = _actor(actorSeed);
        address t = tokens[tokenSeed % tokens.length];
        amount = bound(amount, 1, 1_000 ether);
        price = bound(price, 1, 10 ether);
        life = bound(life, 1, 90 days);
        deal(t, a, IERC20(t).balanceOf(a) + amount);
        vm.startPrank(a);
        IERC20(t).approve(address(board), amount);
        board.post(t, amount, price, block.timestamp + life);
        vm.stopPrank();
        posts++;
    }

    function fill(uint256 actorSeed, uint256 idSeed, uint256 amount) external {
        uint256 count = board.orderCount();
        if (count == 0) return;
        uint256 id = (idSeed % count) + 1;
        OTCBoard.Order memory o = board.order(id);
        if (o.cancelled || o.remaining == 0 || block.timestamp >= o.expiry) return;
        address a = _actor(actorSeed);
        if (a == o.maker) a = actors[((actorSeed % actors.length) + 1) % actors.length];
        if (a == o.maker) return;
        amount = bound(amount, 1, o.remaining);
        uint256 cost = board.quote(id, amount);
        vm.deal(a, a.balance + cost);
        vm.prank(a);
        board.fill{value: cost}(id, amount);
        ghostEthIn += cost;
        fills++;
    }

    function cancel(uint256 idSeed) external {
        uint256 count = board.orderCount();
        if (count == 0) return;
        uint256 id = (idSeed % count) + 1;
        OTCBoard.Order memory o = board.order(id);
        if (o.cancelled || o.remaining == 0) return;
        vm.prank(o.maker);
        board.cancel(id);
        cancels++;
    }

    function withdraw(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        uint256 credit = board.withdrawable(a);
        if (credit == 0) return;
        vm.prank(a);
        board.withdraw();
        ghostEthOut += credit;
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1, 30 days);
        vm.warp(block.timestamp + secs);
    }
}

contract OTCBoardInvariantTest is Test {
    OTCBoard internal board;
    BoardHandler internal handler;
    address[] internal tokens;
    address[] internal actors;

    function setUp() public {
        vm.warp(1_700_000_000);
        LaunchToken desk = new LaunchToken();
        board = new OTCBoard(address(desk));

        tokens.push(address(desk));
        tokens.push(address(new MockERC20("Six", "SIX", 6)));
        tokens.push(address(new MockERC20("Zero", "ZERO", 0)));
        tokens.push(address(new FeeOnTransferERC20(250)));

        actors.push(makeAddr("a1"));
        actors.push(makeAddr("a2"));
        actors.push(makeAddr("a3"));

        handler = new BoardHandler(board, tokens, actors);
        targetContract(address(handler));
    }

    /// @dev For each token, escrow >= sum of remainders of orders that are not cancelled.
    function invariant_tokenBalanceCoversRemainders() public view {
        uint256 count = board.orderCount();
        for (uint256 t; t < tokens.length; ++t) {
            uint256 owed;
            for (uint256 id = 1; id <= count; ++id) {
                OTCBoard.Order memory o = board.order(id);
                if (o.token == tokens[t] && !o.cancelled) owed += o.remaining;
            }
            assertGe(IERC20(tokens[t]).balanceOf(address(board)), owed, "escrow short");
        }
    }

    /// @dev Board ETH == sum of all withdrawable credits.
    function invariant_ethEqualsCredits() public view {
        uint256 credits;
        for (uint256 i; i < actors.length; ++i) {
            credits += board.withdrawable(actors[i]);
        }
        assertEq(address(board).balance, credits, "ETH != credits");
        assertEq(address(board).balance, handler.ghostEthIn() - handler.ghostEthOut(), "ETH != ghost accounting");
    }

    /// @dev remaining never exceeds the recorded amount, and cancelled orders have nothing left.
    function invariant_orderShape() public view {
        uint256 count = board.orderCount();
        for (uint256 id = 1; id <= count; ++id) {
            OTCBoard.Order memory o = board.order(id);
            assertLe(o.remaining, o.amount);
            assertGt(o.amount, 0);
            assertGt(o.pricePerToken, 0);
            assertLe(o.decimals, 30);
            if (o.cancelled) assertEq(o.remaining, 0);
        }
    }
}
