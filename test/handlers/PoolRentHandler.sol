// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolRentHook} from "../../src/PoolRentHook.sol";

/// @dev Bounded actor driver for the stateful invariant run.
///
/// Every action is wrapped in try/catch so a rejected call still counts as an entry and never hides
/// a ghost update behind a revert: on a revert the hook's state and the ghosts roll back together.
/// The ghosts split every wei that crosses the hook boundary into four buckets — pulled in from
/// actors, charged out of the PoolManager, paid back to actors, donated to liquidity providers —
/// which is what `invariant_conservation` closes.
contract PoolRentHandler is CommonBase, StdUtils {
    /// @dev Immutable beneficiary of the Programmable platform share.
    address public constant PLATFORM = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;

    PoolSwapTest internal immutable swapRouter;
    PoolModifyLiquidityTest internal immutable liquidityRouter;
    PoolRentHook internal immutable hook;
    IERC20 internal immutable quote;
    bool internal immutable quoteIsCurrency1;

    PoolKey internal key;
    address[] internal actors;

    int24 internal immutable tickLower;
    int24 internal immutable tickUpper;

    /* ------------------------------- ghosts ------------------------------- */

    /// @notice WETH actors handed to the hook as auction deposits.
    uint256 public ghostPulledIn;
    /// @notice WETH the hook handed back to actors, through withdrawals and fee claims.
    uint256 public ghostPaidOut;
    /// @notice WETH the hook took out of the PoolManager as the volume charge.
    uint256 public ghostCharged;
    /// @notice WETH the hook pushed back into the pool as rent for liquidity providers.
    uint256 public ghostDonated;
    /// @notice Executed gross quote-side volume the charge was levied on.
    uint256 public ghostGrossQuote;
    uint256 public ghostSwaps;

    uint256 public ghostPlatformAccrued;
    uint256 public ghostPlatformClaimed;
    /// @notice Platform liability lost to anything other than the platform's own claim. Must stay 0.
    uint256 public ghostPlatformBadDecrease;
    /// @notice Swaps that left the hook holding less than it took in. Must stay 0.
    uint256 public ghostNegativeCharge;
    /// @notice Accepted bids whose deposit did not cover the minimum tenure. Must stay 0.
    uint256 public ghostBadBids;
    /// @notice Handovers that did not start a fresh tenure, or self-bids that moved the window.
    uint256 public ghostBadTenureStart;
    /// @notice Handovers that did not pay for their own entry block. Must stay 0.
    uint256 public ghostFreeSeatTakeovers;
    /// @notice Manager fee accrued in the very block the seat was taken. Must stay 0.
    uint256 public ghostEntryBlockAccrual;

    uint256 public entries;
    uint256 public useful;
    uint256 public rejected;

    mapping(address actor => uint256 liquidity) public liquidityOf;

    constructor(
        PoolSwapTest _swapRouter,
        PoolModifyLiquidityTest _liquidityRouter,
        PoolRentHook _hook,
        IERC20 _quote,
        PoolKey memory _key,
        address[] memory _actors
    ) {
        swapRouter = _swapRouter;
        liquidityRouter = _liquidityRouter;
        hook = _hook;
        quote = _quote;
        quoteIsCurrency1 = _hook.quoteIsCurrency1();
        key = _key;
        actors = _actors;

        tickLower = (TickMath.MIN_TICK / _key.tickSpacing) * _key.tickSpacing;
        tickUpper = (TickMath.MAX_TICK / _key.tickSpacing) * _key.tickSpacing;
    }

    /// @dev Counts the entry and books every move of the platform liability. Only a platform claim
    ///      may push it down; anything else that does lands in `ghostPlatformBadDecrease`.
    modifier tracks(bool platformMayDecrease) {
        uint256 before = hook.feeOwed(PLATFORM);
        entries++;
        _;
        uint256 current = hook.feeOwed(PLATFORM);
        if (current > before) {
            ghostPlatformAccrued += current - before;
        } else if (current < before) {
            if (platformMayDecrease) ghostPlatformClaimed += before - current;
            else ghostPlatformBadDecrease += before - current;
        }
    }

    /* ------------------------------- actions ------------------------------ */

    function swapExactInput(uint256 actorSeed, bool zeroForOne, uint256 amount) external tracks(false) {
        _swap(_actor(actorSeed), zeroForOne, -int256(bound(amount, 1, 200 ether)));
    }

    function swapExactOutput(uint256 actorSeed, bool zeroForOne, uint256 amount) external tracks(false) {
        _swap(_actor(actorSeed), zeroForOne, int256(bound(amount, 1, 200 ether)));
    }

    function bid(uint256 actorSeed, uint256 rent, uint256 deposit) external tracks(false) {
        address seated = hook.manager();
        // Bid as the incumbent every so often, so the self-bid path is reached as well as handovers.
        address actor = (seated != address(0) && actorSeed % 4 == 0) ? seated : _actor(actorSeed);
        uint128 rentPerBlock = uint128(bound(rent, hook.MIN_RENT_PER_BLOCK(), 1e15));
        // A challenger has to fund the entry block on top of the minimum tenure.
        uint256 floorDeposit = uint256(rentPerBlock) * (hook.MIN_DEPOSIT_BLOCKS() + 1);
        uint256 amount = bound(deposit, floorDeposit, floorDeposit * 4);
        if (amount > quote.balanceOf(actor)) {
            rejected++;
            return;
        }

        uint64 tenureBefore = hook.tenureStartBlock();
        uint256 pendingBefore = hook.pendingRent();

        vm.recordLogs();
        vm.prank(actor);
        try hook.bid(rentPerBlock, amount) {
            ghostPulledIn += amount;
            useful++;
            if (hook.deposits(actor) < uint256(hook.rentPerBlock()) * hook.MIN_DEPOSIT_BLOCKS()) ghostBadBids++;

            // The hook decides after its own accrual, which can evict the caller mid-call and turn
            // what looked like a self-bid into a handover, so take the incumbent from the event.
            if (_incumbentFromLogs() != actor) {
                // A genuine handover starts a fresh tenure, resets the fee and pays its first block.
                if (hook.tenureStartBlock() != uint64(block.number)) ghostBadTenureStart++;
                if (hook.managerLpFee() != hook.DEFAULT_LP_FEE()) ghostBadTenureStart++;
                if (hook.pendingRent() < pendingBefore + rentPerBlock) ghostFreeSeatTakeovers++;
            } else if (hook.tenureStartBlock() != tenureBefore) {
                // Re-posting your own rent must not push the protection window out.
                ghostBadTenureStart++;
            }
        } catch {
            vm.getRecordedLogs();
            rejected++;
        }
    }

    function topUpDeposit(uint256 actorSeed, uint256 amount) external tracks(false) {
        address actor = _actor(actorSeed);
        uint256 value = bound(amount, 1, 10 ether);
        if (value > quote.balanceOf(actor)) {
            rejected++;
            return;
        }

        vm.prank(actor);
        try hook.depositRent(value) {
            ghostPulledIn += value;
            useful++;
        } catch {
            rejected++;
        }
    }

    function withdrawDeposit(uint256 actorSeed, uint256 amount) external tracks(false) {
        address actor = _actor(actorSeed);
        uint256 balance = hook.deposits(actor);
        if (balance == 0) {
            rejected++;
            return;
        }
        uint256 value = bound(amount, 1, balance);
        uint256 before = quote.balanceOf(actor);

        vm.prank(actor);
        try hook.withdrawDeposit(actor, value) {
            ghostPaidOut += quote.balanceOf(actor) - before;
            useful++;
        } catch {
            rejected++;
        }
    }

    function setLpFee(uint256 actorSeed, uint256 lpFee) external tracks(false) {
        address currentManager = hook.manager();
        // Mostly the manager, occasionally an outsider, so the authorisation path is exercised too.
        address who = (currentManager == address(0) || actorSeed % 8 == 0) ? _actor(actorSeed) : currentManager;
        uint24 fee = uint24(bound(lpFee, hook.MIN_LP_FEE(), hook.MAX_LP_FEE()));

        vm.prank(who);
        try hook.setLpFee(fee) {
            useful++;
        } catch {
            rejected++;
        }
    }

    function addLiquidity(uint256 actorSeed, uint256 liquidity) external tracks(false) {
        address actor = _actor(actorSeed);
        uint256 value = bound(liquidity, 1e15, 100 ether);

        vm.prank(actor);
        try liquidityRouter.modifyLiquidity(key, _liquidityParams(actor, int256(value)), "") returns (BalanceDelta) {
            liquidityOf[actor] += value;
            useful++;
        } catch {
            rejected++;
        }
    }

    function removeLiquidity(uint256 actorSeed, uint256 liquidity) external tracks(false) {
        address actor = _actor(actorSeed);
        uint256 held = liquidityOf[actor];
        if (held == 0) {
            rejected++;
            return;
        }
        uint256 value = bound(liquidity, 1, held);

        vm.prank(actor);
        try liquidityRouter.modifyLiquidity(key, _liquidityParams(actor, -int256(value)), "") returns (BalanceDelta) {
            liquidityOf[actor] = held - value;
            useful++;
        } catch {
            rejected++;
        }
    }

    function claimFee(uint256 seed, uint256 amount) external tracks(seed % 2 == 0) {
        address who = seed % 2 == 0 ? PLATFORM : _actor(seed);
        uint256 owed = hook.feeOwed(who);
        if (owed == 0) {
            rejected++;
            return;
        }
        uint256 value = bound(amount, 1, owed);
        uint256 before = quote.balanceOf(who);

        vm.prank(who);
        try hook.claimFee(who, value) {
            ghostPaidOut += quote.balanceOf(who) - before;
            useful++;
        } catch {
            rejected++;
        }
    }

    function poke() external tracks(false) {
        hook.poke();
        useful++;
    }

    function rollBlocks(uint256 blocks) external tracks(false) {
        vm.roll(block.number + bound(blocks, 1, 300));
        useful++;
    }

    /* ------------------------------- internals ---------------------------- */

    function _swap(address actor, bool zeroForOne, int256 amountSpecified) private {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 before = quote.balanceOf(address(hook));

        address seated = hook.manager();
        bool entryBlock = seated != address(0) && block.number == hook.tenureStartBlock();
        uint256 seatedFeeBefore = entryBlock ? hook.feeOwed(seated) : 0;

        vm.recordLogs();
        vm.prank(actor);
        try swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta delta
        ) {
            uint256 donated = _donated();
            // Volume in the entry block belongs to the liquidity providers, not to the searcher that
            // just took the seat, so the manager liability must not move.
            if (entryBlock && hook.feeOwed(seated) > seatedFeeBefore) ghostEntryBlockAccrual++;

            // A swap is the hook's only exchange with the PoolManager: it takes the charge in and
            // pushes the donation out, so the balance move plus the donation is exactly the charge.
            uint256 balanceAndDonation = quote.balanceOf(address(hook)) + donated;
            if (balanceAndDonation < before) {
                ghostNegativeCharge += before - balanceAndDonation;
                useful++;
                return;
            }

            uint256 charged = balanceAndDonation - before;
            ghostDonated += donated;
            ghostCharged += charged;
            ghostGrossQuote += _grossQuote(delta, charged);
            ghostSwaps++;
            useful++;
        } catch {
            vm.getRecordedLogs();
            rejected++;
        }
    }

    /// @dev Executed gross quote-side volume for one swap. When the trader receives quote the AMM
    ///      produced its receipt plus the charge; when the trader pays quote it already paid gross.
    function _grossQuote(BalanceDelta delta, uint256 charged) private view returns (uint256) {
        int128 quoteDelta = quoteIsCurrency1 ? delta.amount1() : delta.amount0();
        if (quoteDelta > 0) return uint256(uint128(quoteDelta)) + charged;
        return uint256(uint128(-quoteDelta));
    }

    /// @dev The manager the hook saw when it settled a bid, read off the last `ManagerChanged`.
    function _incumbentFromLogs() private returns (address) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i != 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter != address(hook) || entry.topics.length < 3) continue;
            if (entry.topics[0] != PoolRentHook.ManagerChanged.selector) continue;
            return address(uint160(uint256(entry.topics[1])));
        }
        return address(0);
    }

    function _donated() private returns (uint256 total) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != PoolRentHook.RentDonated.selector) continue;
            total += abi.decode(logs[i].data, (uint256));
        }
    }

    function _liquidityParams(address actor, int256 liquidityDelta)
        private
        view
        returns (ModifyLiquidityParams memory)
    {
        return ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: bytes32(uint256(uint160(actor)))
        });
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }
}
