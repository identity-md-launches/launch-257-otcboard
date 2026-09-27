// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployScript} from "../script/Deploy.s.sol";

contract DeployScriptTest is Test {
    function test_deployWiresBoardToToken() public {
        DeployScript s = new DeployScript();
        DeployScript.Deployment memory d = s.deploy();
        assertEq(d.board.featuredToken(), address(d.token));
        assertEq(d.token.totalSupply(), 1e27);
        // The script contract is msg.sender for the constructor, mirroring the factory.
        assertEq(d.token.balanceOf(address(s)), 1e27);
        assertEq(d.token.balanceOf(address(d.board)), 0, "board holds no DESK at deploy");
        assertEq(d.board.orderCount(), 0);
    }
}
