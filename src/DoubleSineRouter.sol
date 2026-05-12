// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

import {DoubleSineToken} from "./DoubleSineToken.sol";
import {IDoubleSineHookBinding} from "./IDoubleSineHookBinding.sol";

/// @notice ETH-entry router for one DoubleSine system. The deployer binds
/// tokenA/tokenB plus the canonical hook exactly once, then the router
/// rejects any non-canonical PoolKey before touching user tokens or entering
/// PoolManager.
///
/// Buys: send ETH with msg.value, hook mints token and delivers it.
/// Sells: approve(router, amount), router pulls tokens via transferFrom,
/// hook burns and pays back ETH.
contract DoubleSineRouter is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable manager;
    DoubleSineToken public tokenA;
    DoubleSineToken public tokenB;
    address public hook;
    address private binder;

    int24 public constant TICK_SPACING = 1;
    uint24 public constant POOL_FEE = 0;
    uint160 internal constant REQUIRED_HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    struct CallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
        bytes hookData;
        uint256 value;
    }

    error OnlyPoolManager();
    error NotBinder();
    error AlreadyBound();
    error InvalidCallback();
    error InvalidBinding();
    error HookMustHaveCode();
    error ZeroAddress();
    error UnsupportedPool();
    error UnsupportedToken();
    error TokensNotBound();
    error SettleFailed();
    error EthTransferFailed();
    error TokenTransferFailed();

    constructor(IPoolManager manager_) {
        if (address(manager_) == address(0)) revert ZeroAddress();
        manager = manager_;
        binder = msg.sender;
    }

    receive() external payable {}

    function bindSystem(DoubleSineToken tokenA_, DoubleSineToken tokenB_, address hook_) external {
        if (address(tokenA) != address(0)) revert AlreadyBound();
        if (msg.sender != binder) revert NotBinder();
        if (address(tokenA_) == address(0) || address(tokenB_) == address(0) || hook_ == address(0)) {
            revert ZeroAddress();
        }
        if (hook_.code.length == 0) revert HookMustHaveCode();
        if ((uint160(hook_) & Hooks.ALL_HOOK_MASK) != REQUIRED_HOOK_FLAGS) revert InvalidBinding();
        if (address(tokenA_) == address(tokenB_)) revert UnsupportedToken();
        if (
            tokenA_.poolManager() != address(manager) || tokenB_.poolManager() != address(manager)
                || tokenA_.router() != address(this) || tokenB_.router() != address(this)
        ) revert InvalidBinding();
        (address hookManager, address hookTokenA, address hookTokenB) = _readHookBinding(hook_);
        if (hookManager != address(manager) || hookTokenA != address(tokenA_) || hookTokenB != address(tokenB_)) {
            revert InvalidBinding();
        }
        tokenA = tokenA_;
        tokenB = tokenB_;
        hook = hook_;
        binder = address(0);
    }

    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        if (params.amountSpecified >= 0) revert InvalidCallback();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountIn = uint256(-params.amountSpecified);

        DoubleSineToken token = _tokenFromKey(key);

        if (params.zeroForOne) {
            if (msg.value != amountIn) revert InvalidCallback();
        } else {
            if (msg.value != 0) revert InvalidCallback();
        }

        uint256 balanceBefore = address(this).balance - msg.value;

        if (!params.zeroForOne) {
            if (!token.transferFrom(msg.sender, address(this), amountIn)) revert TokenTransferFailed();
        }

        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, key, params, hookData, msg.value))), (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > balanceBefore) _sendETH(msg.sender, ethBalance - balanceBefore);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyPoolManager();

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        if (data.params.amountSpecified >= 0) revert InvalidCallback();
        DoubleSineToken token = _tokenFromKey(data.key);

        if (data.params.zeroForOne) {
            // Buy: pay ETH (currency0) up front, then trigger swap.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (data.value != uint256(-data.params.amountSpecified)) revert InvalidCallback();
            if (manager.settle{value: data.value}() != data.value) revert SettleFailed();
        } else {
            // Sell: tokens were already pulled from the caller before unlock;
            // settle the router-held tokens with the manager.
            if (data.value != 0) revert InvalidCallback();
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amountIn = uint256(-data.params.amountSpecified);
            manager.sync(data.key.currency1);
            if (!token.transfer(address(manager), amountIn)) revert TokenTransferFailed();
            if (manager.settle() != amountIn) revert SettleFailed();
        }

        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);
        _settleDeltas(data, delta);
        return abi.encode(delta);
    }

    function _settleDeltas(CallbackData memory data, BalanceDelta delta) internal {
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        if (amount0 > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            manager.take(data.key.currency0, data.sender, uint128(amount0));
        }
        if (amount1 > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            manager.take(data.key.currency1, data.sender, uint128(amount1));
        }

        if (amount0 < 0 && !data.key.currency0.isAddressZero()) revert InvalidCallback();
        if (amount1 < 0 && data.key.currency1.isAddressZero()) revert InvalidCallback();
    }

    function _tokenFromKey(PoolKey memory key) internal view returns (DoubleSineToken token) {
        if (address(tokenA) == address(0)) revert TokensNotBound();
        if (
            !key.currency0.isAddressZero() || key.fee != POOL_FEE || key.tickSpacing != TICK_SPACING
                || address(key.hooks) != hook
        ) revert UnsupportedPool();
        address currency1 = Currency.unwrap(key.currency1);
        if (currency1 == address(tokenA)) return tokenA;
        if (currency1 == address(tokenB)) return tokenB;
        revert UnsupportedToken();
    }

    function _sendETH(address to, uint256 amount) internal {
        // slither-disable-next-line low-level-calls
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    function _readHookBinding(address hook_)
        private
        view
        returns (address hookManager, address hookTokenA, address hookTokenB)
    {
        IDoubleSineHookBinding hookBinding = IDoubleSineHookBinding(hook_);
        try hookBinding.manager() returns (address manager_) {
            hookManager = manager_;
        } catch {
            revert InvalidBinding();
        }
        try hookBinding.tokenA() returns (address tokenA_) {
            hookTokenA = tokenA_;
        } catch {
            revert InvalidBinding();
        }
        try hookBinding.tokenB() returns (address tokenB_) {
            hookTokenB = tokenB_;
        } catch {
            revert InvalidBinding();
        }
    }
}
