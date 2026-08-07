// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolRentHook} from "../../src/PoolRentHook.sol";
import {PoolRentToken} from "../../src/PoolRentToken.sol";
import {PoolRentLauncher} from "../../src/PoolRentLauncher.sol";
import {TestQuoteToken} from "./TestQuoteToken.sol";

/// @dev Shared fixture: a real PoolManager, a real launch through the launcher, and helpers for
///      swapping and reading pool state. Every test in this suite runs against the canonical pool
///      produced by `PoolRentLauncher.deployAndLaunch`, never against a hand-wired hook.
abstract contract PoolRentFixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint160 internal constant EXPECTED_MASK = 0x30CC;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint128 internal constant INITIAL_LIQUIDITY = 100_000 ether;

    address internal constant PROGRAMMABLE_OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;

    IPoolManager internal poolManager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;

    TestQuoteToken internal weth;
    PoolRentLauncher internal launcher;
    PoolRentToken internal token;
    PoolRentHook internal hook;
    PoolKey internal key;
    PoolId internal poolId;

    address internal launchWallet = makeAddr("launchWallet");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal trader = makeAddr("trader");

    function setUp() public virtual {
        poolManager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(poolManager);
        liquidityRouter = new PoolModifyLiquidityTest(poolManager);
        weth = new TestQuoteToken("Wrapped Ether", "WETH");

        _launch();
        _fund(trader);
        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    /* ------------------------------- launch ------------------------------- */

    function _launch() internal {
        launcher = new PoolRentLauncher(poolManager, IERC20(address(weth)), launchWallet);

        // Pick a token salt that puts the launched token below WETH, so WETH is currency1.
        (bytes32 tokenSalt, address predictedToken) = _findTokenSalt(true);

        (Currency c0, Currency c1) = predictedToken < address(weth)
            ? (Currency.wrap(predictedToken), Currency.wrap(address(weth)))
            : (Currency.wrap(address(weth)), Currency.wrap(predictedToken));

        (, bytes32 hookSalt) = HookMiner.find(
            address(launcher),
            HOOK_FLAGS,
            type(PoolRentHook).creationCode,
            abi.encode(poolManager, c0, c1, TICK_SPACING, SQRT_PRICE_1_1, IERC20(address(weth)))
        );

        weth.mint(launchWallet, 1_000_000 ether);
        vm.startPrank(launchWallet);
        weth.approve(address(launcher), type(uint256).max);
        (token, hook) = launcher.deployAndLaunch(
            PoolRentLauncher.LaunchParams({
                name: "PoolRent Demo",
                symbol: "PRD",
                totalSupply: TOTAL_SUPPLY,
                tokenSalt: tokenSalt,
                hookSalt: hookSalt,
                tickSpacing: TICK_SPACING,
                sqrtPriceX96: SQRT_PRICE_1_1,
                liquidity: INITIAL_LIQUIDITY,
                maxToken: TOTAL_SUPPLY,
                maxQuote: 500_000 ether
            })
        );
        vm.stopPrank();

        assertEq(address(token), predictedToken, "token address prediction");

        key = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: TICK_SPACING, hooks: hook
        });
        poolId = key.toId();
    }

    /// @dev Brute-forces a CREATE2 salt whose token address sorts on the requested side of WETH.
    function _findTokenSalt(bool wantTokenBelowWeth) internal view returns (bytes32 salt, address predicted) {
        bytes memory initCode = abi.encodePacked(
            type(PoolRentToken).creationCode, abi.encode("PoolRent Demo", "PRD", TOTAL_SUPPLY, address(launcher))
        );
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i; i < 100_000; ++i) {
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(launcher), salt, initCodeHash))))
            );
            if ((predicted < address(weth)) == wantTokenBelowWeth) return (salt, predicted);
        }
        revert("no token salt found");
    }

    /* ------------------------------- helpers ------------------------------ */

    function _fund(address who) internal {
        weth.mint(who, 100_000 ether);
        vm.prank(launchWallet);
        token.transfer(who, 10_000_000 ether);

        vm.startPrank(who);
        weth.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(liquidityRouter), type(uint256).max);
        weth.approve(address(hook), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(liquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(address who, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return _swap(who, zeroForOne, amountSpecified, 0);
    }

    function _swap(address who, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        returns (BalanceDelta)
    {
        uint160 limit = sqrtPriceLimitX96 != 0
            ? sqrtPriceLimitX96
            : (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);

        vm.prank(who);
        return swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _addLiquidity(address who, uint128 liquidity) internal {
        int24 lower = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        int24 upper = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
        vm.prank(who);
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
    }

    function _becomeManager(address who, uint128 rentPerBlock, uint256 deposit) internal {
        vm.startPrank(who);
        weth.approve(address(hook), type(uint256).max);
        hook.bid(rentPerBlock, deposit);
        vm.stopPrank();
    }

    function _quoteDelta(BalanceDelta delta) internal view returns (int128) {
        return hook.quoteIsCurrency1() ? delta.amount1() : delta.amount0();
    }

    function _tokenDelta(BalanceDelta delta) internal view returns (int128) {
        return hook.quoteIsCurrency1() ? delta.amount0() : delta.amount1();
    }

    function _poolLiquidity() internal view returns (uint128) {
        return poolManager.getLiquidity(poolId);
    }

    function _assertSolvent() internal view {
        assertTrue(hook.isSolvent(), "hook insolvent");
    }
}
