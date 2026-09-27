// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Desk (DESK) launch token
/// @notice Fixed-supply ERC-20 for the Release Desk launch. The whole supply of
///         1,000,000,000 DESK (10^27 minor units, 18 decimals) is minted once to the
///         deployer, which is the project factory. There is no owner, minter, pauser,
///         blocklist, fee or upgrade path: the constructor is the only place supply changes.
contract LaunchToken is ERC20 {
    /// @notice Total supply in minor units: 1,000,000,000 * 10^18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("Desk", "DESK") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
