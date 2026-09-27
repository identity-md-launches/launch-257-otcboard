# Release Desk: DESK launch token and OTCBoard

Foundry project for the Release Desk launch on Sepolia (chain id 11155111): a fixed-supply
launch token (DESK) and one application contract (OTCBoard), a fixed-price board where makers
sell any ERC-20 for ETH.

This assignment delivers the contracts, tests and ABI exports. The manifest (`launch.json`),
the independent adversarial review, the factory deployment and the website are separate
assignments and are not part of this tree.

## Layout

| Path | Purpose |
| --- | --- |
| `src/LaunchToken.sol` | `LaunchToken`: Desk (DESK), fixed supply 1,000,000,000 × 10^18, minted to `msg.sender` |
| `src/OTCBoard.sol` | `OTCBoard`: the order board, constructor argument `featuredToken_` = `$token` |
| `test/LaunchToken.t.sol` | Token supply, metadata, transfer, absence of admin paths, runtime opcode scan |
| `test/OTCBoard.t.sol` | Unit, failure-path, boundary, reentrancy and fuzz tests for the board |
| `test/OTCBoard.invariants.t.sol` | Stateful invariants: escrow covers remainders, ETH equals credits |
| `test/Deploy.t.sol` | Calls the deploy script's `deploy()` directly |
| `test/mocks/` | Mock tokens (6/0/30 decimals, fee-on-transfer, callback, broken decimals) and adversarial actors |
| `script/Deploy.s.sol` | Local dry-run deployment in factory order; production uses the project factory |
| `docs/abi/LaunchToken.json`, `docs/abi/OTCBoard.json` | ABI exports from `forge inspect` |
| `lib/forge-std`, `lib/openzeppelin-contracts` | Vendored as ordinary files (no submodules) |

Compiler: `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`, optimizer 200 runs.
`ffi` is off and `fs_permissions` is empty. Tests read no environment variables.

```
forge build
forge test
forge fmt --check
```

## LaunchToken (DESK)

- OpenZeppelin `ERC20` with name `Desk`, symbol `DESK`, 18 decimals.
- No constructor arguments. The constructor mints exactly `1_000_000_000 * 10**18` to
  `msg.sender`, which is the project factory at launch.
- No mint, burn, owner, pause, blocklist, fee, hook or upgrade path. The runtime contains no
  `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` (tested).
- The factory keeps the whole supply for LP and rewards. OTCBoard holds no DESK at deploy and
  never needs a DESK balance.

## OTCBoard

### Constructor and deployment parameters

| Parameter | Type | Manifest value | Meaning |
| --- | --- | --- | --- |
| `featuredToken_` | `address` | `$token` | The DESK address. Exposed as `featuredToken()` for the site's default list. Reverts on zero. |

The constructor is nonpayable, performs no external calls, stores one immutable, and has no
dependency on `msg.sender`. There is no owner and no `$owner` argument: the request names none.
No other configuration exists. Dependency order in the manifest: `LaunchToken` first, then
`OTCBoard` with `constructorArgs: ["$token"]`. Suggested identifier: `OTCBoard`.

Constants: `MAX_DURATION = 90 days`, `MAX_DECIMALS = 30`.

Runtime size is about 8.5 KB, far below the EIP-170 limit; the runtime contains no
`DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`. There is no `receive` or `fallback`, so ETH can
only enter through `fill`.

### Behaviour

- `post(token, amount, pricePerToken, expiry)` → `id`
  - Requires `amount > 0`, `pricePerToken > 0` (wei per whole token, i.e. per `10**decimals`
    base units) and `block.timestamp < expiry <= block.timestamp + 90 days`.
  - Reads `decimals()` once with a `staticcall`. A token whose `decimals()` reverts, is
    missing, returns malformed data or exceeds 30 is rejected with `UnsupportedToken`.
  - Pulls `amount` with `SafeERC20.safeTransferFrom` and records the balance delta as the
    order's `amount` and `remaining`. Zero received reverts with `NothingReceived`.
  - Ids start at 1 and increment. A reverted post consumes no id.
  - Emits `Posted(id, maker, token, amountReceived, pricePerToken, expiry)`.
- `fill(orderId, amount)` payable
  - Requires: order exists, not cancelled, `block.timestamp < expiry`, caller is not the
    maker, `0 < amount <= remaining`.
  - `cost = Math.mulDiv(amount, pricePerToken, 10**decimals, Rounding.Ceil)`, so one base
    unit always costs at least 1 wei. `msg.value` must equal `cost` exactly; more or less
    reverts with `IncorrectPayment(sent, required)`.
  - Effects first: `remaining -= amount`, `withdrawable[maker] += cost`. Then the tokens are
    pushed to the taker with `safeTransfer`. ETH is never pushed to the maker.
  - Emits `Filled(id, maker, taker, amount, cost)`.
- `cancel(orderId)`
  - Maker only, while `remaining > 0` and not already cancelled, before or after expiry.
  - Marks the order cancelled, zeroes `remaining`, returns the remainder to the maker.
  - A fully filled order cannot be cancelled and is not marked cancelled.
  - Emits `Cancelled(id, maker, remainder)`.
