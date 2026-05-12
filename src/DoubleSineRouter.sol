// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

import {DoubleSineToken} from "./DoubleSineToken.sol";

/// @notice Generic ETH-entry router for the DoubleSine system. Holds no
/// state - derives the token from the PoolKey's currency1, so the same
/// router serves both ETH/TokenA and ETH/TokenB pools.
///
/// Buys: send ETH with msg.value, hook mints token and delivers it.
/// Sells: approve(router, amount), router pulls tokens via transferFrom,
/// hook burns and pays back ETH.
contract DoubleSineRouter is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable manager;

    struct CallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
        bytes hookData;
        uint256 value;
    }

    error OnlyPoolManager();
    error InvalidCallback();
    error EthTransferFailed();
    error TokenTransferFailed();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        uint256 balanceBefore = address(this).balance - msg.value;
        delta = abi.decode(
            manager.unlock(
                abi.encode(CallbackData(msg.sender, key, params, hookData, msg.value))
            ),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > balanceBefore) _sendETH(msg.sender, ethBalance - balanceBefore);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyPoolManager();

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        if (data.params.amountSpecified >= 0) revert InvalidCallback();

        if (data.params.zeroForOne) {
            // Buy: pay ETH (currency0) up front, then trigger swap.
            if (!data.key.currency0.isAddressZero()) revert InvalidCallback();
            // forge-lint: disable-next-line(unsafe-typecast)
            if (data.value != uint256(-data.params.amountSpecified)) revert InvalidCallback();
            manager.settle{value: data.value}();
        } else {
            // Sell: pull tokens from caller, settle them with the manager.
            if (data.value != 0) revert InvalidCallback();
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amountIn = uint256(-data.params.amountSpecified);
            manager.sync(data.key.currency1);
            DoubleSineToken token = DoubleSineToken(Currency.unwrap(data.key.currency1));
            if (!token.transferFrom(data.sender, address(manager), amountIn)) revert TokenTransferFailed();
            manager.settle();
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

    function _sendETH(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
