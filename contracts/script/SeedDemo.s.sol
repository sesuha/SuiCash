// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";
import {PolicyVault} from "../src/PolicyVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {HostileToken} from "../src/test/HostileToken.sol";
import {MockUSDC} from "../src/test/MockUSDC.sol";

/// @title SeedDemo
/// @notice Creates the demo vault for the broadcaster (the demo owner) from the factory in
///         deployments/<chainId>.json: USDC enabled at 500 per transaction and 1,000 per day, a
///         50 USDC buffer, the four Personal-persona contacts, funds, and a HostileToken airdrop.
///         Idempotent: re-running reuses the existing vault and skips steps already done.
/// @dev Every value can be overridden with an environment variable (SEED_PER_TX, SEED_DAILY,
///      SEED_BUFFER, SEED_RECIPIENT_DELAY, SEED_FUND, all in USDC base units or seconds), because a
///      Base Sepolia faucet gives only 20 test USDC at a time. On anvil the script mints MockUSDC;
///      on Base Sepolia it transfers what the deployer holds, up to SEED_FUND.
contract SeedDemo is Script {
    struct Contact {
        string name;
        address addr;
        uint128 cap;
    }

    struct Config {
        VaultFactory factory;
        address usdc;
        uint128 perTx;
        uint128 daily;
        uint256 buffer;
        uint64 delay;
        uint256 fund;
    }

    function run() external returns (address vault) {
        Config memory cfg = _config();
        Contact[4] memory contacts = demoContacts();

        _startBroadcast();
        (, address demoOwner,) = vm.readCallers();
        vault = cfg.factory.vaultOf(demoOwner);
        if (vault == address(0)) vault = cfg.factory.createVault();
        _configure(PolicyVault(vault), cfg, contacts);
        _fund(vault, demoOwner, cfg);
        // Scenario 5: an attacker airdrops a token whose name is a prompt injection.
        HostileToken hostile = new HostileToken();
        hostile.airdrop(vault, 1_000_000e18);
        vm.stopBroadcast();

        _write(vault, demoOwner, address(hostile), contacts);
    }

    function _config() internal view returns (Config memory cfg) {
        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        cfg.factory = VaultFactory(vm.parseJsonAddress(json, ".vaultFactory"));
        cfg.usdc = vm.parseJsonAddress(json, ".usdc");
        cfg.perTx = uint128(vm.envOr("SEED_PER_TX", uint256(500e6)));
        cfg.daily = uint128(vm.envOr("SEED_DAILY", uint256(1000e6)));
        cfg.buffer = vm.envOr("SEED_BUFFER", uint256(50e6));
        cfg.delay = uint64(vm.envOr("SEED_RECIPIENT_DELAY", uint256(1 hours)));
        cfg.fund = vm.envOr("SEED_FUND", uint256(2000e6));
    }

    function _configure(PolicyVault v, Config memory cfg, Contact[4] memory contacts) internal {
        (bool enabled,,) = v.tokens(cfg.usdc);
        if (!enabled) v.setTokenLimits(cfg.usdc, cfg.perTx, cfg.daily);
        if (v.minBuffer(cfg.usdc) != cfg.buffer) v.setMinBuffer(cfg.usdc, cfg.buffer);
        if (v.recipientDelay() != cfg.delay) v.setRecipientDelay(cfg.delay);
        for (uint256 i = 0; i < contacts.length; ++i) {
            (bool allowed,,) = v.recipients(contacts[i].addr);
            if (!allowed) v.addRecipient(contacts[i].addr, contacts[i].cap);
        }
    }

    function _fund(address vault, address demoOwner, Config memory cfg) internal {
        uint256 balance = IERC20(cfg.usdc).balanceOf(vault);
        if (balance >= cfg.fund) return;
        if (block.chainid == 31_337) {
            MockUSDC(cfg.usdc).mint(vault, cfg.fund - balance);
            return;
        }
        uint256 available = IERC20(cfg.usdc).balanceOf(demoOwner);
        uint256 amount = cfg.fund - balance < available ? cfg.fund - balance : available;
        if (amount > 0) require(IERC20(cfg.usdc).transfer(vault, amount), "USDC transfer failed");
    }

    /// @notice The Personal persona's contacts (handbook 7.3). Addresses are derived from a label, so
    ///         nobody holds their keys: on testnet, payments to them are effectively burned.
    function demoContacts() public pure returns (Contact[4] memory c) {
        c[0] = Contact("Landlord", _demoAddress("landlord"), 500e6);
        c[1] = Contact("University Bursar", _demoAddress("university-bursar"), 500e6);
        c[2] = Contact("Electricity Co", _demoAddress("electricity-co"), 100e6);
        c[3] = Contact("Mom", _demoAddress("mom"), 200e6);
    }

    function _demoAddress(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked("suicash.demo.contact.", label)))));
    }

    function _startBroadcast() internal {
        bool hasKey = vm.envExists("DEPLOYER_PRIVATE_KEY") && bytes(vm.envString("DEPLOYER_PRIVATE_KEY")).length > 0;
        if (hasKey) {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        } else {
            vm.startBroadcast();
        }
    }

    function _write(address vault, address demoOwner, address hostile, Contact[4] memory contacts) internal {
        string memory contactsJson = "";
        for (uint256 i = 0; i < contacts.length; ++i) {
            contactsJson = string.concat(
                contactsJson,
                i == 0 ? "" : ",",
                '{"name":"',
                contacts[i].name,
                '","address":"',
                vm.toString(contacts[i].addr),
                '","perPaymentCap":',
                vm.toString(uint256(contacts[i].cap)),
                "}"
            );
        }
        string memory json = string.concat(
            '{"vault":"',
            vm.toString(vault),
            '","owner":"',
            vm.toString(demoOwner),
            '","hostileToken":"',
            vm.toString(hostile),
            '","contacts":[',
            contactsJson,
            "]}"
        );
        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), "-demo.json");
        vm.writeFile(path, json);
        console2.log("Demo vault   ", vault);
        console2.log("Demo owner   ", demoOwner);
        console2.log("HostileToken ", hostile);
        console2.log("Wrote", path);
    }
}
