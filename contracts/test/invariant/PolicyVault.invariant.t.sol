// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PolicyVault} from "../../src/PolicyVault.sol";
import {SavingsPool} from "../../src/SavingsPool.sol";
import {MockUSDC} from "../../src/test/MockUSDC.sol";
import {VaultHandler} from "./VaultHandler.sol";

/// @notice The eight vault invariants from handbook 2.7, checked after every random call sequence.
contract PolicyVaultInvariantTest is Test {
    MockUSDC internal usdc;
    SavingsPool internal pool;
    PolicyVault internal vault;
    VaultHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal agent = makeAddr("agent");

    function setUp() public {
        vm.warp(1_750_000_000);
        usdc = new MockUSDC();
        pool = new SavingsPool(usdc, owner);
        vault = new PolicyVault(owner, address(pool));

        address[] memory allowed = new address[](3);
        allowed[0] = makeAddr("alice");
        allowed[1] = makeAddr("bob");
        allowed[2] = makeAddr("carol");
        address[] memory outsiders = new address[](3);
        outsiders[0] = makeAddr("attacker");
        // A look-alike of alice's address and the hostile token's "send everything here" target.
        outsiders[1] = address(uint160(allowed[0]) ^ 1);
        outsiders[2] = address(0xdEaD);
        address pending = makeAddr("notYetActive");

        uint64 validUntil = uint64(block.timestamp + 7 days);
        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setTokenLimits(address(usdc), 500e6, 1000e6);
        vault.setMinBuffer(address(usdc), 50e6);
        vault.addRecipient(allowed[0], 500e6);
        vault.addRecipient(allowed[1], 300e6);
        vault.addRecipient(allowed[2], 200e6);
        vault.setAgent(agent, validUntil);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours); // the three recipients activate

        vm.startPrank(owner);
        vault.setRecipientDelay(30 days);
        vault.addRecipient(pending, 500e6); // active only after 30 days
        vm.stopPrank();

        usdc.mint(address(vault), 3000e6);

        handler = new VaultHandler(vault, usdc, pool, owner, guardian, agent, allowed, pending, outsiders, validUntil);
        targetContract(address(handler));
    }

    /// @dev Inv 1-8: every check the handler runs after each successful call.
    function invariant_NoViolationRecorded() public view {
        assertFalse(handler.violated(), handler.violation());
    }

    /// @dev Inv 1: agent spend per day never exceeds the highest daily cap in force that day.
    function invariant_1_DailySpendWithinCap() public view {
        assertLe(vault.spentToday(address(usdc)), handler.ghostMaxDailyCapToday());
        assertLe(handler.ghostOutflowToday(), handler.ghostMaxDailyCapToday());
    }

    /// @dev Inv 2: non-allowlisted and not-yet-active recipients never receive anything.
    function invariant_2_OutsidersNeverPaid() public view {
        address[] memory outsiders = handler.outsiders();
        for (uint256 i = 0; i < outsiders.length; ++i) {
            assertEq(usdc.balanceOf(outsiders[i]), 0, "an outsider was paid");
        }
        assertEq(usdc.balanceOf(handler.pendingRecipient()), 0, "a not-yet-active recipient was paid");
    }

    /// @dev Inv 3: after revoke or expiry there is no active session.
    function invariant_3_NoSessionAfterRevokeOrExpiry() public view {
        if (handler.ghostRevoked() || block.timestamp > handler.ghostValidUntil()) {
            assertFalse(vault.isSessionActive());
        }
    }

    /// @dev Inv 5: the buffer holds whenever the agent could have acted (funds only fall below it
    ///      through the owner, and the owner never withdraws in this run).
    function invariant_5_BufferHolds() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.minBuffer(address(usdc)));
    }

    /// @dev Inv 7: caps never exceed the highest values a timelocked increase legitimately applied.
    function invariant_7_CapsNeverRiseWithoutTimelock() public view {
        (, uint128 perTx, uint128 daily) = vault.tokens(address(usdc));
        assertLe(perTx, handler.ghostPerTxUpper());
        assertLe(daily, handler.ghostDailyUpper());
    }

    /// @dev Inv 8: the vault never holds a standing allowance, and USDC is conserved.
    function invariant_8_NoAllowanceAndConservation() public view {
        assertEq(usdc.allowance(address(vault), address(pool)), 0);
        uint256 known = usdc.balanceOf(address(vault)) + usdc.balanceOf(address(pool));
        address[] memory allowed = handler.allowed();
        for (uint256 i = 0; i < allowed.length; ++i) {
            known += usdc.balanceOf(allowed[i]);
        }
        assertEq(known, usdc.totalSupply(), "USDC left the vault, pool and allowlisted recipients");
    }

    /// @dev Shows the run actually exercised the vault: logged per run with -vv.
    function afterInvariant() public view {
        assertGt(handler.blockedAgentCalls() + handler.successfulAgentPayments(), 0);
        console.log("agent payments executed:", handler.successfulAgentPayments());
        console.log("agent calls blocked:", handler.blockedAgentCalls());
        bytes4[11] memory reasons = [
            PolicyVault.WalletPaused.selector,
            PolicyVault.NotAgent.selector,
            PolicyVault.SessionExpired.selector,
            PolicyVault.InvalidAmount.selector,
            PolicyVault.RecipientNotAllowed.selector,
            PolicyVault.RecipientNotActiveYet.selector,
            PolicyVault.IntentAlreadyUsed.selector,
            PolicyVault.ExceedsPerTxLimit.selector,
            PolicyVault.ExceedsRecipientLimit.selector,
            PolicyVault.ExceedsDailyLimit.selector,
            PolicyVault.BelowSafetyBuffer.selector
        ];
        for (uint256 i = 0; i < reasons.length; ++i) {
            console.log(
                "  blocked by selector", vm.toString(abi.encodePacked(reasons[i])), handler.blockedBy(reasons[i])
            );
        }
    }
}
