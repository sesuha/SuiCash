// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PolicyVault} from "./PolicyVault.sol";

/// @title VaultFactory
/// @notice Deploys one PolicyVault per owner with CREATE2, so every visitor gets an isolated wallet
///         at an address known before it exists.
contract VaultFactory {
    /// @notice The savings pool every new vault starts with.
    address public immutable savingsPool;

    /// @notice The vault each owner created, if any.
    mapping(address owner => address vault) public vaultOf;

    event VaultCreated(address indexed owner, address indexed vault);

    error VaultAlreadyExists(address owner, address vault);

    /// @param savingsPool_ The ERC-4626 savings pool for new vaults (may be zero).
    constructor(address savingsPool_) {
        savingsPool = savingsPool_;
    }

    /// @notice Creates the caller's vault, owned by the caller. One vault per owner.
    /// @return vault The new vault's address.
    function createVault() external returns (address vault) {
        address existing = vaultOf[msg.sender];
        if (existing != address(0)) revert VaultAlreadyExists(msg.sender, existing);
        vault = address(new PolicyVault{salt: _salt(msg.sender)}(msg.sender, savingsPool));
        vaultOf[msg.sender] = vault;
        emit VaultCreated(msg.sender, vault);
    }

    /// @notice The address `owner`'s vault has (or will have once created).
    /// @param owner The vault owner.
    function predictVault(address owner) external view returns (address) {
        bytes32 initCodeHash = keccak256(bytes.concat(type(PolicyVault).creationCode, abi.encode(owner, savingsPool)));
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(owner), initCodeHash));
        return address(uint160(uint256(hash)));
    }

    function _salt(address owner) private pure returns (bytes32) {
        return bytes32(uint256(uint160(owner)));
    }
}
