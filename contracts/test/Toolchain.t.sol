// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// @notice Phase 1 smoke tests: the compiler, forge-std remapping, cheatcodes and the
///         deploy script all work. Real contract tests arrive with the contracts in Phase 2.
contract ToolchainTest is Test {
    function test_ForgeStdCheatcodesWork() public {
        vm.warp(1_700_000_000);
        assertEq(block.timestamp, 1_700_000_000);
    }

    function testFuzz_FuzzerRuns(uint128 a, uint128 b) public pure {
        // uint256 cannot overflow when adding two uint128 values.
        assertGe(uint256(a) + uint256(b), uint256(a));
    }

    function test_DeployScriptWritesDeploymentFile() public {
        // A chain ID no real deployment uses, so the test never touches deployments/31337.json.
        vm.chainId(999_001);
        new Deploy().run();
        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid);
        vm.removeFile(path);
    }
}
