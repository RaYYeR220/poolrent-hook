// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {PoolRentFixture} from "./utils/PoolRentFixture.sol";
import {PoolRentHook} from "../src/PoolRentHook.sol";
import {PoolRentMath} from "../src/libraries/PoolRentMath.sol";

/// @dev Property tests for the fee arithmetic, the four swap quadrants and the rent auction.
///
/// The charge is measured, never assumed: every swap helper reads the hook's WETH balance before and
/// after and adds back whatever the hook donated in the same call, so `charged` is the exact amount
/// the hook pulled out of the PoolManager. Every property is then stated against that number.
contract FuzzTest is PoolRentFixture {
    using PoolRentMath for uint256;

    uint256 internal constant DENOMINATOR = 1_000_000;

    /// @dev Rent the last measured swap donated to liquidity providers.
    uint256 internal _lastDonated;

    /* -------------------------------------------------------------------------- */
    /*                                 Fee maths                                   */
    /* -------------------------------------------------------------------------- */

    /// @dev A charge carved out of a gross amount may never eat the whole amount.
    function testFuzz_feeFromGrossNeverConsumesTheWholeAmount(uint256 gross, uint256 rate) public pure {
        gross = bound(gross, 0, 1e30);
        // Deliberately reaches past the denominator so the clamp is exercised, not just the maths.
        rate = bound(rate, 0, 5 * DENOMINATOR);

        uint256 fee = gross.feeFromGross(rate);
        if (gross == 0) {
            assertEq(fee, 0, "a zero amount cannot be charged");
        } else {
            assertLt(fee, gross, "charge consumed the whole amount");
        }
        if (rate < DENOMINATOR) {
            assertEq(fee, (gross * rate) / DENOMINATOR, "charge is not the floor of the declared share");
        }
    }

    /// @dev `feeOnNet` is the inverse of `feeFromGross`: grossing a net amount up and carving the
    ///      charge back out lands on the same number, give or take the one wei the two roundings
    ///      disagree on.
    function testFuzz_feeOnNetInvertsFeeFromGrossWithinOneWei(uint256 net, uint256 rate) public pure {
        net = bound(net, 0, 1e27);
        rate = bound(rate, 1, DENOMINATOR - 1);

        uint256 up = net.feeOnNet(rate);
        uint256 gross = net + up;
        uint256 down = gross.feeFromGross(rate);

        assertApproxEqAbs(down, up, 1, "the two rounding legs disagree by more than one wei");
        assertGe(up, down, "grossing up produced the smaller charge");
    }

    /// @dev Round trip: gross a net amount up, take the charge back off, get the net amount back.
    function testFuzz_grossFromNetRoundTrips(uint256 net, uint256 rate) public pure {
        net = bound(net, 0, 1e27);
        rate = bound(rate, 1, DENOMINATOR - 1);

        uint256 gross = net.grossFromNet(rate);
        assertGe(gross, net, "grossing up shrank the amount");

        uint256 back = gross - gross.feeFromGross(rate);
        assertGe(back, net, "the trader would have been short-changed");
        assertLe(back, net + 1, "the round trip drifted by more than one wei");
    }

    function testFuzz_feeOnNetRejectsRatesAtOrAboveTheDenominator(uint256 net, uint256 rate) public {
        net = bound(net, 0, 1e27);
        rate = bound(rate, DENOMINATOR, type(uint128).max);

        vm.expectRevert(PoolRentMath.RateTooHigh.selector);
        this.callFeeOnNet(net, rate);
    }

    /// @dev The split is exact and the platform is never the one that eats the rounding.
    function testFuzz_splitFeeSumsExactlyAndNeverShortChangesThePlatform(uint256 fee, uint256 platformPpm) public pure {
        fee = bound(fee, 0, 1e30);
        platformPpm = bound(platformPpm, 0, DENOMINATOR);

        (uint256 platformAmount, uint256 managerAmount) = fee.splitFee(platformPpm);

        assertEq(platformAmount + managerAmount, fee, "the split did not sum to the charge");
        assertLe(platformAmount, fee, "the platform took more than the charge");
        assertGe(platformAmount, (fee * platformPpm) / DENOMINATOR, "the platform fell below its floor");
    }

    /// @dev The realised rate on both rounding legs sits inside the declared 20 bps band, with at
    ///      most one wei of charge of slack on the leg that rounds up.
    function testFuzz_declaredRateBandHoldsOnBothRoundingLegs(uint256 amount) public view {
        uint256 value = bound(amount, 1, 1e30);
        uint256 rate = hook.TOTAL_FEE();

        uint256 down = value.feeFromGross(rate);
        assertLe(down * DENOMINATOR, value * rate, "the floor leg charged above the declared rate");
        assertGt((down + 1) * DENOMINATOR, value * rate, "the floor leg gave away more than one wei");

        uint256 up = value.feeOnNet(rate);
        uint256 grossed = value + up;
        assertGe(up * DENOMINATOR, grossed * rate, "the ceiling leg charged below the declared rate");
        assertLt(up * DENOMINATOR, grossed * rate + DENOMINATOR, "the ceiling leg overshot by a whole wei");
    }

    /* -------------------------------------------------------------------------- */
    /*                                Swap quadrants                               */
    /* -------------------------------------------------------------------------- */

    /// @dev zeroForOne exact-input: the executed gross output is known, so the charge is carved out
    ///      of it and the trader can never end up with more than the AMM produced.
    function testFuzz_sellTokenExactInputChargesTheGrossOutput(uint256 amountIn) public {
        uint256 size = bound(amountIn, 1, 5_000 ether);
        (BalanceDelta delta, uint256 charged) = _swapMeasured(trader, true, -int256(size));

        int128 quoteDelta = _quoteDelta(delta);
        assertGe(quoteDelta, 0, "the seller paid quote");

        uint256 received = uint256(uint128(quoteDelta));
        uint256 gross = received + charged;

        assertEq(charged, gross.feeFromGross(hook.TOTAL_FEE()), "charge is not the floor of the gross output");
        assertLe(received, gross, "trader received more than the AMM produced");
        _assertClean();
    }

    /// @dev zeroForOne exact-output: only the trader's net receipt is known, so the AMM is made to
    ///      produce the grossed-up amount and the trader still gets exactly what it asked for.
    function testFuzz_buyQuoteExactOutputGrossesUpTheCharge(uint256 amountOut) public {
        uint256 size = bound(amountOut, 1, 1_000 ether);
        (BalanceDelta delta, uint256 charged) = _swapMeasured(trader, true, int256(size));

        assertEq(_quoteDelta(delta), int256(size), "trader did not receive exactly what it asked for");
        assertEq(charged, size.feeOnNet(hook.TOTAL_FEE()), "charge was not grossed up off the net receipt");
        _assertClean();
    }

    /// @dev oneForZero exact-input: the gross quote input is known up front, so the charge comes out
    ///      of it and the AMM only ever swaps the remainder.
    function testFuzz_payQuoteExactInputCarvesOutTheCharge(uint256 amountIn) public {
        uint256 size = bound(amountIn, 1, 1_000 ether);
        (BalanceDelta delta, uint256 charged) = _swapMeasured(trader, false, -int256(size));

        assertEq(_quoteDelta(delta), -int256(size), "trader paid something other than the amount it specified");
        assertEq(charged, size.feeFromGross(hook.TOTAL_FEE()), "charge is not the floor of the gross input");
        assertGe(_tokenDelta(delta), 0, "buyer paid token");
        _assertClean();
    }

    /// @dev oneForZero exact-output: the trader gets exactly the token it asked for and pays the
    ///      executed quote amount grossed up by the charge.
    function testFuzz_buyTokenExactOutputGrossesUpTheCharge(uint256 amountOut) public {
        uint256 size = bound(amountOut, 1, 1_000 ether);
        (BalanceDelta delta, uint256 charged) = _swapMeasured(trader, false, int256(size));

        assertEq(_tokenDelta(delta), int256(size), "trader did not receive exactly the token it asked for");

        uint256 paid = uint256(uint128(-_quoteDelta(delta)));
        assertGe(paid, charged, "the charge exceeded what the trader paid");
        assertEq(
            charged, (paid - charged).feeOnNet(hook.TOTAL_FEE()), "charge was not grossed up off the executed amount"
        );
        _assertClean();
    }

    /// @dev Whatever the quadrant, the hook only ever touches the quote side.
    function testFuzz_chargeIsQuoteSideOnly(uint256 amount, bool zeroForOne, bool exactInput) public {
        uint256 size = bound(amount, 1, 500 ether);
        int256 specified = exactInput ? -int256(size) : int256(size);

        (BalanceDelta delta, uint256 charged) = _swapMeasured(trader, zeroForOne, specified);

        assertEq(token.balanceOf(address(hook)), 0, "the hook took the token side");
        _assertChargeMatchesQuadrant(zeroForOne, exactInput, size, delta, charged);
        _assertClean();
    }

    /// @dev The charge splits into the immutable platform liability and the seated manager's, with
    ///      the platform taking the rounding.
    function testFuzz_chargeSplitsBetweenPlatformAndManager(uint256 amount, uint256 rent) public {
        uint128 rentPerBlock = uint128(bound(rent, hook.MIN_RENT_PER_BLOCK(), 1e15));
        _becomeManager(alice, rentPerBlock, _entryDeposit(rentPerBlock));
        // Volume in the entry block belongs to the liquidity providers, so step past it.
        vm.roll(block.number + 1);

        uint256 size = bound(amount, 1e12, 500 ether);
        (, uint256 charged) = _swapMeasured(trader, false, -int256(size));

        (uint256 platformAmount, uint256 managerAmount) = charged.splitFee(hook.PLATFORM_SHARE_PPM());

        assertEq(platformAmount + managerAmount, charged, "the split did not sum to the charge");
        assertGe(platformAmount, managerAmount, "the platform ate the rounding");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), platformAmount, "platform liability off");
        assertEq(hook.feeOwed(alice), managerAmount, "manager liability off");
        _assertClean();
    }

    /// @dev The entry block is the seat's, not the searcher's: the charge is the same but the
    ///      manager half is routed to the liquidity providers instead of to a fresh manager.
    function testFuzz_entryBlockChargeGoesToLiquidityProvidersNotTheNewManager(uint256 amount, uint256 rent) public {
        uint128 rentPerBlock = uint128(bound(rent, hook.MIN_RENT_PER_BLOCK(), 1e15));
        _becomeManager(alice, rentPerBlock, _entryDeposit(rentPerBlock));

        uint256 size = bound(amount, 1e12, 500 ether);
        (, uint256 charged) = _swapMeasured(trader, false, -int256(size));

        (uint256 platformAmount, uint256 managerAmount) = charged.splitFee(hook.PLATFORM_SHARE_PPM());

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), platformAmount, "platform liability off");
        assertEq(hook.feeOwed(alice), 0, "the entry block paid the fresh manager");
        assertEq(_lastDonated + hook.pendingRent(), managerAmount + rentPerBlock, "manager share missed the providers");
        _assertClean();
    }

    /// @dev `hookData` is untrusted router input and is never read, so it cannot move a number.
    function testFuzz_arbitraryHookDataIsIgnored(bytes calldata hookData, uint256 amount) public {
        uint256 size = bound(amount, 1e12, 200 ether);

        uint256 snapshot = vm.snapshotState();
        (BalanceDelta withData, uint256 chargedWithData) = _swapMeasured(trader, true, -int256(size), hookData);
        uint256 feesWithData = hook.totalFeeOwed();

        vm.revertToState(snapshot);
        (BalanceDelta withoutData, uint256 chargedWithoutData) = _swapMeasured(trader, true, -int256(size), "");

        assertEq(chargedWithData, chargedWithoutData, "hookData moved the charge");
        assertEq(BalanceDelta.unwrap(withData), BalanceDelta.unwrap(withoutData), "hookData moved the trade");
        assertEq(feesWithData, hook.totalFeeOwed(), "hookData moved the books");
        _assertClean();
    }

    /// @dev An arbitrary price limit either executes with a correct charge or is rejected outright.
    ///      There is no third outcome where the books move by a wrong amount.
    function testFuzz_arbitrarySqrtPriceLimitNeverBreaksAccounting(uint160 limit, uint256 amount) public {
        uint256 size = bound(amount, 1, 100 ether);
        uint256 executed;
        uint256 rejected;

        for (uint256 i; i < 4; ++i) {
            bool zeroForOne = i % 2 == 0;
            bool exactInput = i < 2;
            int256 specified = exactInput ? -int256(size) : int256(size);

            uint256 feesBefore = hook.totalFeeOwed();
            uint256 balanceBefore = weth.balanceOf(address(hook));

            vm.recordLogs();
            vm.prank(trader);
            try swapRouter.swap(
                key,
                SwapParams({zeroForOne: zeroForOne, amountSpecified: specified, sqrtPriceLimitX96: limit}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            ) returns (
                BalanceDelta delta
            ) {
                uint256 donated = _donated(vm.getRecordedLogs());
                uint256 charged = weth.balanceOf(address(hook)) + donated - balanceBefore;
                _assertChargeMatchesQuadrant(zeroForOne, exactInput, size, delta, charged);
                executed++;
            } catch {
                vm.getRecordedLogs();
                assertEq(hook.totalFeeOwed(), feesBefore, "a rejected swap moved the books");
                assertEq(weth.balanceOf(address(hook)), balanceBefore, "a rejected swap moved value");
                rejected++;
            }
            _assertClean();
        }

        assertEq(executed + rejected, 4, "a quadrant resolved as neither executed nor rejected");
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Rent auction                                */
    /* -------------------------------------------------------------------------- */

    function testFuzz_validBidLeavesConsistentAuctionState(uint256 rent, uint256 extra) public {
        uint128 rentPerBlock = uint128(bound(rent, hook.MIN_RENT_PER_BLOCK(), 1e18));
        uint256 posted = _entryDeposit(rentPerBlock) + bound(extra, 0, 10 ether);

        _becomeManager(alice, rentPerBlock, posted);

        assertEq(hook.manager(), alice, "seat not handed over");
        assertEq(hook.rentPerBlock(), rentPerBlock, "rent not recorded");
        assertEq(hook.deposits(alice), posted - rentPerBlock, "entry block not charged on the way in");
        assertEq(hook.totalDeposits(), posted - rentPerBlock, "total deposits drifted");
        assertEq(hook.pendingRent(), rentPerBlock, "the entry block did not reach the liquidity providers");
        assertGe(
            hook.deposits(alice),
            uint256(rentPerBlock) * hook.MIN_DEPOSIT_BLOCKS(),
            "the seat is funded for less than a minimum tenure"
        );
        assertEq(hook.tenureStartBlock(), uint64(block.number), "tenure did not start");
        assertEq(hook.lastAccrualBlock(), uint64(block.number), "accrual clock not reset");
        assertEq(hook.managerLpFee(), hook.DEFAULT_LP_FEE(), "a fresh seat did not take the default fee");
        assertEq(hook.currentLpFee(), hook.DEFAULT_LP_FEE(), "live fee disagrees with the seat");
        _assertClean();
    }

    function testFuzz_invalidBidAlwaysReverts(uint256 rent, uint256 deposit) public {
        uint256 rejected;

        uint128 belowFloor = uint128(bound(rent, 0, hook.MIN_RENT_PER_BLOCK() - 1));
        vm.prank(alice);
        vm.expectRevert(PoolRentHook.RentTooLow.selector);
        hook.bid(belowFloor, 1 ether);
        rejected++;

        // Anything short of the entry block plus a full minimum tenure is not a fundable seat.
        uint128 rentPerBlock = uint128(bound(rent, hook.MIN_RENT_PER_BLOCK(), 1e15));
        uint256 short = bound(deposit, 0, _entryDeposit(rentPerBlock) - 1);
        vm.prank(alice);
        vm.expectRevert(PoolRentHook.DepositTooSmall.selector);
        hook.bid(rentPerBlock, short);
        rejected++;

        assertEq(rejected, 2, "an invalid bid shape was not rejected");
        assertEq(hook.manager(), address(0), "a rejected bid still took the seat");
        assertEq(hook.totalDeposits(), 0, "a rejected bid left a deposit behind");
        _assertClean();
    }

    function testFuzz_outbidNeedsTenPercentAfterTheTenure(uint256 base, uint256 challenge) public {
        uint128 standing = uint128(bound(base, hook.MIN_RENT_PER_BLOCK(), 1e14));
        _becomeManager(alice, standing, uint256(standing) * 1_000);
        vm.roll(block.number + hook.MIN_TENURE_BLOCKS());

        uint128 offer = uint128(bound(challenge, hook.MIN_RENT_PER_BLOCK(), 1e15));
        uint256 deposit = _entryDeposit(offer);

        if (uint256(offer) * 100 >= uint256(standing) * hook.OUTBID_PERCENT()) {
            _becomeManager(bob, offer, deposit);
            assertEq(hook.manager(), bob, "a winning challenge did not take the seat");
            assertEq(hook.rentPerBlock(), offer, "the new rent was not recorded");
            assertEq(hook.tenureStartBlock(), uint64(block.number), "the handover did not start a new window");
            assertEq(hook.managerLpFee(), hook.DEFAULT_LP_FEE(), "the new manager inherited a standing fee");
            assertGt(hook.deposits(alice), 0, "the evicted incumbent's deposit was seized");
        } else {
            vm.prank(bob);
            vm.expectRevert(PoolRentHook.OutbidTooLow.selector);
            hook.bid(offer, deposit);
            assertEq(hook.manager(), alice, "a losing challenge took the seat");
        }
        _assertClean();
    }

    function testFuzz_tenureProtectsTheIncumbent(uint256 rent, uint256 blocksElapsed) public {
        uint128 standing = uint128(bound(rent, hook.MIN_RENT_PER_BLOCK(), 1e14));
        _becomeManager(alice, standing, uint256(standing) * 1_000);

        vm.roll(block.number + bound(blocksElapsed, 0, hook.MIN_TENURE_BLOCKS() - 1));

        uint128 offer = standing * 100;
        uint256 deposit = _entryDeposit(offer);

        vm.prank(bob);
        vm.expectRevert(PoolRentHook.TenureProtected.selector);
        hook.bid(offer, deposit);

        assertEq(hook.manager(), alice, "the incumbent lost the seat inside its tenure");
        _assertClean();
    }

    /// @dev Rent is capped by the deposit whatever the block delta, and the shortfall is an eviction
    ///      rather than a negative balance.
    function testFuzz_rentOverAnyBlockDeltaNeverExceedsTheDeposit(uint256 rent, uint256 blocksCovered, uint256 elapsed)
        public
    {
        uint128 rentPerBlock = uint128(bound(rent, hook.MIN_RENT_PER_BLOCK(), 1e15));
        uint256 covered = bound(blocksCovered, hook.MIN_DEPOSIT_BLOCKS(), 5_000);
        // The entry block is paid on the way in, so the deposit funds `covered` blocks after it.
        uint256 posted = uint256(rentPerBlock) * (covered + 1);
        _becomeManager(alice, rentPerBlock, posted);

        uint256 blocks = bound(elapsed, 0, 100_000);
        vm.roll(block.number + blocks);
        hook.poke();

        uint256 charged = hook.pendingRent();
        assertLe(charged, posted, "rent ran past the deposit");
        assertEq(hook.deposits(alice) + charged, posted, "rent did not come out of the deposit");
        assertEq(
            charged,
            uint256(rentPerBlock) * (blocks >= covered ? covered + 1 : blocks + 1),
            "rent is not the entry block plus every block held"
        );

        if (blocks >= covered) {
            assertEq(hook.manager(), address(0), "an exhausted manager kept the seat");
            assertEq(hook.deposits(alice), 0, "an exhausted deposit was not drained");
            assertEq(hook.currentLpFee(), hook.DEFAULT_LP_FEE(), "the fee did not fall back");
        } else {
            assertEq(hook.manager(), alice, "a solvent manager was evicted");
        }
        _assertClean();
    }

    function testFuzz_setLpFeeIsClampedAndManagerOnly(uint256 lpFee, uint256 outsiderSeed) public {
        _becomeManager(alice, 1e12, _entryDeposit(1e12));

        uint24 minLpFee = hook.MIN_LP_FEE();
        uint24 maxLpFee = hook.MAX_LP_FEE();

        uint24 fee = uint24(bound(lpFee, 0, uint256(maxLpFee) * 2));
        if (fee >= minLpFee && fee <= maxLpFee) {
            vm.prank(alice);
            hook.setLpFee(fee);
            assertEq(hook.currentLpFee(), fee, "a valid fee was not applied");
        } else {
            vm.prank(alice);
            vm.expectRevert(PoolRentHook.InvalidLpFee.selector);
            hook.setLpFee(fee);
            assertEq(hook.currentLpFee(), hook.DEFAULT_LP_FEE(), "a rejected fee still moved the pool");
        }

        address outsider = outsiderSeed % 2 == 0 ? bob : carol;
        vm.prank(outsider);
        vm.expectRevert(PoolRentHook.NotManager.selector);
        hook.setLpFee(minLpFee);

        assertGe(hook.currentLpFee(), minLpFee, "live fee below the floor");
        assertLe(hook.currentLpFee(), maxLpFee, "live fee above the ceiling");
        _assertClean();
    }

    function testFuzz_claimFeeNeverExceedsWhatIsOwed(uint256 amount, uint256 seed) public {
        _swap(trader, true, -10 ether);

        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        assertGt(owed, 0, "no platform liability accrued");

        vm.prank(PROGRAMMABLE_OWNER);
        vm.expectRevert(PoolRentHook.NothingOwed.selector);
        hook.claimFee(PROGRAMMABLE_OWNER, bound(amount, owed + 1, type(uint128).max));

        vm.prank(PROGRAMMABLE_OWNER);
        vm.expectRevert(PoolRentHook.NothingOwed.selector);
        hook.claimFee(PROGRAMMABLE_OWNER, 0);

        vm.prank(PROGRAMMABLE_OWNER);
        vm.expectRevert(PoolRentHook.ZeroAddress.selector);
        hook.claimFee(address(0), owed);

        address outsider = seed % 2 == 0 ? alice : bob;
        vm.prank(outsider);
        vm.expectRevert(PoolRentHook.NothingOwed.selector);
        hook.claimFee(outsider, 1);

        uint256 part = bound(seed, 1, owed);
        uint256 before = weth.balanceOf(PROGRAMMABLE_OWNER);
        vm.prank(PROGRAMMABLE_OWNER);
        hook.claimFee(PROGRAMMABLE_OWNER, part);

        assertEq(weth.balanceOf(PROGRAMMABLE_OWNER) - before, part, "the claim paid the wrong amount");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), owed - part, "the liability did not shrink by the claim");
        assertEq(hook.totalFeeOwed(), owed - part, "the total did not follow the per-account book");
        _assertClean();
    }

    /* -------------------------------------------------------------------------- */
    /*                                   Helpers                                   */
    /* -------------------------------------------------------------------------- */

    /// @dev External wrapper so a library revert can be caught by `expectRevert`.
    function callFeeOnNet(uint256 net, uint256 rate) external pure returns (uint256) {
        return net.feeOnNet(rate);
    }

    function _swapMeasured(address who, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta, uint256 charged)
    {
        return _swapMeasured(who, zeroForOne, amountSpecified, "");
    }

    function _swapMeasured(address who, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta delta, uint256 charged)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 before = weth.balanceOf(address(hook));

        vm.recordLogs();
        vm.prank(who);
        delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        _lastDonated = _donated(vm.getRecordedLogs());
        charged = weth.balanceOf(address(hook)) + _lastDonated - before;
    }

    /// @dev What a challenger has to post: the entry block on top of a full minimum tenure.
    function _entryDeposit(uint256 rentPerBlock) internal view returns (uint256) {
        return rentPerBlock * (hook.MIN_DEPOSIT_BLOCKS() + 1);
    }

    function _assertChargeMatchesQuadrant(
        bool zeroForOne,
        bool exactInput,
        uint256 size,
        BalanceDelta delta,
        uint256 charged
    ) internal view {
        uint256 rate = hook.TOTAL_FEE();
        int128 quoteDelta = _quoteDelta(delta);

        if (zeroForOne && exactInput) {
            uint256 gross = uint256(uint128(quoteDelta)) + charged;
            assertEq(charged, gross.feeFromGross(rate), "gross-output charge off");
        } else if (zeroForOne) {
            assertEq(quoteDelta, int256(size), "exact-output receipt off");
            assertEq(charged, size.feeOnNet(rate), "grossed-up charge off");
        } else if (exactInput) {
            assertEq(quoteDelta, -int256(size), "exact-input payment off");
            assertEq(charged, size.feeFromGross(rate), "gross-input charge off");
        } else {
            uint256 paid = uint256(uint128(-quoteDelta));
            assertEq(charged, (paid - charged).feeOnNet(rate), "grossed-up input charge off");
        }
    }

    function _donated(Vm.Log[] memory logs) internal view returns (uint256 total) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != PoolRentHook.RentDonated.selector) continue;
            total += abi.decode(logs[i].data, (uint256));
        }
    }

    /// @dev Solvent, and every wei the hook holds is booked into one of the three namespaces.
    function _assertClean() internal view {
        _assertSolvent();
        assertEq(weth.balanceOf(address(hook)), hook.totalLiabilities(), "hook holds value that belongs to nobody");
    }
}
