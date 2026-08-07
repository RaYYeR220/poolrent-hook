// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolRentHook} from "../src/PoolRentHook.sol";
import {PoolRentToken} from "../src/PoolRentToken.sol";
import {PoolRentLauncher} from "../src/PoolRentLauncher.sol";

/// @notice Deterministic launch plan. Step one deploys the launcher; step two mines both salts and
///         runs the whole launch in a single atomic transaction that rolls back on any mismatch.
/// @dev Nothing here signs or broadcasts by itself — run it with `--broadcast` only against a
///      deliberately chosen RPC and signer. `forge script script/Launch.s.sol` alone simulates.
contract LaunchScript is Script {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IERC20 constant WETH9 = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    string constant NAME = "PoolRent Demo";
    string constant SYMBOL = "PRD";
    uint256 constant TOTAL_SUPPLY = 1_000_000_000 ether;
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint128 constant INITIAL_LIQUIDITY = 100 ether;

    function run() external {
        address launchWallet = msg.sender;

        vm.startBroadcast();
        PoolRentLauncher launcher = new PoolRentLauncher(POOL_MANAGER, WETH9, launchWallet);
        vm.stopBroadcast();

        (bytes32 tokenSalt, address predictedToken) = _mineTokenSalt(address(launcher));
        (Currency c0, Currency c1) = predictedToken < address(WETH9)
            ? (Currency.wrap(predictedToken), Currency.wrap(address(WETH9)))
            : (Currency.wrap(address(WETH9)), Currency.wrap(predictedToken));

        (address predictedHook, bytes32 hookSalt) = HookMiner.find(
            address(launcher),
            HOOK_FLAGS,
            type(PoolRentHook).creationCode,
            abi.encode(POOL_MANAGER, c0, c1, TICK_SPACING, SQRT_PRICE_1_1, WETH9)
        );

        console2.log("launcher       ", address(launcher));
        console2.log("predicted token", predictedToken);
        console2.log("predicted hook ", predictedHook);
        console2.log("permission mask", uint160(predictedHook) & 0x3FFF);

        vm.startBroadcast();
        WETH9.approve(address(launcher), type(uint256).max);
        (PoolRentToken token, PoolRentHook hook) = launcher.deployAndLaunch(
            PoolRentLauncher.LaunchParams({
                name: NAME,
                symbol: SYMBOL,
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
        vm.stopBroadcast();

        require(address(token) == predictedToken, "token address drifted");
        require(address(hook) == predictedHook, "hook address drifted");
    }

    /// @dev Chooses a token salt that fixes the currency ordering before the hook salt is mined,
    ///      because the hook's constructor arguments — and therefore its address — depend on it.
    function _mineTokenSalt(address deployer) internal pure returns (bytes32 salt, address predicted) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(PoolRentToken).creationCode, abi.encode(NAME, SYMBOL, TOTAL_SUPPLY, deployer))
        );
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if (predicted < address(WETH9)) return (salt, predicted);
        }
        revert("no token salt found");
    }
}
