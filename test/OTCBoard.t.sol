// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {OTCBoard} from "../src/OTCBoard.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {
    MockERC20,
    FeeOnTransferERC20,
    RevertingDecimalsToken,
    HugeDecimalsToken,
    NoDecimalsToken,
    NoOpTransferToken,
    FalseReturnToken,
    CallbackERC20
} from "./mocks/MockTokens.sol";
import {EthRejectingMaker, ReentrantWithdrawer, ReentrantTaker, ReentrantMaker} from "./mocks/Actors.sol";

contract OTCBoardTest is Test {
    OTCBoard internal board;
    LaunchToken internal desk;
    MockERC20 internal usd6;
    FeeOnTransferERC20 internal fee;

    address internal factory = makeAddr("factory");
    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");
    address internal other = makeAddr("other");

    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant PRICE = 0.001 ether; // wei per whole token

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

    function setUp() public {
        vm.warp(START);
        vm.prank(factory);
        desk = new LaunchToken();
        vm.prank(factory);
        board = new OTCBoard(address(desk));

        usd6 = new MockERC20("Six", "SIX", 6);
        fee = new FeeOnTransferERC20(100); // 1%

        vm.prank(factory);
        desk.transfer(maker, 1_000_000 ether);
        usd6.mint(maker, 1_000_000e6);
        fee.mint(maker, 1_000_000 ether);

        vm.startPrank(maker);
        desk.approve(address(board), type(uint256).max);
        usd6.approve(address(board), type(uint256).max);
        fee.approve(address(board), type(uint256).max);
        vm.stopPrank();

        vm.deal(taker, 1_000 ether);
        vm.deal(other, 1_000 ether);
    }

    // -------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------

    function _postDesk(uint256 amount, uint256 price, uint256 expiry) internal returns (uint256 id) {
        vm.prank(maker);
        id = board.post(address(desk), amount, price, expiry);
    }

    function _cost(uint256 amount, uint256 price, uint8 dec) internal pure returns (uint256) {
        return Math.mulDiv(amount, price, 10 ** dec, Math.Rounding.Ceil);
    }

    // -------------------------------------------------------------------------------------
    // Deployment
    // -------------------------------------------------------------------------------------

    function test_constructorSetsFeaturedTokenAndHoldsNothing() public view {
        assertEq(board.featuredToken(), address(desk));
        assertEq(desk.balanceOf(address(board)), 0);
        assertEq(address(board).balance, 0);
        assertEq(board.orderCount(), 0);
        assertEq(board.MAX_DURATION(), 90 days);
        assertEq(board.MAX_DECIMALS(), 30);
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(OTCBoard.ZeroAddress.selector);
        new OTCBoard(address(0));
    }

    function test_noReceiveOrFallback() public {
        (bool ok,) = address(board).call{value: 1 ether}("");
        assertFalse(ok, "plain ETH transfer must fail");
        (ok,) = address(board).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok, "unknown selector must fail");
        (ok,) = address(board).call(hex"deadbeef");
        assertFalse(ok, "unknown selector without value must fail");
        assertEq(address(board).balance, 0);
    }

    // -------------------------------------------------------------------------------------
    // post
    // -------------------------------------------------------------------------------------

    function test_postRecordsOrderAndEmits() public {
        uint256 expiry = START + 1 days;
        vm.expectEmit(address(board));
        emit Posted(1, maker, address(desk), 100 ether, PRICE, expiry);
        uint256 id = _postDesk(100 ether, PRICE, expiry);

        assertEq(id, 1);
        assertEq(board.orderCount(), 1);
        OTCBoard.Order memory o = board.order(1);
        assertEq(o.maker, maker);
        assertEq(o.token, address(desk));
        assertEq(o.decimals, 18);
        assertFalse(o.cancelled);
        assertEq(o.amount, 100 ether);
        assertEq(o.remaining, 100 ether);
        assertEq(o.pricePerToken, PRICE);
        assertEq(o.expiry, expiry);
        assertEq(desk.balanceOf(address(board)), 100 ether);
        assertEq(desk.balanceOf(maker), 1_000_000 ether - 100 ether);
    }

    function test_postIdsStartAtOneAndIncrement() public {
        assertEq(_postDesk(1 ether, PRICE, START + 1 days), 1);
        assertEq(_postDesk(1 ether, PRICE, START + 1 days), 2);
        vm.prank(maker);
        assertEq(board.post(address(usd6), 1e6, PRICE, START + 1 days), 3);
        assertEq(board.orderCount(), 3);
    }

    function test_postRevertsOnZeroAmount() public {
        vm.prank(maker);
        vm.expectRevert(OTCBoard.ZeroAmount.selector);
        board.post(address(desk), 0, PRICE, START + 1 days);
    }

    function test_postRevertsOnZeroPrice() public {
        vm.prank(maker);
        vm.expectRevert(OTCBoard.ZeroPrice.selector);
        board.post(address(desk), 1 ether, 0, START + 1 days);
    }

    function test_postExpiryBoundaries() public {
        // expiry == now: rejected
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.InvalidExpiry.selector, START));
        board.post(address(desk), 1 ether, PRICE, START);

        // expiry in the past: rejected
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.InvalidExpiry.selector, START - 1));
        board.post(address(desk), 1 ether, PRICE, START - 1);

        // expiry == now + 1: accepted
        assertEq(_postDesk(1 ether, PRICE, START + 1), 1);

        // expiry == now + 90 days: accepted (inclusive)
        assertEq(_postDesk(1 ether, PRICE, START + 90 days), 2);

        // expiry == now + 90 days + 1: rejected
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.InvalidExpiry.selector, START + 90 days + 1));
        board.post(address(desk), 1 ether, PRICE, START + 90 days + 1);
    }

    function test_postRevertsWhenDecimalsReverts() public {
        RevertingDecimalsToken bad = new RevertingDecimalsToken();
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.UnsupportedToken.selector, address(bad)));
        board.post(address(bad), 1 ether, PRICE, START + 1 days);
    }

    function test_postRevertsWhenDecimalsMissing() public {
        NoDecimalsToken bad = new NoDecimalsToken();
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.UnsupportedToken.selector, address(bad)));
        board.post(address(bad), 1 ether, PRICE, START + 1 days);
    }

    function test_postRevertsWhenDecimalsExceed30() public {
        HugeDecimalsToken bad = new HugeDecimalsToken();
        bad.mint(maker, 1 ether);
        vm.prank(maker);
        bad.approve(address(board), type(uint256).max);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.UnsupportedToken.selector, address(bad)));
        board.post(address(bad), 1 ether, PRICE, START + 1 days);
    }

    function test_postAcceptsExactly30Decimals() public {
        MockERC20 t30 = new MockERC20("Thirty", "T30", 30);
        t30.mint(maker, 10 * 1e30);
        vm.prank(maker);
        t30.approve(address(board), type(uint256).max);
        vm.prank(maker);
        uint256 id = board.post(address(t30), 1e30, 1 ether, START + 1 days);
        assertEq(board.order(id).decimals, 30);
        // One whole token costs exactly the price.
        assertEq(board.quote(id, 1e30), 1 ether);
        // The largest possible fill still quotes without overflow.
        assertEq(board.quote(id, type(uint256).max), Math.mulDiv(type(uint256).max, 1 ether, 1e30, Math.Rounding.Ceil));
    }

    function test_postRevertsForZeroTokenAddress() public {
        vm.prank(maker);
        vm.expectRevert(OTCBoard.ZeroAddress.selector);
        board.post(address(0), 1 ether, PRICE, START + 1 days);
    }

    function test_postRevertsForEOAToken() public {
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.UnsupportedToken.selector, other));
        board.post(other, 1 ether, PRICE, START + 1 days);
    }

    function test_postRevertsWhenNothingReceived() public {
        NoOpTransferToken noop = new NoOpTransferToken();
        vm.prank(maker);
        vm.expectRevert(OTCBoard.NothingReceived.selector);
        board.post(address(noop), 1 ether, PRICE, START + 1 days);
        // The reverted post did not consume an id.
        assertEq(board.orderCount(), 0);
    }

    function test_postRevertsWhenTransferReturnsFalse() public {
        FalseReturnToken f = new FalseReturnToken();
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(f)));
        board.post(address(f), 1 ether, PRICE, START + 1 days);
    }

    function test_postRevertsWithoutAllowance() public {
        vm.prank(maker);
        desk.approve(address(board), 0);
        vm.prank(maker);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(board), 0, 1 ether)
        );
        board.post(address(desk), 1 ether, PRICE, START + 1 days);
    }

    function test_postFeeOnTransferRecordsNetAmount() public {
        vm.prank(maker);
        uint256 id = board.post(address(fee), 100 ether, PRICE, START + 1 days);
        OTCBoard.Order memory o = board.order(id);
        assertEq(o.amount, 99 ether, "recorded net of the 1% fee");
        assertEq(o.remaining, 99 ether);
        assertEq(fee.balanceOf(address(board)), 99 ether);
    }

    // -------------------------------------------------------------------------------------
    // fill
    // -------------------------------------------------------------------------------------

    function test_fillFullOrder() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        uint256 cost = board.quote(id, 100 ether);
        assertEq(cost, 0.1 ether);

        vm.expectEmit(address(board));
        emit Filled(id, maker, taker, 100 ether, cost);
        vm.prank(taker);
        board.fill{value: cost}(id, 100 ether);

        assertEq(board.order(id).remaining, 0);
        assertEq(desk.balanceOf(taker), 100 ether);
        assertEq(desk.balanceOf(address(board)), 0);
        assertEq(board.withdrawable(maker), cost);
        assertEq(address(board).balance, cost);
    }

    function test_fillPartialThenRest() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        vm.prank(taker);
        board.fill{value: 0.03 ether}(id, 30 ether);
        assertEq(board.order(id).remaining, 70 ether);

        vm.prank(other);
        board.fill{value: 0.07 ether}(id, 70 ether);
        assertEq(board.order(id).remaining, 0);
        assertEq(board.withdrawable(maker), 0.1 ether);
        assertEq(desk.balanceOf(taker), 30 ether);
        assertEq(desk.balanceOf(other), 70 ether);
    }

    function test_fillPartialCostRoundsUp() public {
        // price 3 wei per token, buy 1 base unit: 3 / 1e18 rounds up to 1 wei.
        uint256 id = _postDesk(10 ether, 3, START + 1 days);
        assertEq(board.quote(id, 1), 1);
        vm.prank(taker);
        board.fill{value: 1}(id, 1);
        assertEq(desk.balanceOf(taker), 1);
        assertEq(board.withdrawable(maker), 1);

        // 1e18 + 1 base units at 3 wei: exact would be 3.000000000000000003 -> 4 wei.
        assertEq(board.quote(id, 1e18 + 1), 4);
        vm.prank(taker);
        board.fill{value: 4}(id, 1e18 + 1);
        assertEq(board.withdrawable(maker), 5);

        // Paying the rounded-down value is rejected.
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.IncorrectPayment.selector, 3, 4));
        board.fill{value: 3}(id, 1e18 + 1);
    }

    function test_fillOneBaseUnitNeverFree() public {
        uint256 id = _postDesk(10 ether, 1, START + 1 days); // 1 wei per whole token
        assertEq(board.quote(id, 1), 1, "smallest fill costs at least 1 wei");
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.IncorrectPayment.selector, 0, 1));
        board.fill{value: 0}(id, 1);
        vm.prank(taker);
        board.fill{value: 1}(id, 1);
        assertEq(desk.balanceOf(taker), 1);
    }

    function test_fillRoundingCannotBeFarmedBySplitting() public {
        // 7 wei per whole token; splitting into many tiny fills only ever costs more, never less.
        uint256 id = _postDesk(10 ether, 7, START + 1 days);
        uint256 whole = board.quote(id, 1 ether);
        assertEq(whole, 7);
        uint256 total;
        for (uint256 i; i < 10; ++i) {
            uint256 c = board.quote(id, 0.1 ether);
            vm.prank(taker);
            board.fill{value: c}(id, 0.1 ether);
            total += c;
        }
        assertGe(total, whole, "split fills must not undercut the whole price");
        assertEq(desk.balanceOf(taker), 1 ether);
        assertEq(board.withdrawable(maker), total);
    }

    function test_fillRevertsOnOverpayment() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.IncorrectPayment.selector, 0.1 ether + 1, 0.1 ether));
        board.fill{value: 0.1 ether + 1}(id, 100 ether);
    }

    function test_fillRevertsOnUnderpayment() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.IncorrectPayment.selector, 0.1 ether - 1, 0.1 ether));
        board.fill{value: 0.1 ether - 1}(id, 100 ether);
    }

    function test_fillRevertsOnZeroAmount() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        vm.prank(taker);
        vm.expectRevert(OTCBoard.ZeroAmount.selector);
        board.fill{value: 0}(id, 0);
    }

    function test_fillRevertsWhenAmountExceedsRemaining() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.AmountExceedsRemaining.selector, 100 ether + 1, 100 ether));
        board.fill{value: 0.1 ether}(id, 100 ether + 1);

        vm.prank(taker);
        board.fill{value: 0.06 ether}(id, 60 ether);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.AmountExceedsRemaining.selector, 50 ether, 40 ether));
        board.fill{value: 0.05 ether}(id, 50 ether);
    }

    function test_fillRevertsForMaker() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        vm.deal(maker, 1 ether);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.MakerCannotFill.selector, id));
        board.fill{value: 0.1 ether}(id, 100 ether);
    }

    function test_fillRevertsForUnknownOrder() public {
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.UnknownOrder.selector, 1));
        board.fill{value: 1}(1, 1);

        _postDesk(100 ether, PRICE, START + 1 days);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.UnknownOrder.selector, 0));
        board.fill{value: 1}(0, 1);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.UnknownOrder.selector, 2));
        board.fill{value: 1}(2, 1);
    }

    function test_fillExpiryBoundary() public {
        uint256 expiry = START + 1 days;
        uint256 id = _postDesk(100 ether, PRICE, expiry);

        // One second before expiry: fillable.
        vm.warp(expiry - 1);
        vm.prank(taker);
        board.fill{value: 0.01 ether}(id, 10 ether);

        // Exactly at expiry: not fillable.
        vm.warp(expiry);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.OrderExpired.selector, id));
        board.fill{value: 0.01 ether}(id, 10 ether);

        // After expiry: not fillable.
        vm.warp(expiry + 1 days);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.OrderExpired.selector, id));
        board.fill{value: 0.01 ether}(id, 10 ether);
    }

    function test_fillRevertsWhenCancelled() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        vm.prank(maker);
        board.cancel(id);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.OrderCancelled.selector, id));
        board.fill{value: 0.1 ether}(id, 100 ether);
        assertEq(address(board).balance, 0);
    }

    function test_fillRevertsWhenFullyFilled() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        vm.prank(taker);
        board.fill{value: 0.1 ether}(id, 100 ether);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.AmountExceedsRemaining.selector, 1, 0));
        board.fill{value: 1}(id, 1);
    }

    function test_fillSixDecimalToken() public {
        // 1 SIX = 0.002 ETH. Buy 1.5 SIX (1_500_000 base units) -> 0.003 ETH.
        vm.prank(maker);
        uint256 id = board.post(address(usd6), 1_000e6, 0.002 ether, START + 1 days);
        assertEq(board.order(id).decimals, 6);
        assertEq(board.quote(id, 1_500_000), 0.003 ether);

        vm.prank(taker);
        board.fill{value: 0.003 ether}(id, 1_500_000);
        assertEq(usd6.balanceOf(taker), 1_500_000);
        assertEq(board.withdrawable(maker), 0.003 ether);

        // 1 base unit of a 6-decimal token at 0.002 ETH: 2e15 / 1e6 = 2e9 wei exactly.
        assertEq(board.quote(id, 1), 2e9);
        // 3 wei per whole token, 1 base unit -> 3/1e6 rounds up to 1 wei.
        vm.prank(maker);
        uint256 id2 = board.post(address(usd6), 1_000e6, 3, START + 1 days);
        assertEq(board.quote(id2, 1), 1);
        assertEq(board.quote(id2, 1e6), 3);
        assertEq(board.quote(id2, 1e6 + 1), 4);
    }

    function test_fillDecimalsFixedAtPostTime() public {
        // Even if the token's decimals() later changes its answer, quotes use the stored value.
        vm.prank(maker);
        uint256 id = board.post(address(usd6), 1_000e6, 1 ether, START + 1 days);
        assertEq(board.quote(id, 1e6), 1 ether);
        vm.mockCall(address(usd6), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        assertEq(usd6.decimals(), 18, "mock applied");
        assertEq(board.quote(id, 1e6), 1 ether, "quote unchanged");
        vm.prank(taker);
        board.fill{value: 1 ether}(id, 1e6);
        assertEq(usd6.balanceOf(taker), 1e6);
        vm.clearMockedCalls();
    }

    function test_fillFeeOnTransferDeliversLess() public {
        vm.prank(maker);
        uint256 id = board.post(address(fee), 100 ether, PRICE, START + 1 days);
        // 99 ether recorded. Fill all of it.
        uint256 cost = board.quote(id, 99 ether);
        vm.prank(taker);
        board.fill{value: cost}(id, 99 ether);
        assertEq(board.order(id).remaining, 0);
        assertEq(fee.balanceOf(taker), 98.01 ether, "taker receives 99 minus 1%");
        assertEq(fee.balanceOf(address(board)), 0, "board is not left short");
        assertEq(board.withdrawable(maker), cost);
    }

    function test_fillCreditsEthRejectingMaker() public {
        EthRejectingMaker m = new EthRejectingMaker(board);
        vm.prank(factory);
        desk.transfer(address(m), 100 ether);
        vm.prank(address(m));
        desk.approve(address(board), type(uint256).max);
        uint256 id = m.post(address(desk), 100 ether, PRICE, START + 1 days);

        vm.prank(taker);
        board.fill{value: 0.1 ether}(id, 100 ether);
        assertEq(desk.balanceOf(taker), 100 ether);
        assertEq(board.withdrawable(address(m)), 0.1 ether);

        // Its own withdraw fails but the credit is preserved.
        vm.expectRevert(OTCBoard.EthTransferFailed.selector);
        m.withdraw();
        assertEq(board.withdrawable(address(m)), 0.1 ether);
        assertEq(address(board).balance, 0.1 ether);
    }

    function test_fillManyOrdersSameToken() public {
        uint256 a = _postDesk(50 ether, PRICE, START + 1 days);
        uint256 b = _postDesk(70 ether, 2 * PRICE, START + 2 days);
        vm.prank(taker);
        board.fill{value: 0.05 ether}(a, 50 ether);
        assertEq(board.order(b).remaining, 70 ether, "other order untouched");
        vm.prank(taker);
        board.fill{value: 0.02 ether}(b, 10 ether);
        assertEq(board.order(b).remaining, 60 ether);
        assertEq(desk.balanceOf(address(board)), 60 ether);
        assertEq(board.withdrawable(maker), 0.07 ether);
    }

    // -------------------------------------------------------------------------------------
    // cancel
    // -------------------------------------------------------------------------------------

    function test_cancelReturnsFullAmount() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        uint256 before = desk.balanceOf(maker);
        vm.expectEmit(address(board));
        emit Cancelled(id, maker, 100 ether);
        vm.prank(maker);
        board.cancel(id);
        OTCBoard.Order memory o = board.order(id);
        assertTrue(o.cancelled);
        assertEq(o.remaining, 0);
        assertEq(o.amount, 100 ether, "original amount is kept for the record");
        assertEq(desk.balanceOf(maker), before + 100 ether);
        assertEq(desk.balanceOf(address(board)), 0);
    }

    function test_cancelAfterPartialFillReturnsRemainder() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        vm.prank(taker);
        board.fill{value: 0.03 ether}(id, 30 ether);
        uint256 before = desk.balanceOf(maker);
        vm.expectEmit(address(board));
        emit Cancelled(id, maker, 70 ether);
        vm.prank(maker);
        board.cancel(id);
        assertEq(desk.balanceOf(maker), before + 70 ether);
        assertEq(board.withdrawable(maker), 0.03 ether, "proceeds untouched by cancel");
        assertEq(desk.balanceOf(address(board)), 0);
    }

    function test_cancelAfterExpiry() public {
        uint256 expiry = START + 1 days;
        uint256 id = _postDesk(100 ether, PRICE, expiry);
        vm.warp(expiry + 30 days);
        uint256 before = desk.balanceOf(maker);
        vm.prank(maker);
        board.cancel(id);
        assertEq(desk.balanceOf(maker), before + 100 ether);
        assertTrue(board.order(id).cancelled);
    }

    function test_cancelAtExactExpiry() public {
        uint256 expiry = START + 1 days;
        uint256 id = _postDesk(100 ether, PRICE, expiry);
        vm.warp(expiry);
        vm.prank(maker);
        board.cancel(id);
        assertTrue(board.order(id).cancelled);
    }

    function test_cancelRevertsForNonMaker() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.NotMaker.selector, id));
        board.cancel(id);
    }

    function test_cancelRevertsTwice() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        vm.prank(maker);
        board.cancel(id);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.NothingToCancel.selector, id));
        board.cancel(id);
    }

    function test_cancelRevertsWhenFullyFilled() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        vm.prank(taker);
        board.fill{value: 0.1 ether}(id, 100 ether);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.NothingToCancel.selector, id));
        board.cancel(id);
        assertFalse(board.order(id).cancelled, "a fully filled order is not marked cancelled");
    }

    function test_cancelRevertsForUnknownOrder() public {
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.UnknownOrder.selector, 5));
        board.cancel(5);
    }

    function test_cancelFeeOnTransferReturnsNetRemainder() public {
        vm.prank(maker);
        uint256 id = board.post(address(fee), 100 ether, PRICE, START + 1 days);
        uint256 before = fee.balanceOf(maker);
        vm.prank(maker);
        board.cancel(id);
        assertEq(fee.balanceOf(maker), before + 98.01 ether, "99 returned minus 1% fee");
        assertEq(fee.balanceOf(address(board)), 0);
    }

    // -------------------------------------------------------------------------------------
    // withdraw
    // -------------------------------------------------------------------------------------

    function test_withdrawSendsWholeCreditOnce() public {
        uint256 id = _postDesk(100 ether, PRICE, START + 1 days);
        vm.prank(taker);
        board.fill{value: 0.04 ether}(id, 40 ether);
        vm.prank(other);
        board.fill{value: 0.06 ether}(id, 60 ether);
        assertEq(board.withdrawable(maker), 0.1 ether);

        uint256 before = maker.balance;
        vm.expectEmit(address(board));
        emit Withdrawn(maker, 0.1 ether);
        vm.prank(maker);
        board.withdraw();
        assertEq(maker.balance, before + 0.1 ether);
        assertEq(board.withdrawable(maker), 0);
        assertEq(address(board).balance, 0);

        vm.prank(maker);
        vm.expectRevert(OTCBoard.NothingToWithdraw.selector);
        board.withdraw();
    }

    function test_withdrawRevertsOnZero() public {
        vm.prank(other);
        vm.expectRevert(OTCBoard.NothingToWithdraw.selector);
        board.withdraw();
    }

    function test_withdrawIsPerAccount() public {
        uint256 a = _postDesk(10 ether, PRICE, START + 1 days);
        vm.prank(factory);
        desk.transfer(other, 10 ether);
        vm.prank(other);
        desk.approve(address(board), type(uint256).max);
        vm.prank(other);
        uint256 b = board.post(address(desk), 10 ether, PRICE, START + 1 days);

        vm.prank(taker);
        board.fill{value: 0.01 ether}(a, 10 ether);
        vm.prank(taker);
        board.fill{value: 0.01 ether}(b, 10 ether);

        vm.prank(maker);
        board.withdraw();
        assertEq(board.withdrawable(other), 0.01 ether, "another maker's credit is untouched");
        assertEq(address(board).balance, 0.01 ether);
    }

    // -------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------

    function test_viewsRevertForUnknownIds() public {
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.UnknownOrder.selector, 0));
        board.order(0);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.UnknownOrder.selector, 1));
        board.order(1);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.UnknownOrder.selector, 1));
        board.quote(1, 1);
        _postDesk(1 ether, PRICE, START + 1 days);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.UnknownOrder.selector, 2));
        board.order(2);
    }

    function test_quoteRevertsOnZeroAmount() public {
        uint256 id = _postDesk(1 ether, PRICE, START + 1 days);
        vm.expectRevert(OTCBoard.ZeroAmount.selector);
        board.quote(id, 0);
    }

    function test_quoteMatchesFillCost() public {
        uint256 id = _postDesk(100 ether, 123_456_789, START + 1 days);
        uint256 amount = 12_345_678_901_234_567;
        uint256 q = board.quote(id, amount);
        assertEq(q, _cost(amount, 123_456_789, 18));
        vm.prank(taker);
        board.fill{value: q}(id, amount);
        assertEq(board.withdrawable(maker), q);
    }

    // -------------------------------------------------------------------------------------
    // Reentrancy
    // -------------------------------------------------------------------------------------

    function test_reentrancyOnWithdrawIsBlocked() public {
        ReentrantWithdrawer m = new ReentrantWithdrawer(board);
        vm.prank(factory);
        desk.transfer(address(m), 100 ether);
        vm.prank(address(m));
        desk.approve(address(board), type(uint256).max);
        uint256 id = m.post(address(desk), 100 ether, PRICE, START + 1 days);
        vm.prank(taker);
        board.fill{value: 0.1 ether}(id, 100 ether);

        m.withdraw();
        assertTrue(m.reentered(), "hook ran");
        assertFalse(m.reentrySucceeded(), "reentrant withdraw must fail");
        assertEq(address(m).balance, 0.1 ether, "paid exactly once");
        assertEq(address(board).balance, 0);
        assertEq(board.withdrawable(address(m)), 0);
    }

    function test_reentrancyOnFillThroughTokenCallbackIsBlocked() public {
        CallbackERC20 cb = new CallbackERC20();
        cb.mint(maker, 1_000 ether);
        vm.prank(maker);
        cb.approve(address(board), type(uint256).max);
        vm.prank(maker);
        uint256 id = board.post(address(cb), 100 ether, PRICE, START + 1 days);

        ReentrantTaker t = new ReentrantTaker(board);
        vm.deal(address(t), 1 ether);
        cb.setHook(address(t), true);
        // Try to buy another 50 for the correct price from inside the callback.
        t.arm(id, 50 ether, 0.05 ether);

        t.fill{value: 0.05 ether}(id, 50 ether);
        assertTrue(t.attacked(), "callback ran");
        assertFalse(t.reentrySucceeded(), "reentrant fill must fail");
        assertEq(bytes4(t.reentryError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(cb.balanceOf(address(t)), 50 ether, "only the outer fill delivered");
        assertEq(board.order(id).remaining, 50 ether);
        assertEq(board.withdrawable(maker), 0.05 ether);
        assertEq(address(board).balance, 0.05 ether);
        assertEq(cb.balanceOf(address(board)), 50 ether);
    }

    function test_reentrancyOnCancelThroughTokenCallbackIsBlocked() public {
        CallbackERC20 cb = new CallbackERC20();
        ReentrantMaker m = new ReentrantMaker(board);
        cb.mint(address(m), 1_000 ether);
        vm.prank(address(m));
        cb.approve(address(board), type(uint256).max);
        uint256 id = m.post(address(cb), 100 ether, PRICE, START + 1 days);
        cb.setHook(address(m), true);

        vm.prank(taker);
        board.fill{value: 0.03 ether}(id, 30 ether);

        m.cancel();
        assertTrue(m.attacked(), "callback ran");
        assertFalse(m.cancelReentrySucceeded(), "double cancel must fail");
        assertEq(bytes4(m.cancelReentryError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(cb.balanceOf(address(m)), 970 ether, "got the 70 remainder exactly once");
        assertEq(cb.balanceOf(address(board)), 0);
        assertTrue(board.order(id).cancelled);
    }

    // -------------------------------------------------------------------------------------
    // Fuzz
    // -------------------------------------------------------------------------------------

    function testFuzz_quoteNeverFreeAndNeverUnderpays(uint256 amount, uint256 price, uint8 dec) public {
        dec = uint8(bound(dec, 0, 30));
        price = bound(price, 1, 1e30);
        amount = bound(amount, 1, 1e40);
        MockERC20 t = new MockERC20("F", "F", dec);
        t.mint(maker, amount);
        vm.prank(maker);
        t.approve(address(board), type(uint256).max);
        vm.prank(maker);
        uint256 id = board.post(address(t), amount, price, START + 1 days);

        uint256 q = board.quote(id, amount);
        assertGe(q, 1, "never free");
        // q * 10^dec >= amount * price (no underpayment), and q is the smallest such integer.
        uint256 denom = 10 ** uint256(dec);
        assertTrue(Math.mulDiv(q, denom, 1) >= Math.mulDiv(amount, price, 1) || q == type(uint256).max);
        if (q > 1) {
            assertLt(Math.mulDiv(q - 1, denom, 1), Math.mulDiv(amount, price, 1), "q is minimal");
        }
    }

    function testFuzz_partialFillsConserveTokensAndEth(uint256 total, uint256 first, uint256 price) public {
        total = bound(total, 2, 1_000_000 ether);
        first = bound(first, 1, total - 1);
        price = bound(price, 1, 1_000 ether);
        uint256 id = _postDesk(total, price, START + 1 days);

        uint256 c1 = board.quote(id, first);
        vm.deal(taker, c1);
        vm.prank(taker);
        board.fill{value: c1}(id, first);
        uint256 rest = total - first;
        uint256 c2 = board.quote(id, rest);
        vm.deal(other, c2);
        vm.prank(other);
        board.fill{value: c2}(id, rest);

        assertEq(board.order(id).remaining, 0);
        assertEq(desk.balanceOf(taker) + desk.balanceOf(other), total);
        assertEq(desk.balanceOf(address(board)), 0);
        assertEq(board.withdrawable(maker), c1 + c2);
        assertEq(address(board).balance, c1 + c2);
        assertGe(c1 + c2, _cost(total, price, 18), "split never cheaper than whole");
    }

    function testFuzz_wrongPaymentAlwaysReverts(uint256 amount, uint256 price, uint256 sent) public {
        amount = bound(amount, 1, 1_000_000 ether);
        price = bound(price, 1, 1_000 ether);
        uint256 id = _postDesk(amount, price, START + 1 days);
        uint256 cost = board.quote(id, amount);
        sent = bound(sent, 0, 2 * cost + 1);
        vm.assume(sent != cost);
        vm.deal(taker, sent);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(OTCBoard.IncorrectPayment.selector, sent, cost));
        board.fill{value: sent}(id, amount);
    }
}
