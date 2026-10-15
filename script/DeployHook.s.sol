// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import "../src/PointsHook.sol";

// forge script script/DeployHook.s.sol --rpc-url $MAINNET_RPC_URL --chain-id 1 --broadcast
contract DeployHook is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);

        // TODO: Implement HookMiner logic (from @uniswap/v4-hooks-public) to generate salt for valid hook address
        PointsHook hook = new PointsHook();

        vm.stopBroadcast();
    }
}
