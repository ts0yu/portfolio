// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "@prb/math/UD60x18.sol";

import {PoolId} from "../libraries/Pool.sol";
import {SlotId} from "../libraries/Slot.sol";
import {PositionId} from "../libraries/Position.sol";

interface IHyper {
    // ===== View =====

    function AUCTION_SETTLEMENT_TOKEN() external view returns (address);

    function AUCTION_LENGTH() external view returns (uint256);

    function PUBLIC_SWAP_FEE() external view returns (UD60x18);

    function AUCTION_FEE() external view returns (UD60x18);

    function epoch()
        external
        view
        returns (
            uint256 id,
            uint256 endTime,
            uint256 length
        );

    function auctionFeeCollector() external view returns (address);

    function internalBalances(address owner, address token) external view returns (uint256);

    function pools(PoolId poolId)
        external
        view
        returns (
            address tokenA,
            address tokenB,
            uint256 swapLiquidity,
            uint256 maturedLiquidity,
            int256 pendingLiquidity,
            UD60x18 sqrtPrice,
            int128 slotIndex,
            UD60x18 proceedsPerLiquidity,
            UD60x18 feesAPerLiquidity,
            UD60x18 feesBPerLiquidity,
            uint256 lastUpdatedTimestamp
        );

    function slots(SlotId slotId)
        external
        view
        returns (
            uint256 liquidityGross,
            int256 pendingLiquidityGross,
            int256 swapLiquidityDelta,
            int256 maturedLiquidityDelta,
            int256 pendingLiquidityDelta,
            UD60x18 proceedsPerLiquidityOutside,
            UD60x18 feesAPerLiquidityOutside,
            UD60x18 feesBPerLiquidityOutside,
            uint256 lastUpdatedTimestamp
        );

    function positions(PositionId positionId)
        external
        view
        returns (
            int128 lowerSlotIndex,
            int128 upperSlotIndex,
            uint256 swapLiquidity,
            uint256 maturedLiquidity,
            int256 pendingLiquidity,
            UD60x18 proceedsPerLiquidityInsideLast,
            UD60x18 feesAPerLiquidityInsideLast,
            UD60x18 feesBPerLiquidityInsideLast,
            uint256 lastUpdatedTimestamp
        );

    function bids(PoolId poolId, uint256 epochId)
        external
        view
        returns (
            address refunder,
            address swapper,
            uint256 amount,
            UD60x18 proceedsPerSecond
        );

    // ===== Public State Changing =====

    function start() external;

    function fund(
        address to,
        address token,
        uint256 amount
    ) external;

    function withdraw(
        address to,
        address token,
        uint256 amount
    ) external;

    function activatePool(
        address tokenA,
        address tokenB,
        UD60x18 sqrtPrice
    ) external;

    function updateLiquidity(
        PoolId poolId,
        int128 lowerSlotIndex,
        int128 upperSlotIndex,
        int256 amount,
        bool transferOut
    ) external;

    function swap(
        PoolId poolId,
        uint256 amountIn,
        bool direction,
        bool transferOut
    ) external;

    function bid(
        PoolId poolId,
        uint256 epochId,
        address refunder,
        address swapper,
        uint256 amount
    ) external;

    // ===== Events =====

    event SetEpoch(uint256 id, uint256 endTime);

    event Fund(address to, address token, uint256 amount);

    event Withdraw(address to, address token, uint256 amount);

    event ActivatePool(address tokenA, address tokenB);

    event UpdateLiquidity(PoolId poolId, int128 lowerSlotIndex, int128 upperSlotIndex, int256 amount);

    event Swap(PoolId poolId, uint256 tendered, bool direction);

    event LeadingBid(PoolId poolId, uint256 epochId, address swapper, uint256 amount, UD60x18 proceedsPerSecond);

    // ===== Errors =====

    error HyperNotStartedError();
    error PoolAlreadyInitializedError();
    error AmountZeroError();
    error PoolNotInitializedError();
    error InvalidBidEpochError();
    error AuctionNotStartedError();
    error RemoveLiquidityError();
    error RemovePendingLiquidityError();
    error RemoveLiquidityUninitializedError();
    error PositionInvalidRangeError();
    error PoolUninitializedError();
}
