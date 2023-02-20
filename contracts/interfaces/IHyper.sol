// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {HyperCurve, HyperPair} from "../HyperLib.sol";

interface IHyperEvents {
    /**
     * @dev Ether transfers into Hyper via payable `deposit` function.
     */
    event Deposit(address indexed account, uint256 amount);

    /**
     * @notice Assigns `amount` of `token` to `account`.
     * @dev Emitted on `unallocate`, `swap`, or `fund`.
     */
    event IncreaseUserBalance(address indexed account, address indexed token, uint256 amount);

    /**
     * @notice Unassigns `amount` of `token` from `account`.
     * @dev Emitted on `allocate`, `swap`, or `draw`.
     */
    event DecreaseUserBalance(address indexed account, address indexed token, uint256 amount);

    /**
     * @notice Assigns an additional `amount` of `token` to Hyper's internally tracked balance.
     * @dev Emitted on `swap`, `allocate`, and when a user is gifted surplus tokens.
     */
    event IncreaseReserveBalance(address indexed token, uint256 amount);

    /**
     * @notice Unassigns `amount` of `token` from Hyper's internally tracked balance.
     * @dev Emitted on `swap`, `unallocate`, and when paying with an internal balance.
     */
    event DecreaseReserveBalance(address indexed token, uint256 amount);

    /**
     * @dev Assigns `input` amount of `tokenIn` to Hyper's reserves.
     * Unassigns `output` amount of `tokenOut` from Hyper's reserves.
     * @param price Post-swap approximated marginal price in wad units.
     * @param feeAmountDec Amount of `tokenIn` tokens paid as a fee.
     * @param invariantWad Post-swap invariant in wad units.
     */
    event Swap(
        uint64 indexed poolId,
        uint256 price,
        address indexed tokenIn,
        uint256 input,
        address indexed tokenOut,
        uint256 output,
        uint256 feeAmountDec,
        int256 invariantWad
    );

    /**
     * @dev Assigns amount `deltaAsset` of `asset` and `deltaQuote` of `quote` tokens to `poolId.
     */
    event Allocate(
        uint64 indexed poolId,
        address indexed asset,
        address indexed quote,
        uint256 deltaAsset,
        uint256 deltaQuote,
        uint256 deltaLiquidity
    );

    /**
     * @dev Unassigns amount `deltaAsset` of `asset` and `deltaQuote` of `quote` tokens to `poolId.
     */
    event Unallocate(
        uint64 indexed poolId,
        address indexed asset,
        address indexed quote,
        uint256 deltaAsset,
        uint256 deltaQuote,
        uint256 deltaLiquidity
    );

    /** @dev Emits a `0` for unchanged parameters. */
    event ChangeParameters(uint64 indexed poolId, uint16 indexed priorityFee, uint16 indexed fee, uint16 jit);

    /**
     * @notice Reduces `feeAssetDec` amount of `asset` and `feeQuoteDec` amount of `quote` from the position's state.
     */
    event Collect(
        uint64 poolId,
        address indexed account,
        uint256 feeAssetDec,
        address indexed asset,
        uint256 feeQuoteDec,
        address indexed quote
    );
    event CreatePair(
        uint24 indexed pairId,
        address indexed asset,
        address indexed quote,
        uint8 decimalsAsset,
        uint8 decimalsQuote
    );
    event CreatePool(
        uint64 indexed poolId,
        bool isMutable,
        address indexed asset,
        address indexed quote,
        uint256 price
    );
}

interface IHyperGetters {
    function getNetBalance(address token) external view returns (int256);

    function getReserve(address token) external view returns (uint256);

    function getBalance(address owner, address token) external view returns (uint256);

    function pairs(
        uint24 pairId
    ) external view returns (address tokenAsset, uint8 decimalsAsset, address tokenQuote, uint8 decimalsQuote);

    /**
     * @dev Structs in memory are returned as tuples, e.g. (foo, bar...).
     */
    function pools(
        uint64 poolId
    )
        external
        view
        returns (
            uint128 virtualX,
            uint128 virtualY,
            uint128 liquidity,
            uint32 lastTimestamp,
            address controller,
            uint256 invariantGrowthGlobal,
            uint256 feeGrowthGlobalAsset,
            uint256 feeGrowthGlobalQuote,
            HyperCurve memory,
            HyperPair memory
        );

