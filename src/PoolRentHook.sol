// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolRentMath} from "./libraries/PoolRentMath.sol";

/// @title PoolRentHook
/// @notice Sells the right to set one canonical Uniswap v4 pool's LP fee on a continuous,
///         permissionless rent auction and pays the rent to that pool's liquidity providers.
///
/// The pool manager is whoever currently wins the auction. It posts a WETH deposit, names a
/// per-block rent, and in exchange (a) sets the pool's dynamic LP fee inside immutable bounds and
/// (b) accrues half of the fixed 20 bps hook-owned volume charge. Rent accrues per block, is
/// deducted from the deposit, and is donated to in-range liquidity providers. A challenger must
/// beat the standing rent by at least 10% and can only do so after the incumbent's minimum tenure.
/// When a deposit runs out the manager is evicted in constant time and the pool falls back to its
/// default LP fee.
///
/// The value arbitrageurs extract from liquidity providers is therefore bid back to those providers
/// instead of leaking out of the pool.
///
/// The mandatory Programmable volume fee (10 bps of executed gross quote-side volume) is enforced
/// on the same canonical pool, in the same hook, on all four swap quadrants, and accrues to an
/// immutable owner that no role in this system can change, redirect, or spend.
contract PoolRentHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using PoolRentMath for uint256;

    /* -------------------------------------------------------------------------- */
    /*                            Programmable fee policy                          */
    /* -------------------------------------------------------------------------- */

    /// @notice Immutable owner of the mandatory Programmable volume fee.
    /// @dev Policy `programmable-volume-fee-v1` @ `1.0.0`. Not a storage slot: no role can change it.
    address public constant PROGRAMMABLE_OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;

    /// @notice Total hook-owned charge on executed gross quote-side volume, in hundredths of a bip.
    /// @dev 2_000 = 20 bps. `effective = max(selected, 1_000)`; the platform takes exactly 1_000 and
    ///      the project remainder is 1_000. The charge is never added on top of this total.
    uint256 public constant TOTAL_FEE = 2_000;

    /// @notice Share of `TOTAL_FEE` owned by the Programmable platform, in parts per million.
    /// @dev 500_000 ppm of 20 bps is exactly the mandatory 10 bps.
    uint256 public constant PLATFORM_SHARE_PPM = 500_000;

    /* -------------------------------------------------------------------------- */
    /*                              Auction parameters                             */
    /* -------------------------------------------------------------------------- */

    /// @notice Blocks a new manager is protected from being outbid.
    uint256 public constant MIN_TENURE_BLOCKS = 100;

    /// @notice A challenger must offer at least this percentage of the standing rent.
    uint256 public constant OUTBID_PERCENT = 110;

    /// @notice A bid's deposit must cover at least this many blocks of its own rent.
    uint256 public constant MIN_DEPOSIT_BLOCKS = 100;

    /// @notice Smallest accepted rent, which keeps dust bids from taking the pool.
    uint256 public constant MIN_RENT_PER_BLOCK = 1e9;

    /// @notice Rent below this is carried instead of donated, so tiny donations cannot grief gas.
    uint256 public constant MIN_DONATION = 1e9;

    /// @notice LP fee bounds the manager may choose between, in hundredths of a bip.
    uint24 public constant MIN_LP_FEE = 100;
    uint24 public constant DEFAULT_LP_FEE = 3_000;
    uint24 public constant MAX_LP_FEE = 20_000;

    /* -------------------------------------------------------------------------- */
    /*                            Canonical pool binding                           */
    /* -------------------------------------------------------------------------- */

    Currency public immutable currency0;
    Currency public immutable currency1;
    int24 public immutable tickSpacing;
    uint160 public immutable initialSqrtPriceX96;

    /// @notice The quote asset. Every charge and the rent are denominated in it.
    IERC20 public immutable quote;
    bool public immutable quoteIsCurrency1;

    /// @notice The one pool this hook will ever serve, fixed at construction.
    PoolId public immutable canonicalPoolId;

    /* -------------------------------------------------------------------------- */
    /*                                    State                                    */
    /* -------------------------------------------------------------------------- */

    bool public initialized;

    address public manager;
    uint128 public rentPerBlock;
    uint64 public tenureStartBlock;
    uint64 public lastAccrualBlock;
    uint24 public managerLpFee;

    /// @notice Rent that has been charged to a manager but not yet donated to liquidity providers.
    uint256 public pendingRent;

    /// @notice Auction deposits, owned by the depositor and withdrawable at any time.
    mapping(address account => uint256 amount) public deposits;
    uint256 public totalDeposits;

    /// @notice Accrued, unclaimed volume-fee liabilities, keyed by beneficiary.
    mapping(address beneficiary => uint256 amount) public feeOwed;
    uint256 public totalFeeOwed;

    /// @dev Transient slot holding the charge already taken in `beforeSwap` for the swap in flight.
    ///      keccak256("poolrent.pendingBeforeFee") - 1
    bytes32 private constant PENDING_BEFORE_FEE_SLOT =
        0x6d1e1a2f1d0f0ba7f2b4e0d4b0d1c8a6f1f7c6a1d0f2b1c3d4e5f60718293a4b;

    /// @dev Transient slot holding the amount the AMM was expected to execute, for partial-fill rejection.
    ///      keccak256("poolrent.expectedExecuted") - 1
    bytes32 private constant EXPECTED_EXECUTED_SLOT =
        0x1c9f7d5b3a1e0c8d6b4a2f0e9d7c5b3a1f0e8d6c4b2a0f9e7d5c3b1a0f8e6d5c;

    /* -------------------------------------------------------------------------- */
    /*                                    Events                                   */
    /* -------------------------------------------------------------------------- */

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

    /* -------------------------------------------------------------------------- */
    /*                                    Errors                                   */
    /* -------------------------------------------------------------------------- */

    error UnexpectedPool();
    error AlreadyInitialized();
    error NotManager();
    error RentTooLow();
    error OutbidTooLow();
    error TenureProtected();
    error DepositTooSmall();
    error InsufficientDeposit();
    error NothingOwed();
    error InvalidLpFee();
    error PartialFillRejected();
    error ZeroAddress();
    error DonationMismatch();
    error SettlementMismatch();

    /* -------------------------------------------------------------------------- */
    /*                                 Construction                                */
    /* -------------------------------------------------------------------------- */

    constructor(
        IPoolManager _poolManager,
        Currency _currency0,
        Currency _currency1,
        int24 _tickSpacing,
        uint160 _initialSqrtPriceX96,
        IERC20 _quote
    ) BaseHook(_poolManager) {
        if (Currency.unwrap(_currency0) >= Currency.unwrap(_currency1)) revert UnexpectedPool();
        if (_initialSqrtPriceX96 == 0 || _tickSpacing <= 0) revert UnexpectedPool();

        bool quoteIs1 = Currency.unwrap(_currency1) == address(_quote);
        if (!quoteIs1 && Currency.unwrap(_currency0) != address(_quote)) revert UnexpectedPool();

        currency0 = _currency0;
        currency1 = _currency1;
        tickSpacing = _tickSpacing;
        initialSqrtPriceX96 = _initialSqrtPriceX96;
        quote = _quote;
        quoteIsCurrency1 = quoteIs1;

        canonicalPoolId = PoolKey({
            currency0: _currency0,
            currency1: _currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: _tickSpacing,
            hooks: this
        }).toId();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /* -------------------------------------------------------------------------- */
    /*                              Pool admission                                 */
    /* -------------------------------------------------------------------------- */

    /// @dev Admits exactly one PoolKey, once. Every launch-defining member — both currencies, the
    ///      dynamic-fee flag, the tick spacing, the hook address and the start price — is committed
    ///      in this hook's constructor and therefore inside its CREATE2 preimage, so no third party
    ///      can bind this hook to a pool of their choosing or re-bind it to a second one.
    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96) internal override returns (bytes4) {
        if (initialized) revert AlreadyInitialized();
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(currency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(currency1)
                || key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG || key.tickSpacing != tickSpacing
                || address(key.hooks) != address(this) || sqrtPriceX96 != initialSqrtPriceX96
        ) revert UnexpectedPool();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(canonicalPoolId)) revert UnexpectedPool();

        initialized = true;
        lastAccrualBlock = uint64(block.number);
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Seeds the dynamic LP fee. This value applies whenever the auction has no manager.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        poolManager.updateDynamicLPFee(key, DEFAULT_LP_FEE);
        return BaseHook.afterInitialize.selector;
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Swap path                                  */
    /* -------------------------------------------------------------------------- */

    /// @dev Charges the quadrants where the quote asset is the specified currency, and returns the
    ///      manager's LP fee override. `sender` is the router that called the PoolManager and is
    ///      never treated as the trader; `hookData` is unused.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requireCanonical(key);
        _accrueRent();

        bool exactInput = params.amountSpecified < 0;
        bool quoteIsSpecified = _quoteIsSpecified(params.zeroForOne, exactInput);

        uint256 fee = 0;
        if (quoteIsSpecified) {
            uint256 specified = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 executed;
            if (exactInput) {
                // The gross quote input is known: carve the charge out of it and swap the rest.
                fee = specified.feeFromGross(TOTAL_FEE);
                executed = specified - fee;
            } else {
                // Only the trader's net quote output is known: gross it up so the charge is on the
                // executed gross amount, and let the AMM produce the larger amount.
                fee = specified.feeOnNet(TOTAL_FEE);
                executed = specified + fee;
            }
            _tstore(PENDING_BEFORE_FEE_SLOT, fee);
            _tstore(EXPECTED_EXECUTED_SLOT, executed);
        } else {
            _tstore(PENDING_BEFORE_FEE_SLOT, 0);
            _tstore(EXPECTED_EXECUTED_SLOT, 0);
        }

        uint24 lpFeeOverride = manager == address(0) ? 0 : managerLpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        // A positive specified delta moves the amount the AMM executes and credits the hook.
        BeforeSwapDelta delta = fee == 0 ? toBeforeSwapDelta(0, 0) : toBeforeSwapDelta(fee.toInt128(), 0);
        return (BaseHook.beforeSwap.selector, delta, lpFeeOverride);
    }

    /// @dev Charges the quadrants where the quote asset is the unspecified currency, settles the
    ///      whole charge, and donates accrued rent to in-range liquidity providers.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _requireCanonical(key);

        bool exactInput = params.amountSpecified < 0;
        bool quoteIsSpecified = _quoteIsSpecified(params.zeroForOne, exactInput);

        int128 quoteDelta = quoteIsCurrency1 ? delta.amount1() : delta.amount0();

        uint256 beforeFee = _tload(PENDING_BEFORE_FEE_SLOT);
        uint256 afterFee = 0;

        if (quoteIsSpecified) {
            // The charge was already taken. Reject a partial fill rather than charge a trader for
            // volume the pool never executed.
            uint256 expected = _tload(EXPECTED_EXECUTED_SLOT);
            uint256 actual = quoteDelta < 0 ? uint256(uint128(-quoteDelta)) : uint256(uint128(quoteDelta));
            if (actual != expected) revert PartialFillRejected();
        } else if (quoteDelta > 0) {
            // The trader receives quote: the executed gross output is known, carve the charge out.
            afterFee = uint256(uint128(quoteDelta)).feeFromGross(TOTAL_FEE);
        } else if (quoteDelta < 0) {
            // The trader pays quote: the executed amount is net of the charge, so gross it up.
            afterFee = uint256(uint128(-quoteDelta)).feeOnNet(TOTAL_FEE);
        }

        _tstore(PENDING_BEFORE_FEE_SLOT, 0);
        _tstore(EXPECTED_EXECUTED_SLOT, 0);

        uint256 totalFee = beforeFee + afterFee;
        if (totalFee != 0) {
            // Book the liability before touching the PoolManager, then take the matching amount.
            // Both the beforeSwap and the afterSwap portion are credited to this hook once this
            // callback returns, so taking the full amount here nets the hook's delta to zero.
            _accrueFee(totalFee);
            poolManager.take(_quoteCurrency(), address(this), totalFee);
        }

        _donateRent(key);

        return (BaseHook.afterSwap.selector, afterFee == 0 ? int128(0) : afterFee.toInt128());
    }

    /* -------------------------------------------------------------------------- */
    /*                                Fee accounting                               */
    /* -------------------------------------------------------------------------- */

    /// @dev Splits a charge into the immutable platform liability and the current manager's
    ///      liability. With no manager — or in the very block a manager took the seat — the manager
    ///      share is donated to liquidity providers instead, so the charge never becomes unowned.
    ///
    ///      Excluding the entry block is what stops a bid from being free money: without it, a
    ///      searcher could take a vacant seat, collect the manager share of a swap it front-ran, and
    ///      withdraw its whole deposit, all in one block, having paid rent for no elapsed blocks.
    function _accrueFee(uint256 amount) private {
        (uint256 platformAmount, uint256 managerAmount) = amount.splitFee(PLATFORM_SHARE_PPM);

        feeOwed[PROGRAMMABLE_OWNER] += platformAmount;
        totalFeeOwed += platformAmount;
        emit FeeAccrued(PoolId.unwrap(canonicalPoolId), address(quote), PROGRAMMABLE_OWNER, platformAmount);

        if (managerAmount == 0) return;

        address currentManager = manager;
        if (currentManager == address(0) || block.number == tenureStartBlock) {
            pendingRent += managerAmount;
        } else {
            feeOwed[currentManager] += managerAmount;
            totalFeeOwed += managerAmount;
            emit FeeAccrued(PoolId.unwrap(canonicalPoolId), address(quote), currentManager, managerAmount);
        }
    }

    /// @notice Claims an accrued volume-fee liability. The Programmable owner's liability can only
    ///         ever be claimed by the Programmable owner, to a destination it chooses per claim.
    function claimFee(address to, uint256 amount) external {
        if (to == address(0)) revert ZeroAddress();
        uint256 owed = feeOwed[msg.sender];
        if (amount == 0 || amount > owed) revert NothingOwed();

        feeOwed[msg.sender] = owed - amount;
        totalFeeOwed -= amount;

        quote.safeTransfer(to, amount);
        emit FeeClaimed(PoolId.unwrap(canonicalPoolId), address(quote), msg.sender, to, amount);
    }

    /* -------------------------------------------------------------------------- */
    /*                                Rent auction                                 */
    /* -------------------------------------------------------------------------- */

    /// @notice Posts a deposit and bids for the right to set this pool's LP fee.
    /// @dev The incumbent may only raise its own rent. A challenger must beat the standing rent by
    ///      at least `OUTBID_PERCENT` and can only do so once the incumbent's minimum tenure is over.
    function bid(uint128 newRentPerBlock, uint256 depositAmount) external {
        _accrueRent();

        if (newRentPerBlock < MIN_RENT_PER_BLOCK) revert RentTooLow();

        if (depositAmount != 0) _deposit(depositAmount);

        address incumbent = manager;
        bool seatChangesHands = incumbent != msg.sender;

        if (!seatChangesHands) {
            if (newRentPerBlock < rentPerBlock) revert OutbidTooLow();
        } else if (incumbent != address(0)) {
            if (block.number < uint256(tenureStartBlock) + MIN_TENURE_BLOCKS) revert TenureProtected();
            if (uint256(newRentPerBlock) * 100 < uint256(rentPerBlock) * OUTBID_PERCENT) revert OutbidTooLow();
        }

        uint256 balance = deposits[msg.sender];

        if (seatChangesHands) {
            // The first block of a tenure is paid for on entry, so taking the seat is never free
            // and a bid can never be a free option on the very next swap.
            uint256 entryRent = newRentPerBlock;
            if (entryRent > balance) entryRent = balance;
            balance -= entryRent;
            deposits[msg.sender] = balance;
            totalDeposits -= entryRent;
            pendingRent += entryRent;
            emit RentAccrued(msg.sender, entryRent, pendingRent);
        }

        // Checked after the entry payment, so a manager that holds the seat is always funded for a
        // full minimum tenure rather than only up to the moment it took it.
        if (balance < uint256(newRentPerBlock) * MIN_DEPOSIT_BLOCKS) revert DepositTooSmall();

        manager = msg.sender;
        rentPerBlock = newRentPerBlock;
        lastAccrualBlock = uint64(block.number);

        if (seatChangesHands) {
            // Only a genuine handover starts a new tenure. Letting an incumbent restart its own
            // protection window by re-bidding the standing rent would make the seat uncontestable.
            tenureStartBlock = uint64(block.number);
            // The incoming manager gets the documented starting point rather than inheriting
            // whatever the outgoing one happened to leave behind.
            managerLpFee = DEFAULT_LP_FEE;
        }

        emit ManagerChanged(incumbent, msg.sender, newRentPerBlock);
    }

    /// @notice Sets the pool's LP fee. Callable only by the current manager, only inside the
    ///         immutable bounds. The fee belongs to liquidity providers; the manager never takes it.
    function setLpFee(uint24 newLpFee) external {
        _accrueRent();
        if (msg.sender != manager) revert NotManager();
        if (newLpFee < MIN_LP_FEE || newLpFee > MAX_LP_FEE) revert InvalidLpFee();

        managerLpFee = newLpFee;
        emit LpFeeUpdated(msg.sender, newLpFee);
    }

    /// @notice Adds to the caller's auction deposit.
    function depositRent(uint256 amount) external {
        _accrueRent();
        _deposit(amount);
    }

    /// @notice Withdraws part of the caller's own deposit. Always available, including to a manager;
    ///         a manager whose remaining deposit no longer covers its minimum tenure is evicted in
    ///         the same call rather than being locked in.
    function withdrawDeposit(address to, uint256 amount) external {
        if (to == address(0)) revert ZeroAddress();
        _accrueRent();

        uint256 balance = deposits[msg.sender];
        if (amount == 0 || amount > balance) revert InsufficientDeposit();

        uint256 remaining = balance - amount;
        deposits[msg.sender] = remaining;
        totalDeposits -= amount;

        if (msg.sender == manager && remaining < uint256(rentPerBlock) * MIN_DEPOSIT_BLOCKS) _evict();

        quote.safeTransfer(to, amount);
        emit DepositWithdrawn(msg.sender, to, amount, remaining);
    }

    /// @notice Charges any rent owed and evicts an insolvent manager. Permissionless and O(1).
    function poke() external {
        _accrueRent();
    }

    function _deposit(uint256 amount) private {
        quote.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balance = deposits[msg.sender] + amount;
        deposits[msg.sender] = balance;
        totalDeposits += amount;
        emit DepositAdded(msg.sender, amount, balance);
    }

    /// @dev Constant time: it charges the incumbent only, never iterates, and never reverts a swap.
    function _accrueRent() private {
        uint64 last = lastAccrualBlock;
        if (block.number == last) return;
        lastAccrualBlock = uint64(block.number);

        address currentManager = manager;
        if (currentManager == address(0)) return;

        uint256 owed = uint256(rentPerBlock) * (block.number - last);
        uint256 balance = deposits[currentManager];

        if (owed >= balance) {
            owed = balance;
            deposits[currentManager] = 0;
            _evict();
        } else {
            deposits[currentManager] = balance - owed;
        }

        if (owed == 0) return;
        totalDeposits -= owed;
        pendingRent += owed;
        emit RentAccrued(currentManager, owed, pendingRent);
    }

    function _evict() private {
        address previous = manager;
        manager = address(0);
        rentPerBlock = 0;
        tenureStartBlock = 0;
        managerLpFee = 0;
        emit ManagerChanged(previous, address(0), 0);
    }

    /// @dev Pays rent to in-range liquidity providers. Skipped, never reverted, when the pool has no
    ///      in-range liquidity to receive it; the rent stays owed to providers and is paid later.
    function _donateRent(PoolKey calldata key) private {
        uint256 amount = pendingRent;
        if (amount < MIN_DONATION) return;
        if (poolManager.getLiquidity(canonicalPoolId) == 0) return;

        pendingRent = 0;

        BalanceDelta donated = poolManager.donate(key, quoteIsCurrency1 ? 0 : amount, quoteIsCurrency1 ? amount : 0, "");
        int128 owedQuote = quoteIsCurrency1 ? donated.amount1() : donated.amount0();
        if (owedQuote != -int128(uint128(amount))) revert DonationMismatch();

        poolManager.sync(_quoteCurrency());
        quote.safeTransfer(address(poolManager), amount);
        if (poolManager.settle() != amount) revert SettlementMismatch();

        emit RentDonated(amount);
    }

    /* -------------------------------------------------------------------------- */
    /*                                    Views                                    */
    /* -------------------------------------------------------------------------- */

    /// @notice The LP fee a swap would pay right now.
    function currentLpFee() external view returns (uint24) {
        return manager == address(0) ? DEFAULT_LP_FEE : managerLpFee;
    }

    /// @notice Total quote balance the hook owes to depositors, liquidity providers and fee beneficiaries.
    function totalLiabilities() public view returns (uint256) {
        return totalDeposits + pendingRent + totalFeeOwed;
    }

    /// @notice True while the hook holds at least everything it owes.
    function isSolvent() external view returns (bool) {
        return quote.balanceOf(address(this)) >= totalLiabilities();
    }

    /* -------------------------------------------------------------------------- */
    /*                                   Internals                                 */
    /* -------------------------------------------------------------------------- */

    function _requireCanonical(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(canonicalPoolId)) revert UnexpectedPool();
    }

    function _quoteCurrency() private view returns (Currency) {
        return quoteIsCurrency1 ? currency1 : currency0;
    }

    /// @dev The specified currency is the input on an exact-input swap and the output on an
    ///      exact-output swap. The charge is taken in `beforeSwap` when that currency is the quote
    ///      asset, and in `afterSwap` otherwise.
    function _quoteIsSpecified(bool zeroForOne, bool exactInput) private view returns (bool) {
        bool specifiedIsCurrency1 = exactInput ? !zeroForOne : zeroForOne;
        return specifiedIsCurrency1 == quoteIsCurrency1;
    }

    function _tstore(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
