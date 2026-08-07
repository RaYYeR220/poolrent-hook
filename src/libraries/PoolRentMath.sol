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

    /// @notice Accrue one beneficiary's share of an executed gross amount, carrying the remainder.
    /// @dev The numerator, not the quotient, is what survives between swaps. A swap whose share is
    ///      worth less than one wei still adds `gross * rate` to the carry, so a long run of tiny
    ///      swaps eventually pays out exactly what the same volume would have paid in one swap.
    ///      Without this, flooring each swap independently lets an entitlement round away to nothing:
    ///      a thousand 499-wei swaps carry the same 10 bps as one 499,000-wei swap, but floor to zero
    ///      a thousand times.
    /// @param gross the executed gross amount the share is measured on
    /// @param rate the beneficiary's rate in hundredths of a basis point
    /// @param carry the beneficiary's numerator remainder from earlier swaps, always < DENOMINATOR
    /// @return amount whole units payable now
    /// @return nextCarry the numerator remainder to persist. Below DENOMINATOR for this call; a
    ///         caller that withholds a clamped unit adds it back, so a stored carry can reach it.
    function accrue(uint256 gross, uint256 rate, uint256 carry)
        internal
        pure
        returns (uint256 amount, uint256 nextCarry)
    {
        uint256 numerator = gross * rate + carry;
        amount = numerator / DENOMINATOR;
        nextCarry = numerator - (amount * DENOMINATOR);
    }

    /// @notice Charge carved out of an amount that is already gross, rounded DOWN.
    /// @dev Kept for the bound check and for reference arithmetic in tests. Live accrual uses
    ///      `accrue` so that nothing is lost to per-swap flooring.
    function feeFromGross(uint256 gross, uint256 rate) internal pure returns (uint256 fee) {
        fee = (gross * rate) / DENOMINATOR;
        // A charge may never consume the entire executed amount.
        if (fee >= gross) fee = gross == 0 ? 0 : gross - 1;
    }

    /// @notice Charge added on top of a net amount so that `fee / (net + fee) == rate`, rounded UP.
    /// @dev Used as the starting point for the exact-output legs, where only the trader's net amount
    ///      is known and the gross has to be solved for.
    function feeOnNet(uint256 net, uint256 rate) internal pure returns (uint256 fee) {
        if (rate >= DENOMINATOR) revert RateTooHigh();
        uint256 denominator = DENOMINATOR - rate;
        fee = (net * rate + denominator - 1) / denominator;
    }

    /// @notice Gross amount that yields exactly `net` after the charge is removed, rounded UP.
    function grossFromNet(uint256 net, uint256 rate) internal pure returns (uint256 gross) {
        gross = net + feeOnNet(net, rate);
    }

    function toInt128(uint256 value) internal pure returns (int128) {
        if (value > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        return int128(uint128(value));
    }
}
