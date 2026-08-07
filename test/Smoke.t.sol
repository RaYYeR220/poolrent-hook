// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolRentFixture} from "./utils/PoolRentFixture.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract SmokeTest is PoolRentFixture {
    function test_swap_zeroForOne_exactInput() public {
        BalanceDelta d = _swap(trader, true, -1 ether);
        assertLt(_tokenDelta(d), 0, "paid token");
        assertGt(_quoteDelta(d), 0, "received quote");
        assertGt(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "platform accrued");
        _assertSolvent();
    }

    function test_swap_zeroForOne_exactOutput() public {
        BalanceDelta d = _swap(trader, true, 1 ether);
        assertEq(_quoteDelta(d), 1 ether, "exact quote out");
        assertGt(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "platform accrued");
        _assertSolvent();
    }

    function test_swap_oneForZero_exactInput() public {
        BalanceDelta d = _swap(trader, false, -1 ether);
        assertEq(_quoteDelta(d), -1 ether, "exact quote in");
        assertGt(_tokenDelta(d), 0, "received token");
        assertGt(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "platform accrued");
        _assertSolvent();
    }

    function test_swap_oneForZero_exactOutput() public {
        BalanceDelta d = _swap(trader, false, 1 ether);
        assertEq(_tokenDelta(d), 1 ether, "exact token out");
        assertLt(_quoteDelta(d), 0, "paid quote");
        assertGt(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "platform accrued");
        _assertSolvent();
    }

    function test_rentFlowsToLiquidityProviders() public {
        _becomeManager(alice, 1e15, 10 ether);
        vm.roll(block.number + 50);

        uint256 liquidityBefore = _poolLiquidity();
        _swap(trader, true, -1 ether);

        assertGt(hook.totalDeposits(), 0, "deposit remains");
        assertLt(hook.deposits(alice), 10 ether, "rent charged");
        assertEq(_poolLiquidity(), liquidityBefore, "liquidity untouched by donate");
        _assertSolvent();
    }

    function test_managerSetsLpFee() public {
        _becomeManager(alice, 1e15, 10 ether);
        vm.prank(alice);
        hook.setLpFee(500);
        assertEq(hook.currentLpFee(), 500, "manager fee applied");

        // A manager earns nothing in the block it took the seat, so move past it first.
        vm.roll(block.number + 1);
        _swap(trader, true, -1 ether);
        assertGt(hook.feeOwed(alice), 0, "manager accrued its fee share");
        _assertSolvent();
    }

    function test_takingTheSeatIsNeverFree() public {
        uint256 before = weth.balanceOf(alice);
        _becomeManager(alice, 1e15, 10 ether);

        // Front-run a swap and leave in the same block: the entry rent is spent and the manager
        // share of the charge went to liquidity providers, so the round trip cannot turn a profit.
        _swap(trader, true, -10 ether);
        assertEq(hook.feeOwed(alice), 0, "no manager share in the entry block");

        uint256 remaining = hook.deposits(alice);
        vm.prank(alice);
        hook.withdrawDeposit(alice, remaining);
        assertLt(weth.balanceOf(alice), before, "round trip cost the entry rent");
        _assertSolvent();
    }

    function test_evictionWhenDepositRunsOut() public {
        _becomeManager(alice, 1e16, 2e18);
        vm.roll(block.number + 1000);
        hook.poke();

        assertEq(hook.manager(), address(0), "evicted");
        assertEq(hook.currentLpFee(), hook.DEFAULT_LP_FEE(), "fee falls back");
        _assertSolvent();
    }
}
