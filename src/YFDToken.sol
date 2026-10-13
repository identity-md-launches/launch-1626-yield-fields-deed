// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Yield Fields Deed (YFD)
/// @notice Fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the deployer
/// (the launch factory). There is no owner, no mint, no pause, no blacklist and no transfer fee.
contract YFDToken is ERC20 {
    /// @notice 1,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("Yield Fields Deed", "YFD") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
