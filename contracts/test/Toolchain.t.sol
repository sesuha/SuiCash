// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {SeedDemo} from "../script/SeedDemo.s.sol";
import {PolicyVault} from "../src/PolicyVault.sol";
import {SavingsPool} from "../src/SavingsPool.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MockUSDC} from "../src/test/MockUSDC.sol";

/// @notice Smoke tests for the toolchain and the deploy and seed scripts.
contract ToolchainTest is Test {
    function test_ForgeStdCheatcodesWork() public {
        vm.warp(1_700_000_000);
        assertEq(block.timestamp, 1_700_000_000);
    }

    function test_DeployContracts_WiresPoolAndFactory() public {
        Deploy.Deployment memory d = new Deploy().deployContracts(address(0), address(this));
        assertEq(MockUSDC(d.usdc).decimals(), 6);
        assertEq(SavingsPool(d.savingsPool).asset(), d.usdc);
        assertEq(SavingsPool(d.savingsPool).owner(), address(this));
        assertEq(VaultFactory(d.vaultFactory).savingsPool(), d.savingsPool);
    }

    function test_DeployContracts_UsesGivenUsdc() public {
        address circleUsdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        vm.etch(circleUsdc, address(new MockUSDC()).code);
        Deploy.Deployment memory d = new Deploy().deployContracts(circleUsdc, address(this));
        assertEq(d.usdc, circleUsdc);
        assertEq(SavingsPool(d.savingsPool).asset(), circleUsdc);
    }

    function test_DeployRun_RefusesMainnets() public {
        Deploy deploy = new Deploy();
        vm.chainId(8453); // Base mainnet
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, 8453));
        deploy.run();
        vm.chainId(1); // Ethereum mainnet
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, 1));
        deploy.run();
    }

    function test_SeedDemo_ContactsAreDistinctAndCapped() public {
        SeedDemo.Contact[4] memory c = new SeedDemo().demoContacts();
        for (uint256 i = 0; i < c.length; ++i) {
            assertTrue(c[i].addr != address(0));
            assertGt(c[i].cap, 0);
            assertLe(c[i].cap, 500e6);
            for (uint256 j = i + 1; j < c.length; ++j) {
                assertTrue(c[i].addr != c[j].addr);
            }
        }
        assertEq(c[0].name, "Landlord");
    }

    function test_FactoryVault_CanBeSeededLikeTheScript() public {
        Deploy.Deployment memory d = new Deploy().deployContracts(address(0), address(this));
        PolicyVault vault = PolicyVault(VaultFactory(d.vaultFactory).createVault());
        vault.setTokenLimits(d.usdc, 500e6, 1000e6);
        vault.setMinBuffer(d.usdc, 50e6);
        SeedDemo.Contact[4] memory c = new SeedDemo().demoContacts();
        for (uint256 i = 0; i < c.length; ++i) {
            vault.addRecipient(c[i].addr, c[i].cap);
        }
        (bool enabled, uint128 perTx, uint128 daily) = vault.tokens(d.usdc);
        assertTrue(enabled);
        assertEq(perTx, 500e6);
        assertEq(daily, 1000e6);
        assertEq(vault.owner(), address(this));
    }
}
