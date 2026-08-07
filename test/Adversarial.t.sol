// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {PoolRentFixture} from "./utils/PoolRentFixture.sol";
import {PoolRentHook} from "../src/PoolRentHook.sol";

/* ========================================================================== */
/*                            Misbehaving quote tokens                        */
/* ========================================================================== */

/// @dev Every mock extends the same OpenZeppelin `ERC20` the live quote token does, so its storage
///      layout is identical and the mock's runtime code can be `vm.etch`ed straight over the
///      deployed quote asset without disturbing a single balance or allowance.
abstract contract QuoteMock is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev The classic non-reverting failure: the transfer is refused and the refusal is only visible
///      in the return value.
contract FalseQuote is QuoteMock {
    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev A quote token that is simply unavailable — paused, blacklisting, or broken.
contract RevertQuote is QuoteMock {
    error QuoteOffline();

    function transfer(address, uint256) public pure override returns (bool) {
        revert QuoteOffline();
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert QuoteOffline();
    }
}

/// @dev USDT-shaped: it moves the balance correctly and returns nothing at all.
contract NoDataQuote is QuoteMock {
    function transfer(address to, uint256 value) public override returns (bool) {
        _transfer(_msgSender(), to, value);
        assembly ("memory-safe") {
            return(0, 0)
        }
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, _msgSender(), value);
        _transfer(from, to, value);
        assembly ("memory-safe") {
            return(0, 0)
        }
    }
}

/// @dev Returns nothing *and* moves nothing. This is the one shape `SafeERC20` cannot see through,
///      which is exactly why the hook's per-account scoping has to carry the safety argument.
contract SilentQuote is QuoteMock {
    function transfer(address, uint256) public pure override returns (bool) {
        assembly ("memory-safe") {
            return(0, 0)
        }
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        assembly ("memory-safe") {
            return(0, 0)
        }
    }
}

interface IQuoteObserver {
    function onQuoteTransfer() external;
}

/// @dev A well-behaved quote token that hands control to an observer on every transfer it performs.
///      This is the only external code the hook ever calls, so it is the only place a re-entrancy
///      can originate from.
contract ReentrantQuote is QuoteMock {
    address public observer;

    /// @dev Transfers to let through before handing control out, so a test can aim the re-entrancy
    ///      at one specific frame — the hook's `take` and its donate settlement are both transfers
    ///      of this token inside a single swap.
    uint256 public skip;

    function watch(address newObserver, uint256 skipTransfers) external {
        observer = newObserver;
        skip = skipTransfers;
    }

    function transfer(address to, uint256 value) public override returns (bool ok) {
        ok = super.transfer(to, value);
        _notify();
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool ok) {
        ok = super.transferFrom(from, to, value);
        _notify();
    }

    function _notify() private {
        address current = observer;
        if (current == address(0)) return;
        if (skip != 0) {
            skip -= 1;
            return;
        }
        IQuoteObserver(current).onQuoteTransfer();
    }
}

/* ========================================================================== */
/*                                   Actors                                   */
/* ========================================================================== */

/// @dev Re-entrancy relay. It is armed with one target and one payload, fires once per arming, and
///      swallows the result so the test can assert on *whether* the re-entrant call was rejected
///      rather than on the outer frame blowing up.
contract ReentrantActor is IQuoteObserver {
    address public target;
    bytes public payload;
    bool public fired;
    bool public reentryReverted;
    bytes4 public reentryError;

    function approveQuote(IERC20 quote, address spender) external {
        quote.approve(spender, type(uint256).max);
    }

    function arm(address newTarget, bytes calldata newPayload) external {
        target = newTarget;
        payload = newPayload;
        fired = false;
        reentryReverted = false;
        reentryError = bytes4(0);
    }

    function onQuoteTransfer() external override {
        if (target == address(0) || fired) return;
        fired = true;
        // Low-level on purpose: the whole point is to observe a rejected re-entrant call without
        // bubbling it into the frame that is being attacked.
        (bool ok, bytes memory err) = target.call(payload);
        reentryReverted = !ok;
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(err, 0x20))
        }
        reentryError = selector;
    }
}

/// @dev Deliberately has no `receive` and no `fallback`. A contract shaped like this is a normal
///      treasury, and it must be able to hold the seat and collect its share.
contract CodeOnlyActor {
    function approveQuote(IERC20 quote, address spender) external {
        quote.approve(spender, type(uint256).max);
    }

    function bid(PoolRentHook hook, uint128 rentPerBlock, uint256 depositAmount) external {
        hook.bid(rentPerBlock, depositAmount);
    }

    function setLpFee(PoolRentHook hook, uint24 newLpFee) external {
        hook.setLpFee(newLpFee);
    }

    function claimFee(PoolRentHook hook, address to, uint256 amount) external {
        hook.claimFee(to, amount);
    }

    function withdrawDeposit(PoolRentHook hook, address to, uint256 amount) external {
        hook.withdrawDeposit(to, amount);
    }
}

/// @dev Calls the hook's callbacks from a contract that is not the PoolManager the hook was built
///      against. Being a contract rather than an EOA matters: the check must be an address
///      comparison, not something a caller can spoof by looking like a manager.
contract ImpostorManager {
    function relay(address hook, bytes calldata data) external returns (bool ok, bytes memory err) {
        // Low-level: a rejected callback must be observable here, not fatal, so the test can read
        // the selector the hook chose to revert with.
        (ok, err) = hook.call(data);
    }
}

/// @dev A router with no shared code with the canonical test router. It can run several swaps
///      inside a single unlock and can probe a second, nested unlock — the two shapes that let a
///      caller try to fold extra pool actions into one hook invocation.
contract NestedRouter is IUnlockCallback {
    IPoolManager private immutable manager;

    bool public nestedUnlockRefused;
    bytes4 public nestedUnlockError;

    struct Job {
        address payer;
        PoolKey key;
        SwapParams[] swaps;
        bool probeNestedUnlock;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function run(PoolKey memory key, SwapParams[] memory swaps, bool probeNestedUnlock) external {
        manager.unlock(abi.encode(Job(msg.sender, key, swaps, probeNestedUnlock)));
    }

    /// @dev Entry point for the re-entrancy relay: reached from inside the hook's donate settlement.
    function tryNestedUnlock() external {
        _probeNestedUnlock();
    }

    function unlockCallback(bytes calldata raw) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Job memory job = abi.decode(raw, (Job));

        for (uint256 i; i < job.swaps.length; ++i) {
            BalanceDelta delta = manager.swap(job.key, job.swaps[i], "");
            _resolve(job.key.currency0, job.payer, delta.amount0());
            _resolve(job.key.currency1, job.payer, delta.amount1());
        }

        if (job.probeNestedUnlock) _probeNestedUnlock();
        return "";
    }

    function _probeNestedUnlock() private {
        // Low-level: the refusal is the assertion, so it has to come back as data instead of
        // unwinding the frame that is probing for it.
        (bool ok, bytes memory err) = address(manager).call(abi.encodeWithSelector(IPoolManager.unlock.selector, ""));
        nestedUnlockRefused = !ok;
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(err, 0x20))
        }
        nestedUnlockError = selector;
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

