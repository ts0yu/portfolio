// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.13;

/**

  ------------------------------------

  Hyper is a replicating market maker.

  ------------------------------------

  Primitive™

 */

import "./HyperLib.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IHyper.sol";
import "./interfaces/IERC20.sol";

contract Hyper is IHyper {
    using Price for Price.RMM;
    using SafeCastLib for uint256;
    using FixedPointMathLib for int256;
    using FixedPointMathLib for uint256;
    using {Assembly.isBetween} for uint8;
    using {Assembly.scaleFromWadDownSigned} for int;
    using {Assembly.scaleFromWadDown, Assembly.scaleFromWadUp, Assembly.scaleToWad} for uint256;

    function VERSION() public pure returns (string memory) {
        assembly {
            // Load 0x20 (32) in memory at slot 0x00, this corresponds to the
            // offset location of the next data.
            mstore(0x00, 0x20)

            // Then we load both the length of our string (11 bytes, 0x0b in hex) and its
            // actual hex value (0x626574612d76302e312e30) using the offset 0x2b. Using this
            // particular offset value will right pad the length at the end of the slot
            // and left pad the string at the beginning of the next slot, assuring the
            // right ABI format to return a string.
            mstore(0x2b, 0x0b626574612d76302e312e30) // "beta-v0.1.0"

            // Return all the 96 bytes (0x60) of data that was loaded into the memory.
            return(0x00, 0x60)
        }
    }

    OS.AccountSystem public __account__;

    address public immutable WETH;
    uint24 public getPairNonce;
    uint32 public getPoolNonce;

    mapping(uint24 => HyperPair) public pairs;
    mapping(uint64 => HyperPool) public pools;
    mapping(address => mapping(address => uint24)) public getPairId;
    mapping(address => mapping(uint64 => HyperPosition)) public positions;

    uint256 public locked = 1;
    Payment[] private _payments;
    SwapState private _state;

    modifier lock() {
        if (locked != 1) revert InvalidReentrancy();

        locked = 2;
        _;
        locked = 1;
    }

    /**
     * @dev
     * Used on external functions to handle settlement of outstanding token balances.
     *
     * @notice
     * Tokens sent to this contract are lost.
     *
     * @custom:guide
     * Step 1. Enter `locked` re-entrancy guard.
     * Step 2. Validate Hyper's account system has not already been entered.
     * Step 3. Wrap the entire ether balance of this contract and credit the wrapped ether to the msg.sender account.
     * Step 4. Enter the re-entrancy guard of Hyper's account system.
     * Step 5. Execute the function logic.
     * Step 6. Exit the re-entrancy guard of Hyper's account system.
     * Step 7. Enter the settlement function, requesting token payments or sending them out to msg.sender.
     * Step 8. Validate Hyper's account system was settled.
     * Step 9. Exit interactions modifier.
     * Step 10. Exit `locked` re-entrancy guard.
     */
    modifier interactions() {
        if (__account__.prepared) revert InvalidReentrancy();
        __account__.__wrapEther__(WETH); // Deposits msg.value ether, this contract receives WETH.
        __account__.prepared = false;
        _;
        __account__.prepared = true;

        _settlement();

        if (!__account__.settled) revert InvalidSettlement();
    }

    /**
     * @dev
     * Failing to pass a valid WETH contract that implements the `deposit()` function,
     * will cause all transactions with Hyper to fail once address(this).balance > 0.
     *
     * @notice
     * Tokens sent to this contract are lost.
     */
    constructor(address weth) {
        WETH = weth;
        __account__.settled = true;
    }

    receive() external payable {
        if (msg.sender != WETH) revert();
    }

    /**  @dev Alternative entrypoint to process operations using encoded calldata transferred directly as `msg.data`. */
    fallback() external payable lock interactions {
        Enigma.__startProcess__(_process);
    }

    /** @dev balanceOf(token) - getReserve(token). If negative, you win. */
    function getNetBalance(address token) public view returns (int256) {
        return __account__.getNetBalance(token, address(this));
    }

    /** @dev Virtual balance of `token`. */
    function getReserve(address token) public view returns (uint256) {
        return __account__.reserves[token];
    }

    /** @dev Internal balance of `owner` of `token`. */
    function getBalance(address owner, address token) public view returns (uint256) {
        return __account__.balances[owner][token];
    }

    /** @dev Transient stored tokens */
    function getWarm() public view returns (address[] memory warm) {
        return __account__.warm;
    }

    // ===== Actions ===== //

    /// @inheritdoc IHyperActions
    function allocate(
        uint64 poolId,
        uint256 amount
    ) external payable lock interactions returns (uint256 deltaAsset, uint256 deltaQuote) {
        bool useMax = amount == type(uint256).max;
        (deltaAsset, deltaQuote) = _allocate(useMax, poolId, (useMax ? 1 : amount).safeCastTo128());
    }

    /// @inheritdoc IHyperActions
    function unallocate(
        uint64 poolId,
        uint256 amount
    ) external lock interactions returns (uint256 deltaAsset, uint256 deltaQuote) {
        bool useMax = amount == type(uint256).max;
        (deltaAsset, deltaQuote) = _unallocate(useMax, poolId, (useMax ? 1 : amount).safeCastTo128());
    }

    /// @inheritdoc IHyperActions
    function swap(
        uint64 poolId,
        bool sellAsset,
        uint256 amount,
        uint256 limit
    ) external payable lock interactions returns (uint256 output, uint256 remainder) {
        if (limit == type(uint256).max) limit = type(uint128).max;
        bool useMax = amount == type(uint256).max; // magic variable.
        uint128 input = useMax ? type(uint128).max : amount.safeCastTo128();
        (, remainder, , output) = _swapExactIn(
            Order({
                useMax: useMax ? 1 : 0,
                poolId: poolId,
                input: input,
                output: limit.safeCastTo128(),
                direction: sellAsset ? 0 : 1
            })
        );
    }

    /// @inheritdoc IHyperActions
    function draw(address token, uint256 amount, address to) external lock interactions {
        if (to == address(this)) revert InvalidTransfer(); // todo: Investigate attack vectors if this was not here.

        uint256 balance = getBalance(msg.sender, token);
        if (amount == type(uint256).max) amount = balance;
        if (amount > balance) revert DrawBalance();

        _applyDebit(token, amount);
        _decreaseReserves(token, amount);

        if (token == WETH) OS.__dangerousUnwrapEther__(WETH, to, amount);
        else OS.SafeTransferLib.safeTransfer(OS.ERC20(token), to, amount);
    }

    /// @inheritdoc IHyperActions
    function fund(address token, uint256 amount) external override lock interactions {
        if (amount == type(uint256).max) amount = OS.__balanceOf__(token, msg.sender);
        __account__.dangerousFund(token, address(this), amount); // warning: external call to msg.sender.
    }

    /// @inheritdoc IHyperActions
    function deposit() external payable override lock interactions {
        if (msg.value == 0) revert ZeroValue();
        emit Deposit(msg.sender, msg.value);
        // interactions modifier does the work.
    }

    function claim(uint64 poolId, uint256 deltaAsset, uint256 deltaQuote) external lock interactions {
        HyperPool memory pool = pools[poolId];
        HyperPosition storage pos = positions[msg.sender][poolId];
        if (pos.lastTimestamp == 0) revert NonExistentPosition(msg.sender, poolId);

        pos.syncPositionFees(pool.feeGrowthGlobalAsset, pool.feeGrowthGlobalQuote, pool.invariantGrowthGlobal);

        // 2^256 is a magic variable to claim the maximum amount of owed tokens after it has been synced.
        uint256 claimedAssets = deltaAsset == type(uint256).max ? pos.tokensOwedAsset : deltaAsset;
        uint256 claimedQuotes = deltaQuote == type(uint256).max ? pos.tokensOwedQuote : deltaQuote;

        pos.tokensOwedAsset -= claimedAssets.safeCastTo128();
        pos.tokensOwedQuote -= claimedQuotes.safeCastTo128();

        if (claimedAssets > 0) _applyCredit(pool.pair.tokenAsset, claimedAssets);
        if (claimedQuotes > 0) _applyCredit(pool.pair.tokenQuote, claimedQuotes);

        emit Collect(
            poolId,
            msg.sender,
            claimedAssets,
            pool.pair.tokenAsset,
            claimedQuotes,
            pool.pair.tokenQuote,
            0,
            address(0)
        );
    }

    // ===== Effects ===== //

    /** @dev Increases virtal reserves and liquidity. Debits `msg.sender`. */
    function _allocate(
        bool useMax,
        uint64 poolId,
        uint128 deltaLiquidity
    ) internal returns (uint256 deltaAsset, uint256 deltaQuote) {
        HyperPool memory pool = pools[poolId];
        if (!pool.exists()) revert NonExistentPool(poolId);

        if (useMax) {
            deltaLiquidity = pool.getPoolMaxLiquidity({
                deltaAsset: getBalance(msg.sender, pool.pair.tokenAsset),
                deltaQuote: getBalance(msg.sender, pool.pair.tokenQuote)
            });
        }

        if (deltaLiquidity == 0) revert ZeroLiquidity();
        (deltaAsset, deltaQuote) = pool.getPoolLiquidityDeltas(toInt128(deltaLiquidity)); // note: rounds up.
        if (deltaAsset == 0 || deltaQuote == 0) revert ZeroAmounts();

        ChangeLiquidityParams memory args = ChangeLiquidityParams({
            owner: msg.sender,
            poolId: poolId,
            timestamp: block.timestamp,
            deltaAsset: deltaAsset,
            deltaQuote: deltaQuote,
            tokenAsset: pool.pair.tokenAsset,
            tokenQuote: pool.pair.tokenQuote,
            deltaLiquidity: toInt128(deltaLiquidity)
        });

        _changeLiquidity(args);
        emit Allocate(poolId, pool.pair.tokenAsset, pool.pair.tokenQuote, deltaAsset, deltaQuote, deltaLiquidity);
    }

    /** @dev Reduces virtual reserves and liquidity. Credits `msg.sender`. */
    function _unallocate(
        bool useMax,
        uint64 poolId,
        uint128 deltaLiquidity
    ) internal returns (uint256 deltaAsset, uint256 deltaQuote) {
        if (useMax) deltaLiquidity = positions[msg.sender][poolId].freeLiquidity;
        if (deltaLiquidity == 0) revert ZeroLiquidity();

        HyperPool memory pool = pools[poolId];
        if (!pool.exists()) revert NonExistentPool(poolId);

        (deltaAsset, deltaQuote) = pool.getPoolLiquidityDeltas(-toInt128(deltaLiquidity)); // rounds down

        ChangeLiquidityParams memory args = ChangeLiquidityParams({
            owner: msg.sender,
            poolId: poolId,
            timestamp: block.timestamp,
            deltaAsset: deltaAsset,
            deltaQuote: deltaQuote,
            tokenAsset: pool.pair.tokenAsset,
            tokenQuote: pool.pair.tokenQuote,
            deltaLiquidity: -toInt128(deltaLiquidity)
        });

        _changeLiquidity(args);
        emit Unallocate(poolId, pool.pair.tokenAsset, pool.pair.tokenQuote, deltaAsset, deltaQuote, deltaLiquidity);
    }

    function _changeLiquidity(
        ChangeLiquidityParams memory args
    ) internal returns (uint256 feeAsset, uint256 feeQuote, uint256 invariantGrowth) {
        (HyperPool storage pool, HyperPosition storage pos) = (pools[args.poolId], positions[args.owner][args.poolId]);

        (feeAsset, feeQuote, invariantGrowth) = pos.syncPositionFees(
            pool.feeGrowthGlobalAsset,
            pool.feeGrowthGlobalQuote,
            pool.invariantGrowthGlobal
        );

        _changePosition(args);
    }

    /** @dev Changes position liquidity and timestamp. */
    function _changePosition(ChangeLiquidityParams memory args) internal {
        HyperPosition storage position = positions[args.owner][args.poolId];

        if (args.deltaLiquidity < 0) {
            uint256 distance = position.getTimeSinceChanged(block.timestamp);
            if (pools[args.poolId].params.jit > distance) revert JitLiquidity(distance);
        }

        position.changePositionLiquidity(args.timestamp, args.deltaLiquidity);

        _changePool(args);
    }

    /** @dev Changes virtual reserves and pool liquidity. Does not update timestamp of pool. */
    function _changePool(ChangeLiquidityParams memory args) internal {
        (address asset, address quote) = (args.tokenAsset, args.tokenQuote);

        pools[args.poolId].changePoolLiquidity(args.deltaLiquidity);

        if (args.deltaLiquidity < 0) {
            _decreaseReserves(asset, args.deltaAsset);
            _decreaseReserves(quote, args.deltaQuote);
        } else {
            // note: Reserves are used at the end of instruction processing to interactions transactions.
            _increaseReserves(asset, args.deltaAsset);
            _increaseReserves(quote, args.deltaQuote);
        }
    }

    // ===== Swaps ===== //

    function _swapExactIn(
        Order memory args
    ) internal returns (uint64 poolId, uint256 remainder, uint256 input, uint256 output) {
        if (args.input == 0) revert ZeroInput();

        uint256 minAmountOut = args.output;
        bool sellAsset = args.direction == 0;

        HyperPool memory pool = pools[args.poolId];
        if (block.timestamp > pool.params.maturity()) revert PoolExpired();
        if (args.useMax == 0) {
            input = args.input;
        } else {
            address tokenInput = sellAsset ? pool.pair.tokenAsset : pool.pair.tokenQuote;
            input = getBalance(msg.sender, tokenInput);
        }

        uint256 passed = getTimePassed(args.poolId);
        (output, ) = pool.getPoolAmountOut(sellAsset, input, passed);

        args.input = input.safeCastTo128();
        args.output = output.safeCastTo128();

        (poolId, remainder, input, output) = _swap(args);

        if (minAmountOut > args.output) revert SwapLimitReached();
    }

    /** @dev Swaps in direction (0 or 1) input of tokens (0 = asset, 1 = quote) for output of tokens (0 = quote, 1 = asset). */
    function _swap(
        Order memory args
    ) internal returns (uint64 poolId, uint256 remainder, uint256 input, uint256 output) {
        if (args.input == 0) revert ZeroInput();

        HyperPool storage pool = pools[args.poolId];
        if (!pool.exists()) revert NonExistentPool(args.poolId);

        _state.sell = args.direction == 0; // 0: asset -> quote, 1: quote -> asset
        _state.fee = msg.sender == pool.controller ? pool.params.priorityFee : uint256(pool.params.fee);
        _state.feeGrowthGlobal = _state.sell ? pool.feeGrowthGlobalAsset : pool.feeGrowthGlobalQuote;
        _state.tokenInput = _state.sell ? pool.pair.tokenAsset : pool.pair.tokenQuote;
        _state.tokenOutput = _state.sell ? pool.pair.tokenQuote : pool.pair.tokenAsset;

        Price.RMM memory rmm = pool.getRMM();
        Iteration memory iteration;
        {
            (, int256 invariant, uint256 updatedTau) = _computeSyncedPrice(args.poolId);
            rmm.tau = updatedTau;

            uint256 internalBalance = getBalance(msg.sender, _state.sell ? pool.pair.tokenAsset : pool.pair.tokenQuote);
            remainder = args.useMax == 1 ? internalBalance : args.input;
            remainder = remainder.scaleToWad(_state.sell ? pool.pair.decimalsAsset : pool.pair.decimalsQuote);
            output = args.output;
            output = output.scaleToWad(_state.sell ? pool.pair.decimalsQuote : pool.pair.decimalsAsset);

            // Keeps WAD values
            iteration = Iteration({
                virtualX: 0,
                virtualY: 0,
                invariant: invariant,
                feeAmount: 0,
                remainder: remainder,
                liquidity: pool.liquidity,
                input: 0,
                output: output
            });

            (iteration.virtualX, iteration.virtualY) = pool.getAmountsWad();
        }

        if (rmm.tau == 0) revert PoolExpired();
        if (iteration.output == 0) revert ZeroOutput();
        if (iteration.remainder == 0) revert ZeroInput();
        if (iteration.liquidity == 0) revert ZeroLiquidity();

        // =---= Effects =---= //

        // These are WAD values.
        uint256 liveIndependent;
        uint256 nextIndependent;
        uint256 liveDependent;
        uint256 nextDependent;

        {
            uint256 maxInput;
            uint256 deltaInput;
            uint256 deltaInputLessFee;
            uint256 deltaOutput = iteration.output;

            // Virtual reserves
            if (_state.sell) {
                (liveIndependent, liveDependent) = (iteration.virtualX, iteration.virtualY);
                maxInput = (FixedPointMathLib.WAD - liveIndependent).mulWadDown(iteration.liquidity); // There can be maximum 1:1 ratio between assets and liqudiity.
            } else {
                (liveDependent, liveIndependent) = (iteration.virtualX, iteration.virtualY);
                maxInput = (rmm.strike - liveIndependent).mulWadDown(iteration.liquidity); // There can be maximum strike:1 liquidity ratio between quote and liquidity.
            }

            iteration.feeAmount = ((iteration.remainder > maxInput ? maxInput : iteration.remainder) * _state.fee) / 10_000;

            deltaInput = iteration.remainder > maxInput ? maxInput : iteration.remainder; // swaps up to the maximum input
            deltaInputLessFee = deltaInput - iteration.feeAmount;

            nextIndependent = liveIndependent + deltaInputLessFee.divWadDown(iteration.liquidity);
            nextDependent = liveDependent - deltaOutput.divWadDown(iteration.liquidity);

            iteration.remainder -= deltaInput;
            iteration.input += deltaInput;
        }

        {
            int256 liveInvariantWad;
            int256 nextInvariantWad;

            if (_state.sell) {
                (iteration.virtualX, iteration.virtualY) = (nextIndependent, nextDependent);
                liveInvariantWad = iteration.invariant;
                nextInvariantWad = rmm.invariantOf(nextDependent, nextIndependent);
            } else {
                (iteration.virtualX, iteration.virtualY) = (nextDependent, nextIndependent);
                liveInvariantWad = iteration.invariant;
                nextInvariantWad = rmm.invariantOf(nextIndependent, nextDependent);
            }

            iteration.invariant = int128(nextInvariantWad);

            // todo: improve documentation for scaling invariant down, e.g. you can't have a negative invariant of a fraction of a token
            liveInvariantWad = liveInvariantWad.scaleFromWadDownSigned(pool.pair.decimalsQuote); // invariant is denominated in quote token.
            nextInvariantWad = nextInvariantWad.scaleFromWadDownSigned(pool.pair.decimalsQuote);
            if (nextInvariantWad < liveInvariantWad) revert InvalidInvariant(liveInvariantWad, nextInvariantWad);

            // Apply priority invariant growth.
            if (msg.sender == pool.controller) {
                int256 delta = nextInvariantWad - liveInvariantWad;
                uint256 deltaAbs = uint256(delta < 0 ? -delta : delta);
                if (deltaAbs != 0) _state.invariantGrowthGlobal = deltaAbs.divWadDown(iteration.liquidity);
            }
        }

        {
            uint256 inputDec;
            uint256 outputDec;
            if (_state.sell) {
                inputDec = pool.pair.decimalsAsset;
                outputDec = pool.pair.decimalsQuote;
            } else {
                inputDec = pool.pair.decimalsQuote;
                outputDec = pool.pair.decimalsAsset;
            }

            if (iteration.invariant > 0) {
                _state.feeGrowthGlobal = FixedPointMathLib.divWadDown(iteration.feeAmount, iteration.liquidity);
            }

            iteration.input = iteration.input.scaleFromWadDown(inputDec);
            iteration.output = iteration.output.scaleFromWadDown(outputDec);
        }

        // Apply pool effects.
        _syncPool(
            args.poolId,
            iteration.virtualX,
            iteration.virtualY,
            iteration.liquidity,
            _state.sell ? _state.feeGrowthGlobal : 0,
            _state.sell ? 0 : _state.feeGrowthGlobal,
            _state.invariantGrowthGlobal
        );

        _increaseReserves(_state.tokenInput, iteration.input);
        _decreaseReserves(_state.tokenOutput, iteration.output);

        {
            uint64 id = args.poolId;
            uint256 price = getLatestPrice(id);
            emit Swap(id, price, _state.tokenInput, iteration.input, _state.tokenOutput, iteration.output, iteration.feeAmount);
        }

        delete _state;
        return (args.poolId, iteration.remainder, iteration.input, iteration.output);
    }

    /**
     * @dev Computes the price of the pool, which changes over time.
     *
     * @custom:reverts Underflows if the reserve of the input token is lower than the next one, after the next price movement.
     * @custom:reverts Underflows if current reserves of output token is less then next reserves.
     */
    function _computeSyncedPrice(
        uint64 poolId
    ) internal view returns (uint256 price, int256 invariant, uint256 updatedTau) {
        HyperPool memory pool = pools[poolId];
        if (!pool.exists()) revert NonExistentPool(poolId);
        Price.RMM memory curve = pool.getRMM();

        updatedTau = pool.computeTau(block.timestamp);
        curve.tau = updatedTau;

        (uint256 x, uint256 y) = pool.getAmountsWad();
        invariant = curve.invariantOf({R_y: y, R_x: x});
        price = curve.getPriceWithX({R_x: x});
    }

    /**
     * @dev Effects on a Pool after a successful swap order condition has been met.
     */
    function _syncPool(
        uint64 poolId,
        uint256 nextVirtualX,
        uint256 nextVirtualY,
        uint256 liquidity,
        uint256 feeGrowthGlobalAsset,
        uint256 feeGrowthGlobalQuote,
        uint256 invariantGrowthGlobal
    ) internal returns (uint256 timeDelta) {
        HyperPool storage pool = pools[poolId];

        timeDelta = getTimePassed(poolId);

        if (pool.virtualX != nextVirtualX) pool.virtualX = nextVirtualX.safeCastTo128();
        if (pool.virtualY != nextVirtualY) pool.virtualY = nextVirtualY.safeCastTo128();
        if (pool.liquidity != liquidity) pool.liquidity = liquidity.safeCastTo128();
        if (pool.lastTimestamp != block.timestamp) pool.syncPoolTimestamp(block.timestamp);

        pool.feeGrowthGlobalAsset = Assembly.computeCheckpoint(pool.feeGrowthGlobalAsset, feeGrowthGlobalAsset);
        pool.feeGrowthGlobalQuote = Assembly.computeCheckpoint(pool.feeGrowthGlobalQuote, feeGrowthGlobalQuote);
        pool.invariantGrowthGlobal = Assembly.computeCheckpoint(pool.invariantGrowthGlobal, invariantGrowthGlobal);
    }

    // ===== Initializing Pools ===== //

    function createPair(address asset, address quote) external lock interactions returns (uint24 pairId) {
        return _createPair(asset, quote);
    }

    function _createPair(address asset, address quote) internal returns (uint24 pairId) {
        if (asset == quote) revert SameTokenError();

        pairId = getPairId[asset][quote];
        if (pairId != 0) revert PairExists(pairId);

        (uint8 decimalsAsset, uint8 decimalsQuote) = (IERC20(asset).decimals(), IERC20(quote).decimals());
        if (!decimalsAsset.isBetween(Assembly.MIN_DECIMALS, Assembly.MAX_DECIMALS))
            revert InvalidDecimals(decimalsAsset);
        if (!decimalsQuote.isBetween(Assembly.MIN_DECIMALS, Assembly.MAX_DECIMALS))
            revert InvalidDecimals(decimalsQuote);

        pairId = ++getPairNonce;

        getPairId[asset][quote] = pairId; // note: order of tokens matters!
        pairs[pairId] = HyperPair({
            tokenAsset: asset,
            decimalsAsset: decimalsAsset,
            tokenQuote: quote,
            decimalsQuote: decimalsQuote
        });

        emit CreatePair(pairId, asset, quote, decimalsAsset, decimalsQuote);
    }

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
    ) external lock interactions returns (uint64 poolId) {
        return _createPool(pairId, controller, priorityFee, fee, vol, dur, jit, maxPrice, price);
    }

    /** @dev If pairId == 0, its a magic variable that uses current pair nonce. */
    function _createPool(
        uint24 pairId,
        address controller,
        uint16 priorityFee,
        uint16 fee,
        uint16 volatility,
        uint16 duration,
        uint16 jit,
        uint128 maxPrice,
        uint128 price
    ) internal returns (uint64 poolId) {
        if (price == 0) revert ZeroPrice();

        uint32 timestamp = uint256(block.timestamp).safeCastTo32();
        HyperPool memory pool;
        pool.controller = controller;
        pool.lastTimestamp = timestamp;
        bool hasController = pool.controller != address(0);
        if (hasController && priorityFee == 0) revert InvalidFee(priorityFee); // Cannot set priority to 0.

        uint24 pairNonce = pairId == 0 ? getPairNonce : pairId; // magic variable todo: fix, possible to set 0 pairId if getPairNonce is 0
        pool.pair = pairs[pairNonce];

        HyperCurve memory params = HyperCurve({
            maxPrice: maxPrice,
            jit: hasController ? jit : uint8(_liquidityPolicy()),
            fee: fee,
            duration: duration,
            volatility: volatility,
            priorityFee: hasController ? priorityFee : 0, // min fee
            createdAt: timestamp
        });
        params.validateParameters();
        pool.params = params;

        uint32 poolNonce = ++getPoolNonce;

        poolId = Enigma.encodePoolId(pairNonce, hasController, poolNonce);
        if (pools[poolId].exists()) revert PoolExists(); // todo: poolNonce always increments, so this never gets hit, remove

        (uint256 y, uint256 x) = pool.getRMM().computeReserves(price, 0); // todo: write better docs for whats going on here
        (pool.virtualY, pool.virtualX) = (y.safeCastTo128(), x.safeCastTo128());

        pools[poolId] = pool; // effect

        emit CreatePool(poolId, hasController, pool.pair.tokenAsset, pool.pair.tokenQuote, price);
    }

    function changeParameters(uint64 poolId, uint16 priorityFee, uint16 fee, uint16 jit) external lock interactions {
        HyperPool storage pool = pools[poolId];
        if (pool.controller != msg.sender) revert NotController();

        HyperCurve memory modified = pool.params;
        if (jit != 0) modified.jit = jit;
        if (fee != 0) modified.fee = fee;
        if (priorityFee != 0) modified.priorityFee = priorityFee;

        pool.changePoolParameters(modified);

        emit ChangeParameters(poolId, priorityFee, fee, jit);
    }

    /** @dev Overridable in tests.  */
    function _liquidityPolicy() internal view virtual returns (uint256) {
        return JUST_IN_TIME_LIQUIDITY_POLICY;
    }

    // ===== Accounting System ===== //
    /**
     * @dev Reserves are an internally tracked amount of tokens that should match the return value of `balanceOf`.
     *
     * @custom:security Directly manipulates reserves.
     */
    function _increaseReserves(address token, uint256 amount) internal {
        __account__.increase(token, amount);
        emit IncreaseReserveBalance(token, amount);
    }

    /**
     * @dev Reserves are an internally tracked amount of tokens that should match the return value of `balanceOf`.
     *
     * @custom:security Directly manipulates reserves.
     * @custom:reverts With `InsufficientReserve` if current reserve balance for `token` iss less than `amount`.
     */
    function _decreaseReserves(address token, uint256 amount) internal {
        __account__.decrease(token, amount);
        emit DecreaseReserveBalance(token, amount);
    }

    /**
     * @dev A positive credit is a receivable paid to the `msg.sender` internal balance.
     *      Positive credits are only applied to the internal balance of the account.
     *      Therefore, it does not require a state change for the global reserves.
     *
     * @custom:security Directly manipulates intrernal balances.
     */
    function _applyCredit(address token, uint256 amount) internal {
        __account__.credit(msg.sender, token, amount);
        emit IncreaseUserBalance(msg.sender, token, amount);
    }

    /**
     * @dev A positive debit is a cost that must be paid for a transaction to be processed.
     *      If a balance exists for the token for the internal balance of `msg.sender`,
     *      it will be used to pay the debit. Else, the contract expects tokens to be transferred in.
     *
     * @custom:security Directly manipulates intrernal balances.
     */
    function _applyDebit(address token, uint256 amount) internal {
        __account__.debit(msg.sender, token, amount);
        emit DecreaseUserBalance(msg.sender, token, amount);
    }

    /**
     * @dev Alternative entrypoint to execute functions.
     * @param data Encoded Enigma data. First byte must be an Enigma instruction.
     */
    function _process(bytes calldata data) internal {
        (, bytes1 instruction) = Assembly.separate(data[0]); // Upper byte is useMax, lower byte is instruction.

        if (instruction == Enigma.ALLOCATE) {
            (uint8 useMax, uint64 poolId, uint128 deltaLiquidity) = Enigma.decodeAllocate(data);
            _allocate(useMax == 1, poolId, deltaLiquidity);
        } else if (instruction == Enigma.UNALLOCATE) {
            (uint8 useMax, uint64 poolId, uint128 deltaLiquidity) = Enigma.decodeUnallocate(data);
            _unallocate(useMax == 1, poolId, deltaLiquidity);
        } else if (instruction == Enigma.SWAP) {
            Order memory args;
            (args.useMax, args.poolId, args.input, args.output, args.direction) = Enigma.decodeSwap(data);
            _swap(args);
        } else if (instruction == Enigma.CREATE_POOL) {
            (
                uint24 pairId,
                address controller,
                uint16 priorityFee,
                uint16 fee,
                uint16 vol,
                uint16 dur,
                uint16 jit,
                uint128 maxPrice,
                uint128 price
            ) = Enigma.decodeCreatePool(data);
            _createPool(pairId, controller, priorityFee, fee, vol, dur, jit, maxPrice, price);
        } else if (instruction == Enigma.CREATE_PAIR) {
            (address asset, address quote) = Enigma.decodeCreatePair(data);
            _createPair(asset, quote);
        } else {
            revert InvalidInstruction();
        }
    }

    /**

        Be aware of these settlement invariants:

        Invariant 1. Every token that is interacted with is cached and exists.
        Invariant 2. Tokens are removed from cache, and cache is empty by end of settlement.
        Invariant 3. Cached tokens cannot be carried over from previous transactions.
        Invariant 4. Execution does not exit during the loops prematurely.
        Invariant 5. Account `settled` bool is set to true at end of `settlement`.
        Invariant 6. Debits reduce `reserves` of `token`.

     */
    function _settlement() internal {
        if (!__account__.prepared) revert OS.NotPreparedToSettle();

        address[] memory tokens = __account__.warm;
        uint256 loops = tokens.length;
        if (loops == 0) return __account__.reset(); // exit early.

        uint256 x;
        uint256 i = loops;
        do {
            // Loop backwards to pop tokens off.
            address token = tokens[i - 1];
            // Apply credits or debits to net balance.
            (uint256 credited, uint256 debited, uint256 remainder) = __account__.settle(token, address(this));
            // Reserves were increased, we paid a debit, therefore need to decrease reserves by `debited` amount.
            if (debited > 0) {
                emit DecreaseUserBalance(msg.sender, token, debited);
                emit DecreaseReserveBalance(token, debited);
            }
            // Reserves were not tracking some tokens, increase the reserves to account for them.
            if (credited > 0) {
                emit IncreaseUserBalance(msg.sender, token, credited);
                emit IncreaseReserveBalance(token, credited);
            }
            // Outstanding amount must be transferred in.
            if (remainder > 0) _payments.push(Payment({token: token, amount: remainder}));
            // Token accounted for.
            __account__.warm.pop();
            unchecked {
                --i;
                ++x;
            }
        } while (i != 0);

        Payment[] memory payments = _payments;

        uint256 px = payments.length;
        while (px != 0) {
            uint256 index = px - 1;
            OS.__dangerousTransferFrom__(payments[index].token, address(this), payments[index].amount);
            unchecked {
                --px;
            }
        }

        __account__.reset();
        delete _payments;
    }

    // ===== View ===== //

    /** @dev Can be manipulated. */
    function getLatestPrice(uint64 poolId) public view returns (uint256 price) {
        (price, , ) = _computeSyncedPrice(poolId);
    }

    function getTimePassed(uint64 poolId) public view returns (uint256) {
        return block.timestamp - pools[poolId].lastTimestamp;
    }

    function getVirtualReserves(uint64 poolId) public view override returns (uint128 deltaAsset, uint128 deltaQuote) {
        return pools[poolId].getPoolVirtualReserves();
    }

    function getMaxLiquidity(
        uint64 poolId,
        uint256 deltaAsset,
        uint256 deltaQuote
    ) public view override returns (uint128 deltaLiquidity) {
        return pools[poolId].getPoolMaxLiquidity(deltaAsset, deltaQuote);
    }

    function getLiquidityDeltas(
        uint64 poolId,
        int128 deltaLiquidity
    ) public view override returns (uint128 deltaAsset, uint128 deltaQuote) {
        return pools[poolId].getPoolLiquidityDeltas(deltaLiquidity);
    }

    function getAmounts(uint64 poolId) public view override returns (uint256 deltaAsset, uint256 deltaQuote) {
        return pools[poolId].getPoolAmounts();
    }

    function getAmountOut(uint64 poolId, bool sellAsset, uint256 amountIn) public view returns (uint256 output) {
        HyperPool memory pool = pools[poolId];
        (output, ) = pool.getPoolAmountOut({
            sellAsset: sellAsset,
            amountIn: amountIn,
            timeSinceUpdate: block.timestamp - pool.lastTimestamp // invariant: should not underflow.
        });
    }
}
