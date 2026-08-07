// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolRentFixture} from "./utils/PoolRentFixture.sol";
import {PoolRentHook} from "../src/PoolRentHook.sol";
import {PoolRentHandler} from "./handlers/PoolRentHandler.sol";

/// @dev Stateful invariant suite plus the exploit-derived regressions that came out of writing it.
///
/// The whole system is one hook holding WETH for three liability namespaces that are never netted
/// against each other: auction deposits, rent owed to liquidity providers, and claimable fee
/// liabilities. Everything below is a restatement of that split from a different angle.
contract InvariantsTest is PoolRentFixture {
    using StateLibrary for IPoolManager;

    /// @notice Declared bound on WETH sitting in the hook that no liability namespace claims.
    /// @dev Every inbound wei is booked into a namespace in the same call that receives it, so the
    ///      bound is zero rather than "some dust". Per-swap rounding lands in the charge, not here.
    uint256 internal constant MAX_UNATTRIBUTED_WEI = 0;

    PoolRentHandler internal handler;
    address[] internal actors;

    function setUp() public override {
        super.setUp();

        actors.push(alice);
        actors.push(bob);
        actors.push(carol);
        actors.push(trader);

        handler = new PoolRentHandler(swapRouter, liquidityRouter, hook, IERC20(address(weth)), key, actors);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = PoolRentHandler.swapExactInput.selector;
        selectors[1] = PoolRentHandler.swapExactOutput.selector;
        selectors[2] = PoolRentHandler.bid.selector;
        selectors[3] = PoolRentHandler.topUpDeposit.selector;
        selectors[4] = PoolRentHandler.withdrawDeposit.selector;
        selectors[5] = PoolRentHandler.setLpFee.selector;
        selectors[6] = PoolRentHandler.addLiquidity.selector;
        selectors[7] = PoolRentHandler.removeLiquidity.selector;
        selectors[8] = PoolRentHandler.claimFee.selector;
        selectors[9] = PoolRentHandler.poke.selector;
        selectors[10] = PoolRentHandler.rollBlocks.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        excludeSender(address(hook));
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Invariants                                 */
    /* -------------------------------------------------------------------------- */

    /// @notice The hook always holds at least the sum of the three liability namespaces.
    function invariant_solvency() public view {
        uint256 owed = hook.totalDeposits() + hook.pendingRent() + hook.totalFeeOwed();
        assertEq(owed, hook.totalLiabilities(), "totalLiabilities is the sum of the namespaces");
        assertGe(weth.balanceOf(address(hook)), owed, "hook holds less than it owes");
        assertTrue(hook.isSolvent(), "isSolvent disagrees with the balance");
    }

    /// @notice Every wei that entered the hook either left it or is still sitting there.
    function invariant_conservation() public view {
        assertEq(handler.ghostNegativeCharge(), 0, "a swap drained the hook");
        assertEq(
            handler.ghostPulledIn() + handler.ghostCharged(),
            handler.ghostPaidOut() + handler.ghostDonated() + weth.balanceOf(address(hook)),
            "WETH in does not equal WETH out plus what the hook holds"
        );
    }

    /// @notice The per-account books add up to the running totals the solvency check reads.
    function invariant_liabilitySumMatchesTotal() public view {
        uint256 fees = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 depositSum;
        for (uint256 i; i < actors.length; ++i) {
            fees += hook.feeOwed(actors[i]);
            depositSum += hook.deposits(actors[i]);
        }
        assertEq(fees, hook.totalFeeOwed(), "feeOwed sum drifted from totalFeeOwed");
        assertEq(depositSum, hook.totalDeposits(), "deposits sum drifted from totalDeposits");
    }

    /// @notice Nothing in the system can move the platform liability down except the platform.
    function invariant_platformLiabilityNeverDecreasesExceptByItsOwnClaim() public view {
        assertEq(handler.ghostPlatformBadDecrease(), 0, "platform liability lost outside a claim");
        assertEq(
            hook.feeOwed(PROGRAMMABLE_OWNER) + handler.ghostPlatformClaimed(),
            handler.ghostPlatformAccrued(),
            "platform liability is not accrued minus claimed"
        );
    }

    /// @notice The realised charge rate over the whole run sits inside the declared band.
    /// @dev The exact-output legs round the charge up, which can overshoot by strictly less than one
    ///      wei of charge per swap; that is the only slack either bound gets.
    function invariant_feeBounds() public view {
        uint256 gross = handler.ghostGrossQuote();
        uint256 dust = handler.ghostSwaps() * 1e6;

        assertLe(handler.ghostCharged() * 1e6, gross * hook.TOTAL_FEE() + dust, "charge above 20 bps");
        assertGe(2 * handler.ghostPlatformAccrued() * 1e6 + dust, gross * hook.TOTAL_FEE(), "platform below 10 bps");
    }

    /// @notice The live LP fee never leaves the immutable bounds, and falls back with no manager.
    function invariant_lpFeeWithinBounds() public view {
        (,,, uint24 storedLpFee) = poolManager.getSlot0(poolId);
        assertEq(storedLpFee, hook.DEFAULT_LP_FEE(), "stored dynamic fee moved");

        uint24 live = hook.currentLpFee();
        if (hook.manager() == address(0)) {
            assertEq(live, hook.DEFAULT_LP_FEE(), "no manager but not the default fee");
        } else {
            assertGe(live, hook.MIN_LP_FEE(), "live fee below the floor");
            assertLe(live, hook.MAX_LP_FEE(), "live fee above the ceiling");
        }
    }

    /// @notice Anyone holding a deposit can always take all of it back, whatever the auction is doing.
    function invariant_exitAlwaysAvailable() public {
        uint256 snapshot = vm.snapshotState();

        hook.poke();
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            uint256 balance = hook.deposits(actor);
            if (balance == 0) continue;

            uint256 before = weth.balanceOf(actor);
            vm.prank(actor);
            hook.withdrawDeposit(actor, balance);

            assertEq(weth.balanceOf(actor) - before, balance, "exit paid the wrong amount");
            assertEq(hook.deposits(actor), 0, "exit left a remainder");
        }

        vm.revertToState(snapshot);
    }

    /// @notice A seat is either empty and inert, or held by someone who paid for it.
    function invariant_managerConsistency() public view {
        assertEq(handler.ghostBadBids(), 0, "a bid was accepted below the deposit floor");
        assertEq(handler.ghostFreeSeatTakeovers(), 0, "a seat changed hands without paying its entry block");
        assertEq(handler.ghostBadTenureStart(), 0, "the tenure window moved on the wrong kind of bid");
        assertEq(handler.ghostEntryBlockAccrual(), 0, "a fresh manager was paid for its own entry block");

        address currentManager = hook.manager();
        if (currentManager == address(0)) {
            assertEq(hook.rentPerBlock(), 0, "empty seat still charges rent");
            assertEq(hook.managerLpFee(), 0, "empty seat still holds a fee");
            return;
        }

        assertGe(hook.rentPerBlock(), hook.MIN_RENT_PER_BLOCK(), "manager below the rent floor");
        assertGe(hook.deposits(currentManager), 1, "manager holds the seat on an empty deposit");
        assertGe(hook.managerLpFee(), hook.MIN_LP_FEE(), "manager fee below the floor");
        assertLe(hook.managerLpFee(), hook.MAX_LP_FEE(), "manager fee above the ceiling");
    }

    /// @notice No wei of the hook's balance belongs to nobody.
    function invariant_noStuckValue() public view {
        uint256 balance = weth.balanceOf(address(hook));
        uint256 owed = hook.totalLiabilities();
        assertGe(balance, owed, "hook holds less than it owes");
        assertLe(balance - owed, MAX_UNATTRIBUTED_WEI, "unattributed value above the declared bound");
    }

    function afterInvariant() public view {
        assertEq(handler.useful() + handler.rejected(), handler.entries(), "an action escaped the counters");
        assertGt(handler.useful(), 0, "the run made no useful call");
    }

    /* -------------------------------------------------------------------------- */
    /*                          Exploit-derived regressions                        */
    /* -------------------------------------------------------------------------- */

    /// @dev A bid followed by an immediate exit costs exactly the entry block of rent. Taking the
    ///      seat is never free, so a round trip can never be a source of value.
    function test_managerCannotProfitFromBidThenImmediateWithdraw() public {
        uint128 rent = 1e12;
        uint256 posted = _entryDeposit(rent);

        uint256 before = weth.balanceOf(alice);
        _becomeManager(alice, rent, posted);

        uint256 held = hook.deposits(alice);
        assertEq(held, posted - rent, "entry block not charged on the way in");

        vm.prank(alice);
        hook.withdrawDeposit(alice, held);

        assertEq(weth.balanceOf(alice), before - rent, "round trip did not cost exactly one block of rent");
        assertEq(hook.manager(), address(0), "seat not released");
        assertEq(hook.deposits(alice), 0, "deposit not fully returned");
        assertEq(hook.feeOwed(alice), 0, "fee accrued without volume");
        assertEq(hook.pendingRent(), rent, "the entry block did not reach the liquidity providers");
        _assertSolvent();
    }

    /// @dev A manager pays for the entry block plus every block it then holds the seat, and without
    ///      volume that is a straight loss.
    function test_managerPaysRentForEveryBlockItHoldsTheSeat() public {
        uint128 rent = 1e12;
        uint256 held = 10;

        uint256 before = weth.balanceOf(alice);
        _becomeManager(alice, rent, _entryDeposit(rent));
        vm.roll(block.number + held);
        hook.poke();

        uint256 owed = uint256(rent) * (held + 1);
        assertEq(hook.pendingRent(), owed, "rent is not the entry block plus every block held");

        uint256 remaining = hook.deposits(alice);
        vm.prank(alice);
        hook.withdrawDeposit(alice, remaining);
        assertEq(weth.balanceOf(alice), before - owed, "rent did not come out of the deposit");
        _assertSolvent();
    }

    /// @dev The searcher play the entry rules exist for: take a vacant seat, front-run a large swap
    ///      and withdraw everything, all inside one block. The charge is unchanged, but the manager
    ///      half goes to the liquidity providers instead of the searcher, and the seat still costs a
    ///      block of rent, so the round trip is strictly loss-making.
    function test_sameBlockSeatGrabEarnsTheSearcherNothing() public {
        uint128 rent = 1e12;
        uint256 posted = _entryDeposit(rent);

        // Control: the identical swap one block into the tenure, which the manager does earn from.
        uint256 snapshot = vm.snapshotState();
        _becomeManager(alice, rent, posted);
        vm.roll(block.number + 1);
        _swap(trader, false, -10 ether);
        uint256 earnedOutsideEntryBlock = hook.feeOwed(alice);
        assertGt(earnedOutsideEntryBlock, 0, "a seated manager earns nothing at all");
        vm.revertToState(snapshot);

        uint256 start = weth.balanceOf(alice);
        _becomeManager(alice, rent, posted);
        assertEq(hook.tenureStartBlock(), uint64(block.number), "tenure did not start here");
        assertEq(hook.pendingRent(), rent, "entry block not paid");

        vm.recordLogs();
        _swap(trader, false, -10 ether);
        uint256 toLiquidityProviders = _donated(vm.getRecordedLogs()) + hook.pendingRent() - rent;

        assertEq(hook.feeOwed(alice), 0, "the searcher banked a manager share in its entry block");
        assertEq(toLiquidityProviders, earnedOutsideEntryBlock, "the manager share went somewhere else");
        assertGt(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "the platform was not charged");

        uint256 held = hook.deposits(alice);
        vm.prank(alice);
        hook.withdrawDeposit(alice, held);

        assertLe(weth.balanceOf(alice), start, "front-running the seat was profitable");
        assertEq(weth.balanceOf(alice), start - rent, "the seat grab did not cost exactly one block of rent");
        _assertSolvent();
    }

    /// @dev Re-posting your own standing rent must not push the protection window out, or the seat
    ///      would be uncontestable at a constant price. The window runs from the handover only.
    function test_incumbentCannotRenewItsOwnTenure() public {
        uint128 rent = 1e12;
        uint256 tenure = hook.MIN_TENURE_BLOCKS();

        _becomeManager(alice, rent, uint256(rent) * 1_000);
        uint64 start = hook.tenureStartBlock();

        vm.roll(block.number + tenure - 1);
        vm.prank(alice);
        hook.bid(rent, 0);
        assertEq(hook.tenureStartBlock(), start, "a self-bid moved the tenure window");

        uint128 offer = rent * 2;
        uint256 challengerDeposit = _entryDeposit(offer);

        vm.prank(bob);
        vm.expectRevert(PoolRentHook.TenureProtected.selector);
        hook.bid(offer, challengerDeposit);

        // One block later the original window closes, whatever the incumbent did in between.
        vm.roll(block.number + 1);
        assertEq(block.number, uint256(start) + tenure, "the window did not run from the handover");

        vm.prank(bob);
        hook.bid(offer, challengerDeposit);

        assertEq(hook.manager(), bob, "the challenger could not take a lapsed seat");
        assertEq(hook.tenureStartBlock(), uint64(block.number), "the handover did not start a new window");
        assertEq(hook.managerLpFee(), hook.DEFAULT_LP_FEE(), "the new manager inherited a standing fee");
        assertGt(hook.deposits(alice), 0, "the evicted incumbent's deposit was seized");
        _assertSolvent();
    }

    /// @dev The declared per-swap dust is one wei of charge, so splitting a trade into N legs can
    ///      only ever differ from the aggregate by N wei, and never in the trader's favour.
    function test_manySmallSwapsMatchOneAggregateSwapWithinDust() public {
        uint256 legs = 20;
        // A chunk with a remainder against the 20 bps rate, so the floor actually bites.
        uint256 chunk = 1e17 + 499;

        // With a manager seated past its entry block the whole charge lands in `feeOwed`.
        _becomeManager(alice, 1e12, 1e12 * 200);
        vm.roll(block.number + 1);
        uint256 snapshot = vm.snapshotState();

        for (uint256 i; i < legs; ++i) {
            _swap(trader, false, -int256(chunk));
        }
        uint256 split = hook.feeOwed(PROGRAMMABLE_OWNER) + hook.feeOwed(alice);

        vm.revertToState(snapshot);

        _swap(trader, false, -int256(chunk * legs));
        uint256 aggregate = hook.feeOwed(PROGRAMMABLE_OWNER) + hook.feeOwed(alice);

        assertLe(split, aggregate, "splitting a trade cost more than the aggregate");
        assertApproxEqAbs(split, aggregate, legs, "difference above one wei per leg");
        _assertSolvent();
    }

    /// @dev An unsolicited WETH transfer is not a deposit: it credits nobody and stays unreachable.
    function test_directDonationIsNeverCreditedToAnyAccount() public {
        uint256 gift = 5 ether;
        vm.prank(bob);
        weth.transfer(address(hook), gift);

        assertEq(hook.totalLiabilities(), 0, "gift became a liability");
        assertEq(hook.deposits(bob), 0, "gift became a deposit");
        assertEq(hook.feeOwed(bob), 0, "gift became a fee claim");
        _assertSolvent();

        uint256 before = weth.balanceOf(alice);
        vm.prank(alice);
        hook.depositRent(1 ether);
        assertEq(hook.deposits(alice), 1 ether, "deposit inflated by the gift");

        vm.prank(alice);
        vm.expectRevert(PoolRentHook.InsufficientDeposit.selector);
        hook.withdrawDeposit(alice, 1 ether + 1);

        vm.prank(alice);
        hook.withdrawDeposit(alice, 1 ether);
        assertEq(weth.balanceOf(alice), before, "alice reached past her own balance");
        assertEq(weth.balanceOf(address(hook)), gift, "gift did not stay put");
    }

    /// @dev The first depositor gets no privilege, and no account can reach another's balance.
    function test_firstDepositorCannotReachAnotherAccountsBalance() public {
        vm.prank(alice);
        hook.depositRent(3 ether);

        vm.prank(bob);
        hook.depositRent(1);
        assertEq(hook.deposits(bob), 1, "second depositor short-changed");

        vm.prank(bob);
        vm.expectRevert(PoolRentHook.InsufficientDeposit.selector);
        hook.withdrawDeposit(bob, 2);

        uint256 before = weth.balanceOf(bob);
        vm.prank(bob);
        hook.withdrawDeposit(bob, 1);

        assertEq(weth.balanceOf(bob) - before, 1, "withdrawal paid the wrong amount");
        assertEq(hook.deposits(alice), 3 ether, "alice's balance moved");
        assertEq(hook.totalDeposits(), 3 ether, "total drifted from the per-account books");
        _assertSolvent();
    }

    /* -------------------------------------------------------------------------- */
    /*                                   Helpers                                   */
    /* -------------------------------------------------------------------------- */

    /// @dev What a challenger has to post: the entry block on top of a full minimum tenure.
    function _entryDeposit(uint256 rentPerBlock) internal view returns (uint256) {
        return rentPerBlock * (hook.MIN_DEPOSIT_BLOCKS() + 1);
    }

    function _donated(Vm.Log[] memory logs) internal view returns (uint256 total) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != PoolRentHook.RentDonated.selector) continue;
            total += abi.decode(logs[i].data, (uint256));
        }
    }
}
