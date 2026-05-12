// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Constant-product bonding curve shared by TokenA and TokenB.
///
/// The hook maintains ONE virtual reserve pair (virtualEth, virtualTokens)
/// that BOTH tokens trade against. Buying either A or B pulls tokens out
/// of the same virtual reserve and pushes ETH in; selling either A or B
/// does the reverse. Because both tokens read the spot price from the
/// same (virtualEth, virtualTokens) state, priceA == priceB at every block.
///
/// Pricing follows pump.fun-style virtual constant product:
///   virtualEth * virtualTokens = K  (invariant)
///   spotPrice = virtualEth / virtualTokens  (ETH per token, in WAD)
///
/// Curve seeding (compile-time, tweak before deploy):
///   VIRTUAL_ETH_INIT    = 1 ETH
///   VIRTUAL_TOKEN_INIT  = 1,000,000 tokens (1e6 with 18 decimals = 1e24)
///   K = 1e18 * 1e24 = 1e42
///   Starting price = 1e-6 ETH per token (= 1 microETH = 1000 gwei)
///
/// Shape: flat at first, parabolic upward as buys accumulate. Spot price
/// at virtualEth = V is V^2 / K. Doubles every time virtualEth doubles.
library DoubleSineMath {
    uint256 internal constant WAD = 1e18;

    // Virtual reserve seeds. Hook initializes its state to these on deploy.
    uint256 internal constant VIRTUAL_ETH_INIT   = 1e18;     // 1 ETH
    uint256 internal constant VIRTUAL_TOKEN_INIT = 1e24;     // 1M tokens (18 decimals)
    uint256 internal constant K                  = VIRTUAL_ETH_INIT * VIRTUAL_TOKEN_INIT; // 1e42

    // ============================================================
    // Pure curve math (no state)
    // ============================================================

    /// Spot price in WAD: ETH per token at the given virtualEth.
    ///   priceWAD = (virtualEth / virtualTokens) * WAD
    ///           = virtualEth^2 * WAD / K
    /// Both virtualEth and virtualTokens are 1e18-scaled, so the raw ratio
    /// already represents ETH-per-token; we scale by WAD for fixed-point.
    function spotPrice(uint256 virtualEth) internal pure returns (uint256) {
        return (virtualEth * virtualEth * WAD) / K;
    }

    /// Tokens minted out for ethIn pushed into the curve.
    ///   tokensOut = oldVirtualTokens - newVirtualTokens
    ///             = K/virtualEth - K/(virtualEth + ethIn)
    ///             = K * ethIn / (virtualEth * (virtualEth + ethIn))
    function tokensOutForEth(uint256 virtualEth, uint256 ethIn) internal pure returns (uint256) {
        uint256 newVE = virtualEth + ethIn;
        return (K * ethIn) / (virtualEth * newVE);
    }

    /// ETH paid out for tokensIn burned from the curve.
    ///   ethOut = virtualEth - newVirtualEth
    ///          = virtualEth - K/(K/virtualEth + tokensIn)
    function ethOutForTokens(uint256 virtualEth, uint256 tokensIn) internal pure returns (uint256) {
        uint256 oldVT = K / virtualEth;
        uint256 newVT = oldVT + tokensIn;
        uint256 newVE = K / newVT;
        return virtualEth - newVE;
    }

    /// Convenience aliases - both tokens share one price function so the
    /// hook can call priceA / priceB and naturally get identical values.
    function priceA(uint256 virtualEth) internal pure returns (uint256) {
        return spotPrice(virtualEth);
    }

    function priceB(uint256 virtualEth) internal pure returns (uint256) {
        return spotPrice(virtualEth);
    }
}
