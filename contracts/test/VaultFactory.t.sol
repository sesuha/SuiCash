// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PolicyVault} from "../src/PolicyVault.sol";
import {SavingsPool} from "../src/SavingsPool.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MockUSDC} from "../src/test/MockUSDC.sol";

contract VaultFactoryTest is Test {
    MockUSDC internal usdc;
    SavingsPool internal pool;
    VaultFactory internal factory;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockUSDC();
        pool = new SavingsPool(usdc, address(this));
        factory = new VaultFactory(address(pool));
    }

    function test_CreateVault_DeploysAtPredictedAddressAndEmits() public {
        address predicted = factory.predictVault(alice);
        assertEq(predicted.code.length, 0);
        vm.expectEmit(address(factory));
        emit VaultFactory.VaultCreated(alice, predicted);
        vm.prank(alice);
        address vault = factory.createVault();
        assertEq(vault, predicted);
        assertGt(vault.code.length, 0);
        assertEq(factory.vaultOf(alice), vault);
    }

    function test_CreateVault_IsOwnedByCallerAndStartsLocked() public {
        vm.prank(alice);
        PolicyVault vault = PolicyVault(factory.createVault());
        assertEq(vault.owner(), alice);
        assertEq(vault.savingsPool(), address(pool));
        assertEq(vault.agent(), address(0));
        assertEq(vault.guardian(), address(0));
        assertEq(vault.recipientDelay(), 1 hours);
        (bool enabled,,) = vault.tokens(address(usdc));
        assertFalse(enabled); // no token can move until the owner enables one
        assertFalse(vault.isSessionActive());
    }

    function test_CreateVault_RevertsOnSecondCall() public {
        vm.startPrank(alice);
        address vault = factory.createVault();
        vm.expectRevert(abi.encodeWithSelector(VaultFactory.VaultAlreadyExists.selector, alice, vault));
        factory.createVault();
        vm.stopPrank();
    }

    function test_CreateVault_DifferentOwnersGetIsolatedVaults() public {
        vm.prank(alice);
        PolicyVault aliceVault = PolicyVault(factory.createVault());
        vm.prank(bob);
        PolicyVault bobVault = PolicyVault(factory.createVault());
        assertTrue(address(aliceVault) != address(bobVault));
        assertEq(bobVault.owner(), bob);

        // Alice cannot configure Bob's vault.
        vm.expectRevert();
        vm.prank(alice);
        bobVault.setAgent(alice, uint64(block.timestamp + 1 days));
    }

    function testFuzz_PredictVault_MatchesCreate(address owner) public {
        vm.assume(owner != address(0));
        assumeNotForgeAddress(owner);
        address predicted = factory.predictVault(owner);
        vm.prank(owner);
        assertEq(factory.createVault(), predicted);
    }
}
