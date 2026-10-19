// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PolicyVault} from "../src/PolicyVault.sol";
import {VaultTestBase} from "./utils/VaultTestBase.sol";

/// @notice Fuzz tests on amounts, timestamps and recipients (handbook 2.7). Each test predicts the
///         outcome from the limits alone, then checks the vault agrees.
contract PolicyVaultFuzzTest is VaultTestBase {
    function _capOf(address who) internal view returns (uint256) {
        (, uint128 cap,) = vault.recipients(who);
        return cap;
    }

    function testFuzz_ExecuteTransfer_OutcomeMatchesLimits(uint256 amount, uint8 pick) public {
        amount = bound(amount, 0, 3000e6);
        address to = [alice, bob, carol][pick % 3];
        uint256 cap = _capOf(to);
        bytes32 id = _intent();

        if (amount == 0) {
            vm.expectRevert(_err(PolicyVault.InvalidAmount.selector));
        } else if (amount > PER_TX) {
            vm.expectRevert(abi.encodeWithSelector(PolicyVault.ExceedsPerTxLimit.selector, amount, PER_TX));
        } else if (amount > cap) {
            vm.expectRevert(abi.encodeWithSelector(PolicyVault.ExceedsRecipientLimit.selector, to, amount, cap));
        }
        vm.prank(agent);
        vault.executeTransfer(address(usdc), to, amount, id);

        bool ok = amount > 0 && amount <= PER_TX && amount <= cap;
        assertEq(usdc.balanceOf(to), ok ? amount : 0);
        assertEq(usdc.balanceOf(address(vault)), ok ? FUND - amount : FUND);
    }

    function testFuzz_ExecuteTransfer_NeverPaysUnlistedRecipient(address to, uint256 amount) public {
        vm.assume(to != alice && to != bob && to != carol && to != address(0) && to != address(vault));
        amount = bound(amount, 1, PER_TX);
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.RecipientNotAllowed.selector, to));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), to, amount, id);
        assertEq(usdc.balanceOf(address(vault)), FUND);
    }

    function testFuzz_Session_ValidExactlyUntilExpiry(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 30 days);
        vm.warp(block.timestamp + elapsed);
        bytes32 id = _intent();
        if (block.timestamp > sessionEnd) {
            vm.expectRevert(abi.encodeWithSelector(PolicyVault.SessionExpired.selector, sessionEnd));
        }
        vm.prank(agent);
        vault.executeTransfer(address(usdc), carol, 1e6, id);
    }

    function testFuzz_Recipient_ActivatesExactlyAfterDelay(uint64 delay, uint256 elapsed) public {
        delay = uint64(bound(delay, 0, 30 days));
        elapsed = bound(elapsed, 0, 60 days);
        address payee = makeAddr("payee");
        vm.startPrank(owner);
        vault.setRecipientDelay(delay);
        vault.addRecipient(payee, 10e6);
        vault.setAgent(agent, uint64(block.timestamp + 30 days));
        vm.stopPrank();
        uint64 activeFrom = uint64(block.timestamp) + delay;
        // Stay inside the 30-day session.
        vm.warp(block.timestamp + (elapsed > 30 days ? 30 days : elapsed));

        bytes32 id = _intent();
        if (block.timestamp < activeFrom) {
            vm.expectRevert(abi.encodeWithSelector(PolicyVault.RecipientNotActiveYet.selector, payee, activeFrom));
        }
        vm.prank(agent);
        vault.executeTransfer(address(usdc), payee, 1e6, id);
    }

    function testFuzz_DailySpend_NeverExceedsCap(uint256[12] memory amounts) public {
        uint256 paid;
        for (uint256 i = 0; i < amounts.length; ++i) {
            uint256 amount = bound(amounts[i], 1, PER_TX);
            bytes32 id = _intent();
            vm.prank(agent);
            try vault.executeTransfer(address(usdc), alice, amount, id) {
                paid += amount;
            } catch {}
            assertLe(vault.spentToday(address(usdc)), DAILY);
        }
        assertEq(vault.spentToday(address(usdc)), paid);
        assertEq(usdc.balanceOf(alice), paid);
        assertLe(paid, DAILY);
    }

    function testFuzz_Batch_OutcomeMatchesDailyCap(uint256[10] memory raw, uint8 n) public {
        uint256 count = bound(n, 1, 10);
        address[] memory to = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256 total;
        for (uint256 i = 0; i < count; ++i) {
            to[i] = alice;
            amounts[i] = bound(raw[i], 1, PER_TX);
            total += amounts[i];
        }
        bytes32 id = _intent();
        vm.prank(agent);
        try vault.executeBatch(address(usdc), to, amounts, id) {
            assertLe(total, DAILY, "a batch over the daily cap succeeded");
            assertEq(usdc.balanceOf(alice), total);
        } catch {
            assertGt(total, DAILY, "a batch within every limit failed");
            assertEq(usdc.balanceOf(address(vault)), FUND, "a failed batch moved funds");
        }
        assertLe(vault.spentToday(address(usdc)), DAILY);
    }

    function testFuzz_Buffer_NeverBreached(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, FUND);
        amount = bound(amount, 1, PER_TX);
        if (balance < FUND) {
            vm.prank(owner);
            vault.withdraw(address(usdc), owner, FUND - balance);
        }

        bytes32 id = _intent();
        vm.prank(agent);
        try vault.executeTransfer(address(usdc), alice, amount, id) {
            assertGe(balance, amount + BUFFER, "a payment breaching the buffer succeeded");
            assertGe(usdc.balanceOf(address(vault)), BUFFER);
        } catch {
            assertLt(balance, amount + BUFFER, "a payment within the buffer failed");
            assertEq(usdc.balanceOf(address(vault)), balance);
        }
    }

    function testFuzz_Intent_ReplayAlwaysReverts(bytes32 id, uint256 amount) public {
        vm.assume(id != bytes32(0));
        amount = bound(amount, 1, CAROL_CAP);
        vm.prank(agent);
        vault.executeTransfer(address(usdc), carol, amount, id);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.IntentAlreadyUsed.selector, id));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), carol, amount, id);
    }

    function testFuzz_LimitIncrease_NeverBeforeEta(uint128 newPerTx, uint256 elapsed) public {
        newPerTx = uint128(bound(newPerTx, PER_TX + 1, DAILY));
        elapsed = bound(elapsed, 0, 48 hours);
        vm.prank(owner);
        vault.setTokenLimits(address(usdc), newPerTx, DAILY);
        uint256 eta = block.timestamp + 24 hours;
        vm.warp(block.timestamp + elapsed);

        if (block.timestamp < eta) {
            vm.expectRevert(abi.encodeWithSelector(PolicyVault.TimelockNotElapsed.selector, uint64(eta)));
        }
        vault.executeLimitIncrease(address(usdc));
        (, uint128 perTx,) = vault.tokens(address(usdc));
        assertEq(perTx, block.timestamp >= eta ? newPerTx : PER_TX);
    }

    function testFuzz_DailyCap_ResetsOnlyOnANewDay(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 3 days);
        _pay(alice, 500e6);
        _pay(alice, 500e6);
        uint256 dayBefore = block.timestamp / 1 days;
        vm.warp(block.timestamp + elapsed);
        bool newDay = block.timestamp / 1 days > dayBefore;
        assertEq(vault.spentToday(address(usdc)), newDay ? 0 : DAILY);

        bytes32 id = _intent();
        if (block.timestamp > sessionEnd) {
            vm.expectRevert(abi.encodeWithSelector(PolicyVault.SessionExpired.selector, sessionEnd));
        } else if (!newDay) {
            vm.expectRevert(abi.encodeWithSelector(PolicyVault.ExceedsDailyLimit.selector, 1e6, 0));
        }
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 1e6, id);
    }
}
