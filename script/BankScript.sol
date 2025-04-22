// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/CliqueBank.sol";

contract DeployBank is Script {
    function run() external returns (Bank) {
        vm.startBroadcast();
        Bank bank = new Bank();
        vm.stopBroadcast();
        return bank;
    }
}
