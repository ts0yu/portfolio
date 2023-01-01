// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {HyperCurve} from "../EnigmaTypes.sol";

/**
 * @title IHyperEvents
 * @dev Events emitted in the Hyper contract.
 */
interface IHyperEvents {
    /**  @dev Emitted on increasing the internal reserves of a pool. */
    event Allocate(
        uint64 indexed poolId,
        address indexed asset,
        address indexed quote,
        uint256 deltaAsset,
        uint256 deltaQuote,
        uint256 deltaLiquidity
    );

    /**  @dev Emitted on decreasing the internal reserves of a pool. */
    event Unallocate(
        uint64 indexed poolId,
        address indexed asset,
        address indexed quote,
        uint256 deltaAsset,
        uint256 deltaQuote,
        uint256 deltaLiquidity
    );

    /**  @dev Emitted on a token swap in a single virtual pool. */
    event Swap(uint64 indexed poolId, uint256 input, uint256 output, address indexed tokenIn, address indexed tokenOut);

    /**  @dev Emitted on setting a new token pair in state with the key `pairId`. */
    event CreatePair(
        uint24 indexed pairId,
        address indexed asset,
        address indexed quote,
        uint8 decimalsAsset,
        uint8 decimalsQuote
    );

    /**  @dev Emitted on setting a new curve parameter set in state with key `curveId`. */
    event CreateCurve(
        uint32 indexed curveId,
        uint128 strike,
        uint24 sigma,
        uint32 indexed maturity,
        uint32 indexed gamma,
        uint32 priorityGamma
    );

    /**  @dev Emitted on creating a pool for a pair and curve. */
    event CreatePool(uint64 indexed poolId, uint24 indexed pairId, uint32 indexed curveId, uint256 price);
    /**  @dev A payment requested by this contract that must be paid by the `msg.sender` account. */
    event DecreaseUserBalance(address indexed token, uint256 amount);
    /**  @dev A payment that is paid out to the `msg.sender` account from this contract. */
    event IncreaseUserBalance(address indexed token, uint256 amount);
    /**  @dev Emitted on any pool interaction which increases one of the pool's reserves. */
    event IncreaseReserveBalance(address indexed token, uint256 amount);
    /**  @dev Emitted on any pool interaction which decreases one of the pool's reserves. */
    event DecreaseReserveBalance(address indexed token, uint256 amount);
    /**  @dev Emitted on increasing liquidity. */
    event ChangePosition(address indexed account, uint64 indexed poolId, int256 deltaLiquidity);
    /**  @dev Emitted on syncing earned fees to a position's claimable balance. */
    event FeesEarned(
        address indexed account,
        uint64 indexed poolId,
        uint256 feeAsset,
        address asset,
        uint256 feeQuote,
        address quote
    );

    /** @dev Emitted on changes to a pool's state. */
    event PoolUpdate(
        uint64 indexed poolId,
        uint256 price,
        int24 indexed tick,
        uint256 liquidity,
        address tokenAsset,
        address tokenQuote,
        uint256 feeGrowthGlobalAsset,
        uint256 feeGrowthGlobalQuote
    );

    /**  @dev Emitted on external calls to `syncPool` or `swap`. Syncs a pool's timestamp to block.timestamp. */
    event UpdateLastTimestamp(uint64 indexed poolId);

    /** @dev Emitted on depositing ether. */
    event Deposit(address indexed account, uint amount);
}

/**
 * @title IHyperGetters
 * @dev Public view functions exposed by the Enigma's higher level contracts.
 */
interface IHyperGetters {
    /** @dev Contract's internally tracked balance of tokens. Includes balances and positions. */
    function getReserve(address token) external view returns (uint);

    /** @dev Internal balance of a `token` for an account `owner`. Not allocated to a position. */
    function getBalance(address owner, address token) external view returns (uint);

    function pairs(
        uint24 pairId
    ) external view returns (address tokenasset, uint8 decimalsasset, address tokenQuote, uint8 decimalsQuote);

    function pools(
        uint64 poolId
    )
        external
        view
        returns (
            int24 lastTick,
            uint32 lastTimestamp,
            address controller,
            uint256 feeGrowthGlobalAsset,
            uint256 feeGrowthGlobalQuote,
            uint128 lastPrice,
            uint128 liquidity,
            uint128 stakedLiquidity,
            int128 epochStakedLiquidityDelta,
            HyperCurve memory
        );

    function positions(
        address owner,
        uint64 poolId
    )
        external
        view
        returns (
            uint128 totalLiquidity,
            uint256 blockTimestamp,
            uint256 stakeEpochId,
            uint256 unstakeEpochId,
            uint256 lastRewardGrowth,
            uint256 feeGrowthAssetLast,
            uint256 feeGrowthQuoteLast,
            uint128 tokensOwedAsset,
            uint128 tokensOwedQuote
        );

    function getPairNonce() external view returns (uint256);

    function getSecondsSincePositionUpdate(
        address account,
        uint64 poolId
    ) external view returns (uint256 distance, uint256 timestamp);

    function getAllocateAmounts(
        uint64 poolId,
        uint256 deltaLiquidity
    ) external view returns (uint128 deltaAsset, uint128 deltaQuote);

    function getUnallocateAmounts(
        uint64 poolId,
        uint256 deltaLiquidity
    ) external view returns (uint128 deltaAsset, uint128 deltaQuote);

    function getVirtualReserves(uint64 poolId) external view returns (uint128 deltaAsset, uint128 deltaQuote);

    function getLiquidityMinted(
        uint64 poolId,
        uint deltaAsset,
        uint deltaQuote
    ) external view returns (uint128 deltaLiquidity);
}

/**
 * @title IHyperActions
 * @dev External api for interacting with the contract's state.
 */
interface IHyperActions {
    function allocate(uint64 poolId, uint deltaLiquidity) external returns (uint deltaAsset, uint deltaQuote);

    function unallocate(uint64 poolId, uint amount) external returns (uint deltaAsset, uint deltaQuote);

    function stake(uint64 poolId) external;

    function unstake(uint64 poolId) external;

    function swap(
        uint64 poolId,
        bool sellAsset,
        uint amount,
        uint limit
    ) external returns (uint output, uint remainder);

    function fund(address token, uint256 amount) external;

    function deposit() external payable;

    function draw(address token, uint256 amount, address to) external;

    function syncPool(uint64 poolId) external returns (uint128 blockTimestamp);
}

/**
 * @title IHyper
 * @dev All the interfaces of the Enigma, so it can be imported with ease.
 */
interface IHyper is IHyperActions, IHyperEvents, IHyperGetters {

}