/* ========================================================================== */
/*                              Adversarial suite                             */
/* ========================================================================== */

/// @dev The hostile-environment half of the suite. Everything here assumes the two things the hook
///      cannot choose — the PoolManager it was built against and the ERC-20 it quotes in — are
///      actively trying to break it, and that every caller is hostile.
///
///      On low-level calls: they appear here, and in `Auction.t.sol` and `Fee.t.sol`, because a
///      `.call` is the only way a test can prove that an unauthenticated, malformed or absent
///      function is *rejected*. A typed call to a function that does not exist will not compile, and
///      a typed call to one that reverts cannot report which selector came back. None of these
///      calls is production code or a pattern the project itself uses; each one below carries a
///      one-line reason at the call site.
contract AdversarialTest is PoolRentFixture {
    using TransientStateLibrary for IPoolManager;

    uint128 internal constant RENT = 1e15;
    uint256 internal constant DEPOSIT = 10 ether;

    /// @dev Mirrors of the hook's events, so the replay can match on topics.
    event FeeAccrued(bytes32 indexed poolId, address indexed currency, address indexed beneficiary, uint256 amount);
    event FeeClaimed(
        bytes32 indexed poolId, address indexed currency, address indexed beneficiary, address to, uint256 amount
    );
    event ManagerChanged(address indexed previousManager, address indexed newManager, uint128 rentPerBlock);
    event LpFeeUpdated(address indexed manager, uint24 lpFee);
    event RentAccrued(address indexed manager, uint256 amount, uint256 pendingRent);
    event RentDonated(uint256 amount);
    event DepositAdded(address indexed account, uint256 amount, uint256 balance);
    event DepositWithdrawn(address indexed account, address indexed to, uint256 amount, uint256 balance);

    /// @dev Hook state rebuilt from logs alone. Deliberately kept in storage, so the replay reads
    ///      like the indexer it is standing in for.
    mapping(address account => uint256 amount) private _replayDeposits;
    mapping(address beneficiary => uint256 amount) private _replayFeeOwed;
    uint256 private _replayTotalDeposits;
    uint256 private _replayPendingRent;
    uint256 private _replayTotalFeeOwed;
    address[] private _replayTouched;

    struct Rebuilt {
        uint256 totalDeposits;
        uint256 pendingRent;
        uint256 totalFeeOwed;
        uint256 depositsAlice;
        uint256 depositsBob;
        uint256 feePlatform;
        uint256 feeAlice;
        uint256 feeBob;
    }

    /* ====================================================================== */
    /*  1. dependency-failure-tests                                            */
    /*     The hook's only runtime dependencies are the immutable PoolManager  */
    /*     and the quote ERC-20. Both are assumed hostile here.                */
    /* ====================================================================== */

    /// @dev A quote token that refuses by return value must not let the hook believe it paid.
    function test_dep_quoteReturningFalseFailsClosed() public {
        _seedClaimableFee();
        vm.prank(alice);
        hook.depositRent(DEPOSIT);

        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        Ledger memory before = _ledger();

        _etchQuote(address(new FalseQuote()));

        vm.prank(PROGRAMMABLE_OWNER);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(weth)));
        hook.claimFee(PROGRAMMABLE_OWNER, owed);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(weth)));
        hook.withdrawDeposit(alice, 1 ether);

        _assertLedgerUnchanged(before);
        _assertSolvent();
    }

    /// @dev A quote token that reverts outright bubbles its own error; nothing is written first.
    function test_dep_revertingQuoteBubblesAndChangesNothing() public {
        _seedClaimableFee();
        vm.prank(alice);
        hook.depositRent(DEPOSIT);

        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        Ledger memory before = _ledger();

        _etchQuote(address(new RevertQuote()));

        vm.prank(PROGRAMMABLE_OWNER);
        vm.expectRevert(RevertQuote.QuoteOffline.selector);
        hook.claimFee(PROGRAMMABLE_OWNER, owed);

        vm.prank(alice);
        vm.expectRevert(RevertQuote.QuoteOffline.selector);
        hook.withdrawDeposit(alice, 1 ether);

        vm.prank(bob);
        vm.expectRevert(RevertQuote.QuoteOffline.selector);
        hook.depositRent(1 ether);

        _assertLedgerUnchanged(before);
        _assertSolvent();
    }

    /// @dev If the quote asset stops being a contract at all, `SafeERC20` refuses the empty return
    ///      instead of reading a successful call into an EOA as a completed transfer.
    function test_dep_quoteWithNoCodeFailsClosed() public {
        _seedClaimableFee();
        vm.prank(alice);
        hook.depositRent(DEPOSIT);

        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        Ledger memory before = _ledger();
        bytes memory original = address(weth).code;

        vm.etch(address(weth), "");

        vm.prank(PROGRAMMABLE_OWNER);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(weth)));
        hook.claimFee(PROGRAMMABLE_OWNER, owed);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(weth)));
        hook.withdrawDeposit(alice, 1 ether);

        vm.etch(address(weth), original);
        _assertLedgerUnchanged(before);
        _assertSolvent();
    }

    /// @dev The USDT shape — moves the balance, returns nothing — is supported, not rejected.
    function test_dep_quoteWithNoReturnDataStillPays() public {
        _seedClaimableFee();
        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        address destination = makeAddr("noDataDestination");

        _etchQuote(address(new NoDataQuote()));

        vm.prank(PROGRAMMABLE_OWNER);
        hook.claimFee(destination, owed);

        assertEq(weth.balanceOf(destination), owed, "a silent-success token still pays out");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "liability cleared exactly once");
        _assertSolvent();
    }

    /// @dev A token that returns nothing *and* moves nothing is indistinguishable from success at
    ///      the call boundary — `SafeERC20` documents this. What the hook does guarantee is the
    ///      blast radius: only the caller's own liability is at risk, never anyone else's.
    function test_dep_silentQuoteCannotReachAnotherAccount() public {
        _seedClaimableFee();
        vm.prank(alice);
        hook.depositRent(DEPOSIT);
        vm.prank(bob);
        hook.depositRent(DEPOSIT);

        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 aliceBefore = weth.balanceOf(alice);
        uint256 bobBefore = weth.balanceOf(bob);
        uint256 aliceDeposit = hook.deposits(alice);
        uint256 bobDeposit = hook.deposits(bob);
        address destination = makeAddr("silentDestination");

        _etchQuote(address(new SilentQuote()));

        vm.prank(PROGRAMMABLE_OWNER);
        hook.claimFee(destination, owed);

        assertEq(weth.balanceOf(destination), 0, "the token lied and paid nobody");
        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "the claimant, and only the claimant, ate it");
        assertEq(weth.balanceOf(alice), aliceBefore, "no other balance moved");
        assertEq(weth.balanceOf(bob), bobBefore, "no other balance moved");
        assertEq(hook.deposits(alice), aliceDeposit, "no other liability moved");
        assertEq(hook.deposits(bob), bobDeposit, "no other liability moved");
        // The hook still holds everything it did not manage to send, so the invariant survives the lie.
        _assertSolvent();
    }

    /// @dev The pull side fails closed too: a refused `transferFrom` must never credit a deposit.
    function test_dep_depositPullFailsClosedOnABadQuote() public {
        Ledger memory before = _ledger();
        _etchQuote(address(new FalseQuote()));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(weth)));
        hook.depositRent(DEPOSIT);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(weth)));
        hook.bid(RENT, DEPOSIT);

        assertEq(hook.manager(), address(0), "a bid that could not be funded took no seat");
        _assertLedgerUnchanged(before);
        _assertSolvent();
    }

    /// @dev The PoolManager the callbacks authenticate against lives in code, not in a slot.
    function test_dep_poolManagerIsImmutable() public {
        assertEq(address(hook.poolManager()), address(poolManager), "bound at construction");

        uint256 snapshot = vm.snapshotState();
        bytes32 attacker = bytes32(uint256(uint160(makeAddr("attackerManager"))));
        for (uint256 slot; slot < 64; ++slot) {
            vm.store(address(hook), bytes32(slot), attacker);
        }
        assertEq(address(hook.poolManager()), address(poolManager), "no slot backs the PoolManager");

        vm.revertToState(snapshot);
        _assertSolvent();
    }

    /// @dev Every enabled callback rejects anything that is not that one address — including a
    ///      second, perfectly real PoolManager.
    function test_dep_callbacksRejectAForeignPoolManager() public {
        ImpostorManager impostor = new ImpostorManager();
        address realButWrong = address(new PoolManager(address(this)));
        bytes[] memory callbacks = _enabledCallbackCalldata();

        Ledger memory before = _ledger();
        for (uint256 i; i < callbacks.length; ++i) {
            // A contract genuinely making the call, not a pranked address: the check has to be an
            // address comparison, so nothing about looking like a manager can help.
            (bool relayed, bytes memory relayErr) = impostor.relay(address(hook), callbacks[i]);
            assertFalse(relayed, "callback accepted an impostor contract");
            assertEq(_selectorOf(relayErr), BaseHook.NotPoolManager.selector, "wrong rejection");

            // And a second, perfectly real PoolManager is just as foreign as an impostor.
            // Low-level: only a raw call lets the test read back the selector the hook rejected with.
            vm.prank(realButWrong);
            (bool ok, bytes memory err) = address(hook).call(callbacks[i]);
            assertFalse(ok, "callback accepted a foreign PoolManager");
            assertEq(_selectorOf(err), BaseHook.NotPoolManager.selector, "wrong rejection");
        }

        _assertLedgerUnchanged(before);
        _assertSolvent();
    }

    /* ====================================================================== */
    /*  2. external-call-reentrancy-and-failure-tests                          */
    /*     The quote token is the only external code the hook calls, so it is  */
    /*     the only place a re-entrancy can come from.                         */
    /* ====================================================================== */

    /// @dev A claim that re-enters its own claim finds the liability already cleared.
    function test_reentry_claimFeeCannotBeDoubleClaimed() public {
        (ReentrantQuote quote, ReentrantActor actor) = _installReentrantQuote();
        _seedManagerFee(address(actor));

        uint256 owed = hook.feeOwed(address(actor));
        assertGt(owed, 0, "there is something to double-claim");
        uint256 held = weth.balanceOf(address(hook));
        uint256 actorBefore = weth.balanceOf(address(actor));

        actor.arm(address(hook), abi.encodeCall(PoolRentHook.claimFee, (address(actor), owed)));
        quote.watch(address(actor), 0);
        vm.prank(address(actor));
        hook.claimFee(address(actor), owed);
        quote.watch(address(0), 0);

        assertTrue(actor.reentryReverted(), "the re-entrant claim was refused");
        assertEq(actor.reentryError(), PoolRentHook.NothingOwed.selector, "and refused for the right reason");
        assertEq(weth.balanceOf(address(actor)) - actorBefore, owed, "paid exactly once");
        assertEq(weth.balanceOf(address(hook)), held - owed, "and the hook parted with exactly that");
        assertEq(hook.feeOwed(address(actor)), 0, "liability cleared");
        _assertSolvent();
    }

    /// @dev Same story on the deposit side: the balance is written down before the token is touched.
    function test_reentry_withdrawCannotBeDoubleWithdrawn() public {
        (ReentrantQuote quote, ReentrantActor actor) = _installReentrantQuote();
        weth.mint(address(actor), 100 ether);
        actor.approveQuote(IERC20(address(weth)), address(hook));

        vm.prank(address(actor));
        hook.depositRent(DEPOSIT);
        uint256 held = weth.balanceOf(address(hook));
        uint256 actorBefore = weth.balanceOf(address(actor));

        actor.arm(address(hook), abi.encodeCall(PoolRentHook.withdrawDeposit, (address(actor), DEPOSIT)));
        quote.watch(address(actor), 0);
        vm.prank(address(actor));
        hook.withdrawDeposit(address(actor), DEPOSIT);
        quote.watch(address(0), 0);

        assertTrue(actor.reentryReverted(), "the re-entrant withdrawal was refused");
        assertEq(actor.reentryError(), PoolRentHook.InsufficientDeposit.selector, "and refused for the right reason");
        assertEq(weth.balanceOf(address(actor)) - actorBefore, DEPOSIT, "withdrawn exactly once");
        assertEq(weth.balanceOf(address(hook)), held - DEPOSIT, "and the hook parted with exactly that");
        assertEq(hook.deposits(address(actor)), 0, "balance cleared");
        assertEq(hook.totalDeposits(), 0, "and so is the total");
        _assertSolvent();
    }

    /// @dev Re-entering with a *different*, legitimate call must land on exactly the state the same
    ///      two calls would have produced back to back. Nothing is created and nothing is skipped.
    function test_reentry_bidDuringAClaimMatchesTheSequentialResult() public {
        (ReentrantQuote quote, ReentrantActor actor) = _installReentrantQuote();
        _seedManagerFee(address(actor));
        uint256 owed = hook.feeOwed(address(actor));

        // Baseline: the two calls, in order, with nothing re-entrant about them.
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(address(actor));
        hook.claimFee(address(actor), owed);
        hook.bid(RENT, DEPOSIT);
        vm.stopPrank();
        Ledger memory sequential = _ledger();
        uint256 sequentialActorBalance = weth.balanceOf(address(actor));
        address sequentialManager = hook.manager();
        vm.revertToState(snapshot);

        // Same two calls, the second one re-entered from inside the first one's transfer.
        actor.arm(address(hook), abi.encodeCall(PoolRentHook.bid, (RENT, DEPOSIT)));
        quote.watch(address(actor), 0);
        vm.prank(address(actor));
        hook.claimFee(address(actor), owed);
        quote.watch(address(0), 0);

        assertFalse(actor.reentryReverted(), "the re-entrant bid was a legitimate call and went through");
        assertEq(hook.manager(), sequentialManager, "same seat");
        assertEq(weth.balanceOf(address(actor)), sequentialActorBalance, "same balance");
        _assertLedgerUnchanged(sequential);
        _assertSolvent();
    }

    /// @dev Accrual is idempotent within a block, so a re-entrant poke is a no-op rather than a
    ///      second charge against the manager.
    function test_reentry_pokeDuringAWithdrawChangesNothing() public {
        (ReentrantQuote quote, ReentrantActor actor) = _installReentrantQuote();
        weth.mint(address(actor), 100 ether);
        actor.approveQuote(IERC20(address(weth)), address(hook));

        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + 7);

        vm.prank(address(actor));
        hook.depositRent(DEPOSIT);

        uint256 snapshot = vm.snapshotState();
        vm.prank(address(actor));
        hook.withdrawDeposit(address(actor), 1 ether);
        Ledger memory sequential = _ledger();
        vm.revertToState(snapshot);

        actor.arm(address(hook), abi.encodeCall(PoolRentHook.poke, ()));
        quote.watch(address(actor), 0);
        vm.prank(address(actor));
        hook.withdrawDeposit(address(actor), 1 ether);
        quote.watch(address(0), 0);

        assertFalse(actor.reentryReverted(), "poke is permissionless and cannot fail here");
        _assertLedgerUnchanged(sequential);
        _assertSolvent();
    }

    /// @dev The hardest frame to re-enter: between the hook's `donate` and its `settle`. The rent is
    ///      already booked out of `pendingRent` at that point, so a re-entrant claim can only reach
    ///      the caller's own liability and the settlement still balances.
    function test_reentry_donationSettlementCannotBeDrained() public {
        (ReentrantQuote quote, ReentrantActor actor) = _installReentrantQuote();
        _seedManagerFee(address(actor));
        uint256 owed = hook.feeOwed(address(actor));

        vm.roll(block.number + 20);
        hook.poke(); // materialise the elapsed rent so the swap below really has a donation to make
        assertGt(hook.pendingRent(), 0, "there is rent queued for the providers");

        // Baseline: the same swap, then the same claim, in that order and nothing re-entrant.
        uint256 snapshot = vm.snapshotState();
        _swap(trader, true, -1 ether);
        vm.prank(address(actor));
        hook.claimFee(address(actor), owed);
        Ledger memory sequential = _ledger();
        uint256 sequentialActor = weth.balanceOf(address(actor));
        uint256 sequentialOwed = hook.feeOwed(address(actor));
        vm.revertToState(snapshot);

        // Same two things, with the claim folded into the gap between the hook's donate and its
        // settle — the only frame where the hook is mid-conversation with the PoolManager.
        actor.arm(address(hook), abi.encodeCall(PoolRentHook.claimFee, (address(actor), owed)));
        quote.watch(address(actor), 1);
        vm.recordLogs();
        _swap(trader, true, -1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        quote.watch(address(0), 0);

        assertTrue(actor.fired(), "the donate settlement really did hand control out");
        assertFalse(actor.reentryReverted(), "the claim itself is legitimate");
        assertEq(_countHookLogs(logs, RentDonated.selector), 1, "the rent went out once, not twice");
        assertEq(weth.balanceOf(address(actor)), sequentialActor, "same payout as the sequential order");
        assertEq(hook.feeOwed(address(actor)), sequentialOwed, "and the same liability left behind");
        assertEq(hook.pendingRent(), 0, "and the queue is empty");
        _assertLedgerUnchanged(sequential);
        _assertSolvent();
    }

    /* ====================================================================== */
    /*  3. nested-action-reentrancy-tests                                      */
    /*     The hook calls donate / take / sync / settle from inside afterSwap. */
    /*     It never calls swap or modifyLiquidity, from anywhere.              */
    /* ====================================================================== */

    /// @dev A donating swap has to leave the hook owing the pool nothing at all.
    function test_nested_donatingSwapSettlesToZeroHookDelta() public {
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + 30);

        uint256 pending = hook.pendingRent();
        uint256 heldBefore = weth.balanceOf(address(hook));
        uint256 owedBefore = hook.totalFeeOwed();

        vm.recordLogs();
        _swap(trader, true, -1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 donated = _sumHookLogValue(logs, RentDonated.selector);
        uint256 charged = hook.totalFeeOwed() - owedBefore;

        assertGt(donated, pending, "the queued rent plus the blocks this swap accrued all went out");
        assertEq(poolManager.currencyDelta(address(hook), _quoteCurrency()), 0, "hook owes the pool nothing");
        assertEq(poolManager.getNonzeroDeltaCount(), 0, "and the unlock closed clean");

        // The hook took the whole charge out of the pool and paid the rent back into it. Anything
        // else moving would mean a wei the hook holds that nothing accounts for.
        assertEq(weth.balanceOf(address(hook)), heldBefore + charged - donated, "the hook kept exactly what it booked");
        assertEq(hook.pendingRent(), 0, "nothing left queued");
        _assertSolvent();
    }

    /// @dev Two swaps in one unlock: each one donates at most once, and the donations add up to the
    ///      rent that was actually charged. A re-entrant caller cannot make the queue pay twice.
    function test_nested_donationHappensAtMostOncePerSwap() public {
        NestedRouter router = _nestedRouter();
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + 40);

        uint256 rentBefore = hook.deposits(alice) + hook.pendingRent();

        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        swaps[1] =
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});

        vm.recordLogs();
        vm.prank(trader);
        router.run(key, swaps, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 donations = _countHookLogs(logs, RentDonated.selector);
        uint256 donated = _sumHookLogValue(logs, RentDonated.selector);

        assertGt(donations, 0, "the rent did reach the providers");
        assertLe(donations, swaps.length, "never more donations than swaps");
        // Rent is priced per block, not per swap: the entry block plus the 40 that elapsed, once.
        assertEq(donated, uint256(RENT) * 41, "exactly the rent that was charged");
        assertEq(rentBefore - hook.deposits(alice) - hook.pendingRent(), donated, "and it came out of the deposit");
        assertEq(hook.pendingRent(), 0, "queue drained");
        _assertSolvent();
    }

    /// @dev Structural, not behavioural: the hook's deployed code contains the selectors of the four
    ///      pool actions it declares and none of the three it swears off. `selfCallPolicy =
    ///      same-pool-swap-forbidden` is therefore a property of the bytecode, not of a test path.
    function test_nested_hookCodeCannotReachPoolManagerSwap() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0, "hook is deployed");

        // The scan is self-validating: the actions the hook does use must be found by it.
        assertTrue(_codeContains(code, IPoolManager.donate.selector), "donate is used");
        assertTrue(_codeContains(code, IPoolManager.take.selector), "take is used");
        assertTrue(_codeContains(code, IPoolManager.sync.selector), "sync is used");
        assertTrue(_codeContains(code, IPoolManager.settle.selector), "settle is used");

        assertFalse(_codeContains(code, IPoolManager.swap.selector), "no path to PoolManager.swap");
        assertFalse(_codeContains(code, IPoolManager.modifyLiquidity.selector), "no path to modifyLiquidity");
        assertFalse(_codeContains(code, IPoolManager.unlock.selector), "the hook never opens its own unlock");
    }

    /// @dev The behavioural half of the same claim: drive every entry point the hook exposes and the
    ///      pool's swap counter does not move. Only a trader moves it.
    function test_nested_noEntryPointMovesThePoolPrice() public {
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + 3);
        _swap(trader, true, -1 ether); // so the claim path below has something real to move

        vm.recordLogs();
        _driveEveryEntryPoint();
        assertEq(_countPoolSwaps(vm.getRecordedLogs()), 0, "no entry point reaches the AMM");

        vm.recordLogs();
        _swap(trader, true, -1 ether);
        assertEq(_countPoolSwaps(vm.getRecordedLogs()), 1, "a real trade, and exactly one");
        _assertSolvent();
    }

    /// @dev A router that folds two swaps into one unlock pays the charge on each of them, no more
    ///      and no less than two separate transactions would have.
    function test_nested_reenteringRouterIsChargedOncePerSwap() public {
        NestedRouter router = _nestedRouter();
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + 1);

        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        swaps[1] =
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});

        uint256 snapshot = vm.snapshotState();
        _swap(trader, true, -1 ether);
        _swap(trader, false, -1 ether);
        uint256 separately = hook.feeOwed(PROGRAMMABLE_OWNER);
        vm.revertToState(snapshot);

        vm.recordLogs();
        vm.prank(trader);
        router.run(key, swaps, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), separately, "nesting is not a discount");
        assertEq(_countPoolSwaps(logs), 2, "two swaps ran");
        assertEq(_countHookLogs(logs, FeeAccrued.selector), 4, "two beneficiaries on each of them");
        _assertSolvent();
    }

    /// @dev Maximum nesting: a router trying to open a second unlock, from inside its own unlock and
    ///      again from inside the hook's donate settlement. The pool refuses both, and the swap that
    ///      is already in flight still charges exactly once and still settles.
    function test_nested_secondUnlockInsideASwapIsRefused() public {
        NestedRouter router = _nestedRouter();
        (ReentrantQuote quote, ReentrantActor actor) = _installReentrantQuote();
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + 25);

        SwapParams[] memory swaps = new SwapParams[](1);
        swaps[0] =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        uint256 owedBefore = hook.feeOwed(PROGRAMMABLE_OWNER);

        actor.arm(address(router), abi.encodeCall(NestedRouter.tryNestedUnlock, ()));
        quote.watch(address(actor), 1); // fire between the hook's donate and its settle
        vm.recordLogs();
        vm.prank(trader);
        router.run(key, swaps, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        quote.watch(address(0), 0);

        assertTrue(actor.fired(), "the donate settlement really did hand control out");
        assertTrue(router.nestedUnlockRefused(), "a second unlock is refused");
        assertEq(router.nestedUnlockError(), IPoolManager.AlreadyUnlocked.selector, "and refused by the lock");
        assertEq(_countPoolSwaps(logs), 1, "exactly one swap ran");
        assertEq(_countHookLogs(logs, FeeAccrued.selector), 2, "and it was charged exactly once");
        assertGt(hook.feeOwed(PROGRAMMABLE_OWNER), owedBefore, "the platform was paid");
        assertEq(poolManager.getNonzeroDeltaCount(), 0, "everything settled");
        _assertSolvent();
    }

    /* ====================================================================== */
    /*  4. project-external-call-authentication-and-failure-tests              */
    /* ====================================================================== */

    /// @dev The four enabled callbacks are the hook's entire pool-facing surface, and each one is
    ///      bound to a single address.
    function test_auth_callbacksAcceptOnlyTheImmutablePoolManager() public {
        bytes[] memory callbacks = _enabledCallbackCalldata();
        address[4] memory callers = [alice, PROGRAMMABLE_OWNER, address(launcher), address(hook)];

        for (uint256 i; i < callbacks.length; ++i) {
            for (uint256 j; j < callers.length; ++j) {
                // Low-level: proves the rejection selector, which a typed call cannot report.
                vm.prank(callers[j]);
                (bool ok, bytes memory err) = address(hook).call(callbacks[i]);
                assertFalse(ok, "callback accepted an unauthenticated caller");
                assertEq(_selectorOf(err), BaseHook.NotPoolManager.selector, "wrong rejection");
            }
        }

        // And the one address that is allowed still works, so the check is a gate, not a wall.
        _swap(trader, true, -1 ether);
        _assertSolvent();
    }

    /// @dev `setLpFee` is the only authority in the system and it belongs to exactly one address at
    ///      a time — the one currently paying rent for it.
    function test_auth_setLpFeeIsManagerOnly() public {
        _becomeManager(alice, RENT, DEPOSIT);

        address[6] memory outsiders =
            [bob, carol, launchWallet, PROGRAMMABLE_OWNER, address(poolManager), address(launcher)];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(PoolRentHook.NotManager.selector);
            hook.setLpFee(500);
        }

        vm.prank(alice);
        hook.setLpFee(500);
        assertEq(hook.currentLpFee(), 500, "the manager, and nobody else");

        // The authority moves with the seat, it is not attached to the address that once held it.
        vm.roll(block.number + hook.MIN_TENURE_BLOCKS());
        _becomeManager(bob, RENT * 2, DEPOSIT);
        vm.prank(alice);
        vm.expectRevert(PoolRentHook.NotManager.selector);
        hook.setLpFee(500);
        _assertSolvent();
    }

    /// @dev `claimFee` and `withdrawDeposit` take a destination, never an account. There is no
    ///      overload, no `-For` variant and no fallback that would let a caller name a victim.
    function test_auth_claimAndWithdrawAreStrictlySelfScoped() public {
        _seedClaimableFee();
        vm.prank(alice);
        hook.depositRent(DEPOSIT);

        uint256 platformOwed = hook.feeOwed(PROGRAMMABLE_OWNER);
        uint256 aliceDeposit = hook.deposits(alice);

        string[6] memory absent = [
            "claimFee(address,address,uint256)",
            "claimFeeFor(address,address,uint256)",
            "claimFeeFrom(address,address,uint256)",
            "withdrawDeposit(address,address,uint256)",
            "withdrawDepositFor(address,address,uint256)",
            "withdrawFrom(address,address,uint256)"
        ];
        for (uint256 i; i < absent.length; ++i) {
            // Low-level: a function that does not exist cannot be called any other way, and the
            // hook has no fallback, so absence shows up as a failed call.
            vm.prank(bob);
            (bool ok,) = address(hook).call(abi.encodeWithSignature(absent[i], alice, bob, aliceDeposit));
            assertFalse(ok, absent[i]);
        }

        // Naming somebody else as the destination reaches only the caller's own (empty) balance.
        vm.prank(bob);
        vm.expectRevert(PoolRentHook.NothingOwed.selector);
        hook.claimFee(alice, platformOwed);

        vm.prank(bob);
        vm.expectRevert(PoolRentHook.InsufficientDeposit.selector);
        hook.withdrawDeposit(alice, aliceDeposit);

        assertEq(hook.feeOwed(PROGRAMMABLE_OWNER), platformOwed, "platform liability untouched");
        assertEq(hook.deposits(alice), aliceDeposit, "alice's deposit untouched");
        _assertSolvent();
    }

    /// @dev `bid` and `poke` are open to anyone on purpose. Open must still mean each caller spends
    ///      only its own WETH, even when the victim has already approved the hook for everything.
    function test_auth_permissionlessCallsCannotMoveAnotherBalance() public {
        _becomeManager(alice, RENT, DEPOSIT);
        assertEq(weth.allowance(alice, address(hook)), type(uint256).max, "alice has approved the hook");

        uint256 aliceWallet = weth.balanceOf(alice);
        uint256 aliceDeposit = hook.deposits(alice);
        uint256 carolWallet = weth.balanceOf(carol);

        vm.roll(block.number + 10);
        vm.prank(carol);
        hook.poke();

        uint256 rentCharged = uint256(RENT) * 10;
        assertEq(hook.deposits(alice), aliceDeposit - rentCharged, "poke charges the elapsed blocks, exactly");
        assertEq(weth.balanceOf(alice), aliceWallet, "and never reaches her wallet");
        assertEq(weth.balanceOf(carol), carolWallet, "the poker is paid nothing for it");
        assertEq(hook.deposits(carol), 0, "and credited nothing");

        vm.roll(block.number + hook.MIN_TENURE_BLOCKS());
        vm.prank(carol);
        hook.bid(RENT * 2, DEPOSIT);

        assertEq(weth.balanceOf(alice), aliceWallet, "a challenger funds its own bid");
        assertEq(weth.balanceOf(carol), carolWallet - DEPOSIT, "out of its own wallet");
        _assertSolvent();
    }

    /// @dev The hook moves ERC-20 and never native ETH, so a contract with no `receive` and no
    ///      `fallback` is a perfectly good manager and a perfectly good claimant.
    function test_auth_aContractWithNoFallbackCanManageAndClaim() public {
        CodeOnlyActor actor = new CodeOnlyActor();
        weth.mint(address(actor), 100 ether);
        actor.approveQuote(IERC20(address(weth)), address(hook));

        // It really has no way to receive ETH: this is what makes the rest of the test mean something.
        vm.deal(address(this), 1 ether);
        // Low-level: the only way to prove a contract rejects a plain value transfer.
        (bool tookEth,) = address(actor).call{value: 1}("");
        assertFalse(tookEth, "no receive, no fallback");

        actor.bid(hook, RENT, DEPOSIT);
        assertEq(hook.manager(), address(actor), "it holds the seat");

        actor.setLpFee(hook, 1_000);
        assertEq(hook.currentLpFee(), 1_000, "and exercises the authority");

        vm.roll(block.number + 1);
        _swap(trader, true, -1 ether);
        uint256 owed = hook.feeOwed(address(actor));
        assertGt(owed, 0, "it earned its share");

        actor.claimFee(hook, address(actor), owed);
        assertEq(weth.balanceOf(address(actor)), 100 ether - DEPOSIT + owed, "and collected it");

        uint256 remaining = hook.deposits(address(actor));
        actor.withdrawDeposit(hook, address(actor), remaining);
        assertEq(hook.deposits(address(actor)), 0, "and walked away with the rest");
        assertEq(address(actor).balance, 0, "no ETH ever entered the picture");
        _assertSolvent();
    }

    /* ====================================================================== */
    /*  5. event-reorg-backfill-freshness-tests                                */
    /* ====================================================================== */

    /// @dev The indexer test: run a full lifecycle, throw the chain state away, and rebuild every
    ///      accounting slot from the logs alone.
    function test_events_replayReconstructsHookState() public {
        vm.recordLogs();
        _runLifecycle();
        Rebuilt memory rebuilt = _replay(vm.getRecordedLogs());

        assertEq(rebuilt.totalDeposits, hook.totalDeposits(), "totalDeposits");
        assertEq(rebuilt.pendingRent, hook.pendingRent(), "pendingRent");
        assertEq(rebuilt.totalFeeOwed, hook.totalFeeOwed(), "totalFeeOwed");
        assertEq(rebuilt.depositsAlice, hook.deposits(alice), "deposits[alice]");
        assertEq(rebuilt.depositsBob, hook.deposits(bob), "deposits[bob]");
        assertEq(rebuilt.feePlatform, hook.feeOwed(PROGRAMMABLE_OWNER), "feeOwed[platform]");
        assertEq(rebuilt.feeAlice, hook.feeOwed(alice), "feeOwed[alice]");
        assertEq(rebuilt.feeBob, hook.feeOwed(bob), "feeOwed[bob]");

        assertEq(
            rebuilt.depositsAlice + rebuilt.depositsBob, rebuilt.totalDeposits, "the rebuilt total is the rebuilt sum"
        );
        assertEq(
            rebuilt.feePlatform + rebuilt.feeAlice + rebuilt.feeBob, rebuilt.totalFeeOwed, "and so is the fee total"
        );
        _assertSolvent();
    }

    /// @dev Reorg safety, as far as a local chain can show it: the same sequence replayed from the
    ///      same starting state produces byte-identical reconstructed state, so a re-org that
    ///      re-executes the block cannot leave an indexer holding a different answer.
    function test_events_replayIsIdenticalAcrossReorgs() public {
        uint256 snapshot = vm.snapshotState();

        vm.recordLogs();
        _runLifecycle();
        Rebuilt memory first = _replay(vm.getRecordedLogs());
        uint256 firstLive = hook.totalDeposits() + hook.pendingRent() + hook.totalFeeOwed();

        vm.revertToState(snapshot);

        vm.recordLogs();
        _runLifecycle();
        Rebuilt memory second = _replay(vm.getRecordedLogs());
        uint256 secondLive = hook.totalDeposits() + hook.pendingRent() + hook.totalFeeOwed();

        assertEq(keccak256(abi.encode(first)), keccak256(abi.encode(second)), "the replay is deterministic");
        assertEq(firstLive, secondLive, "and so is the chain it was rebuilt from");
        _assertSolvent();
    }

    /// @dev A state change nobody can see is a state change an indexer will get wrong. Every entry
    ///      point that writes must leave at least one log behind.
    function test_events_everyStateChangingCallEmits() public {
        _becomeManager(alice, RENT, DEPOSIT);
        vm.roll(block.number + 2);

        vm.recordLogs();
        vm.prank(bob);
        hook.depositRent(1 ether);
        assertGt(_hookLogCount(vm.getRecordedLogs()), 0, "depositRent");

        vm.recordLogs();
        vm.prank(alice);
        hook.setLpFee(1_234);
        assertGt(_hookLogCount(vm.getRecordedLogs()), 0, "setLpFee");

        vm.roll(block.number + 1);
        vm.recordLogs();
        hook.poke();
        assertGt(_hookLogCount(vm.getRecordedLogs()), 0, "poke that actually charges rent");

        vm.recordLogs();
        vm.prank(bob);
        hook.withdrawDeposit(bob, 1 ether);
        assertGt(_hookLogCount(vm.getRecordedLogs()), 0, "withdrawDeposit");

        vm.roll(block.number + 1);
        vm.recordLogs();
        _swap(trader, true, -1 ether);
        assertGt(_hookLogCount(vm.getRecordedLogs()), 0, "swap");

        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        vm.recordLogs();
        vm.prank(PROGRAMMABLE_OWNER);
        hook.claimFee(PROGRAMMABLE_OWNER, owed);
        assertGt(_hookLogCount(vm.getRecordedLogs()), 0, "claimFee");

        vm.roll(block.number + hook.MIN_TENURE_BLOCKS());
        vm.recordLogs();
        _becomeManager(carol, RENT * 2, DEPOSIT);
        assertGt(_hookLogCount(vm.getRecordedLogs()), 0, "bid");
        _assertSolvent();
    }

    /// @dev The one write with no event of its own: a sub-donation-floor provider share added to
    ///      `pendingRent` inside `_accrueFee`. It is only observable once a `RentDonated` or a
    ///      `RentAccrued` anchors the balance, so the divergence an indexer can carry is bounded by
    ///      `MIN_DONATION` and is closed by the next real swap. Stated, bounded, not hidden.
    function test_events_subFloorProviderShareIsTheOnlyUnanchoredWrite() public {
        assertEq(hook.manager(), address(0), "no manager, so the provider share is queued not accrued");

        vm.recordLogs();
        _swap(trader, false, -1500); // 3 wei of charge: 2 to the platform, 1 to the providers
        Rebuilt memory rebuilt = _replay(vm.getRecordedLogs());

        assertEq(hook.pendingRent(), 1, "the chain queued one wei for the providers");
        assertEq(rebuilt.pendingRent, 0, "the logs alone cannot see it yet");
        assertLt(hook.pendingRent(), hook.MIN_DONATION(), "the gap is bounded by the donation floor");
        assertEq(rebuilt.feePlatform, hook.feeOwed(PROGRAMMABLE_OWNER), "everything that became a liability is evented");

        // The next swap that clears the floor donates the queue and republishes the balance.
        vm.recordLogs();
        _swap(trader, true, -1 ether);
        Rebuilt memory anchored = _replay(vm.getRecordedLogs());

        assertEq(hook.pendingRent(), 0, "queue drained");
        assertEq(anchored.pendingRent, hook.pendingRent(), "and the replay is exact again");
        _assertSolvent();
    }

    /* ====================================================================== */
    /*                                Helpers                                 */
    /* ====================================================================== */

    struct Ledger {
        uint256 totalDeposits;
        uint256 pendingRent;
        uint256 totalFeeOwed;
        uint256 depositAlice;
        uint256 depositBob;
        uint256 feePlatform;
        uint256 feeAlice;
        uint256 walletAlice;
        uint256 walletBob;
        uint256 hookHeld;
    }

    function _ledger() private view returns (Ledger memory) {
        return Ledger({
            totalDeposits: hook.totalDeposits(),
            pendingRent: hook.pendingRent(),
            totalFeeOwed: hook.totalFeeOwed(),
            depositAlice: hook.deposits(alice),
            depositBob: hook.deposits(bob),
            feePlatform: hook.feeOwed(PROGRAMMABLE_OWNER),
            feeAlice: hook.feeOwed(alice),
            walletAlice: weth.balanceOf(alice),
            walletBob: weth.balanceOf(bob),
            hookHeld: weth.balanceOf(address(hook))
        });
    }

    function _assertLedgerUnchanged(Ledger memory before) private view {
        assertEq(keccak256(abi.encode(before)), keccak256(abi.encode(_ledger())), "a failed call moved something");
    }

    /// @dev Swaps the deployed quote asset's code for a misbehaving one. The mocks share the live
    ///      token's storage layout, so every balance and allowance survives the swap.
    function _etchQuote(address implementation) private {
        vm.etch(address(weth), implementation.code);
    }

    function _installReentrantQuote() private returns (ReentrantQuote quote, ReentrantActor actor) {
        _etchQuote(address(new ReentrantQuote()));
        quote = ReentrantQuote(address(weth));
        actor = new ReentrantActor();
    }

    /// @dev Gives an account a claimable manager share: seat it, clear its entry block, then trade.
    function _seedManagerFee(address who) private {
        weth.mint(who, 100 ether);
        vm.startPrank(who);
        weth.approve(address(hook), type(uint256).max);
        hook.bid(RENT, DEPOSIT);
        vm.stopPrank();

        vm.roll(block.number + 1);
        _swap(trader, true, -1 ether);
    }

    function _seedClaimableFee() private {
        _swap(trader, true, -1 ether);
        assertGt(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "the platform accrued something to claim");
    }

    function _nestedRouter() private returns (NestedRouter router) {
        router = new NestedRouter(poolManager);
        vm.startPrank(trader);
        weth.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _quoteCurrency() private view returns (Currency) {
        return hook.quoteIsCurrency1() ? key.currency1 : key.currency0;
    }

    /// @dev Calldata for each of the four callbacks the hook actually enables.
    function _enabledCallbackCalldata() private view returns (bytes[] memory calls) {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        calls = new bytes[](4);
        calls[0] = abi.encodeWithSelector(IHooks.beforeInitialize.selector, address(this), key, SQRT_PRICE_1_1);
        calls[1] = abi.encodeWithSelector(IHooks.afterInitialize.selector, address(this), key, SQRT_PRICE_1_1, int24(0));
        calls[2] = abi.encodeWithSelector(IHooks.beforeSwap.selector, address(this), key, params, bytes(""));
        calls[3] = abi.encodeWithSelector(
            IHooks.afterSwap.selector, address(this), key, params, BalanceDelta.wrap(0), bytes("")
        );
    }

    /// @dev Every non-view function the hook exposes, driven by an account entitled to call it.
    function _driveEveryEntryPoint() private {
        vm.startPrank(alice);
        hook.depositRent(1 ether);
        hook.setLpFee(hook.MAX_LP_FEE());
        hook.bid(RENT + 1, 0);
        hook.withdrawDeposit(alice, 1 ether);
        vm.stopPrank();

        hook.poke();

        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        vm.prank(PROGRAMMABLE_OWNER);
        hook.claimFee(PROGRAMMABLE_OWNER, owed);
    }

    /// @dev launch → four quadrants → bid → fee change → handover → accrual → donation → claims →
    ///      withdrawal. Every block roll is deliberate: rent only accrues across blocks, and a
    ///      manager earns nothing in its own entry block.
    function _runLifecycle() private {
        _swap(trader, true, -1 ether);
        _swap(trader, true, 1 ether);
        _swap(trader, false, -1 ether);
        _swap(trader, false, 1 ether);

        _becomeManager(alice, RENT, DEPOSIT);
        vm.prank(alice);
        hook.setLpFee(500);

        vm.roll(block.number + 20);
        _swap(trader, true, -1 ether);

        vm.roll(block.number + hook.MIN_TENURE_BLOCKS());
        _becomeManager(bob, RENT * 2, DEPOSIT);

        vm.roll(block.number + 5);
        _swap(trader, false, -1 ether);

        uint256 platformOwed = hook.feeOwed(PROGRAMMABLE_OWNER);
        vm.prank(PROGRAMMABLE_OWNER);
        hook.claimFee(PROGRAMMABLE_OWNER, platformOwed / 2);

        uint256 bobOwed = hook.feeOwed(bob);
        vm.prank(bob);
        hook.claimFee(bob, bobOwed);

        vm.roll(block.number + 3);
        uint256 aliceLeft = hook.deposits(alice);
        vm.prank(alice);
        hook.withdrawDeposit(alice, aliceLeft);
    }

    /* ---------------------------- log decoding ---------------------------- */

    /// @dev The indexer. Absolute balances come straight out of the events that carry them;
    ///      everything else is a running total.
    function _replay(Vm.Log[] memory logs) private returns (Rebuilt memory) {
        _resetReplay();

        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(hook)) continue;
            bytes32 topic = log.topics[0];

            if (topic == DepositAdded.selector) {
                address account = _addressTopic(log.topics[1]);
                (uint256 amount, uint256 balance) = abi.decode(log.data, (uint256, uint256));
                _touch(account);
                _replayDeposits[account] = balance;
                _replayTotalDeposits += amount;
            } else if (topic == DepositWithdrawn.selector) {
                address account = _addressTopic(log.topics[1]);
                (uint256 amount, uint256 balance) = abi.decode(log.data, (uint256, uint256));
                _touch(account);
                _replayDeposits[account] = balance;
                _replayTotalDeposits -= amount;
            } else if (topic == RentAccrued.selector) {
                address manager = _addressTopic(log.topics[1]);
                (uint256 amount, uint256 pending) = abi.decode(log.data, (uint256, uint256));
                _touch(manager);
                _replayDeposits[manager] -= amount;
                _replayTotalDeposits -= amount;
                // The event carries the resulting balance, so this is an assignment, not a sum.
                _replayPendingRent = pending;
            } else if (topic == RentDonated.selector) {
                // A donation always empties the queue; the hook zeroes it before it donates.
                _replayPendingRent = 0;
            } else if (topic == FeeAccrued.selector) {
                address beneficiary = _addressTopic(log.topics[3]);
                uint256 amount = abi.decode(log.data, (uint256));
                _touch(beneficiary);
                _replayFeeOwed[beneficiary] += amount;
                _replayTotalFeeOwed += amount;
            } else if (topic == FeeClaimed.selector) {
                address beneficiary = _addressTopic(log.topics[3]);
                (, uint256 amount) = abi.decode(log.data, (address, uint256));
                _touch(beneficiary);
                _replayFeeOwed[beneficiary] -= amount;
                _replayTotalFeeOwed -= amount;
            }
        }

        return Rebuilt({
            totalDeposits: _replayTotalDeposits,
            pendingRent: _replayPendingRent,
            totalFeeOwed: _replayTotalFeeOwed,
            depositsAlice: _replayDeposits[alice],
            depositsBob: _replayDeposits[bob],
            feePlatform: _replayFeeOwed[PROGRAMMABLE_OWNER],
            feeAlice: _replayFeeOwed[alice],
            feeBob: _replayFeeOwed[bob]
        });
    }

    function _resetReplay() private {
        for (uint256 i; i < _replayTouched.length; ++i) {
            delete _replayDeposits[_replayTouched[i]];
            delete _replayFeeOwed[_replayTouched[i]];
        }
        delete _replayTouched;
        _replayTotalDeposits = 0;
        _replayPendingRent = 0;
        _replayTotalFeeOwed = 0;
    }

    function _touch(address account) private {
        for (uint256 i; i < _replayTouched.length; ++i) {
            if (_replayTouched[i] == account) return;
        }
        _replayTouched.push(account);
    }

    function _addressTopic(bytes32 topic) private pure returns (address) {
        return address(uint160(uint256(topic)));
    }

    function _hookLogCount(Vm.Log[] memory logs) private view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook)) ++count;
        }
    }

    function _countHookLogs(Vm.Log[] memory logs, bytes32 topic) private view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic) ++count;
        }
    }

    function _sumHookLogValue(Vm.Log[] memory logs, bytes32 topic) private view returns (uint256 total) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic) {
                total += abi.decode(logs[i].data, (uint256));
            }
        }
    }

    function _countPoolSwaps(Vm.Log[] memory logs) private view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(poolManager)) continue;
            if (logs[i].topics[0] == IPoolManager.Swap.selector) ++count;
        }
    }

    /* ---------------------------- byte scanning --------------------------- */

    function _codeContains(bytes memory code, bytes4 needle) private pure returns (bool) {
        if (code.length < 4) return false;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (
                code[i] == needle[0] && code[i + 1] == needle[1] && code[i + 2] == needle[2] && code[i + 3] == needle[3]
            ) return true;
        }
        return false;
    }

    function _selectorOf(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
        }
    }
}
