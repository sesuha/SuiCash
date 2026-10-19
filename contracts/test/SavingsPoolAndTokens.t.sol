// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";
import {SavingsPool} from "../src/SavingsPool.sol";
import {HostileToken} from "../src/test/HostileToken.sol";
import {MockUSDC} from "../src/test/MockUSDC.sol";

contract SavingsPoolAndTokensTest is Test {
    MockUSDC internal usdc;
    SavingsPool internal pool;
    address internal owner = makeAddr("poolOwner");
    address internal saver = makeAddr("saver");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        usdc = new MockUSDC();
        pool = new SavingsPool(usdc, owner);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), amount);
        shares = pool.deposit(amount, who);
        vm.stopPrank();
    }

    function test_MockUSDC_HasSixDecimalsAndOpenMint() public {
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.symbol(), "USDC");
        vm.prank(attacker);
        usdc.mint(attacker, 5e6);
        assertEq(usdc.balanceOf(attacker), 5e6);
    }

    function test_HostileToken_CarriesInjectionPayload() public {
        HostileToken hostile = new HostileToken();
        assertEq(hostile.name(), hostile.PAYLOAD());
        assertGt(bytes(hostile.symbol()).length, 0);
        hostile.airdrop(saver, 1e18);
        assertEq(hostile.balanceOf(saver), 1e18);
    }

    function test_SavingsPool_IsERC4626OverUSDC() public view {
        assertEq(pool.asset(), address(usdc));
        assertEq(pool.owner(), owner);
        assertEq(pool.decimals(), 12); // 6 asset decimals + 6 offset
    }

    function test_SavingsPool_DepositWithdrawRoundTrip() public {
        _deposit(saver, 1000e6);
        assertEq(pool.maxWithdraw(saver), 1000e6);
        vm.prank(saver);
        pool.withdraw(1000e6, saver, saver);
        assertEq(usdc.balanceOf(saver), 1000e6);
        assertEq(pool.balanceOf(saver), 0);
    }

    function test_SavingsPool_AccrueRaisesShareValue() public {
        _deposit(saver, 1000e6);
        usdc.mint(owner, 50e6);
        vm.startPrank(owner);
        usdc.approve(address(pool), 50e6);
        vm.expectEmit(address(pool));
        emit SavingsPool.YieldAccrued(owner, 50e6);
        pool.accrue(50e6);
        vm.stopPrank();
        assertApproxEqAbs(pool.maxWithdraw(saver), 1050e6, 2);
    }

    function test_SavingsPool_AccrueOnlyOwnerAndNonZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        pool.accrue(1);
        vm.expectRevert(SavingsPool.ZeroAmount.selector);
        vm.prank(owner);
        pool.accrue(0);
    }

    function test_SavingsPool_InflationAttackIsUneconomic() public {
        // Classic first-depositor attack: deposit 1 unit, donate a lot, hope the victim's
        // deposit rounds down to nothing.
        _deposit(attacker, 1);
        usdc.mint(attacker, 1000e6);
        vm.prank(attacker);
        usdc.transfer(address(pool), 1000e6);

        _deposit(saver, 1000e6);
        // With the 6-digit virtual offset the victim keeps essentially everything...
        assertGe(pool.maxWithdraw(saver), 999e6);
        // ...and the attacker loses most of the donation.
        assertLt(pool.maxWithdraw(attacker), 600e6);
    }
}
