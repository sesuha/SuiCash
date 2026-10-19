// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

/// @title Deploy
/// @notice Deploys the SuiCash contracts and writes their addresses to deployments/<chainId>.json.
/// @dev Phase 1 skeleton: no contracts exist yet, so this only records the chain and deployer.
///      Phase 2 adds MockUSDC (anvil only), SavingsPool and VaultFactory here.
///      Signing: on testnet the key comes from DEPLOYER_PRIVATE_KEY (read from the environment,
///      never passed on the command line). On anvil, the caller passes --unlocked --sender so
///      no private key appears anywhere in the repository.
contract Deploy is Script {
    function run() external {
        bool hasKey = vm.envExists("DEPLOYER_PRIVATE_KEY") && bytes(vm.envString("DEPLOYER_PRIVATE_KEY")).length > 0;
        if (hasKey) {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        } else {
            vm.startBroadcast();
        }
        (, address deployer,) = vm.readCallers();

        // Phase 2: deploy contracts here.

        vm.stopBroadcast();

        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "deployer", deployer);
        string memory json = vm.serializeUint(key, "blockNumber", block.number);
        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Wrote", path);
    }
}
