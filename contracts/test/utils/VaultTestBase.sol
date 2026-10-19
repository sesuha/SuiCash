// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PolicyVault} from "../../src/PolicyVault.sol";
import {SavingsPool} from "../../src/SavingsPool.sol";
import {MockUSDC} from "../../src/test/MockUSDC.sol";

/// @notice Shared fixture: a vault with the handbook's demo limits (500 per transaction, 1,000 per
///         day, 50 buffer), a guardian, an agent session, three active recipients and an attacker.
abstract contract VaultTestBase is Test {
    uint128 internal constant PER_TX = 500e6;
    uint128 internal constant DAILY = 1000e6;
    uint256 internal constant BUFFER = 50e6;
    uint256 internal constant FUND = 2000e6;
    uint128 internal constant ALICE_CAP = 500e6;
    uint128 internal constant BOB_CAP = 300e6;
    uint128 internal constant CAROL_CAP = 200e6;

    MockUSDC internal usdc;
    SavingsPool internal pool;
    PolicyVault internal vault;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal attacker = makeAddr("attacker");
    address internal stranger = makeAddr("stranger");

    uint64 internal sessionEnd;
    uint256 private _nonce;

    function setUp() public virtual {
        // A realistic timestamp (mid-afternoon UTC), not the default of 1.
        vm.warp(1_750_000_000);

        usdc = new MockUSDC();
        pool = new SavingsPool(usdc, owner);
        vault = new PolicyVault(owner, address(pool));

        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setTokenLimits(address(usdc), PER_TX, DAILY);
        vault.setMinBuffer(address(usdc), BUFFER);
        vault.addRecipient(alice, ALICE_CAP);
        vault.addRecipient(bob, BOB_CAP);
        vault.addRecipient(carol, CAROL_CAP);
        sessionEnd = uint64(block.timestamp + 7 days);
        vault.setAgent(agent, sessionEnd);
        vm.stopPrank();

        usdc.mint(address(vault), FUND);
        // Recipients activate after the default 1-hour delay.
        skip(1 hours);
    }

    function _intent() internal returns (bytes32) {
        return keccak256(abi.encode("suicash.test.intent", ++_nonce));
    }

    function _pay(address to, uint256 amount) internal {
        bytes32 id = _intent();
        vm.prank(agent);
        vault.executeTransfer(address(usdc), to, amount, id);
    }

    function _err(bytes4 selector) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector);
    }
}
