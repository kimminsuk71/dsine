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
/// at virtualEth = V is V^2 / K. Quadruples every time virtualEth doubles.
library DoubleSineMath {
    uint256 internal constant WAD = 1e18;

    // Virtual reserve seeds. Hook initializes its state to these on deploy.
    uint256 internal constant VIRTUAL_ETH_INIT = 1e18; // 1 ETH
    uint256 internal constant VIRTUAL_TOKEN_INIT = 1e24; // 1M tokens (18 decimals)
    uint256 internal constant K = VIRTUAL_ETH_INIT * VIRTUAL_TOKEN_INIT; // 1e42
    uint256 internal constant PRICE_DENOMINATOR = K / WAD; // 1e24

    // Largest virtualEth that can be squared before division without
    // overflowing uint256.
    uint256 internal constant MAX_SPOT_PRICE_VIRTUAL_ETH = uint256(type(uint128).max);

    error InvalidVirtualEth();
    error VirtualEthOverflow();
    error VirtualTokenOverflow();
    error SpotPriceOverflow();

    // ============================================================
    // Pure curve math (no state)
    // ============================================================

    /// Spot price in WAD: ETH per token at the given virtualEth.
    ///   priceWAD = (virtualEth / virtualTokens) * WAD
    ///           = virtualEth^2 * WAD / K
    ///           = virtualEth^2 / PRICE_DENOMINATOR
    /// Both virtualEth and virtualTokens are 1e18-scaled, so the raw ratio
    /// already represents ETH-per-token; we scale by WAD for fixed-point.
    function spotPrice(uint256 virtualEth) internal pure returns (uint256) {
        if (virtualEth > MAX_SPOT_PRICE_VIRTUAL_ETH) revert SpotPriceOverflow();
        return (virtualEth * virtualEth) / PRICE_DENOMINATOR;
    }

    /// Tokens minted out for ethIn pushed into the curve.
    ///   tokensOut = oldVirtualTokens - newVirtualTokens
    ///             = floor(K/virtualEth) - ceil(K/(virtualEth + ethIn))
    ///
    /// The second division rounds up so integer dust cannot overpay the
    /// trader by one wei-token when K is not evenly divisible by newVE.
    function tokensOutForEth(uint256 virtualEth, uint256 ethIn) internal pure returns (uint256) {
        if (virtualEth == 0) revert InvalidVirtualEth();
        if (ethIn > type(uint256).max - virtualEth) revert VirtualEthOverflow();
        if (ethIn == 0) return 0;
        uint256 newVE = virtualEth + ethIn;
        uint256 oldVT = K / virtualEth;
        uint256 newVT = _divUp(K, newVE);
        if (newVT >= oldVT) return 0;
        return oldVT - newVT;
    }

    /// ETH paid out for tokensIn burned from the curve.
    ///   ethOut = virtualEth - newVirtualEth
    ///          = virtualEth - ceil(K/(floor(K/virtualEth) + tokensIn))
    ///
    /// The final virtualEth rounds up so token dust cannot claim one wei
    /// of ETH when its exact curve value is below one wei.
    function ethOutForTokens(uint256 virtualEth, uint256 tokensIn) internal pure returns (uint256) {
        if (virtualEth == 0) revert InvalidVirtualEth();
        if (tokensIn == 0) return 0;
        uint256 oldVT = K / virtualEth;
        if (tokensIn > type(uint256).max - oldVT) revert VirtualTokenOverflow();
        uint256 newVT = oldVT + tokensIn;
        uint256 newVE = _divUp(K, newVT);
        if (newVE >= virtualEth) return 0;
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

    function _divUp(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return numerator == 0 ? 0 : ((numerator - 1) / denominator) + 1;
    }
}
