// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolRentHook} from "./PoolRentHook.sol";
import {PoolRentToken} from "./PoolRentToken.sol";

/// @title PoolRentLauncher
/// @notice Deploys the token and the hook, initialises the canonical pool and seeds its liquidity in
///         one transaction. Any mismatch reverts the whole launch.
/// @dev The launcher permanently owns the initial full-range position: it exposes no decrease,
///      collect, rescue, arbitrary-call, owner or upgrade path, so the seeded liquidity can never be
///      removed through project code. It is single-use and holds no funds after the launch returns.
contract PoolRentLauncher is IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    struct LaunchParams {
        string name;
        string symbol;
        uint256 totalSupply;
        bytes32 tokenSalt;
        bytes32 hookSalt;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        uint256 maxToken;
        uint256 maxQuote;
    }

    IPoolManager public immutable poolManager;
    IERC20 public immutable quote;

    /// @notice The wallet that authorises the launch and pays the quote-side liquidity.
    address public immutable launchWallet;

    PoolRentToken public token;
    PoolRentHook public hook;
    bool public launched;

    event Launched(address indexed token, address indexed hook, bytes32 poolId, uint128 liquidity);

    error NotLaunchWallet();
    error AlreadyLaunched();
    error NotPoolManager();
    error QuoteExceeded();
    error TokenExceeded();
    error UnexpectedDelta();
    error ZeroLaunchWallet();
    error SettlementMismatch();

    constructor(IPoolManager _poolManager, IERC20 _quote, address _launchWallet) {
        if (_launchWallet == address(0)) revert ZeroLaunchWallet();
        poolManager = _poolManager;
        quote = _quote;
        launchWallet = _launchWallet;
    }

    /// @notice Runs the complete launch. Callable once, by the launch wallet only.
    function deployAndLaunch(LaunchParams calldata params) external returns (PoolRentToken, PoolRentHook) {
        if (msg.sender != launchWallet) revert NotLaunchWallet();
        if (launched) revert AlreadyLaunched();
        launched = true;

        PoolRentToken newToken =
            new PoolRentToken{salt: params.tokenSalt}(params.name, params.symbol, params.totalSupply, address(this));

        (Currency currency0, Currency currency1) = address(newToken) < address(quote)
            ? (Currency.wrap(address(newToken)), Currency.wrap(address(quote)))
            : (Currency.wrap(address(quote)), Currency.wrap(address(newToken)));

        // The hook's constructor validates that its own mined address carries exactly the declared
        // permission bits, so a wrong salt reverts here instead of producing a mis-permissioned pool.
        PoolRentHook newHook = new PoolRentHook{salt: params.hookSalt}(
            poolManager, currency0, currency1, params.tickSpacing, params.sqrtPriceX96, quote
        );

        token = newToken;
        hook = newHook;

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: params.tickSpacing,
            hooks: newHook
        });

        poolManager.initialize(key, params.sqrtPriceX96);

        // msg.sender is the launch wallet: the check at the top of this function is the only way in.
        quote.safeTransferFrom(msg.sender, address(this), params.maxQuote);

        poolManager.unlock(abi.encode(key, params));

        // Return every unspent unit; the launcher deliberately keeps no balance of its own.
        uint256 quoteLeft = quote.balanceOf(address(this));
        if (quoteLeft != 0) quote.safeTransfer(launchWallet, quoteLeft);
        uint256 tokenLeft = newToken.balanceOf(address(this));
        if (tokenLeft != 0) IERC20(address(newToken)).safeTransfer(launchWallet, tokenLeft);

        emit Launched(address(newToken), address(newHook), PoolId.unwrap(key.toId()), params.liquidity);
        return (newToken, newHook);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (PoolKey memory key, LaunchParams memory params) = abi.decode(data, (PoolKey, LaunchParams));

        int24 lower = TickMath.minUsableTick(params.tickSpacing);
        int24 upper = TickMath.maxUsableTick(params.tickSpacing);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(params.liquidity)), salt: bytes32(0)
            }),
            ""
        );

        if (delta.amount0() > 0 || delta.amount1() > 0) revert UnexpectedDelta();

        uint256 owed0 = uint256(uint128(-delta.amount0()));
        uint256 owed1 = uint256(uint128(-delta.amount1()));

        bool quoteIsCurrency1 = Currency.unwrap(key.currency1) == address(quote);
        (uint256 owedQuote, uint256 owedToken) = quoteIsCurrency1 ? (owed1, owed0) : (owed0, owed1);
        if (owedQuote > params.maxQuote) revert QuoteExceeded();
        if (owedToken > params.maxToken) revert TokenExceeded();

        if (owed0 != 0) _settle(key.currency0, owed0);
        if (owed1 != 0) _settle(key.currency1, owed1);

        return "";
    }

    function _settle(Currency currency, uint256 amount) private {
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        if (poolManager.settle() != amount) revert SettlementMismatch();
    }
}

