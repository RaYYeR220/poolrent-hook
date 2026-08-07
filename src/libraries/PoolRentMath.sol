// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title PoolRentMath
/// @notice Rounding-explicit arithmetic for the hook-owned volume charge.
/// @dev Rates are expressed in hundredths of a basis point, so `DENOMINATOR` is 1_000_000
///      and 10 basis points is 1_000.
library PoolRentMath {
    uint256 internal constant DENOMINATOR = 1_000_000;

    error RateTooHigh();
    error AmountTooLarge();

    /// @notice Charge carved out of an amount that is already gross, rounded DOWN.
    /// @dev Used on the legs where the executed gross quote amount is known up front:
    ///      the trader keeps `gross - fee`. Rounding down favours the trader.
    function feeFromGross(uint256 gross, uint256 rate) internal pure returns (uint256 fee) {
        fee = (gross * rate) / DENOMINATOR;
        // A charge may never consume the entire executed amount.
        if (fee >= gross) fee = gross == 0 ? 0 : gross - 1;
    }

    /// @notice Charge added on top of a net amount so that `fee / (net + fee) == rate`, rounded UP.
    /// @dev Used on the legs where only the post-charge amount is known: the trader pays
    ///      `net + fee`. Rounding up keeps the realised rate from drifting below the declared one.
    function feeOnNet(uint256 net, uint256 rate) internal pure returns (uint256 fee) {
        if (rate >= DENOMINATOR) revert RateTooHigh();
        uint256 denominator = DENOMINATOR - rate;
        fee = (net * rate + denominator - 1) / denominator;
    }

    /// @notice Gross amount that yields exactly `net` after the charge is removed, rounded UP.
    function grossFromNet(uint256 net, uint256 rate) internal pure returns (uint256 gross) {
        gross = net + feeOnNet(net, rate);
    }

    /// @notice Split a charge between the platform and the pool manager.
    /// @dev The platform is rounded UP so that per-swap rounding can never leave it short; the
    ///      manager receives the remainder. `platform + manager == fee` exactly.
    function splitFee(uint256 fee, uint256 platformPpm)
        internal
        pure
        returns (uint256 platformAmount, uint256 managerAmount)
    {
        platformAmount = (fee * platformPpm + DENOMINATOR - 1) / DENOMINATOR;
        if (platformAmount > fee) platformAmount = fee;
        managerAmount = fee - platformAmount;
    }

    function toInt128(uint256 value) internal pure returns (int128) {
        if (value > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        return int128(uint128(value));
    }
}
