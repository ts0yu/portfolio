// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "./libraries/BrainMath.sol";

struct Pool {
    bool initialized;
    address tokenA;
    address tokenB;
    uint256 lvrFactor;
    uint256 activeLiquidity;
    uint256 activePriceF;
    int128 activeSlotIndex;
    uint256 feeGrowthGlobalA;
    uint256 feeGrowthGlobalB;
}

struct Slot {
    uint256 liquidityDelta;
    uint256 feeGrowthOutsideA;
    uint256 feeGrowthOutsideB;
}

struct Position {
    int128 lowerSlotIndex;
    int128 upperSlotIndex;
    uint256 liquidityOwned;
    uint256 freeGrowthInsideLastA;
    uint256 freeGrowthInsideLastB;
    uint256 feesOwedA;
    uint256 feesOwedB;
}

contract Smol {
    uint256 public aF = 1000100000000000000; // 1.0001

    mapping(bytes32 => Pool) public pools;
    mapping(bytes32 => Position) public positions;
    mapping(bytes32 => Slot) public slots;

    function initiatePool(
        address tokenA,
        address tokenB,
        // TODO: Should we use active price or active slot?
        uint256 activePriceF,
        int128 activeSlotIndex
    ) public {
        if (tokenA == tokenB) revert();
        (tokenA, tokenB) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        Pool storage pool = pools[_getPoolId(tokenA, tokenB)];

        if (pool.initialized) revert();
        pool.initialized = true;

        // TODO: I think we should only use one of them and deduct the other one
        pool.activePriceF = activePriceF;
        pool.activeSlotIndex = activeSlotIndex;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        int128 lowerSlotIndex,
        int128 upperSlotIndex,
        uint256 amount
    ) public {
        if (lowerSlotIndex > upperSlotIndex) revert();
        if (amount == 0) revert();

        (tokenA, tokenB) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        bytes32 poolId = _getPoolId(tokenA, tokenB);
        Pool storage pool = pools[poolId];
        if (!pool.initialized) revert();

        {
            bytes32 lowerSlotId = _getSlotId(poolId, lowerSlotIndex);
            Slot storage slot = slots[lowerSlotId];
            slot.liquidityDelta += amount;

            if (pool.activeSlotIndex >= lowerSlotIndex) {
                slot.feeGrowthOutsideA = pool.feeGrowthGlobalA;
                slot.feeGrowthOutsideB = pool.feeGrowthGlobalB;
            }
        }

        {
            bytes32 upperSlotId = _getSlotId(poolId, upperSlotIndex);
            Slot storage slot = slots[upperSlotId];
            slot.liquidityDelta -= amount;

            if (pool.activeSlotIndex >= lowerSlotIndex) {
                slot.feeGrowthOutsideA = pool.feeGrowthGlobalA;
                slot.feeGrowthOutsideB = pool.feeGrowthGlobalB;
            }
        }

        uint256 amountA;
        uint256 amountB;

        if (pool.activeSlotIndex > upperSlotIndex) {
            amountB = uint256(int256(upperSlotIndex - lowerSlotIndex)) * amount;
        } else if (pool.activeSlotIndex < lowerSlotIndex) {
            int256 numSlots = upperSlotIndex - lowerSlotIndex;

            // a^(numSlots - 1) / ln(a)
            uint256 firstTerm = FixedPointMathLib.divWadDown(
                uint256(FixedPointMathLib.powWad(int256(aF), numSlots)) - 1000000000000000000,
                uint256(FixedPointMathLib.lnWad(int256(aF)))
            );

            // a^(0.5 - upperSlotIndex)
            uint256 secondTerm = uint256(
                FixedPointMathLib.powWad(
                    int256(aF),
                    int256(500000000000000000 - upperSlotIndex * int128(uint128(FixedPointMathLib.WAD)))
                )
            );
            amountA = FixedPointMathLib.mulWadDown(FixedPointMathLib.mulWadDown(firstTerm, secondTerm), amount);
        } else {
            uint256 slotProportionF = getSlotProportionFromPrice(pool.activePriceF, aF, pool.activeSlotIndex);

            int256 numSlots = (pool.activeSlotIndex - lowerSlotIndex) *
                int256(FixedPointMathLib.WAD) +
                int256(slotProportionF);

            // (a^numSlots - 1) / ln(a)
            uint256 firstTerm = FixedPointMathLib.divWadDown(
                uint256(FixedPointMathLib.powWad(int256(aF), numSlots) - 1000000000000000000),
                uint256(FixedPointMathLib.lnWad(int256(aF)))
            );

            // a^(0.5 - upperSlotIndex - slotProportionF)
            uint256 secondTerm = uint256(
                FixedPointMathLib.powWad(
                    int256(aF),
                    int256(500000000000000000) -
                        upperSlotIndex *
                        int256(FixedPointMathLib.WAD) -
                        int256(slotProportionF)
                )
            );

            amountA = FixedPointMathLib.mulWadDown(FixedPointMathLib.mulWadDown(firstTerm, secondTerm), amount);
            amountB = FixedPointMathLib.mulWadDown(
                uint256(
                    (pool.activeSlotIndex - lowerSlotIndex) *
                        int128(uint128(FixedPointMathLib.WAD)) +
                        int256(slotProportionF)
                ),
                amount
            );

            pool.activeLiquidity += amount;
        }

        bytes32 positionId = _getPositionId(poolId, lowerSlotIndex, upperSlotIndex);
        Position storage position = positions[positionId];
        position.liquidityOwned += amount;
    }

    struct SwapCache {
        int128 activeSlotIndex;
        uint256 slotProportionF;
        uint256 activeLiquidity;
        uint256 activePrice;
        int128 slotIndexOfNextDelta;
        int128 nextDelta;
    }

    function swap(
        address tokenA,
        address tokenB,
        uint256 tendered,
        bool direction
    ) public {
        uint256 tenderedRemaining = tendered;
        uint256 received;

        uint256 cumulativeFees;
        SwapCache memory swapCache;

        if (direction) {}
    }

    function calculateFeeGrowthInside(
        bytes32 poolId,
        int128 lowerSlotIndex,
        int128 upperSlotIndex
    ) internal view returns (uint256 feeGrowthInsideA, uint256 feeGrowthInsideB) {
        bytes32 lowerSlotId = _getSlotId(poolId, lowerSlotIndex);
        uint256 lowerSlotFeeGrowthOutsideA = slots[lowerSlotId].feeGrowthOutsideA;
        uint256 lowerSlotFeeGrowthOutsideB = slots[lowerSlotId].feeGrowthOutsideB;

        bytes32 upperSlotId = _getSlotId(poolId, upperSlotIndex);
        uint256 upperSlotFeeGrowthOutsideA = slots[upperSlotId].feeGrowthOutsideA;
        uint256 upperSlotFeeGrowthOutsideB = slots[upperSlotId].feeGrowthOutsideB;

        Pool memory pool = pools[poolId];

        uint256 feeGrowthAboveA = pool.activeSlotIndex >= upperSlotIndex
            ? pool.feeGrowthGlobalA - upperSlotFeeGrowthOutsideA
            : upperSlotFeeGrowthOutsideA;
        uint256 feeGrowthAboveB = pool.activeSlotIndex >= upperSlotIndex
            ? pool.feeGrowthGlobalB - upperSlotFeeGrowthOutsideB
            : upperSlotFeeGrowthOutsideB;
        uint256 feeGrowthBelowA = pool.activeSlotIndex >= upperSlotIndex
            ? lowerSlotFeeGrowthOutsideA
            : pool.feeGrowthGlobalA - lowerSlotFeeGrowthOutsideA;
        uint256 feeGrowthBelowB = pool.activeSlotIndex >= upperSlotIndex
            ? lowerSlotFeeGrowthOutsideB
            : pool.feeGrowthGlobalB - lowerSlotFeeGrowthOutsideB;

        feeGrowthInsideA = pool.feeGrowthGlobalA - feeGrowthBelowA - feeGrowthAboveA;
        feeGrowthInsideB = pool.feeGrowthGlobalB - feeGrowthBelowB - feeGrowthAboveB;
    }

    function _getPoolId(address tokenA, address tokenB) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenA, tokenB));
    }

    function _getSlotId(bytes32 poolId, int128 slotIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, slotIndex));
    }

    function _getPositionId(
        bytes32 poolId,
        int128 lowerSlotIndex,
        int128 upperSlotIndex
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, lowerSlotIndex, upperSlotIndex));
    }
}
