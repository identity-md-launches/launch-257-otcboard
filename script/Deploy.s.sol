// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {OTCBoard} from "../src/OTCBoard.sol";

/// @notice Local / dry-run deployment helper. Production deployment goes through the project
///         factory driven by launch.json, which deploys LaunchToken and then OTCBoard with
///         constructorArgs ["$token"]. This script only mirrors that sequence for local checks
///         and never touches a wallet key by itself.
contract DeployScript is Script {
    struct Deployment {
        LaunchToken token;
        OTCBoard board;
    }

    /// @dev Deploys the token and the board in factory order. Used directly by tests.
    function deploy() public returns (Deployment memory d) {
        d.token = new LaunchToken();
        d.board = new OTCBoard(address(d.token));
    }

    function run() external returns (Deployment memory d) {
        vm.startBroadcast();
        d = deploy();
        vm.stopBroadcast();
    }
}
