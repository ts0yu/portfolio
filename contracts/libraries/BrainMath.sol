// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.13;

// TODO: Check which one is the best to use?
import "@prb/math/contracts/PRBMathSD59x18.sol";
import "@prb/math/contracts/PRBMathUD60x18.sol";

uint256 constant PRICE_GRID_FIXED_POINT = 1000100000000000000; // 1.0001

/// @dev Get the price square root using the slot index
///      $$p(i)=1.0001^i$$
function _getSqrtPriceAtSlot(int128 slotIndex) pure returns (uint256) {
    return
        uint256(
            PRBMathUD60x18.pow(PRICE_GRID_FIXED_POINT, PRBMathUD60x18.div(uint256(PRBMathSD59x18.abs(slotIndex)), 2))
        );
}

/// @dev Get the slot index using price square root
///      $$i = log_{1.0001}p(i)$$
function _getSlotAtSqrtPrice(uint256 sqrtPriceFixedPoint) pure returns (int128) {
    return
        int128(
            uint128(
                PRBMathUD60x18.mul(
                    PRBMathUD60x18.log10(PRBMathUD60x18.sqrt(PRICE_GRID_FIXED_POINT)),
                    PRBMathUD60x18.sqrt(sqrtPriceFixedPoint)
                )
            )
        );
}

function _calculateLiquidityDeltas(
    uint256 liquidityDeltaFixedPoint,
    uint256 sqrtPriceCurrentSlotFixedPoint,
    int128 currentSlotIndex,
    int128 lowerSlotIndex,
    int128 upperSlotIndex
) pure returns (uint256 amountA, uint256 amountB) {
    uint256 sqrtPriceUpperSlotFixedPoint = _getSqrtPriceAtSlot(upperSlotIndex);
    uint256 sqrtPriceLowerSlotFixedPoint = _getSqrtPriceAtSlot(lowerSlotIndex);

    if (currentSlotIndex < lowerSlotIndex) {
        amountA = PRBMathUD60x18.mul(
            liquidityDeltaFixedPoint,
            PRBMathUD60x18.div(PRBMathUD60x18.toUint(1), sqrtPriceLowerSlotFixedPoint) -
                PRBMathUD60x18.div(PRBMathUD60x18.toUint(1), sqrtPriceUpperSlotFixedPoint)
        );
    } else if (currentSlotIndex < upperSlotIndex) {
        amountA = PRBMathUD60x18.mul(
            liquidityDeltaFixedPoint,
            PRBMathUD60x18.div(PRBMathUD60x18.toUint(1), sqrtPriceCurrentSlotFixedPoint) -
                PRBMathUD60x18.div(PRBMathUD60x18.toUint(1), sqrtPriceUpperSlotFixedPoint)
        );

        amountB = PRBMathUD60x18.mul(
            liquidityDeltaFixedPoint,
            sqrtPriceCurrentSlotFixedPoint - sqrtPriceLowerSlotFixedPoint
        );
    } else {
        amountB = PRBMathUD60x18.mul(
            liquidityDeltaFixedPoint,
            sqrtPriceUpperSlotFixedPoint - sqrtPriceLowerSlotFixedPoint
        );
    }
}
