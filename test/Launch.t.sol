// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolRentFixture} from "./utils/PoolRentFixture.sol";
import {PoolRentHook} from "../src/PoolRentHook.sol";
import {PoolRentLauncher} from "../src/PoolRentLauncher.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract LaunchTest is PoolRentFixture {
    using StateLibrary for IPoolManager;

    /// @dev The floor the launch profile declares, matching `INITIAL_LIQUIDITY` in `script/Launch.s.sol`.
    ///      Asserting merely that some liquidity exists would pass on a pool seeded with one wei of
    ///      liquidity, which is not what the declared profile promises, so the floor itself is asserted.
    uint128 internal constant DECLARED_MINIMUM_INITIAL_LIQUIDITY = 100 ether;

    function test_launch_producesCanonicalPool() public view {
        assertEq(uint160(address(hook)) & 0x3FFF, EXPECTED_MASK, "permission mask");
        assertTrue(hook.initialized(), "hook initialized");
        assertEq(PoolId.unwrap(hook.canonicalPoolId()), PoolId.unwrap(poolId), "canonical pool id");
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG, "dynamic fee flag");
        assertGe(_poolLiquidity(), DECLARED_MINIMUM_INITIAL_LIQUIDITY, "declared minimum initial liquidity");
    }

    function test_launch_seedsDefaultLpFee() public view {
        (,,, uint24 lpFee) = poolManager.getSlot0(poolId);
        assertEq(lpFee, hook.DEFAULT_LP_FEE(), "default lp fee");
        assertEq(hook.currentLpFee(), hook.DEFAULT_LP_FEE(), "current lp fee view");
    }

    function test_launch_leavesNoBalanceInLauncher() public view {
        assertEq(weth.balanceOf(address(launcher)), 0, "launcher weth");
        assertEq(token.balanceOf(address(launcher)), 0, "launcher token");
    }

    function test_launch_isSingleUse() public {
        vm.prank(launchWallet);
        vm.expectRevert(PoolRentLauncher.AlreadyLaunched.selector);
        launcher.deployAndLaunch(_dummyParams());
    }

    function test_launch_rejectsForeignCaller() public {
        vm.prank(alice);
        vm.expectRevert(PoolRentLauncher.NotLaunchWallet.selector);
        launcher.deployAndLaunch(_dummyParams());
    }

    function test_hook_rejectsSecondInitializationOnAnotherTickSpacing() public {
        PoolKey memory foreign = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING + 60,
            hooks: hook
        });
        vm.expectRevert();
        poolManager.initialize(foreign, SQRT_PRICE_1_1);
    }

    function test_hook_rejectsForeignCurrency() public {
        PoolKey memory foreign = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: key.currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });
        vm.expectRevert();
        poolManager.initialize(foreign, SQRT_PRICE_1_1);
    }

    function test_hook_rejectsStaticFeePool() public {
        PoolKey memory foreign = PoolKey({
            currency0: key.currency0, currency1: key.currency1, fee: 3000, tickSpacing: TICK_SPACING, hooks: hook
        });
        vm.expectRevert();
        poolManager.initialize(foreign, SQRT_PRICE_1_1);
    }

    function test_token_hasFixedSupply() public view {
        assertEq(token.totalSupply(), TOTAL_SUPPLY, "fixed supply");
    }

    function _dummyParams() internal view returns (PoolRentLauncher.LaunchParams memory p) {
        p.name = "x";
        p.symbol = "x";
        p.totalSupply = 1 ether;
        p.tickSpacing = TICK_SPACING;
        p.sqrtPriceX96 = SQRT_PRICE_1_1;
        p.liquidity = 1;
        p.maxToken = 1 ether;
        p.maxQuote = 1 ether;
    }
}
