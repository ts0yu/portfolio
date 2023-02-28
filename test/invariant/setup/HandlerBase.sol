// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.4;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console} from "forge-std/console.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";

import "solmate/test/utils/mocks/MockERC20.sol";

import "contracts/interfaces/IHyper.sol";
import {HyperPool, HyperPosition, HyperPair, HyperCurve} from "contracts/HyperLib.sol";
import {GhostState} from "../../HelperGhostLib.sol";
import {ActorsState} from "../../HelperActorsLib.sol";

interface Context {
    // Manipulate ghost environment
    function setGhostPoolId(uint64) external;

    function addGhostPoolId(uint64) external;

    function setGhostActor(address) external;

    function addGhostActor(address) external;

    // Ghost environment getters from Setup.sol
    function subject() external view returns (IHyper);

    function actor() external view returns (address);

    function ghost() external view returns (GhostState memory);

    function getActors() external view returns (address[] memory);

    function getRandomActor(uint index) external view returns (address);

    // Ghost Invariant environment getters

    function getPoolIds() external view returns (uint64[] memory);

    function getRandomPoolId(uint index) external view returns (uint64);

    // Subject Specific Getters
    function getBalanceSum(address) external view returns (uint);

    function getPositionsLiquiditySum() external view returns (uint);
}

/** @dev Target contract must inherit. Read: https://github.com/dapphub/dapptools/blob/master/src/dapp/README.md#invariant-testing */
abstract contract HandlerBase is CommonBase, StdCheats, StdUtils, StdAssertions {
    Context ctx;
    mapping(bytes32 => uint256) public calls;

    constructor() {
        ctx = Context(msg.sender);
    }

    modifier countCall(bytes32 key) {
        calls[key]++;
        _;
    }

    function name() public view virtual returns (string memory);

    modifier createActor() {
        ctx.addGhostActor(msg.sender);
        ctx.setGhostActor(msg.sender);
        _;
    }

    modifier useActor(uint seed) {
        ctx.setGhostActor(ctx.getRandomActor(seed));
        vm.startPrank(ctx.actor());
        _;
        vm.stopPrank();
    }

    modifier usePool(uint seed) {
        ctx.setGhostPoolId(ctx.getRandomPoolId(seed));
        _;
    }
}
