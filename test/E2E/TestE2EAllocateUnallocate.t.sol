// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./setup/TestE2ESetup.sol";

contract TestE2EAllocateUnallocate is TestE2ESetup {
    function testFuzzAllocateUnallocateSuccessful(uint deltaLiquidity) public {
        vm.assume(deltaLiquidity > 0);
        vm.assume(deltaLiquidity < 2 ** 127);
        // TODO: Add use max flag support.

        // Preconditions
        HyperPool memory pool = getPool(address(__hyper__), __poolId__);
        assertTrue(pool.blockTimestamp != 0, "Pool not initialized");
        assertTrue(pool.lastPrice != 0, "Pool not created with a price");

        (uint expectedDeltaAsset, uint expectedDeltaQuote) = __hyper__.getReserveDelta(__poolId__, deltaLiquidity);
        fundUsers(expectedDeltaAsset, expectedDeltaQuote);

        // Execution
        HyperState memory prev = getState();
        (uint deltaAsset, uint deltaQuote) = __hyper__.allocate(__poolId__, deltaLiquidity);
        HyperState memory post = getState();

        // Postconditions
        {
            assertEq(deltaAsset, expectedDeltaAsset, "pool-delta-asset");
            assertEq(deltaQuote, expectedDeltaQuote, "pool-delta-quote");
            assertEq(post.totalPoolLiquidity, prev.totalPoolLiquidity + deltaLiquidity, "pool-total-liquidity");
            assertTrue(post.totalPoolLiquidity > prev.totalPoolLiquidity, "pool-liquidity-increases");
            assertEq(
                post.callerPositionLiquidity,
                prev.callerPositionLiquidity + deltaLiquidity,
                "position-liquidity-increases"
            );

            assertEq(post.reserveAsset, prev.reserveAsset + expectedDeltaAsset, "reserve-asset");
            assertEq(post.reserveQuote, prev.reserveQuote + expectedDeltaQuote, "reserve-quote");
            assertEq(post.physicalBalanceAsset, prev.physicalBalanceAsset + expectedDeltaAsset, "physical-asset");
            assertEq(post.physicalBalanceQuote, prev.physicalBalanceQuote + expectedDeltaQuote, "physical-quote");

            uint feeDelta0 = post.feeGrowthAssetPosition - prev.feeGrowthAssetPosition;
            uint feeDelta1 = post.feeGrowthAssetPool - prev.feeGrowthAssetPool;
            assertTrue(feeDelta0 == feeDelta1, "asset-growth");

            uint feeDelta2 = post.feeGrowthQuotePosition - prev.feeGrowthQuotePosition;
            uint feeDelta3 = post.feeGrowthQuotePool - prev.feeGrowthQuotePool;
            assertTrue(feeDelta2 == feeDelta3, "quote-growth");
        }

        // Unallocate
        customWarp(block.timestamp + __hyper__.JUST_IN_TIME_LIQUIDITY_POLICY()); // TODO: make this public function.
        (uint unallocatedAsset, uint unallocatedQuote) = __hyper__.unallocate(__poolId__, deltaLiquidity);

        {
            HyperState memory end = getState();
            assertEq(unallocatedAsset, deltaAsset);
            assertEq(unallocatedQuote, deltaQuote);
            assertEq(end.reserveAsset, prev.reserveAsset);
            assertEq(end.reserveQuote, prev.reserveQuote);
            assertEq(end.totalPoolLiquidity, prev.totalPoolLiquidity);
            assertEq(end.totalPositionLiquidity, prev.totalPositionLiquidity);
            assertEq(end.callerPositionLiquidity, prev.callerPositionLiquidity);
        }
    }

    function swap(uint amount) public {
        vm.assume(amount < 1e18);
        __asset__.approve(address(__hyper__), amount);
        deal(address(__asset__), address(this), amount);
        __hyper__.swap(__poolId__, true, amount, type(uint).max);
    }
}