- `withdraw()`
  - Sends the caller's entire ETH credit with `call`, reverts on zero credit and on a failed
    send (credit is preserved in that case).
  - Emits `Withdrawn(account, amount)`.
- Orders cannot be edited: cancel and repost.
- Views: `order(id)`, `orderCount()`, `quote(id, amount)`, `withdrawable(address)`,
  `featuredToken()`. `order` and `quote` revert with `UnknownOrder` for id 0 or an id above
  `orderCount`. `quote` reverts on zero amount and does not check expiry, cancellation or
  remaining.
- `post`, `fill`, `cancel` and `withdraw` are `nonReentrant` and follow
  checks-effects-interactions.

### Token assumptions

- **Decimals are fixed at post time.** If a token changes its `decimals()` answer later, quotes
  and fills for existing orders keep using the stored value (tested).
- **Fee-on-transfer tokens** are supported on a best-effort basis: the order records the net
  amount received; a fill transfers `amount` from the board, so the taker receives less than
  `amount`; a cancel returns the remainder minus the token's fee. The board is never left short
  because remainders are counted against what actually arrived.
- **Rebasing tokens are unsupported.** A negative rebase can make the board's balance smaller
  than the recorded remainders, in which case later fills or cancels revert for lack of balance.
  A positive rebase leaves surplus tokens stranded in the contract; there is no sweep.
- **Tokens with transfer hooks** (ERC-777, ERC-1363 style) are tolerated: reentry into any
  board function during the hook reverts with `ReentrancyGuardReentrantCall` (tested for
  `fill` and `cancel`).
- **Blocklisting / pausable tokens** can make an individual order's fill or cancel revert. This
  affects only that token's orders; ETH credits and other tokens are unaffected.
- Tokens that return `false` or no data are handled by `SafeERC20` (tested).

### Economic notes

- Rounding is always up in the taker's payment. Splitting a fill into smaller pieces can only
  cost the taker the same or more, never less (unit and fuzz tested). The dust from rounding
  accrues to the maker.
- Prices are quoted in wei per whole token. For a token with 30 decimals and `pricePerToken`
  up to `1e30`, the largest possible fill still quotes without overflow (`mulDiv` is 512-bit).
- Expiry is strict: a fill at `block.timestamp == expiry` reverts. Cancel works at and after
  expiry. Validators can nudge `block.timestamp` by a few seconds; makers should not rely on
  second-level expiry precision.
- Front-running: fills are first-come. Two takers racing for the same remainder means the
  second reverts with `AmountExceedsRemaining` and pays only gas. A maker can cancel ahead of
  a pending fill, in which case the fill reverts and no ETH is taken.

### Operational responsibilities

- **Makers** approve the board for the token before `post`, monitor their orders, and call
  `withdraw()` to collect ETH. Proceeds are never pushed. Contract makers must be able to
  receive ETH via `call` or they cannot withdraw (the credit stays recorded).
- **Takers** call `quote(id, amount)` and send exactly that value in the same transaction
  flow. Checking `order(id)` for `remaining`, `expiry` and `cancelled` before filling avoids
  wasted gas.
- **The site** lists orders from `Posted` / `Filled` / `Cancelled` events and the `order`
  view only. There is no admin, no pause and no upgrade; nothing to operate after deployment.
- **Nobody** can recover tokens sent directly to the board outside `post`, or ETH that cannot
  be sent by `call`. There is no sweep function by design.

## Tests

`forge test` runs 67 tests across four suites, plus 3 stateful invariants (64 runs × 32 calls
with `fail_on_revert = true`). Coverage requested by the workflow:

- partial fills whose cost rounds up, and proof that splitting cannot undercut the whole price
- exact `msg.value`: over- and underpayment revert (unit and fuzz)
- expiry at the boundary for both `post` and `fill`
- cancel after partial fills, at and after expiry, twice, by non-maker, when fully filled
- a 6-decimal token, a 0-decimal token (invariants), a 30-decimal token, a 31-decimal token
- a fee-on-transfer token on post, fill and cancel
- reentrancy through a callback token on `fill` and `cancel`, and through `receive` on `withdraw`
- invariants: per-token escrow ≥ sum of remainders of non-cancelled orders; board ETH == sum
  of withdrawable credits

Tests use no environment variables and no `ffi`, fix time with `vm.warp`, and pass in any
order. The protected floor tests in `.imd/reads/protected/` were run locally against the
compiled creation code with a simulated factory and pass; they are not part of this tree.

## Unresolved deployment choices and review items

- The final review should confirm the manifest lists `LaunchToken` as the token and
  `OTCBoard` with `constructorArgs: ["$token"]`, no `$owner`, and the pool parameters from
  policy.
- Tests are not an audit. The independent adversarial review is expected to attack rounding,
  reentrancy through hooked tokens, filling cancelled or expired orders, and decimals mismatch
  between post and fill; the corresponding tests are named above as starting points.
- This assignment performs no transactions and holds no keys. `script/Deploy.s.sol` is a
  local dry-run helper only; production deployment is the factory's.
