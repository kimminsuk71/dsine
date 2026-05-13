// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

import {DoubleSineMath} from "./DoubleSineMath.sol";
import {DoubleSineToken} from "./DoubleSineToken.sol";

/// @notice Single hook controlling two canonical pools: ETH/TokenA and
/// ETH/TokenB. Both pools share one constant-product virtual reserve.
///
/// Mechanism:
///   - On every swap (in either pool), virtualEth moves and the swap is
///     fully settled by the curve (BEFORE_SWAP_RETURNS_DELTA_FLAG).
///   - The pool's AMM curve is bypassed; this hook IS the AMM.
///   - Both prices update together because both are functions of virtualEth.
///   - ETH from buys and to sells flows through one shared reserve.
///   - Optional slippage protection via hookData (abi.encode(minOut)).
///
/// Pricing (see DoubleSineMath):
///   spotPrice = virtualEth^2 / K  (in WAD)
///   priceA(virtualEth) == priceB(virtualEth) always
contract DoubleSineHook is IHooks {
    IPoolManager public immutable manager;
    address public immutable router;
    DoubleSineToken public immutable tokenA;
    DoubleSineToken public immutable tokenB;
    address public immutable initializer;

    int24 public constant TICK_SPACING = 1;
    uint24 public constant POOL_FEE = 0;
    uint160 public constant INITIAL_SQRT_PRICE_X96 = 79228162514264337593543950336;

    // Trader-side fees in basis points (10000 = 100%). Skimmed before
    // the curve sees the trade size; retained in ethReserve as protocol
    // cushion. Symmetric 1%/1% matches pump.fun parity.
    uint256 public constant BUY_FEE_BPS = 100;
    uint256 public constant SELL_FEE_BPS = 100;

    PoolId public canonicalPoolA;
    PoolId public canonicalPoolB;
    bool public poolAInitialized;
    bool public poolBInitialized;

    /// Block number at which the FIRST canonical pool was initialized.
    /// Used as the anchor for the anti-snipe window; set once and never
    /// reset. Both pools (A and B) share this anchor.
    uint64 public bootstrapBlock;

    /// Anti-sniper window: number of blocks after bootstrap during which
    /// per-swap buy size is capped. 5 blocks * 12s/block ~= 60s on mainnet.
    uint64 public constant ANTI_SNIPE_BLOCKS = 5;

    /// Per-swap input ETH cap during the anti-sniper window. Matches the
    /// deployer's INITIAL_BUY_WEI default so the bootstrap self-buy passes
    /// the same cap any sniper would face.
    uint256 public constant ANTI_SNIPE_MAX_BUY_WEI = 0.001 ether;

    /// Shared virtual ETH reserve used by both A and B pools (pump.fun
    /// style constant product against DoubleSineMath.K). Both prices
    /// derive from this single value so priceA == priceB always.
    uint256 public virtualEth;
    /// Real ETH held by the hook. Always >= virtualEth - INITIAL because
    /// of accumulated buy/sell fees (extra retained beyond what the curve
    /// requires).
    uint256 public ethReserve;

    event PoolInitialized(bool isA, PoolId poolId);
    event Buy(
        address indexed sender, bool isA, uint256 ethIn, uint256 tokenOut, uint256 virtualEthAfter, uint256 priceAfter
    );
    event Sell(
        address indexed sender, bool isA, uint256 tokenIn, uint256 ethOut, uint256 virtualEthAfter, uint256 priceAfter
    );

    error OnlyPoolManager();
    error OnlyInitializer();
    error PoolAlreadyInitialized();
    error InvalidPoolShape();
    error NonCanonicalPool();
    error LiquidityDisabled();
    error ExactOutputDisabled();
    error ZeroAddress();
    error DuplicateToken();
    error InsufficientReserve();
    error TokenTransferFailed();
    error SettleFailed();
    error HookNotImplemented();
    error AntiSnipeBuyCapped();
    error Slippage();
    error InvalidHookData();
    error Int128Overflow();
    error ExactInputOverflow();
    error SystemAddressMustHaveCode();
    error InvalidInitialPrice();
    error DirectEthDisabled();
    error ZeroOutput();

    constructor(
        IPoolManager manager_,
        address router_,
        DoubleSineToken tokenA_,
        DoubleSineToken tokenB_,
        address initializer_
    ) {
        if (
            address(manager_) == address(0) || router_ == address(0) || address(tokenA_) == address(0)
                || address(tokenB_) == address(0) || initializer_ == address(0)
        ) revert ZeroAddress();
        if (
            address(manager_).code.length == 0 || router_.code.length == 0 || address(tokenA_).code.length == 0
                || address(tokenB_).code.length == 0
        ) {
            revert SystemAddressMustHaveCode();
        }
        if (address(tokenA_) == address(tokenB_)) revert DuplicateToken();
        manager = manager_;
        router = router_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        initializer = initializer_;
        virtualEth = DoubleSineMath.VIRTUAL_ETH_INIT;

        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    receive() external payable {
        if (msg.sender != address(manager)) revert DirectEthDisabled();
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(manager)) revert OnlyPoolManager();
        _;
    }

    // ============================================================
    // Hook lifecycle
    // ============================================================

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != initializer) revert OnlyInitializer();
        if (sqrtPriceX96 != INITIAL_SQRT_PRICE_X96 || tick != 0) revert InvalidInitialPrice();

        bool isA = false;
        if (Currency.unwrap(key.currency1) == address(tokenA)) {
            if (poolAInitialized) revert PoolAlreadyInitialized();
            isA = true;
        } else if (Currency.unwrap(key.currency1) == address(tokenB)) {
            if (poolBInitialized) revert PoolAlreadyInitialized();
            isA = false;
        } else {
            revert InvalidPoolShape();
        }

        if (
            Currency.unwrap(key.currency0) != address(0) || key.fee != POOL_FEE || key.tickSpacing != TICK_SPACING
                || key.hooks != IHooks(address(this))
        ) revert InvalidPoolShape();

        PoolId pid = key.toId();
        if (isA) {
            canonicalPoolA = pid;
            poolAInitialized = true;
        } else {
            canonicalPoolB = pid;
            poolBInitialized = true;
        }
        // Anchor the anti-snipe window at the FIRST pool init. The two
        // pools are deployed in the same tx in our launch path, so this
        // protects both. Don't reset on the second pool's init.
        if (bootstrapBlock == 0) {
            bootstrapBlock = uint64(block.number);
        }
        emit PoolInitialized(isA, pid);
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        _requireCanonicalPool(key);
        revert LiquidityDisabled();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        _requireCanonicalPool(key);
        revert LiquidityDisabled();
    }

    // ============================================================
    // Swap: the meat
    // ============================================================

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool isA = _classifyPool(key);
        if (params.amountSpecified >= 0) revert ExactOutputDisabled();
        if (params.amountSpecified == type(int256).min) revert ExactInputOverflow();
        uint256 amountIn = uint256(-params.amountSpecified);

        // Optional slippage protection: hookData carries one uint256
        // representing the user's minimum acceptable counterparty amount.
        //   - buy: minTokensOut
        //   - sell: minEthOut
        // Empty hookData -> minOut = 0 -> no protection (caller's choice).
        // Any non-empty value must be exactly one ABI-encoded uint256 so
        // malformed calldata cannot silently disable the caller's protection.
        if (hookData.length != 0 && hookData.length != 32) revert InvalidHookData();
        uint256 minOut = hookData.length == 32 ? abi.decode(hookData, (uint256)) : 0;

        if (params.zeroForOne) {
            // BUY: ETH -> token
            return _executeBuy(sender, key, amountIn, isA, minOut);
        } else {
            // SELL: token -> ETH
            return _executeSell(sender, key, amountIn, isA, minOut);
        }
    }

    function _executeBuy(address sender, PoolKey calldata key, uint256 ethIn, bool isA, uint256 minTokensOut)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (ethIn > uint256(uint128(type(int128).max))) revert Int128Overflow();
        // Anti-sniper cap: during the first ANTI_SNIPE_BLOCKS after pool
        // init, any single buy input is capped to ANTI_SNIPE_MAX_BUY_WEI.
        // The cap applies symmetrically to both A and B pools (one shared
        // bootstrapBlock). Sells are unaffected.
        if (uint64(block.number) - bootstrapBlock < ANTI_SNIPE_BLOCKS) {
            if (ethIn > ANTI_SNIPE_MAX_BUY_WEI) revert AntiSnipeBuyCapped();
        }

        // Skim buy fee outside the curve. The remaining ethCurve enters
        // the constant-product reserve and determines tokensOut.
        uint256 fee = _feeUp(ethIn, BUY_FEE_BPS);
        uint256 ethCurve = ethIn - fee;
        if (
            virtualEth > DoubleSineMath.MAX_SPOT_PRICE_VIRTUAL_ETH
                || ethCurve > DoubleSineMath.MAX_SPOT_PRICE_VIRTUAL_ETH - virtualEth
        ) {
            revert DoubleSineMath.SpotPriceOverflow();
        }

        uint256 tokenOut = DoubleSineMath.tokensOutForEth(virtualEth, ethCurve);
        if (tokenOut == 0) revert ZeroOutput();
        if (tokenOut > uint256(uint128(type(int128).max))) revert Int128Overflow();
        if (tokenOut < minTokensOut) revert Slippage();
        virtualEth += ethCurve;
        ethReserve += ethIn;
        emit Buy(sender, isA, ethIn, tokenOut, virtualEth, DoubleSineMath.spotPrice(virtualEth));

        // Settle on PoolManager: hook claims the user's ETH (including
        // the fee) and delivers the token.
        manager.take(key.currency0, address(this), ethIn);

        DoubleSineToken token = isA ? tokenA : tokenB;
        token.mint(address(this), tokenOut);
        _settleToken(key.currency1, token, tokenOut);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toPositiveInt128(ethIn), _toNegativeInt128(tokenOut)), 0);
    }

    function _executeSell(address sender, PoolKey calldata key, uint256 tokenIn, bool isA, uint256 minEthOut)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (tokenIn > uint256(uint128(type(int128).max))) revert Int128Overflow();
        // Curve gives the gross ETH for these tokens at current state.
        uint256 ethGross = DoubleSineMath.ethOutForTokens(virtualEth, tokenIn);
        if (ethGross == 0) revert ZeroOutput();
        uint256 fee = _feeUp(ethGross, SELL_FEE_BPS);
        uint256 ethOut = ethGross - fee;
        if (ethOut == 0) revert ZeroOutput();
        if (ethOut > uint256(uint128(type(int128).max))) revert Int128Overflow();
        if (ethOut < minEthOut) revert Slippage();

        // The curve is "owed" ethGross worth of ETH. Don't let the seller
        // pull more real ETH than the hook actually holds.
        if (ethOut > ethReserve) revert InsufficientReserve();

        virtualEth -= ethGross;
        ethReserve -= ethOut;
        emit Sell(sender, isA, tokenIn, ethOut, virtualEth, DoubleSineMath.spotPrice(virtualEth));

        // Take token in, burn it. Total supply contracts on sells.
        DoubleSineToken token = isA ? tokenA : tokenB;
        manager.take(key.currency1, address(this), tokenIn);
        token.burn(address(this), tokenIn);

        if (manager.settle{value: ethOut}() != ethOut) revert SettleFailed();

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toPositiveInt128(tokenIn), _toNegativeInt128(ethOut)), 0);
    }

    // ============================================================
    // Required IHooks no-ops (we don't use these flows)
    // ============================================================

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ============================================================
    // Views
    // ============================================================

    function currentPriceA() external view returns (uint256) {
        return DoubleSineMath.priceA(virtualEth);
    }

    function currentPriceB() external view returns (uint256) {
        return DoubleSineMath.priceB(virtualEth);
    }

    // ============================================================
    // Internals
    // ============================================================

    function _classifyPool(PoolKey calldata key) internal view returns (bool isA) {
        PoolId pid = key.toId();
        if (poolAInitialized && PoolId.unwrap(pid) == PoolId.unwrap(canonicalPoolA)) return true;
        if (poolBInitialized && PoolId.unwrap(pid) == PoolId.unwrap(canonicalPoolB)) return false;
        revert NonCanonicalPool();
    }

    function _requireCanonicalPool(PoolKey calldata key) internal view {
        PoolId pid = key.toId();
        bool ok = (poolAInitialized && PoolId.unwrap(pid) == PoolId.unwrap(canonicalPoolA))
            || (poolBInitialized && PoolId.unwrap(pid) == PoolId.unwrap(canonicalPoolB));
        if (!ok) revert NonCanonicalPool();
    }

    function _settleToken(Currency currency, DoubleSineToken token, uint256 amount) internal {
        if (amount == 0) return;
        manager.sync(currency);
        if (!token.transfer(address(manager), amount)) revert TokenTransferFailed();
        if (manager.settle() != amount) revert SettleFailed();
    }

    // BeforeSwapDelta helpers - safe int128 casts.
    function _toPositiveInt128(uint256 v) internal pure returns (int128) {
        if (v > uint256(uint128(type(int128).max))) revert Int128Overflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(int256(v));
    }

    function _toNegativeInt128(uint256 v) internal pure returns (int128) {
        if (v > uint256(uint128(type(int128).max))) revert Int128Overflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        return -int128(int256(v));
    }

    function _feeUp(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (amount == 0 || bps == 0) return 0;
        return ((amount * bps) - 1) / 10000 + 1;
    }
}
