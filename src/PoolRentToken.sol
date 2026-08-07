// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title PoolRentToken
/// @notice A fixed-supply ERC-20 launched into one canonical Uniswap v4 pool.
/// @dev The entire supply is minted once, to the launcher, inside the constructor. There is no
///      owner, minter, pauser, blacklist, transfer tax, rebase, upgrade path or rescue function:
///      transfer, approve and burn-by-send are the only behaviours this token has.
contract PoolRentToken is ERC20 {
    error ZeroSupply();
    error ZeroRecipient();

    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, address recipient)
        ERC20(name_, symbol_)
    {
        if (totalSupply_ == 0) revert ZeroSupply();
        if (recipient == address(0)) revert ZeroRecipient();
        _mint(recipient, totalSupply_);
    }
}
