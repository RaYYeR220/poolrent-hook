// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolRentFixture} from "./utils/PoolRentFixture.sol";
import {PoolRentHook} from "../src/PoolRentHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev The auction is the only mutable authority in this system, so it carries the whole trust
///      story: who may set the LP fee, on what terms the seat changes hands, and what happens to the
///      money when a manager runs out. Every test here ends on the solvency invariant, because a
///      rule that is only true while the hook is short of WETH is not a rule.
contract AuctionTest is PoolRentFixture {
    using StateLibrary for IPoolManager;

    /// @dev 0.001 WETH per block, so the 100-block deposit floor is 0.1 WETH and stays readable.
    uint128 internal constant RENT = 1e15;
    uint256 internal constant DEPOSIT = 10 ether;

    bytes32 private constant RENT_DONATED_TOPIC = keccak256("RentDonated(uint256)");

    /* -------------------------------------------------------------------------- */
    /*                                  First bid                                  */
    /* -------------------------------------------------------------------------- */

    function test_firstBid_takesAnUnmanagedPool() public {
        uint256 start = block.number;
        _becomeManager(alice, RENT, DEPOSIT);

        assertEq(hook.manager(), alice, "manager");
        assertEq(hook.rentPerBlock(), RENT, "rent");
        assertEq(hook.deposits(alice), DEPOSIT - RENT, "deposit credited, less the entry block");
        assertEq(hook.totalDeposits(), DEPOSIT - RENT, "total deposits");
        assertEq(hook.pendingRent(), RENT, "the entry block is owed to the LPs straight away");
        assertEq(hook.tenureStartBlock(), start, "tenure starts now");
        assertEq(hook.currentLpFee(), hook.DEFAULT_LP_FEE(), "a fresh manager starts at the default fee");
        _assertSolvent();
    }

    function test_firstBid_atTheMinimumRentWins() public {
        uint128 minRent = uint128(hook.MIN_RENT_PER_BLOCK());
        _becomeManager(alice, minRent, _seatDeposit(minRent));

        assertEq(hook.manager(), alice, "an empty pool has no premium to beat");
        assertEq(hook.rentPerBlock(), minRent, "rent");
        _assertSolvent();
    }

    /// @dev Taking the seat is never free: one block of rent is charged on entry, before the seat is
    ///      recorded, so a bid can never be a free option on the swap that follows it.
    function test_bid_paysOneBlockOfRentOnEntry() public {
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + hook.MIN_TENURE_BLOCKS());

        uint256 depositsBefore = hook.totalDeposits();
        uint256 pendingBefore = hook.pendingRent();
        uint128 challengerRent = RENT * 2;

        _becomeManager(bob, challengerRent, DEPOSIT);

        uint256 outgoingOwed = uint256(RENT) * hook.MIN_TENURE_BLOCKS(); // charged on the way out
        assertEq(hook.deposits(bob), DEPOSIT - challengerRent, "the challenger pays its own entry block");
        assertEq(hook.pendingRent(), pendingBefore + outgoingOwed + challengerRent, "both charges land on the LP side");
        assertEq(hook.totalDeposits(), depositsBefore + DEPOSIT - outgoingOwed - challengerRent, "and nowhere else");
        _assertSolvent();
    }

    /// @dev Bid and leave in the same block and the round trip costs exactly one block of rent.
    function test_bid_thenImmediateWithdrawCostsOneBlockOfRent() public {
        uint256 before = weth.balanceOf(alice);
        _becomeManager(alice, RENT, DEPOSIT);
        uint256 remaining = hook.deposits(alice);

        vm.prank(alice);
        hook.withdrawDeposit(alice, remaining);

        assertEq(hook.manager(), address(0), "emptying the deposit gives up the seat");
        assertEq(weth.balanceOf(alice), before - RENT, "down exactly one block of rent");
        assertEq(hook.deposits(alice), 0, "nothing else held back");
        assertEq(hook.pendingRent(), RENT, "and that block is owed to the LPs");
        _assertSolvent();
    }

    function test_firstBid_belowTheMinimumRentReverts() public {
        uint128 minRent = uint128(hook.MIN_RENT_PER_BLOCK());

        vm.prank(alice);
        vm.expectRevert(PoolRentHook.RentTooLow.selector);
        hook.bid(minRent - 1, DEPOSIT);

        vm.prank(alice);
        vm.expectRevert(PoolRentHook.RentTooLow.selector);
        hook.bid(0, DEPOSIT);

        assertEq(hook.manager(), address(0), "pool stays unmanaged");
        assertEq(hook.totalDeposits(), 0, "a rejected bid pulls nothing");
        _assertSolvent();
    }

    /// @dev The floor is measured after the entry payment, so a new manager has to fund the block it
    ///      buys the seat in *and* the tenure it is buying. Exactly one tenure is one block short.
    function test_firstBid_depositFloorIsTheEntryBlockPlusATenure() public {
        uint256 tenureCost = uint256(RENT) * hook.MIN_DEPOSIT_BLOCKS();

        vm.prank(alice);
        vm.expectRevert(PoolRentHook.DepositTooSmall.selector);
        hook.bid(RENT, tenureCost);

        _becomeManager(bob, RENT, tenureCost + RENT);
        assertEq(hook.manager(), bob, "one block more is enough");
        assertEq(hook.deposits(bob), tenureCost, "and a full tenure is left once the entry block is paid");
        assertEq(hook.deposits(alice), 0, "the failed bid was rolled back whole");
        _assertSolvent();
    }

    function test_bid_countsADepositPostedEarlier() public {
        vm.prank(alice);
        hook.depositRent(DEPOSIT);

        vm.prank(alice);
        hook.bid(RENT, 0);

        assertEq(hook.manager(), alice, "the floor is checked against the balance, not the top-up");
        assertEq(hook.deposits(alice), DEPOSIT - RENT, "only the entry block came out of it");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                              Tenure protection                              */
    /* -------------------------------------------------------------------------- */

    function test_challenger_isRejectedInsideTheTenure() public {
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + 1);

        vm.prank(bob);
        vm.expectRevert(PoolRentHook.TenureProtected.selector);
        hook.bid(RENT * 2, DEPOSIT);

        assertEq(hook.manager(), alice, "incumbent keeps the seat");
        _assertSolvent();
    }

    /// @dev The boundary is the whole point of a minimum tenure: one block early must fail and the
    ///      block itself must succeed, or a manager cannot price the seat it just bought.
    function test_challenger_tenureBoundaryIsExact() public {
        uint256 start = block.number;
        _becomeManager(alice, RENT, DEPOSIT);

        vm.roll(start + hook.MIN_TENURE_BLOCKS() - 1);
        vm.prank(bob);
        vm.expectRevert(PoolRentHook.TenureProtected.selector);
        hook.bid(RENT * 2, DEPOSIT);

        vm.roll(start + hook.MIN_TENURE_BLOCKS());
        _becomeManager(bob, RENT * 2, DEPOSIT);

        assertEq(hook.manager(), bob, "the boundary block is open");
        assertEq(hook.tenureStartBlock(), block.number, "the winner gets a fresh tenure");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                              Outbid threshold                               */
    /* -------------------------------------------------------------------------- */

    function test_outbid_thresholdIsExactlyTenPercent() public {
        uint256 tenure = hook.MIN_TENURE_BLOCKS();
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + tenure);

        vm.prank(bob);
        vm.expectRevert(PoolRentHook.OutbidTooLow.selector);
        hook.bid(uint128(uint256(RENT) * 109 / 100), DEPOSIT);

        _becomeManager(bob, uint128(uint256(RENT) * 110 / 100), DEPOSIT);
        assertEq(hook.manager(), bob, "110% is enough");
        assertEq(hook.rentPerBlock(), uint256(RENT) * 110 / 100, "standing rent is the winning bid");

        // Anything over the threshold wins just as well.
        vm.roll(block.number + tenure);
        _becomeManager(carol, RENT * 3, DEPOSIT);
        assertEq(hook.manager(), carol, "a bid well over the threshold wins");
        _assertSolvent();
    }

    /// @dev At the smallest legal rent 10% is exact, so the last rejected bid is one wei short.
    function test_outbid_roundingAtTheMinimumRent() public {
        uint128 minRent = uint128(hook.MIN_RENT_PER_BLOCK());
        uint256 start = block.number;
        // A deposit far above the floor, so the tenure elapses without evicting the incumbent and the
        // challenger really is facing a standing bid.
        _becomeManager(alice, minRent, 1 ether);
        vm.roll(start + hook.MIN_TENURE_BLOCKS());

        uint128 required = uint128(uint256(minRent) * 110 / 100);
        vm.prank(bob);
        vm.expectRevert(PoolRentHook.OutbidTooLow.selector);
        hook.bid(required - 1, 1 ether);

        _becomeManager(bob, required, 1 ether);
        assertEq(hook.rentPerBlock(), required, "the exact threshold is accepted");
        _assertSolvent();
    }

    /// @dev With a rent that is not divisible by ten the threshold has to round up, otherwise a
    ///      challenger could take the seat for slightly less than the advertised 110%.
    function test_outbid_roundingOnAnIndivisibleRent() public {
        uint128 rent = 3e15 + 7;
        uint256 start = block.number;
        _becomeManager(alice, rent, DEPOSIT);
        vm.roll(start + hook.MIN_TENURE_BLOCKS());

        uint128 required = uint128((uint256(rent) * hook.OUTBID_PERCENT() + 99) / 100);
        vm.prank(bob);
        vm.expectRevert(PoolRentHook.OutbidTooLow.selector);
        hook.bid(required - 1, DEPOSIT);

        _becomeManager(bob, required, DEPOSIT);
        assertEq(hook.rentPerBlock(), required, "rounded-up threshold accepted");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                             Incumbent behaviour                             */
    /* -------------------------------------------------------------------------- */

    function test_incumbent_raisesItsOwnRentWithoutAPremium() public {
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + 10);

        // One wei more, inside its own tenure: the 10% rule protects LPs from cheap challengers,
        // not from a manager paying them more.
        vm.prank(alice);
        hook.bid(RENT + 1, 0);

        assertEq(hook.manager(), alice, "still the manager");
        assertEq(hook.rentPerBlock(), RENT + 1, "rent raised");
        // The entry block was paid once, when she took the seat; holding it is not a new entry.
        assertEq(hook.deposits(alice), DEPOSIT - RENT - uint256(RENT) * 10, "no second entry payment");
        _assertSolvent();
    }

    /// @dev The floor is asymmetric on purpose. A challenger pays an entry block first, so it needs
    ///      a tenure plus that block; an incumbent pays nothing to re-bid, so the bare tenure is
    ///      exactly enough. Both boundaries are one wei wide.
    function test_incumbent_rebidFloorIsTheBareTenure() public {
        uint256 tenureCost = uint256(RENT) * hook.MIN_DEPOSIT_BLOCKS();
        _becomeManager(alice, RENT, tenureCost + RENT);
        assertEq(hook.deposits(alice), tenureCost, "exactly one tenure left after entry");

        vm.prank(alice);
        hook.bid(RENT, 0);
        assertEq(hook.manager(), alice, "an incumbent re-bids on the bare tenure");
        assertEq(hook.deposits(alice), tenureCost, "and pays nothing to do it");

        // One wei per block more and the same balance no longer funds a full tenure.
        vm.prank(alice);
        vm.expectRevert(PoolRentHook.DepositTooSmall.selector);
        hook.bid(RENT + 1, 0);

        assertEq(hook.rentPerBlock(), RENT, "rent unchanged");
        _assertSolvent();
    }

    function test_incumbent_cannotLowerItsRent() public {
        _becomeManager(alice, RENT, DEPOSIT);

        vm.prank(alice);
        vm.expectRevert(PoolRentHook.OutbidTooLow.selector);
        hook.bid(RENT - 1, 0);

        assertEq(hook.rentPerBlock(), RENT, "rent unchanged");
        _assertSolvent();
    }

    function test_incumbent_topUpDoesNotExtendProtection() public {
        uint256 start = block.number;
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(start + 50);

        vm.prank(alice);
        hook.depositRent(5 ether);

        assertEq(hook.tenureStartBlock(), start, "topping up does not restart the tenure");
        assertEq(hook.rentPerBlock(), RENT, "topping up does not reprice the seat");
        assertEq(hook.deposits(alice), DEPOSIT - RENT - uint256(RENT) * 50 + 5 ether, "rent charged before the top-up");

        // The protection still expires on the original schedule.
        vm.roll(start + hook.MIN_TENURE_BLOCKS());
        _becomeManager(bob, RENT * 2, DEPOSIT);
        assertEq(hook.manager(), bob, "challenger still gets its window");
        _assertSolvent();
    }

    /// @dev The window belongs to the tenure, not to the last bid. If re-bidding restarted it, an
    ///      incumbent could hold the seat forever at a constant rent by bidding every 99 blocks and
    ///      the auction would stop being contestable.
    function test_incumbent_cannotRenewItsOwnProtection() public {
        uint256 start = block.number;
        uint128 raised = RENT + 1;
        _becomeManager(alice, RENT, DEPOSIT);

        // Three re-bids inside the window, the last one raising the rent.
        vm.roll(start + 40);
        vm.prank(alice);
        hook.bid(RENT, 0);
        vm.roll(start + 80);
        vm.prank(alice);
        hook.bid(RENT, 0);
        vm.roll(start + 99);
        vm.prank(alice);
        hook.bid(raised, 0);
        assertEq(hook.tenureStartBlock(), start, "the window still starts at the handover");

        vm.roll(start + hook.MIN_TENURE_BLOCKS());
        _becomeManager(bob, uint128((uint256(raised) * hook.OUTBID_PERCENT() + 99) / 100), DEPOSIT);
        assertEq(hook.manager(), bob, "the seat is contestable on the original schedule");
        _assertSolvent();
    }

    /// @dev A handover resets the fee to the documented default rather than leaving the pool priced
    ///      by a manager that no longer holds the seat and no longer pays for it.
    function test_newManager_startsFromTheDefaultLpFee() public {
        uint24 minFee = hook.MIN_LP_FEE();
        uint256 start = block.number;
        _becomeManager(alice, RENT, DEPOSIT);
        vm.prank(alice);
        hook.setLpFee(minFee);
        assertEq(hook.currentLpFee(), minFee, "the incumbent's fee applies while it holds the seat");

        vm.roll(start + hook.MIN_TENURE_BLOCKS());
        _becomeManager(bob, RENT * 2, DEPOSIT);
        assertEq(hook.currentLpFee(), hook.DEFAULT_LP_FEE(), "and is dropped the moment it does not");

        vm.prank(bob);
        hook.setLpFee(1_000);
        assertEq(hook.currentLpFee(), 1_000, "the new manager reprices from there");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                                Rent accrual                                 */
    /* -------------------------------------------------------------------------- */

    function test_accrual_chargesExactlyRentPerBlock() public {
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + 37);
        hook.poke();

        // The entry block was charged at the bid, so the tenure so far costs 38 blocks in total.
        uint256 owed = uint256(RENT) * 37;
        assertEq(hook.deposits(alice), DEPOSIT - RENT - owed, "deposit falls by rent * blocks");
        assertEq(hook.totalDeposits(), DEPOSIT - RENT - owed, "total deposits follow");
        assertEq(hook.pendingRent(), RENT + owed, "and the same amount is owed to the LPs");
        _assertSolvent();
    }

    function test_accrual_isIdempotentWithinOneBlock() public {
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + 5);
        hook.poke();

        uint256 deposited = hook.deposits(alice);
        uint256 pending = hook.pendingRent();

        // A second caller in the same block must not be able to charge the manager twice.
        hook.poke();
        vm.prank(bob);
        hook.poke();

        assertEq(hook.deposits(alice), deposited, "deposit charged once");
        assertEq(hook.pendingRent(), pending, "rent counted once");
        _assertSolvent();
    }

    function test_accrual_withoutAManagerChargesNothing() public {
        vm.roll(block.number + 500);
        hook.poke();

        assertEq(hook.pendingRent(), 0, "no manager, no rent");
        assertEq(hook.manager(), address(0), "still unmanaged");
        _assertSolvent();
    }

    function test_accrual_runsInsideTheSwap() public {
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + 25);

        _swap(trader, true, -1 ether);

        assertEq(hook.deposits(alice), DEPOSIT - RENT - uint256(RENT) * 25, "swap charged the elapsed blocks");
        assertEq(hook.pendingRent(), 0, "and handed the rent to the LPs in the same swap");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                            Eviction on exhaustion                           */
    /* -------------------------------------------------------------------------- */

    function test_eviction_landsOnTheExhaustingBlock() public {
        // The smallest deposit the auction accepts: the entry block plus exactly one tenure.
        uint256 deposit = _seatDeposit(RENT);
        uint256 start = block.number;
        _becomeManager(alice, RENT, deposit);
        assertEq(hook.deposits(alice), deposit - RENT, "entry block paid");

        vm.roll(start + 99);
        hook.poke();
        assertEq(hook.manager(), alice, "one block of rent left, still solvent");
        assertEq(hook.deposits(alice), RENT, "exactly one block left");

        vm.roll(start + 100);
        hook.poke();
        assertEq(hook.manager(), address(0), "evicted the block the deposit runs out");
        assertEq(hook.deposits(alice), 0, "deposit spent to the last wei");
        assertEq(hook.pendingRent(), deposit, "every charged wei is owed to the LPs");
        _assertSolvent();
    }

    function test_eviction_chargeIsCappedAtTheRemainingDeposit() public {
        uint256 deposit = _seatDeposit(RENT);
        _becomeManager(alice, RENT, deposit);

        // Rent owed on paper is four orders of magnitude over the deposit.
        vm.roll(block.number + 1_000_000);
        hook.poke();

        assertEq(hook.deposits(alice), 0, "deposit emptied");
        assertEq(hook.pendingRent(), deposit, "never charges more than the deposit");
        assertEq(hook.totalDeposits(), 0, "and the shortfall is not booked as a liability");
        _assertSolvent();
    }

    function test_eviction_resetsTheSeatAndReopensTheAuction() public {
        uint24 maxFee = hook.MAX_LP_FEE();
        _becomeManager(alice, RENT, _seatDeposit(RENT));
        vm.prank(alice);
        hook.setLpFee(maxFee);

        vm.roll(block.number + 200);
        vm.prank(carol);
        hook.poke();

        assertEq(hook.manager(), address(0), "seat is empty");
        assertEq(hook.rentPerBlock(), 0, "no standing rent");
        assertEq(hook.tenureStartBlock(), 0, "no standing tenure");
        assertEq(hook.currentLpFee(), hook.DEFAULT_LP_FEE(), "pool falls back to its default fee");

        // Nothing survives the eviction for the next bidder to beat.
        uint128 minRent = uint128(hook.MIN_RENT_PER_BLOCK());
        _becomeManager(carol, minRent, 1 ether);
        assertEq(hook.manager(), carol, "auction reopens at the minimum rent");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                             Eviction inside a swap                          */
    /* -------------------------------------------------------------------------- */

    /// @dev The swap path is the one place eviction must never be allowed to revert: an insolvent
    ///      manager is a bookkeeping problem, not a reason to take the pool offline.
    function test_swap_evictsAnExhaustedManagerAndStillExecutes() public {
        uint256 deposit = _seatDeposit(RENT);
        _becomeManager(alice, RENT, deposit);
        vm.roll(block.number + 5_000);

        vm.recordLogs();
        BalanceDelta delta = _swap(trader, true, -1 ether);
        uint256 donated = _lastDonation();

        assertGt(_quoteDelta(delta), 0, "swap executed");
        assertEq(hook.manager(), address(0), "manager evicted inside the swap");
        assertEq(hook.deposits(alice), 0, "deposit consumed");
        assertEq(hook.pendingRent(), 0, "nothing left owed");
        assertGt(donated, deposit, "the whole deposit reached the LPs, plus the orphaned fee share");

        // Losing the manager leaves the pool fully live on both sides at the default fee.
        assertGt(_quoteDelta(_swap(trader, true, -1 ether)), 0, "sell side live");
        assertLt(_quoteDelta(_swap(trader, false, -1 ether)), 0, "buy side live");
        assertEq(hook.currentLpFee(), hook.DEFAULT_LP_FEE(), "default fee");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                              Deposit withdrawal                             */
    /* -------------------------------------------------------------------------- */

    function test_withdraw_paysAChosenDestination() public {
        vm.prank(alice);
        hook.depositRent(DEPOSIT);

        uint256 before = weth.balanceOf(carol);
        vm.prank(alice);
        hook.withdrawDeposit(carol, 4 ether);

        assertEq(weth.balanceOf(carol), before + 4 ether, "paid out where the owner asked");
        assertEq(hook.deposits(alice), DEPOSIT - 4 ether, "balance reduced");
        assertEq(hook.totalDeposits(), DEPOSIT - 4 ether, "total deposits follow");
        _assertSolvent();
    }

    function test_withdraw_rejectsBadAmountsAndDestinations() public {
        vm.prank(alice);
        hook.depositRent(1 ether);

        vm.prank(alice);
        vm.expectRevert(PoolRentHook.InsufficientDeposit.selector);
        hook.withdrawDeposit(alice, 1 ether + 1);

        vm.prank(alice);
        vm.expectRevert(PoolRentHook.InsufficientDeposit.selector);
        hook.withdrawDeposit(alice, 0);

        vm.prank(alice);
        vm.expectRevert(PoolRentHook.ZeroAddress.selector);
        hook.withdrawDeposit(address(0), 1 ether);

        assertEq(hook.deposits(alice), 1 ether, "balance untouched");
        _assertSolvent();
    }

    function test_withdraw_evictedManagerKeepsItsRemainder() public {
        uint256 start = block.number;
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(start + hook.MIN_TENURE_BLOCKS());
        _becomeManager(bob, RENT * 2, DEPOSIT);

        // Her entry block plus every block she actually held the seat, and not one wei more.
        uint256 remaining = DEPOSIT - RENT - uint256(RENT) * hook.MIN_TENURE_BLOCKS();
        assertEq(hook.deposits(alice), remaining, "losing the seat is not losing the deposit");

        uint256 before = weth.balanceOf(alice);
        vm.prank(alice);
        hook.withdrawDeposit(alice, remaining);

        assertEq(weth.balanceOf(alice), before + remaining, "withdrawn in full");
        assertEq(hook.deposits(alice), 0, "nothing held back");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                                Self-eviction                                */
    /* -------------------------------------------------------------------------- */

    function test_withdraw_managerBelowTheFloorSelfEvicts() public {
        _becomeManager(alice, RENT, DEPOSIT);
        uint256 floor = uint256(RENT) * hook.MIN_DEPOSIT_BLOCKS();
        uint256 amount = hook.deposits(alice) - floor + 1; // one wei under the floor

        uint256 before = weth.balanceOf(alice);
        vm.prank(alice);
        hook.withdrawDeposit(alice, amount);

        assertEq(hook.manager(), address(0), "a manager who cannot fund a tenure gives up the seat");
        assertEq(weth.balanceOf(alice), before + amount, "the withdrawal still goes through");
        assertEq(hook.deposits(alice), floor - 1, "the rest is still hers");
        assertEq(hook.currentLpFee(), hook.DEFAULT_LP_FEE(), "pool falls back to its default fee");

        vm.prank(alice);
        hook.withdrawDeposit(alice, floor - 1);
        assertEq(hook.deposits(alice), 0, "and it comes out too");
        _assertSolvent();
    }

    function test_withdraw_managerDownToTheFloorKeepsTheSeat() public {
        uint256 start = block.number;
        _becomeManager(alice, RENT, DEPOSIT);
        uint256 floor = uint256(RENT) * hook.MIN_DEPOSIT_BLOCKS();
        uint256 spare = hook.deposits(alice) - floor;

        vm.prank(alice);
        hook.withdrawDeposit(alice, spare);

        assertEq(hook.manager(), alice, "still funded for a full tenure");
        assertEq(hook.rentPerBlock(), RENT, "rent unchanged");
        assertEq(hook.tenureStartBlock(), start, "tenure unchanged");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                               LP fee authority                              */
    /* -------------------------------------------------------------------------- */

    function test_setLpFee_rejectsEveryoneButTheManager() public {
        _becomeManager(alice, RENT, DEPOSIT);

        // The launch wallet, the immutable platform owner and the deployer of the test rig all have
        // exactly the same standing here as a stranger: none.
        address[4] memory outsiders = [bob, launchWallet, PROGRAMMABLE_OWNER, address(this)];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(PoolRentHook.NotManager.selector);
            hook.setLpFee(500);
        }

        assertEq(hook.currentLpFee(), hook.DEFAULT_LP_FEE(), "fee untouched");
        _assertSolvent();
    }

    function test_setLpFee_rejectsAnEvictedManager() public {
        _becomeManager(alice, RENT, _seatDeposit(RENT));
        vm.roll(block.number + 200);

        // The accrual at the top of the call evicts her before the authority check runs.
        vm.prank(alice);
        vm.expectRevert(PoolRentHook.NotManager.selector);
        hook.setLpFee(500);

        assertEq(hook.currentLpFee(), hook.DEFAULT_LP_FEE(), "fee falls back");
        _assertSolvent();
    }

    function test_setLpFee_rejectsOutOfBounds() public {
        uint24 minFee = hook.MIN_LP_FEE();
        uint24 maxFee = hook.MAX_LP_FEE();
        _becomeManager(alice, RENT, DEPOSIT);

        vm.prank(alice);
        vm.expectRevert(PoolRentHook.InvalidLpFee.selector);
        hook.setLpFee(minFee - 1);

        vm.prank(alice);
        vm.expectRevert(PoolRentHook.InvalidLpFee.selector);
        hook.setLpFee(maxFee + 1);

        assertEq(hook.currentLpFee(), hook.DEFAULT_LP_FEE(), "fee untouched");
        _assertSolvent();
    }

    function test_setLpFee_acceptsBothBounds() public {
        uint24 minFee = hook.MIN_LP_FEE();
        uint24 maxFee = hook.MAX_LP_FEE();
        _becomeManager(alice, RENT, DEPOSIT);

        vm.prank(alice);
        hook.setLpFee(minFee);
        assertEq(hook.currentLpFee(), minFee, "min accepted");

        vm.prank(alice);
        hook.setLpFee(maxFee);
        assertEq(hook.currentLpFee(), maxFee, "max accepted");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                             Fee applied to swaps                            */
    /* -------------------------------------------------------------------------- */

    /// @dev The fee is only an authority worth auctioning if it actually reaches the trader's price.
    function test_lpFee_movesTheRealisedPrice() public {
        uint24 minFee = hook.MIN_LP_FEE();
        uint24 maxFee = hook.MAX_LP_FEE();
        _becomeManager(alice, RENT, DEPOSIT);
        uint256 snapshot = vm.snapshotState();

        vm.prank(alice);
        hook.setLpFee(minFee);
        int128 cheap = _quoteDelta(_swap(trader, true, -1 ether));

        vm.revertToState(snapshot);

        vm.prank(alice);
        hook.setLpFee(maxFee);
        int128 expensive = _quoteDelta(_swap(trader, true, -1 ether));

        assertGt(cheap, expensive, "the same sell buys less WETH at 200 bps than at 1 bp");
        _assertSolvent();
    }

    function test_lpFee_defaultAppliesWithNoManager() public {
        assertEq(hook.currentLpFee(), hook.DEFAULT_LP_FEE(), "unmanaged pools quote the default");

        uint256 snapshot = vm.snapshotState();
        int128 unmanaged = _quoteDelta(_swap(trader, true, -1 ether));

        vm.revertToState(snapshot);

        // A manager that has not repriced anything must produce exactly the same execution.
        _becomeManager(alice, RENT, DEPOSIT);
        int128 managed = _quoteDelta(_swap(trader, true, -1 ether));

        assertEq(unmanaged, managed, "no manager means the pool's own default fee");
        _assertSolvent();
    }

    function test_lpFee_overrideNeverMutatesTheStoredPoolFee() public {
        uint24 maxFee = hook.MAX_LP_FEE();
        _becomeManager(alice, RENT, DEPOSIT);
        vm.prank(alice);
        hook.setLpFee(maxFee);

        _swap(trader, true, -1 ether);

        (,,, uint24 stored) = poolManager.getSlot0(poolId);
        assertEq(stored, hook.DEFAULT_LP_FEE(), "the override is per swap; pool storage keeps the default");
        assertEq(hook.currentLpFee(), maxFee, "while the manager's fee is what swaps pay");
        _assertSolvent();
    }

    /// @dev A seat taken this block earns nothing from this block's swaps. Without that rule a
    ///      searcher could take a vacant seat, collect the manager share of a swap it front-ran and
    ///      withdraw, all in one block, having paid rent for no elapsed time.
    function test_manager_earnsNothingInItsEntryBlock() public {
        _becomeManager(alice, RENT, DEPOSIT);
        assertEq(hook.pendingRent(), RENT, "entry block paid up front");

        vm.recordLogs();
        _swap(trader, true, -1 ether);
        uint256 donated = _lastDonation();

        assertEq(hook.feeOwed(alice), 0, "no fee share in the entry block");
        assertGt(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "the platform still accrued, so a charge did happen");
        assertGt(donated, RENT, "the manager's share went to the LPs instead");

        // From the next block on the seat earns normally.
        vm.roll(block.number + 1);
        _swap(trader, true, -1 ether);
        assertGt(hook.feeOwed(alice), 0, "a seat held across a block earns its share");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                                Rent to the LPs                              */
    /* -------------------------------------------------------------------------- */

    /// @dev The whole point of the design: rent has to end up withdrawable by liquidity providers,
    ///      not parked in the hook. A zeroForOne exact-input swap pays its LP fee in the token, so
    ///      any WETH the position gains here can only have come from the donated rent.
    function test_rent_reachesInRangeLiquidityProviders() public {
        uint128 launchLiquidity = _poolLiquidity();
        uint128 lpLiquidity = 10_000 ether;
        _addLiquidity(alice, lpLiquidity);
        assertEq(_poolLiquidity(), launchLiquidity + lpLiquidity, "position is in range");

        _becomeManager(bob, RENT, DEPOSIT);
        vm.roll(block.number + 50);
        uint256 rent = uint256(RENT) * 51; // the entry block plus the 50 he held the seat for

        uint256 before = weth.balanceOf(alice);
        _swap(trader, true, -1 ether);
        assertEq(hook.pendingRent(), 0, "pending rent was consumed by the donate");

        _collectFees(alice);
        uint256 share = rent * lpLiquidity / (launchLiquidity + lpLiquidity);
        assertApproxEqAbs(weth.balanceOf(alice) - before, share, 100, "LP collected its share of the rent");

        // And the position itself still comes out whole.
        _removeLiquidity(alice, lpLiquidity);
        assertGt(weth.balanceOf(alice), before + share, "principal on top of the rent");
        _assertSolvent();
    }

    /// @dev Dust is carried rather than donated so a near-empty manager cannot grief swappers with
    ///      gas-heavy one-wei donations. It is still owed to the LPs and paid on the next real swap.
    function test_rent_belowTheDonationFloorIsCarried() public {
        uint128 minRent = uint128(hook.MIN_RENT_PER_BLOCK());
        uint256 remainder = 5e8; // deliberately less than one block of rent
        uint256 start = block.number;
        _becomeManager(alice, minRent, _seatDeposit(minRent) + remainder);

        vm.roll(start + hook.MIN_DEPOSIT_BLOCKS());
        _swap(trader, true, -1 ether); // flushes the full-size rent to the LPs
        assertEq(hook.pendingRent(), 0, "flushed");

        vm.roll(block.number + 1);
        hook.poke();
        assertEq(hook.manager(), address(0), "the remainder cannot cover a block, so she is evicted");
        assertEq(hook.pendingRent(), remainder, "the capped charge is all that is owed");

        // A tiny swap keeps the total under the donation floor: it must not be donated, or lost.
        _swap(trader, true, -1e11);
        assertGt(hook.pendingRent(), 0, "still owed to the LPs");
        assertLt(hook.pendingRent(), hook.MIN_DONATION(), "still under the floor");

        _swap(trader, true, -1 ether);
        assertEq(hook.pendingRent(), 0, "and it goes out with the next real swap");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                           Zero in-range liquidity                           */
    /* -------------------------------------------------------------------------- */

    /// @dev The launch position is locked forever, so an empty pool cannot happen through project
    ///      code and has to be staged: zero the pool's in-range liquidity directly and swap into a
    ///      price limit a hair below spot, which fills nothing and crosses no tick.
    function test_zeroInRangeLiquidity_carriesRentAndNeverBlocksASwap() public {
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + 20);
        uint256 rent = uint256(RENT) * 21; // entry block plus 20 elapsed

        uint128 liquidity = _poolLiquidity();
        _setPoolLiquidity(0);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        _swap(trader, true, -1 ether, sqrtPriceX96 - 1e18);

        assertEq(hook.deposits(alice), DEPOSIT - rent, "rent was still charged");
        assertEq(hook.pendingRent(), rent, "and carried, because there was nobody in range to pay");

        _setPoolLiquidity(liquidity);
        _swap(trader, true, -1 ether);
        assertEq(hook.pendingRent(), 0, "carried rent goes out on the next swap that has liquidity");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                             No privileged surface                           */
    /* -------------------------------------------------------------------------- */

    /// @dev There is no admin to find. Every classic escape hatch is probed by selector; the hook
    ///      has no fallback, so a missing function is a revert.
    function test_authority_hookHasNoAdminSurface() public {
        string[9] memory escapes = [
            "pause()",
            "unpause()",
            "owner()",
            "transferOwnership(address)",
            "setManager(address)",
            "setRentPerBlock(uint128)",
            "rescue(address,uint256)",
            "sweep(address)",
            "upgradeTo(address)"
        ];

        for (uint256 i; i < escapes.length; ++i) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(escapes[i]));
            assertFalse(ok, escapes[i]);
        }
        _assertSolvent();
    }

    function test_authority_nobodyCanTouchAnotherAccountsDeposit() public {
        vm.prank(bob);
        hook.depositRent(5 ether);

        address[4] memory outsiders = [alice, carol, launchWallet, PROGRAMMABLE_OWNER];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(PoolRentHook.InsufficientDeposit.selector);
            hook.withdrawDeposit(outsiders[i], 5 ether);
        }

        assertEq(hook.deposits(bob), 5 ether, "deposit is only ever spendable by its owner");
        _assertSolvent();
    }

    function test_authority_managerCannotBlockExitsOrTrades() public {
        uint24 maxFee = hook.MAX_LP_FEE();
        _becomeManager(alice, RENT, DEPOSIT);
        vm.prank(alice);
        hook.setLpFee(maxFee);

        vm.prank(bob);
        hook.depositRent(3 ether);
        vm.prank(bob);
        hook.withdrawDeposit(bob, 3 ether);
        assertEq(hook.deposits(bob), 0, "the manager cannot hold another account's deposit hostage");

        // The worst a manager can do is price the pool at its ceiling, never close it.
        assertGt(_quoteDelta(_swap(trader, true, -1 ether)), 0, "trading stays open");
        _assertSolvent();
    }

    function test_authority_managerSeatChangesOnlyThroughTheAuction() public {
        _becomeManager(alice, RENT, DEPOSIT);

        address[3] memory outsiders = [launchWallet, PROGRAMMABLE_OWNER, address(this)];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(PoolRentHook.TenureProtected.selector);
            hook.bid(RENT * 10, 0);
        }

        vm.prank(carol);
        hook.poke();
        _swap(trader, true, -1 ether);

        assertEq(hook.manager(), alice, "only a winning bid moves the seat");
        _assertSolvent();
    }

    function test_authority_platformLiabilityIsUnreachable() public {
        _becomeManager(alice, RENT, DEPOSIT);
        _swap(trader, true, -1 ether);

        uint256 platformOwed = hook.feeOwed(PROGRAMMABLE_OWNER);
        assertGt(platformOwed, 0, "platform accrued");

        address[4] memory outsiders = [alice, bob, launchWallet, address(this)];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(PoolRentHook.NothingOwed.selector);
            hook.claimFee(outsiders[i], platformOwed + 1);
        }
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), platformOwed, "platform liability untouched");

        uint256 before = weth.balanceOf(carol);
        vm.prank(PROGRAMMABLE_OWNER);
        hook.claimFee(carol, platformOwed);
        assertEq(weth.balanceOf(carol), before + platformOwed, "and only its owner can move it");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "claimed in full");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                                   Helpers                                   */
    /* -------------------------------------------------------------------------- */

    /// @dev The smallest deposit a *new* manager can bid with: the entry block it pays on the way in
    ///      plus the full minimum tenure the floor is measured against afterwards.
    function _seatDeposit(uint128 rent) private view returns (uint256) {
        return uint256(rent) * (hook.MIN_DEPOSIT_BLOCKS() + 1);
    }

    function _lpRange() private pure returns (int24 lower, int24 upper) {
        lower = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        upper = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
    }

    /// @dev Pokes the position with a zero delta, which pays out fees and donations only.
    function _collectFees(address who) private {
        (int24 lower, int24 upper) = _lpRange();
        vm.prank(who);
        liquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 0, salt: bytes32(0)}), ""
        );
    }

    function _removeLiquidity(address who, uint128 liquidity) private {
        (int24 lower, int24 upper) = _lpRange();
        vm.prank(who);
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: -int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
    }

    function _setPoolLiquidity(uint128 liquidity) private {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), StateLibrary.POOLS_SLOT));
        vm.store(
            address(poolManager),
            bytes32(uint256(stateSlot) + StateLibrary.LIQUIDITY_OFFSET),
            bytes32(uint256(liquidity))
        );
        assertEq(_poolLiquidity(), liquidity, "staged liquidity");
    }

    function _lastDonation() private returns (uint256 amount) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == RENT_DONATED_TOPIC) {
                amount = abi.decode(logs[i].data, (uint256));
            }
        }
    }
}
