// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PolicyVault} from "../src/PolicyVault.sol";
import {SavingsPool} from "../src/SavingsPool.sol";
import {HostileToken} from "../src/test/HostileToken.sol";
import {MockUSDC} from "../src/test/MockUSDC.sol";
import {VaultTestBase} from "./utils/VaultTestBase.sol";

contract PolicyVaultTest is VaultTestBase {
    // =====================================================================
    // Deployment and session
    // =====================================================================

    function test_Constructor_SetsOwnerPoolAndDefaults() public view {
        assertEq(vault.owner(), owner);
        assertEq(vault.savingsPool(), address(pool));
        assertEq(vault.recipientDelay(), 1 hours);
        assertEq(vault.LIMIT_TIMELOCK(), 24 hours);
        assertEq(vault.agent(), agent);
        assertEq(vault.agentValidUntil(), sessionEnd);
        assertTrue(vault.isSessionActive());
    }

    function test_SetAgent_EmitsAndReplacesExistingSession() public {
        address newAgent = makeAddr("newAgent");
        uint64 until = uint64(block.timestamp + 1 days);
        vm.expectEmit(address(vault));
        emit PolicyVault.AgentSet(newAgent, until);
        vm.prank(owner);
        vault.setAgent(newAgent, until);

        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.NotAgent.selector, agent));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 1e6, id);
    }

    function test_SetAgent_RevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vm.prank(agent);
        vault.setAgent(agent, uint64(block.timestamp + 1 days));
    }

    function test_SetAgent_RevertsOnZeroSelfOrOwner() public {
        uint64 until = uint64(block.timestamp + 1 days);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidAddress.selector, address(0)));
        vault.setAgent(address(0), until);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidAddress.selector, address(vault)));
        vault.setAgent(address(vault), until);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidAddress.selector, owner));
        vault.setAgent(owner, until);
        vm.stopPrank();
    }

    function test_SetAgent_RevertsOnPastOrTooLongExpiry() public {
        vm.startPrank(owner);
        uint64 past = uint64(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidSessionExpiry.selector, past));
        vault.setAgent(agent, past);
        uint64 tooLong = uint64(block.timestamp + 30 days + 1);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidSessionExpiry.selector, tooLong));
        vault.setAgent(agent, tooLong);
        vault.setAgent(agent, uint64(block.timestamp + 30 days)); // the maximum is allowed
        vm.stopPrank();
    }

    function test_RevokeAgent_ByOwner() public {
        vm.expectEmit(address(vault));
        emit PolicyVault.AgentRevoked(agent, owner);
        vm.prank(owner);
        vault.revokeAgent();
        assertEq(vault.agent(), address(0));
        assertEq(vault.agentValidUntil(), 0);
        assertFalse(vault.isSessionActive());
    }

    function test_RevokeAgent_ByGuardian() public {
        vm.prank(guardian);
        vault.revokeAgent();
        assertEq(vault.agent(), address(0));
    }

    function test_RevokeAgent_RevertsForStrangerAndAgent() public {
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.NotOwnerOrGuardian.selector, stranger));
        vm.prank(stranger);
        vault.revokeAgent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.NotOwnerOrGuardian.selector, agent));
        vm.prank(agent);
        vault.revokeAgent();
    }

    // =====================================================================
    // executeTransfer: success
    // =====================================================================

    function test_ExecuteTransfer_PaysAllowlistedRecipient() public {
        bytes32 id = _intent();
        vm.expectEmit(address(vault));
        emit PolicyVault.TransferExecuted(id, address(usdc), alice, 100e6, 100e6);
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 100e6, id);

        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(usdc.balanceOf(address(vault)), FUND - 100e6);
        assertEq(vault.spentToday(address(usdc)), 100e6);
        assertEq(vault.remainingDailyCap(address(usdc)), DAILY - 100e6);
        assertTrue(vault.usedIntent(id));
    }

    function test_ExecuteTransfer_SucceedsAtExactExpiry() public {
        vm.warp(sessionEnd);
        _pay(alice, 1e6);
        assertEq(usdc.balanceOf(alice), 1e6);
    }

    function test_ExecuteTransfer_AllowsExactlyTheCaps() public {
        _pay(alice, PER_TX); // at the per-transaction and alice's cap
        _pay(bob, BOB_CAP);
        _pay(carol, CAROL_CAP); // 500 + 300 + 200 = the daily cap exactly
        assertEq(vault.remainingDailyCap(address(usdc)), 0);
    }

    // =====================================================================
    // executeTransfer: every revert reason, in handbook 2.4 order
    // =====================================================================

    function test_ExecuteTransfer_RevertsWhenPaused() public {
        vm.prank(guardian);
        vault.pause();
        bytes32 id = _intent();
        vm.expectRevert(_err(PolicyVault.WalletPaused.selector));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 1e6, id);
    }

    function test_ExecuteTransfer_PauseIsCheckedBeforeTheCaller() public {
        vm.prank(owner);
        vault.pause();
        bytes32 id = _intent();
        vm.expectRevert(_err(PolicyVault.WalletPaused.selector));
        vm.prank(stranger);
        vault.executeTransfer(address(usdc), alice, 1e6, id);
    }

    function test_ExecuteTransfer_RevertsForNonAgent() public {
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.NotAgent.selector, owner));
        vm.prank(owner);
        vault.executeTransfer(address(usdc), alice, 1e6, id);
    }

    function test_ExecuteTransfer_RevertsAfterExpiry() public {
        vm.warp(uint256(sessionEnd) + 1);
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.SessionExpired.selector, sessionEnd));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 1e6, id);
    }

    function test_ExecuteTransfer_RevertsAfterRevoke() public {
        vm.prank(owner);
        vault.revokeAgent();
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.NotAgent.selector, agent));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 1e6, id);
    }

    function test_ExecuteTransfer_RevertsOnZeroAmount() public {
        bytes32 id = _intent();
        vm.expectRevert(_err(PolicyVault.InvalidAmount.selector));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 0, id);
    }

    function test_ExecuteTransfer_RevertsOnZeroOrSelfRecipient() public {
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidRecipient.selector, address(0)));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), address(0), 1e6, id);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidRecipient.selector, address(vault)));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), address(vault), 1e6, id);
    }

    function test_ExecuteTransfer_RevertsOnDisabledToken() public {
        MockUSDC other = new MockUSDC();
        other.mint(address(vault), 100e6);
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.TokenNotAllowed.selector, address(other)));
        vm.prank(agent);
        vault.executeTransfer(address(other), alice, 1e6, id);
    }

    function test_ExecuteTransfer_RevertsOnNonAllowlistedRecipient() public {
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.RecipientNotAllowed.selector, attacker));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), attacker, 1e6, id);
        assertEq(usdc.balanceOf(attacker), 0);
    }

    function test_ExecuteTransfer_RevertsOnNotYetActiveRecipient() public {
        address newcomer = makeAddr("newcomer");
        vm.prank(owner);
        vault.addRecipient(newcomer, 100e6);
        uint64 activeFrom = uint64(block.timestamp + 1 hours);

        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.RecipientNotActiveYet.selector, newcomer, activeFrom));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), newcomer, 1e6, id);

        vm.warp(activeFrom);
        _pay(newcomer, 1e6);
        assertEq(usdc.balanceOf(newcomer), 1e6);
    }

    function test_ExecuteTransfer_RevertsOnReusedIntent() public {
        bytes32 id = _intent();
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 1e6, id);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.IntentAlreadyUsed.selector, id));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 1e6, id);
    }

    function test_ExecuteTransfer_RevertsOnZeroIntent() public {
        vm.expectRevert(_err(PolicyVault.InvalidIntent.selector));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 1e6, bytes32(0));
    }

    function test_ExecuteTransfer_RevertsAbovePerTxCap() public {
        vm.prank(owner);
        vault.addRecipient(stranger, 900e6); // a recipient cap above the per-transaction cap
        skip(1 hours);
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.ExceedsPerTxLimit.selector, 500e6 + 1, PER_TX));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), stranger, 500e6 + 1, id);
    }

    function test_ExecuteTransfer_RevertsAboveRecipientCap() public {
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.ExceedsRecipientLimit.selector, carol, 201e6, CAROL_CAP));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), carol, 201e6, id);
    }

    function test_ExecuteTransfer_RevertsAboveDailyCap() public {
        _pay(alice, 500e6);
        _pay(alice, 400e6);
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.ExceedsDailyLimit.selector, 101e6, 100e6));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 101e6, id);
    }

    function test_ExecuteTransfer_DailyCapResetsNextDay() public {
        _pay(alice, 500e6);
        _pay(alice, 500e6);
        assertEq(vault.remainingDailyCap(address(usdc)), 0);
        vm.warp((block.timestamp / 1 days + 1) * 1 days); // next UTC midnight
        assertEq(vault.spentToday(address(usdc)), 0);
        _pay(alice, 500e6);
        assertEq(vault.spentToday(address(usdc)), 500e6);
    }

    function test_ExecuteTransfer_DailyCapLoweredBelowSpent_RevertsWithNamedError() public {
        _pay(alice, 500e6);
        vm.prank(owner);
        vault.setTokenLimits(address(usdc), 100e6, 200e6); // already spent 500 today
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.ExceedsDailyLimit.selector, 1e6, 0));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 1e6, id);
    }

    function test_ExecuteTransfer_RevertsBelowSafetyBuffer() public {
        vm.prank(owner);
        vault.withdraw(address(usdc), owner, FUND - 120e6); // leave 120
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.BelowSafetyBuffer.selector, 120e6, 71e6, BUFFER));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 71e6, id);
        _pay(alice, 70e6); // exactly down to the buffer is allowed
        assertEq(usdc.balanceOf(address(vault)), BUFFER);
    }

    function test_ExecuteTransfer_RevertsAfterRecipientRemoved() public {
        vm.prank(owner);
        vault.removeRecipient(alice);
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.RecipientNotAllowed.selector, alice));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 1e6, id);
    }

    function test_ExecuteTransfer_FailedCallDoesNotConsumeIntent() public {
        bytes32 id = _intent();
        vm.prank(agent);
        vm.expectRevert();
        vault.executeTransfer(address(usdc), alice, 600e6, id);
        assertFalse(vault.usedIntent(id));
    }

    // =====================================================================
    // executeBatch
    // =====================================================================

    function _batch3() internal view returns (address[] memory to, uint256[] memory amounts) {
        to = new address[](3);
        amounts = new uint256[](3);
        (to[0], to[1], to[2]) = (alice, bob, carol);
        (amounts[0], amounts[1], amounts[2]) = (300e6, 250e6, 150e6);
    }

    function test_ExecuteBatch_PaysEveryItemAndEmits() public {
        (address[] memory to, uint256[] memory amounts) = _batch3();
        bytes32 id = _intent();
        // Item IDs are keccak256(abi.encode(batchId, index)); computed locally to also pin the format.
        bytes32 item0 = keccak256(abi.encode(id, uint256(0)));
        bytes32 item1 = keccak256(abi.encode(id, uint256(1)));
        bytes32 item2 = keccak256(abi.encode(id, uint256(2)));
        assertEq(vault.itemIntentId(id, 2), item2);
        vm.expectEmit(address(vault));
        emit PolicyVault.TransferExecuted(item0, address(usdc), alice, 300e6, 300e6);
        vm.expectEmit(address(vault));
        emit PolicyVault.TransferExecuted(item1, address(usdc), bob, 250e6, 550e6);
        vm.expectEmit(address(vault));
        emit PolicyVault.TransferExecuted(item2, address(usdc), carol, 150e6, 700e6);
        vm.expectEmit(address(vault));
        emit PolicyVault.BatchExecuted(id, address(usdc), 3, 700e6);
        vm.prank(agent);
        vault.executeBatch(address(usdc), to, amounts, id);

        assertEq(usdc.balanceOf(alice), 300e6);
        assertEq(usdc.balanceOf(bob), 250e6);
        assertEq(usdc.balanceOf(carol), 150e6);
        assertEq(vault.spentToday(address(usdc)), 700e6);
        assertTrue(vault.usedIntent(id));
        assertTrue(vault.usedIntent(vault.itemIntentId(id, 2)));
    }

    function test_ExecuteBatch_RevertsOnEmpty() public {
        bytes32 id = _intent();
        vm.expectRevert(_err(PolicyVault.EmptyBatch.selector));
        vm.prank(agent);
        vault.executeBatch(address(usdc), new address[](0), new uint256[](0), id);
    }

    function test_ExecuteBatch_RevertsOnElevenItems() public {
        address[] memory to = new address[](11);
        uint256[] memory amounts = new uint256[](11);
        for (uint256 i = 0; i < 11; ++i) {
            to[i] = alice;
            amounts[i] = 1e6;
        }
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.BatchTooLarge.selector, 11));
        vm.prank(agent);
        vault.executeBatch(address(usdc), to, amounts, id);
    }

    function test_ExecuteBatch_AllowsTenItems() public {
        address[] memory to = new address[](10);
        uint256[] memory amounts = new uint256[](10);
        for (uint256 i = 0; i < 10; ++i) {
            to[i] = alice;
            amounts[i] = 10e6;
        }
        bytes32 id = _intent();
        vm.prank(agent);
        vault.executeBatch(address(usdc), to, amounts, id);
        assertEq(usdc.balanceOf(alice), 100e6);
    }

    function test_ExecuteBatch_RevertsOnLengthMismatch() public {
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.LengthMismatch.selector, 2, 1));
        vm.prank(agent);
        vault.executeBatch(address(usdc), new address[](2), new uint256[](1), id);
    }

    function test_ExecuteBatch_OneMaliciousItemChangesNoBalances() public {
        address[] memory to = new address[](10);
        uint256[] memory amounts = new uint256[](10);
        for (uint256 i = 0; i < 10; ++i) {
            to[i] = i % 2 == 0 ? alice : bob;
            amounts[i] = 10e6;
        }
        to[7] = attacker; // hidden among nine safe items
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.RecipientNotAllowed.selector, attacker));
        vm.prank(agent);
        vault.executeBatch(address(usdc), to, amounts, id);

        assertEq(usdc.balanceOf(address(vault)), FUND);
        assertEq(usdc.balanceOf(alice) + usdc.balanceOf(bob) + usdc.balanceOf(attacker), 0);
        assertEq(vault.spentToday(address(usdc)), 0);
        assertFalse(vault.usedIntent(id));
    }

    function test_ExecuteBatch_TotalOverDailyCapReverts() public {
        address[] memory to = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        (to[0], to[1], to[2]) = (alice, alice, bob);
        (amounts[0], amounts[1], amounts[2]) = (500e6, 400e6, 200e6); // 1,100 > 1,000
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.ExceedsDailyLimit.selector, 200e6, 100e6));
        vm.prank(agent);
        vault.executeBatch(address(usdc), to, amounts, id);
    }

    function test_ExecuteBatch_CountsEarlierSpendTowardDailyCap() public {
        _pay(alice, 500e6);
        (address[] memory to, uint256[] memory amounts) = _batch3(); // 700 more
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.ExceedsDailyLimit.selector, 250e6, 200e6));
        vm.prank(agent);
        vault.executeBatch(address(usdc), to, amounts, id);
    }

    function test_ExecuteBatch_RevertsOnReplay() public {
        (address[] memory to, uint256[] memory amounts) = _batch3();
        bytes32 id = _intent();
        vm.prank(agent);
        vault.executeBatch(address(usdc), to, amounts, id);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.IntentAlreadyUsed.selector, id));
        vm.prank(agent);
        vault.executeBatch(address(usdc), to, amounts, id);
    }

    function test_ExecuteBatch_ItemIntentCannotBeReplayedAsSingleTransfer() public {
        (address[] memory to, uint256[] memory amounts) = _batch3();
        bytes32 id = _intent();
        vm.prank(agent);
        vault.executeBatch(address(usdc), to, amounts, id);
        bytes32 item0 = vault.itemIntentId(id, 0);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.IntentAlreadyUsed.selector, item0));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 1e6, item0);
    }

    function test_ExecuteBatch_RespectsBufferCumulatively() public {
        vm.prank(owner);
        vault.withdraw(address(usdc), owner, FUND - 400e6); // leave 400, buffer 50
        (address[] memory to, uint256[] memory amounts) = _batch3(); // 300 leaves 100; then 250 breaches
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.BelowSafetyBuffer.selector, 100e6, 250e6, BUFFER));
        vm.prank(agent);
        vault.executeBatch(address(usdc), to, amounts, id);
    }

    function test_ExecuteBatch_RevertsForNonAgentAndWhenPaused() public {
        (address[] memory to, uint256[] memory amounts) = _batch3();
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.NotAgent.selector, stranger));
        vm.prank(stranger);
        vault.executeBatch(address(usdc), to, amounts, id);

        vm.prank(guardian);
        vault.pause();
        vm.expectRevert(_err(PolicyVault.WalletPaused.selector));
        vm.prank(agent);
        vault.executeBatch(address(usdc), to, amounts, id);
    }

    // =====================================================================
    // T2 requests and owner approvals
    // =====================================================================

    function _request(address to, uint256 amount) internal returns (uint256 id) {
        bytes32 intentId = _intent();
        vm.prank(agent);
        id = vault.requestTransfer(address(usdc), to, amount, intentId, keccak256("Tuition, spring term"));
    }

    function test_RequestTransfer_CreatesPendingRequestAndMovesNoFunds() public {
        bytes32 intentId = _intent();
        bytes32 memoHash = keccak256("Tuition");
        uint64 expiresAt = uint64(block.timestamp + 72 hours);
        vm.expectEmit(address(vault));
        emit PolicyVault.TransferRequested(1, intentId, address(usdc), stranger, 1800e6, memoHash, expiresAt);
        vm.prank(agent);
        uint256 id = vault.requestTransfer(address(usdc), stranger, 1800e6, intentId, memoHash);

        assertEq(id, 1);
        assertEq(vault.requestCount(), 1);
        PolicyVault.Request memory r = vault.getRequest(id);
        assertEq(r.to, stranger);
        assertEq(r.amount, 1800e6);
        assertEq(r.expiresAt, expiresAt);
        assertEq(uint8(r.status), uint8(PolicyVault.RequestStatus.Pending));
        assertEq(usdc.balanceOf(address(vault)), FUND);
    }

    function test_RequestTransfer_RevertsOnReusedIntentAndForNonAgent() public {
        bytes32 intentId = _intent();
        vm.prank(agent);
        vault.requestTransfer(address(usdc), stranger, 10e6, intentId, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.IntentAlreadyUsed.selector, intentId));
        vm.prank(agent);
        vault.requestTransfer(address(usdc), stranger, 10e6, intentId, bytes32(0));

        bytes32 other = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.NotAgent.selector, attacker));
        vm.prank(attacker);
        vault.requestTransfer(address(usdc), attacker, 10e6, other, bytes32(0));
    }

    function test_ApproveRequest_PaysNonAllowlistedRecipientAboveCaps() public {
        uint256 id = _request(stranger, 1800e6);
        vm.expectEmit(address(vault));
        emit PolicyVault.RequestApproved(id, address(usdc), stranger, 1800e6);
        vm.prank(owner);
        vault.approveRequest(id);
        assertEq(usdc.balanceOf(stranger), 1800e6);
        assertEq(uint8(vault.getRequest(id).status), uint8(PolicyVault.RequestStatus.Approved));
        // Owner-approved payments do not use the agent's daily allowance.
        assertEq(vault.spentToday(address(usdc)), 0);
    }

    function test_ApproveRequest_RevertsForAgentAndStranger() public {
        uint256 id = _request(stranger, 10e6);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vm.prank(agent);
        vault.approveRequest(id);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.approveRequest(id);
    }

    function test_ApproveRequest_RevertsWhenPaused() public {
        uint256 id = _request(stranger, 10e6);
        vm.prank(guardian);
        vault.pause();
        vm.expectRevert(_err(PolicyVault.WalletPaused.selector));
        vm.prank(owner);
        vault.approveRequest(id);
    }

    function test_ApproveRequest_RevertsAfterExpiry() public {
        uint256 id = _request(stranger, 10e6);
        skip(72 hours + 1);
        assertEq(uint8(vault.getRequest(id).status), uint8(PolicyVault.RequestStatus.Expired));
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.RequestExpired.selector, id));
        vm.prank(owner);
        vault.approveRequest(id);
    }

    function test_ApproveRequest_RevertsTwiceAndForUnknownId() public {
        uint256 id = _request(stranger, 10e6);
        vm.startPrank(owner);
        vault.approveRequest(id);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.RequestNotPending.selector, id));
        vault.approveRequest(id);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.RequestNotPending.selector, 99));
        vault.approveRequest(99);
        vm.stopPrank();
    }

    function test_RejectRequest_ThenCannotApprove() public {
        uint256 id = _request(stranger, 10e6);
        vm.expectEmit(address(vault));
        emit PolicyVault.RequestRejected(id);
        vm.prank(owner);
        vault.rejectRequest(id);
        assertEq(uint8(vault.getRequest(id).status), uint8(PolicyVault.RequestStatus.Rejected));
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.RequestNotPending.selector, id));
        vm.prank(owner);
        vault.approveRequest(id);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vm.prank(agent);
        vault.rejectRequest(id);
    }

    // =====================================================================
    // Limits and timelock
    // =====================================================================

    function test_SetTokenLimits_FirstCallEnablesImmediately() public {
        MockUSDC other = new MockUSDC();
        vm.expectEmit(address(vault));
        emit PolicyVault.TokenEnabled(address(other), 10e6, 20e6);
        vm.prank(owner);
        vault.setTokenLimits(address(other), 10e6, 20e6);
        (bool enabled, uint128 perTx, uint128 daily) = vault.tokens(address(other));
        assertTrue(enabled);
        assertEq(perTx, 10e6);
        assertEq(daily, 20e6);
    }

    function test_SetTokenLimits_DecreaseAppliesNow() public {
        vm.expectEmit(address(vault));
        emit PolicyVault.LimitsDecreased(address(usdc), 100e6, 200e6);
        vm.prank(owner);
        vault.setTokenLimits(address(usdc), 100e6, 200e6);
        (, uint128 perTx, uint128 daily) = vault.tokens(address(usdc));
        assertEq(perTx, 100e6);
        assertEq(daily, 200e6);
        (,, uint64 eta) = vault.pendingIncrease(address(usdc));
        assertEq(eta, 0);
    }

    function test_SetTokenLimits_IncreaseIsQueuedNotApplied() public {
        uint64 eta = uint64(block.timestamp + 24 hours);
        vm.expectEmit(address(vault));
        emit PolicyVault.LimitIncreaseQueued(address(usdc), 600e6, 1200e6, eta);
        vm.prank(owner);
        vault.setTokenLimits(address(usdc), 600e6, 1200e6);
        (, uint128 perTx, uint128 daily) = vault.tokens(address(usdc));
        assertEq(perTx, PER_TX);
        assertEq(daily, DAILY);

        vm.prank(owner);
        vault.addRecipient(stranger, 900e6);
        skip(1 hours);
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.ExceedsPerTxLimit.selector, 600e6, PER_TX));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), stranger, 600e6, id);
    }

    function test_ExecuteLimitIncrease_RevertsBeforeEtaAndAppliesAfter() public {
        vm.prank(owner);
        vault.setTokenLimits(address(usdc), 600e6, 1200e6);
        uint64 eta = uint64(block.timestamp + 24 hours);

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.TimelockNotElapsed.selector, eta));
        vault.executeLimitIncrease(address(usdc));

        vm.warp(eta);
        vm.expectEmit(address(vault));
        emit PolicyVault.LimitIncreaseExecuted(address(usdc), 600e6, 1200e6);
        vm.prank(stranger); // anyone may execute
        vault.executeLimitIncrease(address(usdc));
        (, uint128 perTx, uint128 daily) = vault.tokens(address(usdc));
        assertEq(perTx, 600e6);
        assertEq(daily, 1200e6);
    }

    function test_ExecuteLimitIncrease_RevertsWithoutPending() public {
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.NoPendingIncrease.selector, address(usdc)));
        vault.executeLimitIncrease(address(usdc));
    }

    function test_CancelLimitIncrease_ByGuardian() public {
        vm.prank(owner);
        vault.setTokenLimits(address(usdc), 600e6, 1200e6);
        vm.expectEmit(address(vault));
        emit PolicyVault.LimitIncreaseCancelled(address(usdc));
        vm.prank(guardian);
        vault.cancelLimitIncrease(address(usdc));
        skip(24 hours);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.NoPendingIncrease.selector, address(usdc)));
        vault.executeLimitIncrease(address(usdc));
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.NotOwnerOrGuardian.selector, agent));
        vm.prank(agent);
        vault.cancelLimitIncrease(address(usdc));
    }

    function test_SetTokenLimits_MixedChangeDecreasesNowAndQueuesIncrease() public {
        vm.prank(owner);
        vault.setTokenLimits(address(usdc), 100e6, 2000e6); // perTx down, daily up
        (, uint128 perTx, uint128 daily) = vault.tokens(address(usdc));
        assertEq(perTx, 100e6);
        assertEq(daily, DAILY);
        (uint128 pendingPerTx, uint128 pendingDaily, uint64 eta) = vault.pendingIncrease(address(usdc));
        assertEq(pendingPerTx, 100e6);
        assertEq(pendingDaily, 2000e6);
        assertEq(eta, block.timestamp + 24 hours);
    }

    function test_SetTokenLimits_LaterDecreaseCancelsQueuedIncrease() public {
        vm.startPrank(owner);
        vault.setTokenLimits(address(usdc), 600e6, 1200e6);
        vm.expectEmit(address(vault));
        emit PolicyVault.LimitIncreaseCancelled(address(usdc));
        vault.setTokenLimits(address(usdc), 400e6, 900e6);
        vm.stopPrank();
        (,, uint64 eta) = vault.pendingIncrease(address(usdc));
        assertEq(eta, 0);
    }

    function test_SetTokenLimits_ReEnablingAfterZeroCapsIsTimelocked() public {
        vm.startPrank(owner);
        vault.setTokenLimits(address(usdc), 0, 0); // disable agent spending
        vault.setTokenLimits(address(usdc), PER_TX, DAILY);
        vm.stopPrank();
        (, uint128 perTx,) = vault.tokens(address(usdc));
        assertEq(perTx, 0);
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.ExceedsPerTxLimit.selector, 1e6, 0));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 1e6, id);
    }

    function test_SetTokenLimits_RevertsOnInvalidInput() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidCaps.selector, 200e6, 100e6));
        vault.setTokenLimits(address(usdc), 200e6, 100e6);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidAddress.selector, address(0)));
        vault.setTokenLimits(address(0), 1, 1);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vm.prank(agent);
        vault.setTokenLimits(address(usdc), 1, 1);
    }

    function test_SetMinBuffer() public {
        vm.expectEmit(address(vault));
        emit PolicyVault.MinBufferSet(address(usdc), 200e6);
        vm.prank(owner);
        vault.setMinBuffer(address(usdc), 200e6);
        assertEq(vault.minBuffer(address(usdc)), 200e6);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vm.prank(agent);
        vault.setMinBuffer(address(usdc), 0);
    }

    // =====================================================================
    // Recipients
    // =====================================================================

    function test_AddRecipient_SetsActivationDelay() public {
        address payee = makeAddr("payee");
        uint64 activeFrom = uint64(block.timestamp + 1 hours);
        vm.expectEmit(address(vault));
        emit PolicyVault.RecipientAdded(payee, 100e6, activeFrom);
        vm.prank(owner);
        vault.addRecipient(payee, 100e6);
        (bool allowed, uint128 cap, uint64 from) = vault.recipients(payee);
        assertTrue(allowed);
        assertEq(cap, 100e6);
        assertEq(from, activeFrom);
        assertFalse(vault.isRecipientActive(payee));
        vm.warp(activeFrom);
        assertTrue(vault.isRecipientActive(payee));
    }

    function test_AddRecipient_RevertsOnInvalidInput() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidRecipient.selector, address(0)));
        vault.addRecipient(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidRecipient.selector, address(vault)));
        vault.addRecipient(address(vault), 1);
        vm.expectRevert(_err(PolicyVault.InvalidAmount.selector));
        vault.addRecipient(stranger, 0);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.RecipientAlreadyAdded.selector, alice));
        vault.addRecipient(alice, 1);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vm.prank(agent);
        vault.addRecipient(attacker, 1000e6);
    }

    function test_RemoveRecipient() public {
        vm.expectEmit(address(vault));
        emit PolicyVault.RecipientRemoved(alice);
        vm.prank(owner);
        vault.removeRecipient(alice);
        (bool allowed,,) = vault.recipients(alice);
        assertFalse(allowed);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.RecipientNotAllowed.selector, alice));
        vm.prank(owner);
        vault.removeRecipient(alice);
    }

    function test_SetRecipientDelay_ZeroForDemoAndBounded() public {
        vm.startPrank(owner);
        vault.setRecipientDelay(0);
        vault.addRecipient(stranger, 10e6);
        assertTrue(vault.isRecipientActive(stranger));
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidDelay.selector, 30 days + 1));
        vault.setRecipientDelay(30 days + 1);
        vm.stopPrank();
        _pay(stranger, 1e6);
    }

    // =====================================================================
    // Savings
    // =====================================================================

    function test_DepositToSavings_MovesFundsToPoolAndLeavesNoAllowance() public {
        vm.prank(agent);
        vault.depositToSavings(1000e6);
        assertEq(usdc.balanceOf(address(vault)), FUND - 1000e6);
        assertEq(usdc.balanceOf(address(pool)), 1000e6);
        assertEq(pool.maxWithdraw(address(vault)), 1000e6);
        assertEq(usdc.allowance(address(vault), address(pool)), 0);
        // Savings moves are not spending.
        assertEq(vault.spentToday(address(usdc)), 0);
    }

    function test_DepositToSavings_RevertsBelowBuffer() public {
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.BelowSafetyBuffer.selector, FUND, FUND - 49e6, BUFFER));
        vm.prank(agent);
        vault.depositToSavings(FUND - 49e6);
    }

    function test_WithdrawFromSavings_ReturnsFundsToVault() public {
        vm.startPrank(agent);
        vault.depositToSavings(1000e6);
        vault.withdrawFromSavings(400e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), FUND - 600e6);
        assertEq(usdc.balanceOf(address(pool)), 600e6);
    }

    function test_WithdrawFromSavings_IncludesAccruedYield() public {
        vm.prank(agent);
        vault.depositToSavings(1000e6);
        usdc.mint(owner, 100e6);
        vm.startPrank(owner);
        usdc.approve(address(pool), 100e6);
        pool.accrue(100e6);
        vm.stopPrank();
        uint256 withdrawable = pool.maxWithdraw(address(vault));
        // ERC-4626 rounds in the pool's favour; the virtual share keeps a sub-unit sliver.
        assertApproxEqAbs(withdrawable, 1100e6, 2);
        vm.prank(agent);
        vault.withdrawFromSavings(withdrawable);
        assertApproxEqAbs(usdc.balanceOf(address(vault)), FUND + 100e6, 2);
    }

    function test_Savings_RevertForNonAgentPausedOrZero() public {
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.NotAgent.selector, attacker));
        vm.prank(attacker);
        vault.depositToSavings(1e6);
        vm.expectRevert(_err(PolicyVault.InvalidAmount.selector));
        vm.prank(agent);
        vault.depositToSavings(0);
        vm.prank(guardian);
        vault.pause();
        vm.expectRevert(_err(PolicyVault.WalletPaused.selector));
        vm.prank(agent);
        vault.withdrawFromSavings(1e6);
    }

    function test_Savings_RevertWhenPoolNotSet() public {
        PolicyVault bare = new PolicyVault(owner, address(0));
        vm.prank(owner);
        bare.setAgent(agent, uint64(block.timestamp + 1 days));
        vm.expectRevert(_err(PolicyVault.SavingsPoolNotSet.selector));
        vm.prank(agent);
        bare.depositToSavings(1e6);
        // The first pool is set immediately.
        vm.prank(owner);
        bare.setSavingsPool(address(pool));
        assertEq(bare.savingsPool(), address(pool));
    }

    function test_SetSavingsPool_ChangeIsTimelocked() public {
        SavingsPool other = new SavingsPool(usdc, owner);
        uint64 eta = uint64(block.timestamp + 24 hours);
        vm.expectEmit(address(vault));
        emit PolicyVault.SavingsPoolChangeQueued(address(other), eta);
        vm.prank(owner);
        vault.setSavingsPool(address(other));
        assertEq(vault.savingsPool(), address(pool));

        vm.expectRevert(abi.encodeWithSelector(PolicyVault.TimelockNotElapsed.selector, eta));
        vault.executeSavingsPoolChange();
        vm.warp(eta);
        vault.executeSavingsPoolChange();
        assertEq(vault.savingsPool(), address(other));
        vm.expectRevert(_err(PolicyVault.NoPendingPoolChange.selector));
        vault.executeSavingsPoolChange();
    }

    function test_CancelSavingsPoolChange_ByGuardian() public {
        SavingsPool other = new SavingsPool(usdc, owner);
        vm.prank(owner);
        vault.setSavingsPool(address(other));
        vm.prank(guardian);
        vault.cancelSavingsPoolChange();
        skip(24 hours);
        vm.expectRevert(_err(PolicyVault.NoPendingPoolChange.selector));
        vault.executeSavingsPoolChange();
        vm.expectRevert(_err(PolicyVault.NoPendingPoolChange.selector));
        vm.prank(owner);
        vault.cancelSavingsPoolChange();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidAddress.selector, address(0)));
        vm.prank(owner);
        vault.setSavingsPool(address(0));
    }

    // =====================================================================
    // Pause, guardian, ownership, escape hatch
    // =====================================================================

    function test_Pause_GuardianPausesOnlyOwnerUnpauses() public {
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());
        assertFalse(vault.isSessionActive());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vm.prank(guardian);
        vault.unpause();
        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
        _pay(alice, 1e6);
    }

    function test_Pause_RevertsForAgentAndStranger() public {
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.NotOwnerOrGuardian.selector, agent));
        vm.prank(agent);
        vault.pause();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.NotOwnerOrGuardian.selector, stranger));
        vm.prank(stranger);
        vault.pause();
    }

    function test_Withdraw_OwnerEscapeHatchWorksWhilePaused() public {
        vm.prank(guardian);
        vault.pause();
        vm.expectEmit(address(vault));
        emit PolicyVault.OwnerWithdraw(address(usdc), owner, FUND);
        vm.prank(owner);
        vault.withdraw(address(usdc), owner, FUND); // no caps, no buffer
        assertEq(usdc.balanceOf(owner), FUND);
    }

    function test_Withdraw_RevertsForAgentAndOnBadInput() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vm.prank(agent);
        vault.withdraw(address(usdc), agent, 1e6);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidAddress.selector, address(0)));
        vault.withdraw(address(usdc), address(0), 1e6);
        vm.expectRevert(_err(PolicyVault.InvalidAmount.selector));
        vault.withdraw(address(usdc), owner, 0);
        vm.stopPrank();
    }

    function test_RenounceOwnership_IsDisabled() public {
        vm.expectRevert(_err(PolicyVault.RenounceDisabled.selector));
        vm.prank(owner);
        vault.renounceOwnership();
        assertEq(vault.owner(), owner);
    }

    function test_OwnershipTransfer_IsTwoStep() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        assertEq(vault.owner(), owner); // not yet
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        vault.acceptOwnership();
        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);
    }

    function test_SetGuardian_RejectsAgentAndSelf() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidAddress.selector, agent));
        vault.setGuardian(agent);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.InvalidAddress.selector, address(vault)));
        vault.setGuardian(address(vault));
        vm.expectEmit(address(vault));
        emit PolicyVault.GuardianSet(address(0));
        vault.setGuardian(address(0)); // removing the guardian is allowed
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.NotOwnerOrGuardian.selector, guardian));
        vm.prank(guardian);
        vault.pause();
    }

    // =====================================================================
    // Attack scenarios
    // =====================================================================

    function test_HostileTokenAirdrop_AgentCannotMoveIt() public {
        HostileToken hostile = new HostileToken();
        hostile.airdrop(address(vault), 1_000_000e18);
        assertEq(hostile.name(), hostile.PAYLOAD());

        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.TokenNotAllowed.selector, address(hostile)));
        vm.prank(agent);
        vault.executeTransfer(address(hostile), alice, 1e18, id);
        // Following the payload's instruction fails too: the "attacker" is not allowlisted.
        bytes32 id2 = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.RecipientNotAllowed.selector, address(0xdEaD)));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), address(0xdEaD), 1e6, id2);
    }

    function test_StolenSessionKey_LossIsBoundedByDailyCap() public {
        // A thief holding the session key drains as fast as possible.
        _pay(alice, 500e6);
        _pay(bob, 300e6);
        _pay(carol, 200e6);
        bytes32 id = _intent();
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.ExceedsDailyLimit.selector, 1e6, 0));
        vm.prank(agent);
        vault.executeTransfer(address(usdc), alice, 1e6, id);
        assertEq(usdc.balanceOf(address(vault)), FUND - DAILY);
    }

    function test_AgentCannotChangeItsOwnLimitsOrAllowlist() public {
        vm.startPrank(agent);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vault.setTokenLimits(address(usdc), 1e12, 1e12);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vault.addRecipient(attacker, 1e12);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vault.setAgent(attacker, uint64(block.timestamp + 1 days));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vault.unpause();
        vm.stopPrank();
    }
}
