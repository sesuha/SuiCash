// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice 6-decimal stand-in for USDC with an open mint. FOR ANVIL AND TESTS ONLY:
///         on Base Sepolia the deploy script uses Circle's test USDC instead.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "USDC") {}

    /// @notice Mints `amount` to `to`. Anyone may call it; this token has no value.
    /// @param to Receiver of the new tokens.
    /// @param amount Amount in token units (6 decimals).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
