// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "solmate/tokens/WETH.sol";
import "contracts/RMM01Portfolio.sol";

contract Deploy is Script {
    // Set address if deploying on a network with an existing weth.
    address public __weth__; // = 0x663F3ad617193148711d28f5334eE4Ed07016602;

    event Deployed(address owner, address weth, address Portfolio);

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address weth = __weth__;
        if (weth == address(0)) weth = address(new WETH());

        address portfolio = address(new RMM01Portfolio(weth));

        emit Deployed(msg.sender, weth, portfolio);

        vm.stopBroadcast();
    }
}