    function positions(
        address owner,
        uint64 poolId
    )
        external
        view
        returns (
            uint128 freeLiquidity,
            uint256 lastTimestamp,
            uint256 invariantGrowthLast,
            uint256 feeGrowthAssetLast,
            uint256 feeGrowthQuoteLast,
            uint128 tokensOwedAsset,
            uint128 tokensOwedQuote,
            uint128 invariantOwed
        );

    function getPairNonce() external view returns (uint24);

    function getPoolNonce() external view returns (uint32);

    function getPairId(address asset, address quote) external view returns (uint24 pairId);

    function getAmounts(uint64 poolId) external view returns (uint256 deltaAsset, uint256 deltaQuote);

    function getAmountOut(uint64 poolId, bool sellAsset, uint256 amountIn) external view returns (uint256);

    function getVirtualReserves(uint64 poolId) external view returns (uint128 deltaAsset, uint128 deltaQuote);

    function getMaxLiquidity(
        uint64 poolId,
        uint256 deltaAsset,
        uint256 deltaQuote
    ) external view returns (uint128 deltaLiquidity);

    function getLiquidityDeltas(
        uint64 poolId,
        int128 deltaLiquidity
    ) external view returns (uint128 deltaAsset, uint128 deltaQuote);

    function getLatestPrice(uint64 poolId) external view returns (uint256 price);
}

interface IHyperActions {
    /**
     * @notice Increases liquidity of `poolId` and position of `msg.sender` by `amount`.
     * @param amount Amount of wad units of liquidity added to pool and position.
     * @return deltaAsset Quantity of asset tokens assigned to `poolId`.
     * @return deltaQuote Quantity of quote tokens assigned to `poolId`.
     */
    function allocate(uint64 poolId, uint256 amount) external payable returns (uint256 deltaAsset, uint256 deltaQuote);

    /**
     * @notice Decreases liquidity of `poolId` and position of `msg.sender` by `amount`.
     * @return deltaAsset Quantity of asset tokens unassigned to `poolId`.
     * @return deltaQuote Quantity of quote tokens unassigned to `poolId`.
     */
    function unallocate(uint64 poolId, uint256 amount) external returns (uint256 deltaAsset, uint256 deltaQuote);

    /**
     * @notice Swaps asset and quote tokens within the pool `poolId`.
     * @param sellAsset True if asset tokens should be swapped for quote tokens.
     * @param amount Amount of tokens to swap, which are assigned to `poolId`.
     * @param minAmountOut Minimum amount of tokens required to be received by the user.
     * @return output Amount of tokens received by the user.
     * @return remainder Amount of tokens unused by the swap and refunded to the user.
     */
    function swap(
        uint64 poolId,
        bool sellAsset,
        uint256 amount,
        uint256 minAmountOut
    ) external payable returns (uint256 output, uint256 remainder);

    /**
     * @notice Assigns `amount` of `token` to `msg.sender` internal balance.
     * @dev Uses `IERC20.transferFrom`.
     */
    function fund(address token, uint256 amount) external;

    /**
     * @notice Unassigns `amount` of `token` from `msg.sender` and transfers it to the `to` address.
     * @dev Uses `IERC20.transfer`.
     */
    function draw(address token, uint256 amount, address to) external;

    /**
     * @notice Deposits ETH into the user internal balance.
     * @dev Amount of ETH must be sent as `msg.value`, the ETH will be wrapped.
     */
    function deposit() external payable;

    /**
     * @notice Updates the parameters of the pool `poolId`.
     * @dev The sender must be the pool controller, leaving a function parameter
     * as '0' will not change the pool parameter.
     * @param priorityFee New priority fee of the pool in basis points (1 = 0.01%).
     * @param fee New fee of the pool in basis points (1 = 0.01%).
     * @param jit New JIT policy of the pool in seconds (1 = 1 second).
     */
    function changeParameters(uint64 poolId, uint16 priorityFee, uint16 fee, uint16 jit) external;

    /**
     * @notice Credits excees fees earned to `msg.sender` for a position in `poolId`.
     */
    function claim(uint64 poolId, uint256 deltaAsset, uint256 deltaQuote) external;

    /**
     * @notice Creates a new pool.
     */
    function createPool(
        uint24 pairId,
        address controller,
        uint16 priorityFee,
        uint16 fee,
        uint16 vol,
        uint16 dur,
        uint16 jit,
        uint128 maxPrice,
        uint128 price
    ) external returns (uint64 poolId);

    function createPair(address asset, address quote) external returns (uint24 pairId);
}

interface IHyper is IHyperActions, IHyperEvents, IHyperGetters {}
