// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {DoubleSineMath} from "../src/DoubleSineMath.sol";

/// @notice Validates the constant-product curve math. Both tokens share
/// the same virtual reserve, so priceA == priceB at every state.
contract DoubleSineMathTest is Test {
    uint256 constant V0 = DoubleSineMath.VIRTUAL_ETH_INIT;
    uint256 constant K = DoubleSineMath.K;

    // ============================================================
    // Spot price
    // ============================================================

    function test_spotPrice_initial() public pure {
        // spot = V^2 / K = 1e36 / 1e42 = 1e-6 ETH per token
        uint256 p = DoubleSineMath.spotPrice(V0);
        assertEq(p, 1e12); // 1e-6 ETH in WAD = 1e12 wei (because WAD is the price denominator)
    }

    function test_spotPrice_monotonic() public pure {
        // Price strictly increases with virtualEth
        uint256 p0 = DoubleSineMath.spotPrice(V0);
        uint256 p1 = DoubleSineMath.spotPrice(V0 + 0.1 ether);
        uint256 p2 = DoubleSineMath.spotPrice(V0 + 1 ether);
        assertGt(p1, p0);
        assertGt(p2, p1);
    }

    function test_spotPrice_doublesWhenVirtualEthDoubles() public pure {
        // p(2V) = 4V^2 / K = 4 * p(V).
        uint256 p1 = DoubleSineMath.spotPrice(V0);
        uint256 p2 = DoubleSineMath.spotPrice(V0 * 2);
        // p2 == 4 * p1, with rounding tolerance
        _assertApproxRel(p2, p1 * 4, 1, "doubles");
    }

    // ============================================================
    // Both prices identical at every state (the core property)
    // ============================================================

    function test_priceA_equals_priceB_always() public pure {
        uint256[6] memory states = [V0, V0 + 1e15, V0 + 1e16, V0 * 2, V0 * 10, V0 * 100];
        for (uint256 i = 0; i < states.length; i++) {
            uint256 pA = DoubleSineMath.priceA(states[i]);
            uint256 pB = DoubleSineMath.priceB(states[i]);
            assertEq(pA, pB, "priceA != priceB");
        }
    }

    // ============================================================
    // Constant product invariant
    // ============================================================

    function test_buyPreservesK() public pure {
        uint256 ethIn = 0.1 ether;
        uint256 tokensOut = DoubleSineMath.tokensOutForEth(V0, ethIn);
        uint256 newVE = V0 + ethIn;
        uint256 newVT = K / V0 - tokensOut;
        // newVE * newVT should equal K (modulo integer rounding)
        uint256 product = newVE * newVT;
        _assertApproxRel(product, K, 10, "k invariant on buy");
    }

    function test_sellPreservesK() public pure {
        // First do a buy to move state away from initial, then sell.
        uint256 ethIn = 0.5 ether;
        uint256 tokensOut = DoubleSineMath.tokensOutForEth(V0, ethIn);
        uint256 newVE = V0 + ethIn;

        uint256 ethBack = DoubleSineMath.ethOutForTokens(newVE, tokensOut);
        // Round-trip should give back ~ethIn (up to integer rounding in two
        // separate K-divisions).
        _assertApproxRel(ethBack, ethIn, 5, "buy/sell round trip");
    }

    function test_buyMakesPriceGoUp() public pure {
        uint256 ethIn = 0.1 ether;
        uint256 p0 = DoubleSineMath.spotPrice(V0);
        uint256 p1 = DoubleSineMath.spotPrice(V0 + ethIn);
        assertGt(p1, p0, "price did not increase");
    }

    function test_sellMakesPriceGoDown() public pure {
        uint256 ethIn = 0.1 ether;
        uint256 tokensOut = DoubleSineMath.tokensOutForEth(V0, ethIn);
        uint256 newVE = V0 + ethIn;

        uint256 ethOut = DoubleSineMath.ethOutForTokens(newVE, tokensOut);
        uint256 finalVE = newVE - ethOut;
        uint256 pAfterSell = DoubleSineMath.spotPrice(finalVE);
        uint256 pPeak = DoubleSineMath.spotPrice(newVE);
        assertLt(pAfterSell, pPeak, "price did not decrease on sell");
    }

    // ============================================================
    // Concrete numbers (sanity check)
    // ============================================================

    function test_tokensOutFor_one_ETH() public pure {
        // ethIn = 1 ETH, V0 = 1 ETH:
        //   newVE = 2 ETH = 2e18
        //   oldVT = 1e42 / 1e18 = 1e24 (1M tokens)
        //   newVT = 1e42 / 2e18 = 5e23 (500k tokens)
        //   tokensOut = 5e23 (500k tokens with 18 decimals)
        uint256 out = DoubleSineMath.tokensOutForEth(V0, 1 ether);
        _assertApproxRel(out, 5e23, 1, "1 ETH -> 500k tokens");
    }

    function test_priceQuadrupledAfter_one_ETH() public pure {
        // After 1 ETH in, virtualEth = 2 ETH, price = 4 * initial.
        uint256 p0 = DoubleSineMath.spotPrice(V0);
        uint256 p1 = DoubleSineMath.spotPrice(V0 + 1 ether);
        _assertApproxRel(p1, p0 * 4, 1, "4x after 1 ETH");
    }

    // ============================================================
    // Trajectory dump for off-chain plotting
    // ============================================================

    /// Steps 0.01 ETH at a time, dumping (cumulative ETH in, virtualEth,
    /// price, tokensSoldSoFar). Copy out of the test log to plot the
    /// pump.fun-style flat-then-moonshot curve.
    function test_emitTrajectory() public pure {
        uint256 ve = V0;
        uint256 cumEth = 0;
        uint256 cumTokens = 0;
        console2.log("cumEth_wei,virtualEth_wei,spotPrice_wei,cumTokens");
        console2.log(uint256(0), ve, DoubleSineMath.spotPrice(ve), uint256(0));
        for (uint256 i = 1; i <= 50; i++) {
            uint256 ethIn = 0.05 ether;
            uint256 out = DoubleSineMath.tokensOutForEth(ve, ethIn);
            ve += ethIn;
            cumEth += ethIn;
            cumTokens += out;
            console2.log(cumEth, ve, DoubleSineMath.spotPrice(ve), cumTokens);
        }
    }

    // ============================================================
    // helpers
    // ============================================================

    function _assertApproxRel(uint256 a, uint256 b, uint256 bpsTol, string memory msg_) internal pure {
        uint256 diff = a > b ? a - b : b - a;
        if (b == 0) {
            require(diff == 0, msg_);
            return;
        }
        require(diff * 10000 <= b * bpsTol, msg_);
    }
}
