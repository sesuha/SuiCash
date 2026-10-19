// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PolicyVault} from "../../src/PolicyVault.sol";
import {SavingsPool} from "../../src/SavingsPool.sol";
import {MockUSDC} from "../../src/test/MockUSDC.sol";

/// @notice Plays a hostile agent making random calls, mixed with random owner and guardian actions
///         and time jumps. Every successful agent action is checked against what the handler knows
///         must hold; any breach is recorded as a violation for the invariant test to report.
contract VaultHandler is Test {
    PolicyVault public immutable vault;
    MockUSDC public immutable usdc;
    SavingsPool public immutable pool;
    address public immutable owner;
    address public immutable guardian;
    address public immutable agent;

    address[] internal _allowed; // allowlisted and active
    address public immutable pendingRecipient; // allowlisted, never active during the run
    address[] internal _outsiders; // never allowlisted
    bytes32[8] internal _idPool; // a small pool so the fuzzer often replays intent IDs

    // ---- ghost state ----
    bool public violated;
    string public violation;
    mapping(bytes32 => uint256) public executions;
    uint256 public ghostDay;
    uint256 public ghostOutflowToday;
    uint256 public ghostMaxDailyCapToday;
    bool public ghostRevoked;
    uint64 public ghostValidUntil;
    uint128 public ghostPerTxUpper;
    uint128 public ghostDailyUpper;
    uint64 public ghostQueuedEta;
    uint256 public successfulAgentPayments;
    uint256 public blockedAgentCalls;
    uint256 private _fresh;

    constructor(
        PolicyVault vault_,
        MockUSDC usdc_,
        SavingsPool pool_,
        address owner_,
        address guardian_,
        address agent_,
        address[] memory allowed_,
        address pendingRecipient_,
        address[] memory outsiders_,
        uint64 validUntil
    ) {
        vault = vault_;
        usdc = usdc_;
        pool = pool_;
        owner = owner_;
        guardian = guardian_;
        agent = agent_;
        _allowed = allowed_;
        pendingRecipient = pendingRecipient_;
        _outsiders = outsiders_;
        ghostValidUntil = validUntil;
        for (uint256 i = 0; i < _idPool.length; ++i) {
            _idPool[i] = keccak256(abi.encode("pool-intent", i));
        }
        (, uint128 perTx, uint128 daily) = vault.tokens(address(usdc));
        ghostPerTxUpper = perTx;
        ghostDailyUpper = daily;
        ghostDay = block.timestamp / 1 days;
        ghostMaxDailyCapToday = daily;
    }

    // =====================================================================
    // Hostile agent actions
    // =====================================================================

    function agentTransfer(uint256 toSeed, uint256 amount, uint256 idSeed) external {
        _rollDay();
        address to = _anyRecipient(toSeed);
        // Mostly within the caps; one time in eight anything up to 3x the per-transaction cap.
        amount = _roll(amount, 8) == 0 ? bound(amount, 0, 1500e6) : bound(amount, 1, 300e6);
        bytes32 id = _intentId(idSeed);
        bool wasPaused = vault.paused();

        vm.prank(agent);
        try vault.executeTransfer(address(usdc), to, amount, id) {
            _onAgentPayment(to, amount, id, wasPaused);
        } catch (bytes memory reason) {
            ++blockedAgentCalls;
            ++blockedBy[bytes4(reason)];
        }
    }

    /// @notice Blocked transfers per revert selector, to show which guard stopped the attacks.
    mapping(bytes4 => uint256) public blockedBy;

    function agentBatch(uint256 count, uint256 seed, uint256 idSeed) external {
        _rollDay();
        count = bound(count, 0, 12);
        address[] memory to = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        // Half the batches are clean (allowlisted, small amounts); the rest mix in anything.
        bool clean = _roll(seed, 2) == 0;
        for (uint256 i = 0; i < count; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            to[i] = clean ? _allowed[r % _allowed.length] : _anyRecipient(r);
            amounts[i] = clean ? bound(r >> 128, 1, 100e6) : bound(r >> 128, 1, 600e6);
        }
        bytes32 id = _intentId(idSeed);
        bool wasPaused = vault.paused();

        vm.prank(agent);
        try vault.executeBatch(address(usdc), to, amounts, id) {
            if (count == 0 || count > 10) _fail("inv: a batch of invalid size executed");
            _recordExecution(id);
            for (uint256 i = 0; i < count; ++i) {
                _onAgentPayment(to[i], amounts[i], vault.itemIntentId(id, i), wasPaused);
            }
        } catch {
            ++blockedAgentCalls;
        }
    }

    function agentRequest(uint256 toSeed, uint256 amount, uint256 idSeed) external {
        address to = _anyRecipient(toSeed);
        amount = bound(amount, 1, 1_000_000e6);
        bytes32 id = _intentId(idSeed);
        uint256 before = usdc.balanceOf(address(vault));
        bool wasPaused = vault.paused();
        vm.prank(agent);
        try vault.requestTransfer(address(usdc), to, amount, id, bytes32(0)) {
            if (usdc.balanceOf(address(vault)) != before) _fail("a request moved funds");
            if (wasPaused) _fail("inv4: request created while paused");
            _checkSession();
            _recordExecution(id);
        } catch {
            ++blockedAgentCalls;
        }
    }

    function agentDeposit(uint256 amount) external {
        amount = bound(amount, 0, 1500e6);
        uint256 outsideBefore = _outsideBalance();
        bool wasPaused = vault.paused();
        vm.prank(agent);
        try vault.depositToSavings(amount) {
            if (wasPaused) _fail("inv4: deposit while paused");
            _checkSession();
            _checkSavingsContained(outsideBefore);
            if (usdc.balanceOf(address(vault)) < vault.minBuffer(address(usdc))) {
                _fail("inv5: deposit took the vault below the buffer");
            }
        } catch {
            ++blockedAgentCalls;
        }
    }

    function agentWithdraw(uint256 amount) external {
        amount = bound(amount, 0, 5000e6);
        uint256 outsideBefore = _outsideBalance();
        bool wasPaused = vault.paused();
        vm.prank(agent);
        try vault.withdrawFromSavings(amount) {
            if (wasPaused) _fail("inv4: withdrawal while paused");
            _checkSession();
            _checkSavingsContained(outsideBefore);
        } catch {
            ++blockedAgentCalls;
        }
    }

    /// @dev Someone who is not the agent tries the agent paths. Must always fail.
    function outsiderTransfer(uint256 who, uint256 toSeed, uint256 amount) external {
        address caller = _outsiders[who % _outsiders.length];
        address to = _anyRecipient(toSeed);
        amount = bound(amount, 1, 500e6);
        bytes32 id = keccak256(abi.encode("outsider", ++_fresh));
        vm.prank(caller);
        try vault.executeTransfer(address(usdc), to, amount, id) {
            _fail("inv3: a non-agent executed a transfer");
        } catch {}
    }

    // =====================================================================
    // Owner and guardian actions
    // =====================================================================

    function ownerSetLimits(uint128 perTx, uint128 daily) external {
        // Mostly realistic caps; one time in eight anything, including zero.
        if (_roll(daily, 8) == 0) {
            daily = uint128(bound(daily, 0, 3000e6));
            perTx = uint128(bound(perTx, 0, daily));
        } else {
            daily = uint128(bound(daily, 500e6, 3000e6));
            perTx = uint128(bound(perTx, 100e6, daily));
        }
        vm.prank(owner);
        vault.setTokenLimits(address(usdc), perTx, daily);
        (,, uint64 eta) = vault.pendingIncrease(address(usdc));
        ghostQueuedEta = eta;
        _checkCapsWithinUpperBound();
    }

    function executeIncrease(uint256 callerSeed) external {
        (uint128 perTx, uint128 daily, uint64 eta) = vault.pendingIncrease(address(usdc));
        address caller = callerSeed % 2 == 0 ? _outsiders[0] : owner;
        vm.prank(caller);
        try vault.executeLimitIncrease(address(usdc)) {
            if (eta == 0 || block.timestamp < eta || eta != ghostQueuedEta) {
                _fail("inv7: a limit increase applied before its eta");
            }
            if (perTx > ghostPerTxUpper) ghostPerTxUpper = perTx;
            if (daily > ghostDailyUpper) ghostDailyUpper = daily;
            if (daily > ghostMaxDailyCapToday) ghostMaxDailyCapToday = daily;
            ghostQueuedEta = 0;
        } catch {}
        _checkCapsWithinUpperBound();
    }

    function guardianCancelIncrease() external {
        vm.prank(guardian);
        try vault.cancelLimitIncrease(address(usdc)) {
            ghostQueuedEta = 0;
        } catch {}
    }

    /// @dev Pauses one time in four it is picked, so most of the run happens with a live vault.
    function pauseVault(uint256 seed) external {
        if (vault.paused() || _roll(seed, 4) != 0) return;
        vm.prank(_roll(seed, 2) == 0 ? guardian : owner);
        vault.pause();
    }

    function unpauseVault() external {
        if (!vault.paused()) return;
        vm.prank(owner);
        vault.unpause();
    }

    /// @dev Revokes one time in four it is picked.
    function revokeSession(uint256 seed) external {
        if (_roll(seed, 4) != 0) return;
        vm.prank(_roll(seed, 2) == 0 ? guardian : owner);
        vault.revokeAgent();
        ghostRevoked = true;
    }

    function regrantSession(uint256 duration) external {
        // Usually a week or more; sometimes a session of seconds, to test expiry edges.
        duration = _roll(duration, 4) == 0 ? bound(duration, 1, 1 days) : bound(duration, 7 days, 30 days);
        uint64 until = uint64(block.timestamp + duration);
        vm.prank(owner);
        vault.setAgent(agent, until);
        ghostRevoked = false;
        ghostValidUntil = until;
    }

    /// @dev An honest owner approves pending requests, but only to recipients they know.
    function ownerApprove(uint256 idSeed) external {
        uint256 count = vault.requestCount();
        if (count == 0) return;
        uint256 id = (idSeed % count) + 1;
        PolicyVault.Request memory r = vault.getRequest(id);
        if (!_isAllowed(r.to)) return;
        // Approvals may legally dip below the buffer (the owner decides); this owner chooses not to,
        // so the global buffer invariant isolates what the agent can do.
        uint256 balance = usdc.balanceOf(address(vault));
        if (balance < r.amount || balance - r.amount < vault.minBuffer(address(usdc))) return;
        bool wasPaused = vault.paused();
        vm.prank(owner);
        try vault.approveRequest(id) {
            if (wasPaused) _fail("inv4: approval paid while paused");
        } catch {}
    }

    function topUp(uint256 amount) external {
        amount = bound(amount, 1, 2000e6);
        usdc.mint(address(vault), amount);
    }

    function warp(uint256 secs) external {
        // Usually minutes to hours; sometimes past a day boundary or the 24-hour timelock.
        secs = _roll(secs, 4) == 0 ? bound(secs, 0, 2 days) : bound(secs, 0, 6 hours);
        vm.warp(block.timestamp + secs);
        _rollDay();
    }

    // =====================================================================
    // Views for the invariant test
    // =====================================================================

    function outsiders() external view returns (address[] memory) {
        return _outsiders;
    }

    function allowed() external view returns (address[] memory) {
        return _allowed;
    }

    // =====================================================================
    // Internals
    // =====================================================================

    function _onAgentPayment(address to, uint256 amount, bytes32 id, bool wasPaused) internal {
        ++successfulAgentPayments;
        if (wasPaused) _fail("inv4: agent paid while paused");
        _checkSession();
        if (!_isAllowed(to)) _fail("inv2: paid a non-allowlisted or inactive recipient");
        if (usdc.balanceOf(address(vault)) < vault.minBuffer(address(usdc))) {
            _fail("inv5: agent transfer took the vault below the buffer");
        }
        _recordExecution(id);
        ghostOutflowToday += amount;
        if (ghostOutflowToday > ghostMaxDailyCapToday) _fail("inv1: agent spend exceeded the daily cap");
    }

    function _checkSession() internal {
        if (ghostRevoked) _fail("inv3: agent acted after revoke");
        if (block.timestamp > ghostValidUntil) _fail("inv3: agent acted after expiry");
    }

    function _recordExecution(bytes32 id) internal {
        if (++executions[id] > 1) _fail("inv6: an intent ID executed twice");
    }

    function _checkSavingsContained(uint256 outsideBefore) internal {
        if (_outsideBalance() != outsideBefore) _fail("inv8: savings moved funds outside the vault and pool");
        if (usdc.allowance(address(vault), address(pool)) != 0) _fail("inv8: savings left an allowance");
    }

    function _checkCapsWithinUpperBound() internal {
        (, uint128 perTx, uint128 daily) = vault.tokens(address(usdc));
        if (perTx > ghostPerTxUpper || daily > ghostDailyUpper) _fail("inv7: caps rose without the timelock");
    }

    function _rollDay() internal {
        uint256 today = block.timestamp / 1 days;
        if (today != ghostDay) {
            ghostDay = today;
            ghostOutflowToday = 0;
            (,, uint128 daily) = vault.tokens(address(usdc));
            ghostMaxDailyCapToday = daily;
        }
    }

    function _outsideBalance() internal view returns (uint256 total) {
        for (uint256 i = 0; i < _allowed.length; ++i) {
            total += usdc.balanceOf(_allowed[i]);
        }
        for (uint256 i = 0; i < _outsiders.length; ++i) {
            total += usdc.balanceOf(_outsiders[i]);
        }
        total += usdc.balanceOf(pendingRecipient) + usdc.balanceOf(agent) + usdc.balanceOf(owner);
    }

    function _isAllowed(address who) internal view returns (bool) {
        for (uint256 i = 0; i < _allowed.length; ++i) {
            if (_allowed[i] == who) return true;
        }
        return false;
    }

    /// @dev Three times in four an allowlisted recipient (so payments often succeed and the
    ///      invariants see real outflows); otherwise an outsider or the not-yet-active recipient.
    function _anyRecipient(uint256 seed) internal view returns (address) {
        if (_roll(seed, 4) != 0) return _allowed[(seed >> 2) % _allowed.length];
        uint256 i = (seed >> 2) % (_outsiders.length + 1);
        return i < _outsiders.length ? _outsiders[i] : pendingRecipient;
    }

    function _intentId(uint256 seed) internal returns (bytes32) {
        // One time in four reuse an ID from a small pool, to hammer replay protection.
        if (_roll(seed, 4) == 0) return _idPool[(seed >> 2) % _idPool.length];
        return keccak256(abi.encode("fresh-intent", ++_fresh));
    }

    /// @dev Fuzzers favour edge values such as 0, which would make every `% n == 0` branch fire far
    ///      more often than intended; hashing first gives a fair one-in-n choice.
    function _roll(uint256 seed, uint256 n) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed))) % n;
    }

    function _fail(string memory reason) internal {
        if (!violated) {
            violated = true;
            violation = reason;
        }
    }
}
