// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";
import {SavingsPool} from "../src/SavingsPool.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MockUSDC} from "../src/test/MockUSDC.sol";

/// @title Deploy
/// @notice Deploys the savings pool and the vault factory (and MockUSDC on anvil), then writes
///         deployments/<chainId>.json. Testnet only: any chain other than anvil and Base Sepolia
///         is refused.
/// @dev Signing: on testnet the key comes from DEPLOYER_PRIVATE_KEY (read from the environment,
///      never passed on the command line). On anvil, the caller passes --unlocked --sender, so no
///      private key appears anywhere in the repository.
contract Deploy is Script {
    uint256 internal constant ANVIL_CHAIN_ID = 31_337;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    /// @notice Circle's test USDC on Base Sepolia.
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    struct Deployment {
        address usdc;
        address savingsPool;
        address vaultFactory;
    }

    error UnsupportedChain(uint256 chainId);

    function run() external returns (Deployment memory d) {
        // Refuse unsupported chains before any signing session starts.
        address usdc = _usdcFor(block.chainid);
        _startBroadcast();
        (, address deployer,) = vm.readCallers();
        d = deployContracts(usdc, deployer);
        vm.stopBroadcast();
        _write(d, deployer);
    }

    /// @notice Deploys everything. Pass usdc = address(0) to deploy a MockUSDC.
    /// @param usdc The stablecoin the pool holds, or zero for a fresh MockUSDC.
    /// @param poolOwner The account allowed to simulate yield on the pool.
    function deployContracts(address usdc, address poolOwner) public returns (Deployment memory d) {
        d.usdc = usdc == address(0) ? address(new MockUSDC()) : usdc;
        d.savingsPool = address(new SavingsPool(IERC20(d.usdc), poolOwner));
        d.vaultFactory = address(new VaultFactory(d.savingsPool));
    }

    function _usdcFor(uint256 chainId) internal pure returns (address) {
        if (chainId == BASE_SEPOLIA_CHAIN_ID) return BASE_SEPOLIA_USDC;
        if (chainId == ANVIL_CHAIN_ID) return address(0);
        revert UnsupportedChain(chainId);
    }

    function _startBroadcast() internal {
        bool hasKey = vm.envExists("DEPLOYER_PRIVATE_KEY") && bytes(vm.envString("DEPLOYER_PRIVATE_KEY")).length > 0;
        if (hasKey) {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        } else {
            vm.startBroadcast();
        }
    }

    function _write(Deployment memory d, address deployer) internal {
        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "deployer", deployer);
        vm.serializeUint(key, "blockNumber", block.number);
        vm.serializeAddress(key, "usdc", d.usdc);
        vm.serializeAddress(key, "savingsPool", d.savingsPool);
        string memory json = vm.serializeAddress(key, "vaultFactory", d.vaultFactory);
        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("USDC         ", d.usdc);
        console2.log("SavingsPool  ", d.savingsPool);
        console2.log("VaultFactory ", d.vaultFactory);
        console2.log("Wrote", path);
    }
}
