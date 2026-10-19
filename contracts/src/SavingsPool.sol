// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SavingsPool
/// @notice ERC-4626 vault over USDC where SuiCash parks idle funds. Testnets have no real yield,
///         so the owner can simulate interest with `accrue`, which raises the share price.
contract SavingsPool is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Emitted when the owner adds simulated yield.
    event YieldAccrued(address indexed from, uint256 amount);

    error ZeroAmount();

    /// @param asset_ The underlying token (USDC).
    /// @param owner_ The account allowed to call `accrue`.
    constructor(IERC20 asset_, address owner_)
        ERC20("SuiCash Savings USDC", "svUSDC")
        ERC4626(asset_)
        Ownable(owner_)
    {}

    /// @notice Simulates yield by moving `amount` of the asset from the owner into the pool.
    ///         Every share becomes worth proportionally more; no shares are minted.
    /// @param amount Amount of the asset to add, in token units.
    function accrue(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit YieldAccrued(msg.sender, amount);
    }

    /// @dev A 6-digit virtual share offset makes the first-depositor inflation attack uneconomic.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
