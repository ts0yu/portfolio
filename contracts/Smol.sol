// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "./libraries/BrainMath.sol";

struct Pool {
    bool initialized;
    address tokenA;
    address tokenB;
    uint256 activeLiquidity;
    uint256 activePriceFixedPoint;
    int128 activeSlotIndex;
    uint256 feeGrowthGlobalAFixedPoint;
    uint256 feeGrowthGlobalBFixedPoint;
    address arbRightOwner;
}

struct Slot {
    int256 liquidityDelta;
    uint256 feeGrowthOutsideAFixedPoint;
    uint256 feeGrowthOutsideBFixedPoint;
}

struct Position {
    int128 lowerSlotIndex;
    int128 upperSlotIndex;
    uint256 liquidityOwned;
    uint256 feeGrowthInsideLastAFixedPoint;
    uint256 feeGrowthInsideLastBFixedPoint;
    // TODO: Should we track these fees with precision or nah?
    uint256 feesOwedAFixedPoint;
    uint256 feesOwedBFixedPoint;
}

// TODO:
// - Add WETH wrapping / unwrapping
// - Add the internal balances, fund and withdraw
// - Add Multicall?
// - Fixed point library
// - Slippage checks
// - Extra function parameters
// - Epochs / staking feature
// - Auction
// - Events
// - Custom errors
// - Interface
// - Change `addLiquidity` to `updateLiquidity`
// - slots bitmap

contract Smol {
    uint256 public priceGridFixedPoint = 1000100000000000000; // 1.0001
    uint256 public epochLength;
    uint256 public auctionLength;
    address public auctionSettlementToken;
    uint256 public auctionFee;

    mapping(bytes32 => Pool) public pools;
    mapping(bytes32 => Position) public positions;
    mapping(bytes32 => Slot) public slots;

    function initiatePool(
        address tokenA,
        address tokenB,
        uint256 activePriceF
    ) public {
        if (tokenA == tokenB) revert();
        (tokenA, tokenB) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        Pool storage pool = pools[_getPoolId(tokenA, tokenB)];

        if (pool.initialized) revert();
        pool.initialized = true;
        pool.activePriceF = activePriceF;
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
            slot.liquidityDelta += int256(amount);

            if (pool.activeSlotIndex >= lowerSlotIndex) {
                slot.feeGrowthOutsideA = pool.feeGrowthGlobalA;
                slot.feeGrowthOutsideB = pool.feeGrowthGlobalB;
            }
        }

        {
            bytes32 upperSlotId = _getSlotId(poolId, upperSlotIndex);
            Slot storage slot = slots[upperSlotId];
            slot.liquidityDelta -= int256(amount);

            if (pool.activeSlotIndex >= lowerSlotIndex) {
                slot.feeGrowthOutsideA = pool.feeGrowthGlobalA;
                slot.feeGrowthOutsideB = pool.feeGrowthGlobalB;
            }
        }

        uint256 amountA;
        uint256 amountB;

        if (pool.activeSlotIndex > upperSlotIndex) {
            amountA = _calculateDeltaX(
                amount,
                _getPriceSqrtAtSlot(int256(aF), lowerSlotIndex),
                _getPriceSqrtAtSlot(int256(aF), upperSlotIndex)
            );
        } else if (pool.activeSlotIndex < lowerSlotIndex) {
            amountA = _calculateDeltaX(
                amount,
                _getPriceSqrtAtSlot(int256(aF), pool.activeSlotIndex),
                _getPriceSqrtAtSlot(int256(aF), upperSlotIndex)
            );

            amountB = _calculateDeltaY(
                amount,
                _getPriceSqrtAtSlot(int256(aF), lowerSlotIndex),
                _getPriceSqrtAtSlot(int256(aF), pool.activeSlotIndex)
            );

            pool.activeLiquidity += amount;
        } else {
            amountB = _calculateDeltaY(
                amount,
                _getPriceSqrtAtSlot(int256(aF), lowerSlotIndex),
                _getPriceSqrtAtSlot(int256(aF), upperSlotIndex)
            );
        }

        bytes32 positionId = _getPositionId(msg.sender, poolId, lowerSlotIndex, upperSlotIndex);
        Position storage position = positions[positionId];
        position.liquidityOwned += amount;

        {
            (uint256 feeGrowthInsideA, uint256 feeGrowthInsideB) = _calculateFeeGrowthInside(
                poolId,
                lowerSlotIndex,
                upperSlotIndex
            );

            uint256 changeInFeeGrowthA = feeGrowthInsideA - position.freeGrowthInsideLastA;
            uint256 changeInFeeGrowthB = feeGrowthInsideB - position.freeGrowthInsideLastB;

            position.feesOwedA += uint256(
                PRBMathSD59x18.div(int256(changeInFeeGrowthA), int256(position.liquidityOwned))
            );
            position.feesOwedB += uint256(
                PRBMathSD59x18.div(int256(changeInFeeGrowthB), int256(position.liquidityOwned))
            );

            position.freeGrowthInsideLastA = feeGrowthInsideA;
            position.freeGrowthInsideLastB = feeGrowthInsideB;
        }
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

        if (!direction) {} else {}
    }

    function _calculateFeeGrowthInside(
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
        address owner,
        bytes32 poolId,
        int128 lowerSlotIndex,
        int128 upperSlotIndex
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, poolId, lowerSlotIndex, upperSlotIndex));
    }
}
