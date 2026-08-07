// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolRentFixture} from "./utils/PoolRentFixture.sol";
import {PoolRentHook} from "../src/PoolRentHook.sol";
import {PoolRentMath} from "../src/libraries/PoolRentMath.sol";

/// @dev A router that talks to the PoolManager itself, with no shared code with the canonical test
///      router. The hook must not care which contract fronts the swap.
contract RawRouter is IUnlockCallback {
    IPoolManager private immutable manager;

    struct Call {
        address payer;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(Call(msg.sender, key, params, hookData))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata raw) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Call memory c = abi.decode(raw, (Call));

        BalanceDelta delta = manager.swap(c.key, c.params, c.hookData);
        _resolve(c.key.currency0, c.payer, delta.amount0());
        _resolve(c.key.currency1, c.payer, delta.amount1());

        return abi.encode(delta);
    }

    function _resolve(Currency currency, address payer, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(uint128(amount)));
        }
    }
}

/// @dev Proves the mandatory Programmable volume-fee policy end to end: the charge exists on all four
///      swap quadrants, is computed on what the AMM actually executed, splits so the platform is
///      never short-changed, cannot be redirected or routed around, and leaves the hook solvent.
contract FeeTest is PoolRentFixture {
    using PoolIdLibrary for PoolKey;

    /// @dev Hundredths of a bip, as everywhere else in this system.
    uint256 internal constant RATE = 2_000;
    uint256 internal constant PLATFORM_PPM = 500_000;
    uint256 internal constant DENOM = 1_000_000;

    /// @dev The floor Programmable enforces on any selected fee: 10 bps, owned by the platform.
    uint256 internal constant MANDATORY = 1_000;

    /// @dev Mirrors of the hook's events so the reconciliation tests can match on topics.
    event FeeAccrued(bytes32 indexed poolId, address indexed currency, address indexed beneficiary, uint256 amount);
    event FeeClaimed(
        bytes32 indexed poolId, address indexed currency, address indexed beneficiary, address to, uint256 amount
    );

    PoolKey internal unrelatedKey;

    /* ====================================================================== */
    /*                       Every quadrant is charged                        */
    /* ====================================================================== */

    function test_quadrant_zeroForOneExactInput_isCharged() public {
        uint256 before = hook.feeOwed(PROGRAMMABLE_OWNER);
        BalanceDelta d = _swap(trader, true, -1 ether);

        assertGt(hook.feeOwed(PROGRAMMABLE_OWNER), before, "platform accrued");
        assertGt(_quoteDelta(d), 0, "trader still receives quote");
        assertEq(token.balanceOf(address(hook)), 0, "charge is never taken in the base asset");
        _assertSolvent();
    }

    function test_quadrant_zeroForOneExactOutput_isCharged() public {
        uint256 before = hook.feeOwed(PROGRAMMABLE_OWNER);
        BalanceDelta d = _swap(trader, true, 1 ether);

        assertGt(hook.feeOwed(PROGRAMMABLE_OWNER), before, "platform accrued");
        assertEq(_quoteDelta(d), 1 ether, "trader receives exactly what it asked for");
        assertEq(token.balanceOf(address(hook)), 0, "charge is never taken in the base asset");
        _assertSolvent();
    }

    function test_quadrant_oneForZeroExactInput_isCharged() public {
        uint256 before = hook.feeOwed(PROGRAMMABLE_OWNER);
        BalanceDelta d = _swap(trader, false, -1 ether);

        assertGt(hook.feeOwed(PROGRAMMABLE_OWNER), before, "platform accrued");
        assertEq(_quoteDelta(d), -1 ether, "trader pays exactly what it offered");
        assertEq(token.balanceOf(address(hook)), 0, "charge is never taken in the base asset");
        _assertSolvent();
    }

    function test_quadrant_oneForZeroExactOutput_isCharged() public {
        uint256 before = hook.feeOwed(PROGRAMMABLE_OWNER);
        BalanceDelta d = _swap(trader, false, 1 ether);

        assertGt(hook.feeOwed(PROGRAMMABLE_OWNER), before, "platform accrued");
        assertEq(_tokenDelta(d), 1 ether, "trader receives exactly what it asked for");
        assertEq(token.balanceOf(address(hook)), 0, "charge is never taken in the base asset");
        _assertSolvent();
    }

    /// @dev With no manager the platform share is the only part that stays in the hook; the rest is
    ///      handed to liquidity providers inside the same call.
    function test_quadrant_chargeLandsOnlyInTheQuoteBalance() public {
        uint256 heldBefore = weth.balanceOf(address(hook));
        uint256 owedBefore = hook.feeOwed(PROGRAMMABLE_OWNER);

        _swap(trader, true, -1 ether);

        assertEq(
            weth.balanceOf(address(hook)) - heldBefore,
            hook.feeOwed(PROGRAMMABLE_OWNER) - owedBefore,
            "retained quote equals the platform liability"
        );
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                      The charge basis, to the wei                      */
    /* ====================================================================== */

    function test_basis_zeroForOneExactInput_flooredOnGrossOutput() public {
        _installManager();

        uint256 before = _charged();
        (BalanceDelta d, int256 executed) = _swapRecorded(trader, true, -1 ether, 0);

        uint256 gross = uint256(executed);
        uint256 expected = PoolRentMath.feeFromGross(gross, RATE);

        assertEq(_charged() - before, expected, "floor(gross output * rate)");
        assertEq(uint256(int256(_quoteDelta(d))), gross - expected, "trader keeps the remainder");
        _assertSolvent();
    }

    function test_basis_zeroForOneExactOutput_grossedUpOnSpecifiedOutput() public {
        _installManager();

        uint256 before = _charged();
        (, int256 executed) = _swapRecorded(trader, true, 1 ether, 0);

        uint256 expected = PoolRentMath.feeOnNet(1 ether, RATE);

        assertEq(_charged() - before, expected, "ceil(net * rate / (1e6 - rate))");
        assertEq(uint256(executed), 1 ether + expected, "the AMM produced the grossed-up amount");
        _assertSolvent();
    }

    function test_basis_oneForZeroExactInput_carvedOutOfSpecifiedInput() public {
        _installManager();

        uint256 before = _charged();
        (, int256 executed) = _swapRecorded(trader, false, -1 ether, 0);

        uint256 expected = PoolRentMath.feeFromGross(1 ether, RATE);

        assertEq(_charged() - before, expected, "floor(gross input * rate)");
        assertEq(uint256(-executed), 1 ether - expected, "the AMM only saw the net input");
        _assertSolvent();
    }

    function test_basis_oneForZeroExactOutput_grossedUpOnExecutedInput() public {
        _installManager();

        uint256 before = _charged();
        (BalanceDelta d, int256 executed) = _swapRecorded(trader, false, 1 ether, 0);

        uint256 net = uint256(-executed);
        uint256 expected = PoolRentMath.feeOnNet(net, RATE);

        assertEq(_charged() - before, expected, "ceil(executed input * rate / (1e6 - rate))");
        assertEq(uint256(int256(-_quoteDelta(d))), net + expected, "trader pays the executed input plus the charge");
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                        Platform / manager split                        */
    /* ====================================================================== */

    /// @dev 1500 wei of quote input yields a charge of 3 wei, so the split is genuinely uneven and
    ///      the odd wei has to be visible on one side or the other.
    function test_split_oddChargeGivesTheOddWeiToThePlatform() public {
        _installManager();

        uint256 platformBefore = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 managerBefore = hook.feeOwed(alice);

        _swap(trader, false, -1500);

        uint256 platform = hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore;
        uint256 manager = hook.feeOwed(alice) - managerBefore;

        assertEq(platform + manager, 3, "floor(1500 * 2000 / 1e6)");
        assertEq(platform, 2, "platform rounds up");
        assertEq(manager, 1, "manager takes the remainder");
        _assertSolvent();
    }

    function test_split_sumsToTheWholeChargeOnALargeSwap() public {
        _installManager();

        uint256 platformBefore = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 managerBefore = hook.feeOwed(alice);

        (, int256 executed) = _swapRecorded(trader, true, -1 ether, 0);
        uint256 total = PoolRentMath.feeFromGross(uint256(executed), RATE);

        uint256 platform = hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore;
        uint256 manager = hook.feeOwed(alice) - managerBefore;

        assertEq(platform + manager, total, "nothing is lost between the two beneficiaries");
        assertEq(platform, (total + 1) / 2, "platform half, rounded up");
        assertEq(manager, total / 2, "manager half, rounded down");
        _assertSolvent();
    }

    /// @dev Without a manager the manager half is not silently kept: it becomes rent owed to LPs.
    function test_split_withoutManagerTheManagerShareBecomesRent() public {
        assertEq(hook.manager(), address(0), "no manager");
        uint256 platformBefore = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 rentBefore = hook.pendingRent();

        _swap(trader, false, -1500);

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore, 2, "platform share unchanged by the vacancy");
        assertEq(hook.pendingRent() - rentBefore, 1, "manager share is owed to liquidity providers");
        _assertSolvent();
    }

    /// @dev Taking the seat is not a free option on the very next swap. In the entry block the charge
    ///      is still exactly 20 bps and still fully attributed — the manager half simply lands on the
    ///      liquidity providers instead of in the newcomer's claimable liability.
    function test_split_entryBlockPaysLiquidityProvidersNotTheNewManager() public {
        _becomeManager(alice, 1e9, 1 ether);

        // Flush the rent paid on entry, so the only thing left in `pendingRent` afterwards is the
        // manager share of the swap under test.
        _swap(trader, false, -1500);
        assertEq(hook.pendingRent(), 0, "entry rent already donated");
        assertEq(hook.tenureStartBlock(), uint64(block.number), "still inside the entry block");

        uint256 platformBefore = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 managerBefore = hook.feeOwed(alice);
        uint256 totalBefore = hook.totalFeeOwed();

        vm.recordLogs();
        _swap(trader, false, -1500);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 platform = hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore;
        uint256 toProviders = hook.pendingRent();

        assertEq(platform, 2, "platform share is untouched by the entry rule");
        assertEq(hook.feeOwed(alice), managerBefore, "the newcomer earns nothing in its own entry block");
        assertEq(toProviders, 1, "its half is owed to liquidity providers instead");
        assertEq(platform + toProviders, PoolRentMath.feeFromGross(1500, RATE), "the whole 20 bps is still charged");
        assertEq(hook.totalFeeOwed() - totalBefore, platform, "and only the platform half becomes a liability");
        assertEq(_countLogs(logs, FeeAccrued.selector), 1, "one beneficiary, so one event");
        _assertSolvent();
    }

    /// @dev Rounding runs in the platform's favour on every single swap, so it can never drift behind
    ///      the manager by more than one wei per swap.
    function test_split_platformNeverFallsBehindAcrossManySwaps() public {
        _installManager();

        uint256 platformBefore = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 managerBefore = hook.feeOwed(alice);

        uint256 swaps = 8;
        for (uint256 i; i < swaps; ++i) {
            _swap(trader, i % 2 == 0, -int256(1501 + int256(i) * 7));
        }

        uint256 platform = hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore;
        uint256 manager = hook.feeOwed(alice) - managerBefore;

        assertGe(platform, manager, "platform never short-changed");
        assertLe(platform - manager, swaps, "at most one wei of drift per swap");
        _assertSolvent();
    }

    function testFuzz_split_isExactAndFavoursThePlatform(uint256 charge) public pure {
        charge = bound(charge, 0, type(uint128).max);
        (uint256 platform, uint256 manager) = PoolRentMath.splitFee(charge, PLATFORM_PPM);

        assertEq(platform + manager, charge, "split is exact");
        assertEq(platform, (charge + 1) / 2, "platform rounds up");
        assertGe(platform, manager, "platform never below manager");
    }

    /* ====================================================================== */
    /*                      The declared worked examples                      */
    /* ====================================================================== */

    function test_policy_zeroSelectedStillOwesTenBps() public pure {
        assertEq(_effective(0), 1_000, "effective floor is 10 bps");
        assertEq(_platform(0), 1_000, "platform takes the whole floor");
        assertEq(_project(0), 0, "nothing left for the project");
    }

    function test_policy_fiveBpsSelectedIsRaisedToTenBps() public pure {
        assertEq(_effective(500), 1_000, "5 bps is raised to 10 bps");
        assertEq(_platform(500), 1_000, "platform still takes 10 bps");
        assertEq(_project(500), 0, "the project cannot undercut the floor");
    }

    function test_policy_tenBpsSelectedStaysTenBps() public pure {
        assertEq(_effective(1_000), 1_000, "10 bps is already the floor");
        assertEq(_platform(1_000), 1_000, "platform takes all of it");
        assertEq(_project(1_000), 0, "no top-up is added");
    }

    function test_policy_threePercentSplitsIntoPlatformAndProject() public pure {
        uint256 selected = 300_000;
        assertEq(_effective(selected), 300_000, "3% stays 3%");
        assertEq(_platform(selected), 1_000, "platform 0.1%");
        assertEq(_project(selected), 299_000, "project 2.9%");
    }

    /// @dev The floor is carved out of the selected fee, never added on top: 3% must not become 3.1%.
    function test_policy_threePercentIsNeverToppedUp() public pure {
        uint256 selected = 300_000;
        assertTrue(_effective(selected) != 310_000, "no 0.1% surcharge");
        assertEq(_platform(selected) + _project(selected), _effective(selected), "shares reconstruct the total");
    }

    function testFuzz_policy_platformIsAlwaysExactlyTenBps(uint256 selected) public pure {
        selected = bound(selected, 0, DENOM - 1);

        assertEq(_platform(selected), MANDATORY, "platform is a constant 10 bps");
        assertGe(_effective(selected), selected, "the trader is never charged less than selected");
        assertGe(_effective(selected), MANDATORY, "and never less than the floor");
        assertEq(_platform(selected) + _project(selected), _effective(selected), "shares reconstruct the total");
    }

    /// @dev The deployed constants are one instance of that formula: 20 bps selected, split 500_000
    ///      ppm, gives the platform exactly the mandatory 10 bps and the project the other 10.
    function test_policy_deployedConstantsResolveToTenBps() public view {
        assertEq(hook.TOTAL_FEE(), _effective(hook.TOTAL_FEE()), "20 bps is above the floor");
        assertEq(hook.TOTAL_FEE() * hook.PLATFORM_SHARE_PPM() / DENOM, MANDATORY, "platform rate is 10 bps");

        (uint256 platform, uint256 manager) = PoolRentMath.splitFee(hook.TOTAL_FEE(), hook.PLATFORM_SHARE_PPM());
        assertEq(platform, MANDATORY, "platform 10 bps");
        assertEq(manager, hook.TOTAL_FEE() - MANDATORY, "project remainder");
    }

    /* ====================================================================== */
    /*                Executed volume, never requested volume                 */
    /* ====================================================================== */

    function test_executed_zeroForOneExactInput_partialFillChargesWhatRan() public {
        _installManager();

        uint256 requested = 10_000 ether;
        uint256 before = _charged();
        (BalanceDelta d, int256 executed) = _swapRecorded(trader, true, -int256(requested), _limitDown());

        assertLt(uint256(int256(-_tokenDelta(d))), requested, "the pool stopped at the price limit");
        assertEq(_charged() - before, PoolRentMath.feeFromGross(uint256(executed), RATE), "charged on executed output");
        assertLt(_charged() - before, PoolRentMath.feeFromGross(requested, RATE), "requested volume was never used");
        _assertSolvent();
    }

    function test_executed_oneForZeroExactOutput_partialFillChargesWhatRan() public {
        _installManager();

        uint256 requested = 10_000 ether;
        uint256 before = _charged();
        (BalanceDelta d, int256 executed) = _swapRecorded(trader, false, int256(requested), _limitUp());

        assertLt(uint256(int256(_tokenDelta(d))), requested, "the pool stopped at the price limit");
        assertEq(_charged() - before, PoolRentMath.feeOnNet(uint256(-executed), RATE), "charged on executed input");
        assertLt(_charged() - before, PoolRentMath.feeOnNet(requested, RATE), "requested volume was never used");
        _assertSolvent();
    }

    /// @dev Here the charge is already taken before the AMM runs, so a short fill would mean charging
    ///      for volume that never happened. The swap is rejected instead.
    function test_executed_zeroForOneExactOutput_partialFillIsRejected() public {
        _expectHookRevert(IHooks.afterSwap.selector, PoolRentHook.PartialFillRejected.selector);
        _swap(trader, true, int256(10_000 ether), _limitDown());
        _assertSolvent();
    }

    function test_executed_oneForZeroExactInput_partialFillIsRejected() public {
        _expectHookRevert(IHooks.afterSwap.selector, PoolRentHook.PartialFillRejected.selector);
        _swap(trader, false, -int256(10_000 ether), _limitUp());
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                Dust: never confiscatory, never phantom                 */
    /* ====================================================================== */

    function testFuzz_cap_chargeNeverConsumesTheWholeGross(uint256 gross) public pure {
        gross = bound(gross, 1, type(uint128).max);
        assertLt(PoolRentMath.feeFromGross(gross, RATE), gross, "trader always keeps something");
    }

    /// @dev Even a rate that would swallow the whole amount is clamped one wei short of it.
    function test_cap_clampsAtOneWeiBelowGross() public pure {
        assertEq(PoolRentMath.feeFromGross(5, DENOM), 4, "clamped below gross");
        assertEq(PoolRentMath.feeFromGross(1, DENOM), 0, "one wei is untouchable");
        assertEq(PoolRentMath.feeFromGross(0, DENOM), 0, "nothing from nothing");
    }

    function test_dust_oneWeiQuoteInputAccruesNothing() public {
        uint256 before = hook.feeOwed(PROGRAMMABLE_OWNER);
        BalanceDelta d = _swap(trader, false, -1);

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), before, "nothing accrued");
        assertEq(_quoteDelta(d), -1, "trader paid exactly one wei, no more");
        _assertSolvent();
    }

    function test_dust_oneWeiOutputIsStillDelivered() public {
        BalanceDelta quoteOut = _swap(trader, true, 1);
        assertEq(_quoteDelta(quoteOut), 1, "one wei of quote delivered");

        BalanceDelta tokenOut = _swap(trader, false, 1);
        assertEq(_tokenDelta(tokenOut), 1, "one wei of token delivered");
        assertLt(_quoteDelta(tokenOut), 0, "and paid for, not conjured");
        _assertSolvent();
    }

    function test_zeroCharge_subThresholdSwapAccruesNothing() public {
        _installManager();

        uint256 platformBefore = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 managerBefore = hook.feeOwed(alice);
        uint256 totalBefore = hook.totalFeeOwed();

        // 499 wei * 2000 / 1e6 rounds to zero.
        _swap(trader, false, -499);

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), platformBefore, "platform unchanged");
        assertEq(hook.feeOwed(alice), managerBefore, "manager unchanged");
        assertEq(hook.totalFeeOwed(), totalBefore, "total unchanged");
        _assertSolvent();
    }

    function test_zeroCharge_emitsNoFeeAccruedEvent() public {
        _installManager();

        vm.recordLogs();
        _swap(trader, false, -499);

        assertEq(_countLogs(vm.getRecordedLogs(), FeeAccrued.selector), 0, "no phantom accrual event");
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                            Claim authority                             */
    /* ====================================================================== */

    function test_claim_ownerIsPaidAtTheDestinationItPicks() public {
        _swap(trader, true, -1 ether);
        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        address dest = makeAddr("platformTreasury");

        vm.prank(PROGRAMMABLE_OWNER);
        hook.claimFee(dest, owed);

        assertEq(weth.balanceOf(dest), owed, "paid in full");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "liability cleared");
        _assertSolvent();
    }

    /// @dev The destination is an argument, not stored state, so it can differ on every claim.
    function test_claim_ownerCanUseADifferentDestinationEachTime() public {
        _swap(trader, true, -1 ether);
        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        address first = makeAddr("firstDestination");
        address second = makeAddr("secondDestination");

        vm.startPrank(PROGRAMMABLE_OWNER);
        hook.claimFee(first, owed / 3);
        hook.claimFee(second, owed - owed / 3);
        vm.stopPrank();

        assertEq(weth.balanceOf(first) + weth.balanceOf(second), owed, "both destinations paid");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "liability cleared");
        _assertSolvent();
    }

    function test_claim_strangersCannotReachThePlatformLiability() public {
        _becomeManager(bob, 1e9, 1 ether);
        _swap(trader, true, -1 ether);
        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        assertGt(owed, 0, "there is something to steal");

        address[5] memory strangers = [alice, bob, carol, address(launcher), makeAddr("randomAddress")];
        for (uint256 i; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(PoolRentHook.NothingOwed.selector);
            hook.claimFee(strangers[i], owed);
        }

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), owed, "liability untouched");
        _assertSolvent();
    }

    function test_claim_moreThanOwedReverts() public {
        _swap(trader, true, -1 ether);
        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);

        vm.prank(PROGRAMMABLE_OWNER);
        vm.expectRevert(PoolRentHook.NothingOwed.selector);
        hook.claimFee(PROGRAMMABLE_OWNER, owed + 1);

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), owed, "liability untouched");
        _assertSolvent();
    }

    function test_claim_rejectsZeroAmountAndZeroDestination() public {
        _swap(trader, true, -1 ether);

        vm.startPrank(PROGRAMMABLE_OWNER);
        vm.expectRevert(PoolRentHook.ZeroAddress.selector);
        hook.claimFee(address(0), 1);

        vm.expectRevert(PoolRentHook.NothingOwed.selector);
        hook.claimFee(PROGRAMMABLE_OWNER, 0);
        vm.stopPrank();

        _assertSolvent();
    }

    function test_claim_managerReachesOnlyItsOwnShare() public {
        _installManager();
        _swap(trader, true, -1 ether);

        uint256 managerOwed = hook.feeOwed(alice);
        uint256 platformOwed = hook.feeOwed(PROGRAMMABLE_OWNER);
        assertGt(managerOwed, 0, "manager accrued");

        vm.prank(alice);
        vm.expectRevert(PoolRentHook.NothingOwed.selector);
        hook.claimFee(alice, managerOwed + platformOwed);

        vm.prank(alice);
        hook.claimFee(alice, managerOwed);

        assertEq(hook.feeOwed(alice), 0, "manager paid out");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), platformOwed, "platform untouched");
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                        No mutable fee recipient                        */
    /* ====================================================================== */

    /// @dev A constant lives in code, not in a slot. Rewriting the hook's entire storage layout with
    ///      an attacker address still cannot move the recipient, because no slot backs it.
    function test_owner_isNotAStorageSlot() public {
        assertEq(hook.PROGRAMMABLE_OWNER(), PROGRAMMABLE_OWNER, "declared owner");
        _swap(trader, true, -1 ether);

        uint256 snapshot = vm.snapshotState();
        bytes32 attacker = bytes32(uint256(uint160(makeAddr("attacker"))));
        for (uint256 slot; slot < 64; ++slot) {
            assertTrue(vm.load(address(hook), bytes32(slot)) != attacker, "slot already held the attacker");
            vm.store(address(hook), bytes32(slot), attacker);
        }
        assertEq(hook.PROGRAMMABLE_OWNER(), PROGRAMMABLE_OWNER, "no slot backs the owner");

        vm.revertToState(snapshot);
        _assertSolvent();
    }

    /// @dev Every plausible setter is absent, and every function that does exist leaves the owner and
    ///      its accrued liability exactly where they were.
    function test_owner_hasNoSetterAndCannotBeRedirected() public {
        _becomeManager(alice, 1e9, 1 ether);
        _swap(trader, true, -1 ether);
        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);

        string[10] memory setters = [
            "setProgrammableOwner(address)",
            "setPlatformOwner(address)",
            "setOwner(address)",
            "transferOwnership(address)",
            "setFeeRecipient(address)",
            "setRecipient(address)",
            "setTreasury(address)",
            "setPlatformShare(uint256)",
            "setTotalFee(uint256)",
            "upgradeTo(address)"
        ];
        address[3] memory callers = [alice, PROGRAMMABLE_OWNER, address(launcher)];

        for (uint256 i; i < setters.length; ++i) {
            for (uint256 j; j < callers.length; ++j) {
                vm.prank(callers[j]);
                (bool ok,) = address(hook).call(abi.encodeWithSignature(setters[i], alice));
                assertFalse(ok, setters[i]);
            }
        }

        // The functions that do exist are exercised too, from the roles that may call them.
        uint24 maxLpFee = hook.MAX_LP_FEE();
        vm.startPrank(alice);
        hook.setLpFee(maxLpFee);
        hook.depositRent(1 ether);
        hook.withdrawDeposit(alice, 1 ether);
        vm.stopPrank();
        hook.poke();

        assertEq(hook.PROGRAMMABLE_OWNER(), PROGRAMMABLE_OWNER, "owner unchanged");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), owed, "liability unchanged");
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                           Non-bypassability                            */
    /* ====================================================================== */

    function test_bypass_foreignRouterIsStillCharged() public {
        RawRouter raw = new RawRouter(poolManager);
        vm.startPrank(trader);
        weth.approve(address(raw), type(uint256).max);
        token.approve(address(raw), type(uint256).max);
        vm.stopPrank();

        uint256 before = hook.feeOwed(PROGRAMMABLE_OWNER);

        vm.recordLogs();
        vm.prank(trader);
        raw.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        int256 executed = _executedQuote(vm.getRecordedLogs());

        uint256 expected = PoolRentMath.feeFromGross(uint256(executed), RATE);
        (uint256 platform,) = PoolRentMath.splitFee(expected, PLATFORM_PPM);
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER) - before, platform, "a hand-rolled router pays the same");
        _assertSolvent();
    }

    /// @dev `hookData` is attacker-controlled and the hook ignores it, so it cannot steer the charge.
    function test_bypass_arbitraryHookDataChangesNothing() public {
        uint256 snapshot = vm.snapshotState();

        vm.prank(trader);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 baseline = hook.feeOwed(PROGRAMMABLE_OWNER);

        vm.revertToState(snapshot);

        vm.prank(trader);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(PROGRAMMABLE_OWNER, uint256(0), bytes32("skip the fee"))
        );

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), baseline, "hookData is inert");
        assertGt(baseline, 0, "and the charge was real to begin with");
        _assertSolvent();
    }

    function test_bypass_secondPoolOnTheSameCurrenciesReverts() public {
        PoolKey memory sameKey = key;
        _expectHookRevert(IHooks.beforeInitialize.selector, PoolRentHook.AlreadyInitialized.selector);
        poolManager.initialize(sameKey, SQRT_PRICE_1_1);

        PoolKey memory widerSpacing = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING * 2,
            hooks: hook
        });
        _expectHookRevert(IHooks.beforeInitialize.selector, PoolRentHook.AlreadyInitialized.selector);
        poolManager.initialize(widerSpacing, SQRT_PRICE_1_1);

        _assertSolvent();
    }

    /// @dev A hookless pool on the same pair is somebody else's pool. It must neither feed this hook
    ///      nor let its volume net against this hook's liabilities.
    function test_bypass_poolWithoutTheHookAccruesNothingToIt() public {
        _initUnrelatedPool();

        uint256 platformBefore = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 totalBefore = hook.totalFeeOwed();
        uint256 heldBefore = weth.balanceOf(address(hook));

        vm.prank(trader);
        swapRouter.swap(
            unrelatedKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), platformBefore, "no cross-pool accrual");
        assertEq(hook.totalFeeOwed(), totalBefore, "no cross-pool netting");
        assertEq(weth.balanceOf(address(hook)), heldBefore, "no cross-pool custody");
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                    Pool- and currency-scoped ledger                    */
    /* ====================================================================== */

    function test_accounting_totalMatchesTheSumOfEntries() public {
        _swap(trader, true, -1 ether);

        _installManager();
        _swap(trader, false, -2 ether);
        _swap(trader, true, 1 ether);

        uint256 aliceDeposit = hook.deposits(alice);
        vm.prank(alice);
        hook.withdrawDeposit(alice, aliceDeposit);
        assertEq(hook.manager(), address(0), "alice stepped down");

        _becomeManager(bob, 2e9, 1 ether);
        vm.roll(block.number + 1);
        _swap(trader, false, 1 ether);

        uint256 sum = hook.feeOwed(PROGRAMMABLE_OWNER) + hook.feeOwed(alice) + hook.feeOwed(bob);
        assertEq(hook.totalFeeOwed(), sum, "total equals the sum of its entries");
        assertGt(hook.feeOwed(alice), 0, "alice earned while she held the pool");
        assertGt(hook.feeOwed(bob), 0, "bob earned after he took it");
        _assertSolvent();
    }

    function test_accounting_liabilityOnlyEverGrowsInTheQuoteCurrency() public {
        _installManager();

        _swap(trader, true, -1 ether);
        _swap(trader, false, -1 ether);
        _swap(trader, true, 1 ether);
        _swap(trader, false, 1 ether);

        assertEq(address(hook.quote()), address(weth), "quote is WETH");
        assertEq(token.balanceOf(address(hook)), 0, "the hook never custodies the base asset");
        assertGe(weth.balanceOf(address(hook)), hook.totalLiabilities(), "quote covers every liability");
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                            Events reconcile                            */
    /* ====================================================================== */

    function test_events_feeAccruedSumsToTheLiabilityGrowth() public {
        _installManager();

        uint256 platformBefore = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 managerBefore = hook.feeOwed(alice);

        vm.recordLogs();
        _swap(trader, true, -1 ether);
        _swap(trader, false, -1 ether);
        _swap(trader, true, 1 ether);
        _swap(trader, false, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _sumAccrued(logs, PROGRAMMABLE_OWNER),
            hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore,
            "platform events reconcile"
        );
        assertEq(_sumAccrued(logs, alice), hook.feeOwed(alice) - managerBefore, "manager events reconcile");
        assertEq(_countLogs(logs, FeeAccrued.selector), 8, "two beneficiaries on each of four swaps");
        _assertSolvent();
    }

    function test_events_feeClaimedMatchesTheTransfer() public {
        _swap(trader, true, -1 ether);
        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        address dest = makeAddr("claimDestination");

        vm.expectEmit(true, true, true, true, address(hook));
        emit FeeClaimed(PoolId.unwrap(poolId), address(weth), PROGRAMMABLE_OWNER, dest, owed);

        uint256 heldBefore = weth.balanceOf(address(hook));
        vm.prank(PROGRAMMABLE_OWNER);
        hook.claimFee(dest, owed);

        assertEq(weth.balanceOf(dest), owed, "destination credited");
        assertEq(heldBefore - weth.balanceOf(address(hook)), owed, "hook debited by the same amount");
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                                Solvency                                */
    /* ====================================================================== */

    /// @dev The directional rounding leaves dust in the hook. It must always leave a surplus, never a
    ///      shortfall, no matter how the quadrants are interleaved.
    function test_solvency_holdsAfterAMixedSession() public {
        _installManager();

        for (uint256 i; i < 6; ++i) {
            _swap(trader, i % 2 == 0, i % 3 == 0 ? -int256(0.3 ether) : int256(0.2 ether));
            vm.roll(block.number + 1);
            _assertSolvent();
        }

        uint256 platformOwed = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 managerOwed = hook.feeOwed(alice);
        vm.prank(PROGRAMMABLE_OWNER);
        hook.claimFee(PROGRAMMABLE_OWNER, platformOwed);
        vm.prank(alice);
        hook.claimFee(alice, managerOwed);

        assertGe(weth.balanceOf(address(hook)), hook.totalLiabilities(), "surplus, never shortfall");
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                                Helpers                                 */
    /* ====================================================================== */

    /// @dev With a seated manager the whole charge is observable in `feeOwed`; with the seat empty
    ///      half of it is donated to LPs inside the same call and never lands in a liability slot.
    ///      The roll clears the entry block, where the manager half also goes to LPs.
    function _installManager() private {
        _becomeManager(alice, 1e9, 1 ether);
        vm.roll(block.number + 1);
    }

    function _charged() private view returns (uint256) {
        return hook.feeOwed(PROGRAMMABLE_OWNER) + hook.feeOwed(alice);
    }

    function _swapRecorded(address who, bool zeroForOne, int256 amountSpecified, uint160 limit)
        private
        returns (BalanceDelta delta, int256 executedQuote)
    {
        vm.recordLogs();
        delta = _swap(who, zeroForOne, amountSpecified, limit);
        executedQuote = _executedQuote(vm.getRecordedLogs());
    }

    /// @dev The pool's own Swap event carries the amount the AMM actually moved, before the hook's
    ///      return delta shifts it. That is the only honest basis for the charge.
    function _executedQuote(Vm.Log[] memory logs) private view returns (int256) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(poolManager)) continue;
            if (logs[i].topics[0] != IPoolManager.Swap.selector) continue;
            if (logs[i].topics[1] != PoolId.unwrap(poolId)) continue;
            (int128 amount0, int128 amount1,,,,) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            return hook.quoteIsCurrency1() ? int256(amount1) : int256(amount0);
        }
        revert("no swap event");
    }

    function _sumAccrued(Vm.Log[] memory logs, address beneficiary) private view returns (uint256 total) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] != FeeAccrued.selector) continue;
            if (logs[i].topics[3] != bytes32(uint256(uint160(beneficiary)))) continue;
            total += abi.decode(logs[i].data, (uint256));
        }
    }

    function _countLogs(Vm.Log[] memory logs, bytes32 topic) private view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic) ++count;
        }
    }

    /// @dev A v4-core hook revert reaches the caller inside the ERC-7751 envelope the library adds.
    function _expectHookRevert(bytes4 hookFn, bytes4 err) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                hookFn,
                abi.encodeWithSelector(err),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    /// @dev Price limits tight enough that a large swap runs out of room and only partially fills.
    function _limitDown() private pure returns (uint160) {
        return SQRT_PRICE_1_1 - SQRT_PRICE_1_1 / 1_000;
    }

    function _limitUp() private pure returns (uint160) {
        return SQRT_PRICE_1_1 + SQRT_PRICE_1_1 / 1_000;
    }

    function _initUnrelatedPool() private {
        unrelatedKey = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: 3_000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(unrelatedKey, SQRT_PRICE_1_1);

        int24 lower = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        int24 upper = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
        vm.prank(alice);
        liquidityRouter.modifyLiquidity(
            unrelatedKey,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1_000 ether, salt: bytes32(0)}),
            ""
        );
    }

    /* --------------------------- policy formula --------------------------- */

    /// @dev `effective = max(selected, 1000)`: the mandatory 10 bps is carved out of whatever the
    ///      project selects, never stacked on top of it.
    function _effective(uint256 selected) private pure returns (uint256) {
        return selected < MANDATORY ? MANDATORY : selected;
    }

    function _platform(uint256) private pure returns (uint256) {
        return MANDATORY;
    }

    function _project(uint256 selected) private pure returns (uint256) {
        return _effective(selected) - MANDATORY;
    }
}
