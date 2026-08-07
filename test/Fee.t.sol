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

/// @dev Proves the mandatory Programmable volume-fee policy end to end.
///
/// The quantity the policy conserves is not `feeOwed` but the *numerator* behind it: whole wei
/// already booked, times the denominator, plus the sub-wei remainder still carried. Flooring each
/// swap independently would let an entitlement round away — a thousand 499-wei swaps carry the same
/// 10 bps as one 499,000-wei swap but floor to zero a thousand times — so most assertions here are
/// stated on that numerator, and the wei-level payout is checked against it.
contract FeeTest is PoolRentFixture {
    using PoolIdLibrary for PoolKey;

    /// @dev Hundredths of a bip, as everywhere else in this system.
    uint256 internal constant TOTAL_RATE = 2_000;
    uint256 internal constant PLATFORM_RATE = 1_000;
    uint256 internal constant PROJECT_RATE = 1_000;
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

    /// @dev With no manager the platform share is the only part that stays in the hook; the project
    ///      share is handed to liquidity providers inside the same call.
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

    function test_basis_zeroForOneExactInput_accruedOnGrossOutput() public {
        _installManager();

        (uint256 platformBefore, uint256 projectBefore) = _owed();
        (uint256 platformCarry, uint256 projectCarry) = _carries();
        (BalanceDelta d, int256 amm) = _swapRecorded(trader, true, -1 ether, 0);

        uint256 gross = uint256(amm);
        (uint256 platform, uint256 project) = _expectedFrom(gross, platformCarry, projectCarry);

        assertEq(_grossOf(d, amm), gross, "the AMM's gross output is the basis");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore, platform, "platform accrued on the gross output");
        assertEq(hook.feeOwed(alice) - projectBefore, project, "project accrued on the same gross output");
        assertEq(uint256(int256(_quoteDelta(d))), gross - platform - project, "trader keeps the remainder");
        _assertSolvent();
    }

    function test_basis_zeroForOneExactOutput_grossedUpOnSpecifiedOutput() public {
        _installManager();

        (uint256 platformBefore, uint256 projectBefore) = _owed();
        (uint256 platformCarry, uint256 projectCarry) = _carries();
        (BalanceDelta d, int256 amm) = _swapRecorded(trader, true, 1 ether, 0);

        uint256 gross = uint256(amm);
        (uint256 platform, uint256 project) = _expectedFrom(gross, platformCarry, projectCarry);

        assertEq(gross, 1 ether + platform + project, "the AMM produced the grossed-up amount");
        assertEq(_quoteDelta(d), 1 ether, "and the trader received exactly its net");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore, platform, "platform accrued on the gross");
        assertEq(hook.feeOwed(alice) - projectBefore, project, "project accrued on the same gross");
        _assertSolvent();
    }

    function test_basis_oneForZeroExactInput_carvedOutOfSpecifiedInput() public {
        _installManager();

        (uint256 platformBefore, uint256 projectBefore) = _owed();
        (uint256 platform, uint256 project) = _expected(1 ether);
        (, int256 amm) = _swapRecorded(trader, false, -1 ether, 0);

        assertEq(uint256(-amm), 1 ether - platform - project, "the AMM only saw the net input");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore, platform, "platform accrued on the gross input");
        assertEq(hook.feeOwed(alice) - projectBefore, project, "project accrued on the same gross input");
        _assertSolvent();
    }

    function test_basis_oneForZeroExactOutput_grossedUpOnExecutedInput() public {
        _installManager();

        (uint256 platformBefore, uint256 projectBefore) = _owed();
        (uint256 platformCarry, uint256 projectCarry) = _carries();
        (BalanceDelta d, int256 amm) = _swapRecorded(trader, false, 1 ether, 0);

        uint256 net = uint256(-amm);
        uint256 gross = _grossOf(d, amm);
        (uint256 platform, uint256 project) = _expectedFrom(gross, platformCarry, projectCarry);

        assertEq(gross, net + platform + project, "the charge sits on top of the executed input");
        assertEq(uint256(int256(-_quoteDelta(d))), gross, "and the trader paid the gross");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore, platform, "platform accrued on the gross");
        assertEq(hook.feeOwed(alice) - projectBefore, project, "project accrued on the same gross");
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                 Two independent entitlements, carried                  */
    /* ====================================================================== */

    /// @dev Neither entitlement is derived from the other by splitting a rounded total: each is
    ///      accrued from the gross against its own remainder.
    function test_accrual_bothSidesAccrueFromTheGrossIndependently() public {
        _installManager();
        assertEq(hook.platformFeeCarry(), 0, "fresh platform remainder");
        assertEq(hook.projectFeeCarry(), 0, "fresh project remainder");

        (uint256 platformBefore, uint256 projectBefore) = _owed();
        _swap(trader, false, -1500);

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore, 1, "floor(1500 * 1000 / 1e6)");
        assertEq(hook.feeOwed(alice) - projectBefore, 1, "the project side floors identically");
        assertEq(hook.platformFeeCarry(), 500_000, "and the half wei is carried, not dropped");
        assertEq(hook.projectFeeCarry(), 500_000, "on both sides");
        _assertSolvent();
    }

    function test_accrual_theTwoRatesSumToTheChargeTheTraderPays() public {
        _installManager();

        (uint256 platformBefore, uint256 projectBefore) = _owed();
        (uint256 platform, uint256 project) = _expected(1 ether);

        (, int256 amm) = _swapRecorded(trader, false, -1 ether, 0);

        assertEq(platform + project, PoolRentMath.feeFromGross(1 ether, TOTAL_RATE), "20 bps in total");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore, platform, "platform booked");
        assertEq(hook.feeOwed(alice) - projectBefore, project, "project booked");
        assertEq(1 ether - uint256(-amm), platform + project, "and the trader actually paid both of them");
        _assertSolvent();
    }

    /// @dev A vacant seat changes who the project share is owed to, never whether it accrues.
    function test_accrual_withoutManagerTheProjectShareBecomesRent() public {
        assertEq(hook.manager(), address(0), "no manager");
        uint256 platformBefore = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 rentBefore = hook.pendingRent();

        _swap(trader, false, -1500);

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore, 1, "platform share unchanged by the vacancy");
        assertEq(hook.pendingRent() - rentBefore, 1, "project share is owed to liquidity providers");
        assertEq(hook.platformFeeCarry(), 500_000, "both remainders still carried");
        assertEq(hook.projectFeeCarry(), 500_000, "including the project's");
        _assertSolvent();
    }

    /// @dev Taking the seat is not a free option on the very next swap. In the entry block the charge
    ///      is still exactly 20 bps and still fully attributed — the project half simply lands on the
    ///      liquidity providers instead of in the newcomer's claimable liability.
    function test_accrual_entryBlockPaysLiquidityProvidersNotTheNewManager() public {
        _becomeManager(alice, 1e9, 1 ether);

        // Flush the rent paid on entry, so the only thing left in `pendingRent` afterwards is the
        // project share of the swap under test.
        _swap(trader, false, -1500);
        assertEq(hook.pendingRent(), 0, "entry rent already donated");
        assertEq(hook.tenureStartBlock(), uint64(block.number), "still inside the entry block");

        (uint256 platformBefore, uint256 projectBefore) = _owed();
        (uint256 platform, uint256 project) = _expected(1500);

        vm.recordLogs();
        _swap(trader, false, -1500);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore, platform, "platform untouched by the entry rule");
        assertEq(hook.feeOwed(alice), projectBefore, "the newcomer earns nothing in its own entry block");
        assertEq(hook.pendingRent(), project, "its share is owed to liquidity providers instead");
        assertEq(_countLogs(logs, FeeAccrued.selector), 1, "one beneficiary, so one FeeAccrued");
        _assertSolvent();
    }

    function testFuzz_accrue_conservesTheNumerator(uint256 gross, uint256 carry) public pure {
        gross = bound(gross, 0, type(uint128).max);
        carry = bound(carry, 0, DENOM - 1);

        (uint256 amount, uint256 next) = PoolRentMath.accrue(gross, PLATFORM_RATE, carry);

        assertEq(amount * DENOM + next, gross * PLATFORM_RATE + carry, "numerator in equals numerator out");
        assertLt(next, DENOM, "the remainder stays sub-wei");
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

    /// @dev The deployed constants are one instance of that formula: 20 bps selected, of which the
    ///      mandatory 10 bps is the platform's own rate and the other 10 is the project's. Neither is
    ///      obtained by splitting a rounded total.
    function test_policy_deployedConstantsResolveToTenBps() public view {
        assertEq(hook.TOTAL_FEE(), _effective(hook.TOTAL_FEE()), "20 bps is above the floor");
        assertEq(hook.PLATFORM_RATE(), MANDATORY, "platform rate is the mandatory 10 bps");
        assertEq(hook.PROJECT_RATE(), _project(hook.TOTAL_FEE()), "project rate is the remainder");
        assertEq(hook.PLATFORM_RATE() + hook.PROJECT_RATE(), hook.TOTAL_FEE(), "and nothing else");
    }

    /* ====================================================================== */
    /*             Sub-wei swaps still pay, on all four quadrants              */
    /* ====================================================================== */

    /// @dev The maintainer's scenario, verbatim: a thousand 499-wei gross swaps each floor to zero on
    ///      their own, yet their 499,000 wei of aggregate volume owes 499 wei at 10 bps, and it is
    ///      paid. `oneForZero-exactInput` is used because there the gross is the specified amount, so
    ///      the aggregate volume is exact rather than measured.
    function test_tiny_thousandSubWeiSwapsPayTheAggregateEntitlement() public {
        uint256 slice = 499;
        uint256 slices = 1_000;

        assertEq(PoolRentMath.feeFromGross(slice, PLATFORM_RATE), 0, "each swap floors to zero on its own");

        for (uint256 i; i < slices; ++i) {
            _swap(trader, false, -int256(slice));
        }

        uint256 volume = slice * slices;
        assertEq(volume, 499_000, "the maintainer's aggregate volume");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), 499, "and its 10 bps entitlement, paid in full");
        assertEq(_platformNumerator(), volume * PLATFORM_RATE, "nothing rounded away");
        assertEq(hook.pendingRent(), 499, "the project side is conserved the same way");
        _assertSolvent();
    }

    function test_tiny_zeroForOneExactInput_accruesInAggregate() public {
        _assertTinyRunPays(true, -700, 25);
    }

    function test_tiny_zeroForOneExactOutput_accruesInAggregate() public {
        _assertTinyRunPays(true, 499, 25);
    }

    function test_tiny_oneForZeroExactInput_accruesInAggregate() public {
        _assertTinyRunPays(false, -499, 25);
    }

    function test_tiny_oneForZeroExactOutput_accruesInAggregate() public {
        _assertTinyRunPays(false, 499, 25);
    }

    /* ====================================================================== */
    /*                  Split volume versus whole volume                      */
    /* ====================================================================== */

    /// @dev Splitting a volume cannot change what it owes. Where the AMM executes the same gross
    ///      either way this is exact to the wei; where it does not, the entitlement moves by exactly
    ///      the difference in executed gross and by nothing else.
    function test_conservation_zeroForOneExactInput_splitMatchesWhole() public {
        _assertSplitMatchesWhole(true, -700, 25, false);
    }

    function test_conservation_zeroForOneExactOutput_splitMatchesWhole() public {
        _assertSplitMatchesWhole(true, 499, 25, true);
    }

    function test_conservation_oneForZeroExactInput_splitMatchesWhole() public {
        _assertSplitMatchesWhole(false, -499, 25, true);
    }

    function test_conservation_oneForZeroExactOutput_splitMatchesWhole() public {
        _assertSplitMatchesWhole(false, 499, 25, false);
    }

    /// @dev The same statement as pure arithmetic, over every slice size and slice count.
    function testFuzz_conservation_slicesEqualTheWhole(uint256 slice, uint8 count) public pure {
        slice = bound(slice, 0, 1e24);
        uint256 slices = bound(count, 1, 64);

        uint256 carry;
        uint256 paid;
        for (uint256 i; i < slices; ++i) {
            (uint256 amount, uint256 next) = PoolRentMath.accrue(slice, PLATFORM_RATE, carry);
            paid += amount;
            carry = next;
        }

        (uint256 whole,) = PoolRentMath.accrue(slice * slices, PLATFORM_RATE, 0);
        assertEq(paid, whole, "slices pay what the whole pays");
        assertEq(paid * DENOM + carry, slice * slices * PLATFORM_RATE, "and the numerator is conserved");
    }

    /* ====================================================================== */
    /*                   Claims never reset the remainder                     */
    /* ====================================================================== */

    function test_carry_claimDoesNotResetTheRemainder() public {
        _swap(trader, false, -1500);
        uint256 carry = hook.platformFeeCarry();
        assertEq(carry, 500_000, "a remainder is standing");

        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        vm.prank(PROGRAMMABLE_OWNER);
        hook.claimFee(makeAddr("platformTreasury"), owed);

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "the wei were paid out");
        assertEq(hook.platformFeeCarry(), carry, "the remainder survives the claim");
        assertEq(hook.projectFeeCarry(), carry, "so does the project's");
        _assertSolvent();
    }

    /// @dev Claiming halfway through a run of sub-wei swaps must not cost the owner anything: the
    ///      total eventually paid is the same as if it had never claimed.
    function test_carry_midRunClaimDoesNotChangeTheTotal() public {
        uint256 slice = 499;
        uint256 slices = 200;
        address destination = makeAddr("platformTreasury");

        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < slices; ++i) {
            _swap(trader, false, -int256(slice));
        }
        uint256 uninterrupted = hook.feeOwed(PROGRAMMABLE_OWNER);
        vm.revertToState(snapshot);

        for (uint256 i; i < slices; ++i) {
            _swap(trader, false, -int256(slice));
            if (i == slices / 2) {
                uint256 carry = hook.platformFeeCarry();
                uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
                vm.prank(PROGRAMMABLE_OWNER);
                hook.claimFee(destination, owed);
                assertEq(hook.platformFeeCarry(), carry, "the claim left the remainder alone");
            }
        }

        assertEq(
            weth.balanceOf(destination) + hook.feeOwed(PROGRAMMABLE_OWNER),
            uninterrupted,
            "claiming mid-run costs the owner nothing"
        );
        assertEq(
            _platformNumerator() + weth.balanceOf(destination) * DENOM, slice * slices * PLATFORM_RATE, "conserved"
        );
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                       Partial fills roll back                          */
    /* ====================================================================== */

    /// @dev On the two quadrants where the charge is sized before the AMM runs, a short fill reverts.
    ///      The remainders must be exactly what they were, or a rejected swap would still have moved
    ///      an entitlement.
    function test_rollback_zeroForOneExactOutput_leavesBothRemaindersUntouched() public {
        _assertPartialFillRollsBack(true, int256(10_000 ether), _limitDown());
    }

    function test_rollback_oneForZeroExactInput_leavesBothRemaindersUntouched() public {
        _assertPartialFillRollsBack(false, -int256(10_000 ether), _limitUp());
    }

    /* ====================================================================== */
    /*                           Manager turnover                             */
    /* ====================================================================== */

    /// @dev The project entitlement belongs to the seat, not to whoever happened to generate it, so a
    ///      remainder built up under one manager pays out to the next rather than being forfeited.
    function test_turnover_projectRemainderSurvivesAHandover() public {
        _installManager();
        _swap(trader, false, -1500);

        uint256 carry = hook.projectFeeCarry();
        assertEq(carry, 500_000, "half a wei standing under alice");
        assertEq(hook.feeOwed(alice), 1, "and one whole wei already hers");

        vm.roll(block.number + hook.MIN_TENURE_BLOCKS());
        _becomeManager(bob, 11e8, 1 ether);
        assertEq(hook.manager(), bob, "seat changed hands");
        assertEq(hook.projectFeeCarry(), carry, "the handover left the remainder alone");

        vm.roll(block.number + 1);
        (, uint256 project) = _expected(1500);
        _swap(trader, false, -1500);

        assertEq(project, 2, "the carried half wei matures into the next payout");
        assertEq(hook.feeOwed(bob), 2, "and is paid, not forfeited");
        assertEq(hook.feeOwed(alice), 1, "alice keeps what she was already owed");
        _assertSolvent();
    }

    function test_turnover_projectRemainderSurvivesAnEviction() public {
        _installManager();
        _swap(trader, false, -1500);

        uint256 carry = hook.projectFeeCarry();
        uint256 deposit = hook.deposits(alice);
        vm.prank(alice);
        hook.withdrawDeposit(alice, deposit);

        assertEq(hook.manager(), address(0), "evicted");
        assertEq(hook.projectFeeCarry(), carry, "eviction left the remainder alone");
        assertEq(hook.pendingRent(), 0, "and nothing is owed to providers yet");

        (, uint256 project) = _expected(1500);
        _swap(trader, false, -1500);

        assertEq(project, 2, "the carried half wei still matures");
        assertEq(hook.pendingRent(), 2, "and reaches liquidity providers instead of being lost");
        _assertSolvent();
    }

    /// @dev The platform entitlement is measured on volume alone, so who holds the seat — or whether
    ///      anyone does — cannot change it.
    function test_turnover_platformSideIsIndifferentToTheSeat() public {
        uint256 slice = 499;
        uint256 slices = 40;

        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < slices; ++i) {
            _swap(trader, false, -int256(slice));
        }
        uint256 vacantOwed = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 vacantCarry = hook.platformFeeCarry();
        vm.revertToState(snapshot);

        _installManager();
        for (uint256 i; i < slices; ++i) {
            _swap(trader, false, -int256(slice));
        }

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), vacantOwed, "same wei with a manager as without");
        assertEq(hook.platformFeeCarry(), vacantCarry, "same remainder too");
        assertEq(_platformNumerator(), slice * slices * PLATFORM_RATE, "and both equal the volume's 10 bps");
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                        Vacant-seat routing                             */
    /* ====================================================================== */

    /// @dev With nobody seated the project share is owed to liquidity providers, but it is still
    ///      accrued against the same carried remainder rather than being skipped.
    function test_vacantSeat_projectRemainderStillAccruesAndConserves() public {
        assertEq(hook.manager(), address(0), "no manager");
        uint256 slice = 499;
        uint256 slices = 40;

        for (uint256 i; i < slices; ++i) {
            _swap(trader, false, -int256(slice));
        }

        uint256 volume = slice * slices;
        assertEq(
            hook.pendingRent() * DENOM + hook.projectFeeCarry(),
            volume * PROJECT_RATE,
            "the project numerator is conserved into pendingRent"
        );
        assertGt(hook.pendingRent(), 0, "and whole wei actually reached liquidity providers");
        assertEq(_platformNumerator(), volume * PLATFORM_RATE, "the platform side is untouched by the vacancy");
        _assertSolvent();
    }

    /// @dev A seat that is empty, filled and emptied again must not disturb either remainder's
    ///      conservation. The project share changes destination three times over the session and
    ///      still adds up.
    function test_vacantSeat_conservesAcrossAFullSeatCycle() public {
        uint256 slice = 499;
        uint256 volume;

        // Vacant: the project share is owed to liquidity providers and waits in `pendingRent`.
        for (uint256 i; i < 10; ++i) {
            _swap(trader, false, -int256(slice));
            volume += slice;
        }
        uint256 deliveredWhileVacant = hook.pendingRent();
        assertGt(deliveredWhileVacant, 0, "providers are owed something");

        // Seated: it is owed to the manager. Taking the seat pays a block of rent, which pushes the
        // standing balance over the donation floor and hands the earlier wei to providers for real.
        _installManager();
        for (uint256 i; i < 10; ++i) {
            _swap(trader, false, -int256(slice));
            volume += slice;
        }
        assertEq(hook.pendingRent(), 0, "flushed on the way in");

        // Vacant again.
        uint256 deposit = hook.deposits(alice);
        vm.prank(alice);
        hook.withdrawDeposit(alice, deposit);
        assertEq(hook.manager(), address(0), "seat empty again");
        for (uint256 i; i < 10; ++i) {
            _swap(trader, false, -int256(slice));
            volume += slice;
        }

        assertEq(_platformNumerator(), volume * PLATFORM_RATE, "platform conserved across the cycle");
        assertEq(
            (hook.feeOwed(alice) + hook.pendingRent() + deliveredWhileVacant) * DENOM + hook.projectFeeCarry(),
            volume * PROJECT_RATE,
            "project conserved across the cycle, wherever it was routed"
        );
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                Executed volume, never requested volume                 */
    /* ====================================================================== */

    function test_executed_zeroForOneExactInput_partialFillChargesWhatRan() public {
        _installManager();

        uint256 requested = 10_000 ether;
        (uint256 platformBefore,) = _owed();
        (uint256 platformCarry, uint256 projectCarry) = _carries();
        (BalanceDelta d, int256 amm) = _swapRecorded(trader, true, -int256(requested), _limitDown());

        uint256 gross = _grossOf(d, amm);
        (uint256 platform,) = _expectedFrom(gross, platformCarry, projectCarry);

        assertLt(uint256(int256(-_tokenDelta(d))), requested, "the pool stopped at the price limit");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore, platform, "charged on the executed output");
        assertLt(platform, PoolRentMath.feeFromGross(requested, PLATFORM_RATE), "requested volume was never used");
        _assertSolvent();
    }

    function test_executed_oneForZeroExactOutput_partialFillChargesWhatRan() public {
        _installManager();

        uint256 requested = 10_000 ether;
        (uint256 platformBefore,) = _owed();
        (uint256 platformCarry, uint256 projectCarry) = _carries();
        (BalanceDelta d, int256 amm) = _swapRecorded(trader, false, int256(requested), _limitUp());

        uint256 gross = _grossOf(d, amm);
        (uint256 platform,) = _expectedFrom(gross, platformCarry, projectCarry);

        assertLt(uint256(int256(_tokenDelta(d))), requested, "the pool stopped at the price limit");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER) - platformBefore, platform, "charged on the executed input");
        assertLt(platform, PoolRentMath.feeFromGross(requested, PLATFORM_RATE), "requested volume was never used");
        _assertSolvent();
    }

    /// @dev Here the charge is sized before the AMM runs, so a short fill would mean charging for
    ///      volume that never happened. The swap is rejected instead.
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
        assertLt(PoolRentMath.feeFromGross(gross, TOTAL_RATE), gross, "trader always keeps something");
    }

    /// @dev Even a rate that would swallow the whole amount is clamped one wei short of it.
    function test_cap_clampsAtOneWeiBelowGross() public pure {
        assertEq(PoolRentMath.feeFromGross(5, DENOM), 4, "clamped below gross");
        assertEq(PoolRentMath.feeFromGross(1, DENOM), 0, "one wei is untouchable");
        assertEq(PoolRentMath.feeFromGross(0, DENOM), 0, "nothing from nothing");
    }

    /// @dev When the bound withholds whole wei, they go back on the carry rather than being dropped:
    ///      999 wei fills both remainders to one wei short of maturity, then a 1-wei swap matures
    ///      both but cannot be charged 2 wei out of 1.
    function test_cap_withheldUnitsGoBackOnTheCarry() public {
        _installManager();

        _swap(trader, false, -999);
        assertEq(hook.platformFeeCarry(), 999_000, "one wei short of maturity");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "nothing paid yet");

        (uint256 platformBefore, uint256 projectBefore) = _owed();
        BalanceDelta d = _swap(trader, false, -1);

        assertEq(_quoteDelta(d), -1, "the trader still paid only its one wei");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), platformBefore, "the charge could not be taken");
        assertEq(hook.feeOwed(alice), projectBefore, "on either side");
        assertEq(hook.platformFeeCarry(), DENOM, "so the withheld wei went back on the carry");
        assertEq(hook.projectFeeCarry(), DENOM, "project side too");

        // Nothing was lost: the very next swap pays out what the bound refused to take.
        (uint256 platform, uint256 project) = _expected(1);
        assertEq(platform, 1, "matured platform wei is still owed");
        assertEq(project, 1, "matured project wei is still owed");
        assertEq(_platformNumerator(), 1_000_000, "999 + 1 wei of volume, at 10 bps, conserved");
        _assertSolvent();
    }

    function test_dust_oneWeiQuoteInputAccruesNothing() public {
        uint256 before = hook.feeOwed(PROGRAMMABLE_OWNER);
        BalanceDelta d = _swap(trader, false, -1);

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), before, "nothing accrued");
        assertEq(hook.platformFeeCarry(), PLATFORM_RATE, "but the entitlement was recorded");
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

    function test_zeroCharge_subThresholdSwapPaysNoWeiButRecordsTheEntitlement() public {
        _installManager();

        (uint256 platformBefore, uint256 projectBefore) = _owed();
        uint256 totalBefore = hook.totalFeeOwed();

        // 499 wei * 1000 / 1e6 rounds to zero on both sides.
        _swap(trader, false, -499);

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), platformBefore, "no platform wei");
        assertEq(hook.feeOwed(alice), projectBefore, "no project wei");
        assertEq(hook.totalFeeOwed(), totalBefore, "no liability");
        assertEq(hook.platformFeeCarry(), 499_000, "but the platform entitlement was not thrown away");
        assertEq(hook.projectFeeCarry(), 499_000, "nor the project's");
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

    /// @dev Every plausible setter is absent, and every function that does exist leaves the owner,
    ///      its accrued liability and its carried remainder exactly where they were.
    function test_owner_hasNoSetterAndCannotBeRedirected() public {
        _installManager();
        _swap(trader, true, -1 ether);
        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 carry = hook.platformFeeCarry();

        string[10] memory setters = [
            "setProgrammableOwner(address)",
            "setPlatformOwner(address)",
            "setOwner(address)",
            "transferOwnership(address)",
            "setFeeRecipient(address)",
            "setRecipient(address)",
            "setTreasury(address)",
            "setPlatformRate(uint256)",
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
        assertEq(hook.platformFeeCarry(), carry, "remainder unchanged");
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
        int256 amm = _executedQuote(vm.getRecordedLogs());

        (uint256 platform,) = PoolRentMath.accrue(uint256(amm), PLATFORM_RATE, 0);
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER) - before, platform, "a hand-rolled router pays the same");
        _assertSolvent();
    }

    /// @dev `hookData` is attacker-controlled and the hook ignores it, so it cannot steer the charge.
    function test_bypass_arbitraryHookDataChangesNothing() public {
        uint256 snapshot = vm.snapshotState();

        _rawSwap("");
        uint256 baselineOwed = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 baselineCarry = hook.platformFeeCarry();

        vm.revertToState(snapshot);

        _rawSwap(abi.encode(PROGRAMMABLE_OWNER, uint256(0), bytes32("skip the fee")));

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), baselineOwed, "hookData is inert");
        assertEq(hook.platformFeeCarry(), baselineCarry, "down to the carried remainder");
        assertGt(baselineOwed, 0, "and the charge was real to begin with");
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
    ///      nor let its volume net against this hook's liabilities or remainders.
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
        assertEq(hook.platformFeeCarry(), 0, "no cross-pool remainder");
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

    /// @dev Both remainders are sub-wei by construction, so they are an accounting fact rather than a
    ///      balance the hook has to hold.
    function test_accounting_remaindersStaySubWei() public {
        _installManager();
        for (uint256 i; i < 12; ++i) {
            _swap(trader, false, -int256(499 + int256(i) * 137));
        }

        assertLt(hook.platformFeeCarry(), DENOM, "platform remainder is sub-wei");
        assertLt(hook.projectFeeCarry(), DENOM, "project remainder is sub-wei");
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                            Events reconcile                            */
    /* ====================================================================== */

    function test_events_feeAccruedSumsToTheLiabilityGrowth() public {
        _installManager();

        (uint256 platformBefore, uint256 projectBefore) = _owed();

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
        assertEq(_sumAccrued(logs, alice), hook.feeOwed(alice) - projectBefore, "project events reconcile");
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

    /// @dev With a seated manager the whole charge is observable in `feeOwed`; with the seat empty the
    ///      project half is owed to LPs instead. The roll clears the entry block, where the project
    ///      half also goes to LPs.
    function _installManager() private {
        _becomeManager(alice, 1e9, 1 ether);
        vm.roll(block.number + 1);
    }

    /// @dev Whole wei booked to the platform plus the sub-wei remainder still carried, in numerator
    ///      units. This is what the policy conserves; `feeOwed` alone is only its floor.
    function _platformNumerator() private view returns (uint256) {
        return hook.feeOwed(PROGRAMMABLE_OWNER) * DENOM + hook.platformFeeCarry();
    }

    function _owed() private view returns (uint256 platform, uint256 project) {
        platform = hook.feeOwed(PROGRAMMABLE_OWNER);
        project = hook.feeOwed(alice);
    }

    function _carries() private view returns (uint256 platformCarry, uint256 projectCarry) {
        platformCarry = hook.platformFeeCarry();
        projectCarry = hook.projectFeeCarry();
    }

    /// @dev What the hook must book for one executed gross, given the remainders standing right now.
    function _expected(uint256 gross) private view returns (uint256 platform, uint256 project) {
        (uint256 platformCarry, uint256 projectCarry) = _carries();
        return _expectedFrom(gross, platformCarry, projectCarry);
    }

    /// @dev The same, from remainders captured before the swap ran — the swap moves them, so a test
    ///      that only learns the gross afterwards has to hold on to the earlier values.
    function _expectedFrom(uint256 gross, uint256 platformCarry, uint256 projectCarry)
        private
        pure
        returns (uint256 platform, uint256 project)
    {
        (platform,) = PoolRentMath.accrue(gross, PLATFORM_RATE, platformCarry);
        (project,) = PoolRentMath.accrue(gross, PROJECT_RATE, projectCarry);
    }

    /// @dev The executed gross quote volume a swap was charged on. The AMM's own leg and the trader's
    ///      leg differ by exactly the charge, which always comes out of the quote side, so the gross
    ///      is whichever of the two is larger.
    function _grossOf(BalanceDelta d, int256 ammQuote) private view returns (uint256) {
        uint256 amm = ammQuote < 0 ? uint256(-ammQuote) : uint256(ammQuote);
        int128 q = _quoteDelta(d);
        uint256 side = q < 0 ? uint256(uint128(-q)) : uint256(uint128(q));
        return amm > side ? amm : side;
    }

    function _swapGross(address who, bool zeroForOne, int256 amountSpecified) private returns (uint256) {
        (BalanceDelta d, int256 amm) = _swapRecorded(who, zeroForOne, amountSpecified, 0);
        return _grossOf(d, amm);
    }

    /// @dev A run of swaps each too small to owe a whole wei on its own must still pay the aggregate.
    function _assertTinyRunPays(bool zeroForOne, int256 amountSpecified, uint256 slices) private {
        uint256 volume;
        for (uint256 i; i < slices; ++i) {
            volume += _swapGross(trader, zeroForOne, amountSpecified);
        }

        uint256 perSwap = volume / slices;
        assertEq(PoolRentMath.feeFromGross(perSwap, PLATFORM_RATE), 0, "each swap floors to zero on its own");
        assertEq(_platformNumerator(), volume * PLATFORM_RATE, "the aggregate entitlement is conserved");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), volume * PLATFORM_RATE / DENOM, "and paid out in whole wei");
        assertGt(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "a run of sub-wei swaps still pays");
        _assertSolvent();
    }

    /// @dev The entitlement is a function of executed gross and nothing else, so `feeOwed + carry`
    ///      per unit of gross must be the same however the volume is chopped up. On the quadrants
    ///      where the quote side is the specified currency the AMM executes the identical gross
    ///      either way, so the payout is also identical to the wei; on the other two, per-swap AMM
    ///      rounding moves the gross a little and the entitlement follows it exactly.
    function _assertSplitMatchesWhole(bool zeroForOne, int256 slice, uint256 slices, bool grossIsExact) private {
        uint256 snapshot = vm.snapshotState();

        uint256 splitGross;
        for (uint256 i; i < slices; ++i) {
            splitGross += _swapGross(trader, zeroForOne, slice);
        }
        uint256 splitNumerator = _platformNumerator();
        uint256 splitOwed = hook.feeOwed(PROGRAMMABLE_OWNER);

        vm.revertToState(snapshot);

        uint256 wholeGross = _swapGross(trader, zeroForOne, slice * int256(slices));
        uint256 wholeNumerator = _platformNumerator();
        uint256 wholeOwed = hook.feeOwed(PROGRAMMABLE_OWNER);

        assertEq(splitNumerator, splitGross * PLATFORM_RATE, "conserved when the volume is split");
        assertEq(wholeNumerator, wholeGross * PLATFORM_RATE, "conserved when it is whole");
        assertEq(splitOwed, splitNumerator / DENOM, "split payout is the whole-wei part of it");
        assertEq(wholeOwed, wholeNumerator / DENOM, "so is the unsplit payout");

        if (grossIsExact) {
            assertEq(splitGross, wholeGross, "the AMM executed the same volume either way");
            assertEq(splitOwed, wholeOwed, "so the payout is identical to the wei");
            assertEq(splitNumerator, wholeNumerator, "remainder included");
        } else {
            assertApproxEqRel(splitGross, wholeGross, 0.01e18, "the AMM executed essentially the same volume");
        }
        _assertSolvent();
    }

    /// @dev A rejected swap must leave both remainders exactly where it found them.
    function _assertPartialFillRollsBack(bool zeroForOne, int256 amountSpecified, uint160 limit) private {
        _installManager();
        _swap(trader, false, -1500);

        uint256 platformCarry = hook.platformFeeCarry();
        uint256 projectCarry = hook.projectFeeCarry();
        (uint256 platformOwed, uint256 projectOwed) = _owed();
        assertGt(platformCarry, 0, "there is a remainder to disturb");

        _expectHookRevert(IHooks.afterSwap.selector, PoolRentHook.PartialFillRejected.selector);
        _swap(trader, zeroForOne, amountSpecified, limit);

        assertEq(hook.platformFeeCarry(), platformCarry, "platform remainder rolled back");
        assertEq(hook.projectFeeCarry(), projectCarry, "project remainder rolled back");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), platformOwed, "platform liability rolled back");
        assertEq(hook.feeOwed(alice), projectOwed, "project liability rolled back");
        _assertSolvent();
    }

    function _rawSwap(bytes memory hookData) private {
        vm.prank(trader);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
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
    ///      return delta shifts it.
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
