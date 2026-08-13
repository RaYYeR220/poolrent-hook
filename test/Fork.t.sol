// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolRentHook} from "../src/PoolRentHook.sol";
import {PoolRentToken} from "../src/PoolRentToken.sol";
import {PoolRentLauncher} from "../src/PoolRentLauncher.sol";

interface IWETH9 is IERC20 {
    function deposit() external payable;
}

/// @dev Runs the whole launch against the real Ethereum mainnet PoolManager and the real WETH9.
///      Two suites are required and kept separate: one pinned to an exact block, so the result is
///      reproducible forever, and one against the current head, so today's deployment is still
///      compatible. A fork run proves compatibility with deployed code. It is not a deployment.
abstract contract ForkBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IWETH9 internal constant WETH9 = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address internal constant PROGRAMMABLE_OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint128 internal constant INITIAL_LIQUIDITY = 100 ether;

    PoolSwapTest internal swapRouter;
    PoolRentLauncher internal launcher;
    PoolRentToken internal token;
    PoolRentHook internal hook;
    PoolKey internal key;
    PoolId internal poolId;

    address internal launchWallet = makeAddr("launchWallet");
    address internal trader = makeAddr("trader");
    address internal manager = makeAddr("manager");

    function _setUpFork() internal {
        assertGt(address(POOL_MANAGER).code.length, 0, "PoolManager has no runtime on this fork");
        assertGt(address(WETH9).code.length, 0, "WETH9 has no runtime on this fork");

        swapRouter = new PoolSwapTest(POOL_MANAGER);
        launcher = new PoolRentLauncher(POOL_MANAGER, IERC20(address(WETH9)), launchWallet);

        (bytes32 tokenSalt, address predictedToken) = _findTokenSalt();
        (Currency c0, Currency c1) = predictedToken < address(WETH9)
            ? (Currency.wrap(predictedToken), Currency.wrap(address(WETH9)))
            : (Currency.wrap(address(WETH9)), Currency.wrap(predictedToken));

        (, bytes32 hookSalt) = HookMiner.find(
            address(launcher),
            HOOK_FLAGS,
            type(PoolRentHook).creationCode,
            abi.encode(POOL_MANAGER, c0, c1, TICK_SPACING, SQRT_PRICE_1_1, IERC20(address(WETH9)))
        );

        _wrap(launchWallet, 1_000 ether);
        vm.startPrank(launchWallet);
        WETH9.approve(address(launcher), type(uint256).max);
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
                maxQuote: 500 ether
            })
        );
        vm.stopPrank();

        key = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: TICK_SPACING, hooks: hook
        });
        poolId = key.toId();

        _wrap(trader, 100 ether);
        _wrap(manager, 100 ether);
        vm.prank(launchWallet);
        token.transfer(trader, 1_000_000 ether);

        vm.startPrank(trader);
        WETH9.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _wrap(address who, uint256 amount) private {
        vm.deal(who, amount);
        vm.prank(who);
        WETH9.deposit{value: amount}();
    }

    function _findTokenSalt() private view returns (bytes32 salt, address predicted) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(PoolRentToken).creationCode, abi.encode("PoolRent Demo", "PRD", TOTAL_SUPPLY, address(launcher))
            )
        );
        for (uint256 i; i < 100_000; ++i) {
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(launcher), salt, initCodeHash))))
            );
            if (predicted < address(WETH9)) return (salt, predicted);
        }
        revert("no token salt found");
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        vm.prank(trader);
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev The full lifecycle, run against deployed mainnet code.
    function _runLifecycle() internal {
        assertEq(uint160(address(hook)) & 0x3FFF, 0x30CC, "permission mask");
        (,,, uint24 lpFee) = POOL_MANAGER.getSlot0(poolId);
        assertEq(lpFee, hook.DEFAULT_LP_FEE(), "default lp fee seeded");
        assertGt(POOL_MANAGER.getLiquidity(poolId), 0, "liquidity seeded");

        // All four quadrants against real deployed code.
        _swap(true, -1 ether);
        _swap(true, 0.5 ether);
        _swap(false, -1 ether);
        _swap(false, 0.5 ether);
        assertGt(hook.feeOwed(PROGRAMMABLE_OWNER), 0, "platform liability accrued");

        // Win the auction, set a fee, let rent accrue, and see it reach liquidity providers.
        vm.startPrank(manager);
        WETH9.approve(address(hook), type(uint256).max);
        hook.bid(1e15, 10 ether);
        hook.setLpFee(500);
        vm.stopPrank();
        assertEq(hook.manager(), manager, "manager won the auction");
        assertEq(hook.currentLpFee(), 500, "manager fee applies");

        vm.roll(block.number + 50);
        uint256 depositBefore = hook.deposits(manager);
        _swap(true, -1 ether);
        assertLt(hook.deposits(manager), depositBefore, "rent charged");

        // Only the immutable owner can claim its liability, to a destination it chooses.
        uint256 owed = hook.feeOwed(PROGRAMMABLE_OWNER);
        address destination = makeAddr("platformDestination");
        vm.prank(PROGRAMMABLE_OWNER);
        hook.claimFee(destination, owed);
        assertEq(WETH9.balanceOf(destination), owed, "platform claim settled");

        assertTrue(hook.isSolvent(), "hook solvent after lifecycle");
    }
}

/// @dev Reproducible: pinned to an exact mainnet block.
contract ForkPinnedTest is ForkBase {
    uint256 internal constant PINNED_BLOCK = 25_700_000;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")), PINNED_BLOCK);
        _setUpFork();
    }

    function test_fork_pinned_fullLifecycle() public {
        assertEq(block.number, PINNED_BLOCK, "fork pinned to the declared block");
        _runLifecycle();
    }
}

/// @dev Compatibility with whatever is deployed right now.
contract ForkHeadTest is ForkBase {
    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        _setUpFork();
    }

    function test_fork_head_fullLifecycle() public {
        _runLifecycle();
    }
}
