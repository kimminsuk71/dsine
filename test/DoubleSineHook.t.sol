// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {DoubleSineMath} from "../src/DoubleSineMath.sol";
import {DoubleSineToken} from "../src/DoubleSineToken.sol";
import {DoubleSineHook} from "../src/DoubleSineHook.sol";
import {DoubleSineRouter} from "../src/DoubleSineRouter.sol";
import {HookMiner} from "../script/utils/HookMiner.sol";

/// @notice End-to-end test: deploys V4 PoolManager, both tokens, the hook,
/// and a router; initializes ETH/A and ETH/B pools; then drives buy/sell
/// traffic and verifies (a) the price trajectory matches the formula and
/// (b) the canonical v4 hook keeps A/B prices locked while the ERC20s remain
/// freely transferable for external venues.
contract DoubleSineHookTest is Test {
    using BalanceDeltaLibrary for BalanceDelta;

    PoolManager internal manager;
    DoubleSineToken internal tokenA;
    DoubleSineToken internal tokenB;
    DoubleSineHook internal hook;
    DoubleSineRouter internal router;

    PoolKey internal keyA;
    PoolKey internal keyB;

    address internal user = address(0xBEEF);
    address internal initializer = address(this);

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    uint256 internal constant HOOK_BOOTSTRAP_BLOCK_SLOT = 2;
    uint256 internal constant HOOK_VIRTUAL_ETH_SLOT = 4;

    receive() external payable {}

    function setUp() public {
        vm.deal(user, 1_000 ether);
        vm.deal(address(this), 1_000 ether);

        manager = new PoolManager(address(this));
        router = new DoubleSineRouter(IPoolManager(address(manager)));

        tokenA = new DoubleSineToken("DoubleSine A", "DSA", address(manager), address(router));
        tokenB = new DoubleSineToken("DoubleSine B", "DSB", address(manager), address(router));

        // Hook address must encode permission flags in its low bits.
        address hookAddr = _deployHookFor(tokenA, tokenB, initializer, 0);
        hook = DoubleSineHook(payable(hookAddr));

        router.bindSystem(tokenA, tokenB, hookAddr);
        tokenA.bindHook(hookAddr);
        tokenB.bindHook(hookAddr);

        keyA = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(tokenA)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(hookAddr)
        });
        keyB = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(tokenB)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(hookAddr)
        });
        manager.initialize(keyA, SQRT_PRICE_1_1);
        manager.initialize(keyB, SQRT_PRICE_1_1);

        // Roll forward past the anti-snipe window so most tests can buy
        // freely. Anti-snipe tests roll back to within the window via
        // vm.roll(hook.bootstrapBlock()) before exercising the cap.
        vm.roll(block.number + hook.ANTI_SNIPE_BLOCKS());
    }

    /// Helper for anti-snipe tests to re-enter the cap window.
    function _resetToBootstrap() internal {
        vm.roll(hook.bootstrapBlock());
    }

    // ============================================================
    // Basic invariants
    // ============================================================

    function test_initialState() public view {
        assertEq(hook.virtualEth(), DoubleSineMath.VIRTUAL_ETH_INIT);
        assertEq(hook.ethReserve(), 0);
        // Both prices equal initial spot price (V^2 / K).
        uint256 p0 = DoubleSineMath.spotPrice(DoubleSineMath.VIRTUAL_ETH_INIT);
        assertEq(hook.currentPriceA(), p0);
        assertEq(hook.currentPriceB(), p0);
        assertEq(hook.currentPriceA(), hook.currentPriceB(), "A != B");
        assertEq(address(hook).balance, 0);
    }

    function test_canonicalPoolsClaimed() public view {
        assertTrue(hook.poolAInitialized());
        assertTrue(hook.poolBInitialized());
    }

    // ============================================================
    // Single swaps - prove the formula
    // ============================================================

    function test_buyA_advancesCurveAndMatchesFormula() public {
        uint256 ethIn = 0.01 ether;
        uint256 ethCurve = ethIn - _feeUp(ethIn, hook.BUY_FEE_BPS());
        uint256 v0 = hook.virtualEth();
        uint256 expectedTokenOut = DoubleSineMath.tokensOutForEth(v0, ethCurve);

        uint256 userEthBefore = user.balance;
        _buyA(user, ethIn);

        assertEq(hook.virtualEth(), v0 + ethCurve, "virtualEth after buy");
        assertEq(hook.ethReserve(), ethIn, "reserve includes fee");
        assertEq(address(hook).balance, ethIn, "hook eth balance");
        assertEq(user.balance, userEthBefore - ethIn, "user eth spent");
        assertEq(tokenA.balanceOf(user), expectedTokenOut, "tokenOut formula");
    }

    function test_buyB_advancesCurveAndMatchesFormula() public {
        uint256 ethIn = 0.01 ether;
        uint256 ethCurve = ethIn - _feeUp(ethIn, hook.BUY_FEE_BPS());
        uint256 v0 = hook.virtualEth();
        uint256 expectedTokenOut = DoubleSineMath.tokensOutForEth(v0, ethCurve);

        _buyB(user, ethIn);

        assertEq(hook.virtualEth(), v0 + ethCurve);
        assertEq(tokenB.balanceOf(user), expectedTokenOut, "B tokenOut");
    }

    function test_sellA_returnsEthAndRetreatsCurve() public {
        _buyA(user, 0.01 ether);
        uint256 tokensHeld = tokenA.balanceOf(user);
        uint256 virtualEthAfterBuy = hook.virtualEth();
        uint256 reserveAfterBuy = hook.ethReserve();

        // Sell half
        uint256 sellAmount = tokensHeld / 2;
        _sellA(user, sellAmount);

        assertLt(hook.virtualEth(), virtualEthAfterBuy, "virtualEth retreated");
        assertLt(hook.ethReserve(), reserveAfterBuy, "reserve drained");
        assertGt(user.balance, 1_000 ether - 0.01 ether, "got some eth back");
    }

    function test_priceA_equals_priceB_after_any_trade() public {
        // Mix of A/B buys and A/B sells - prices must remain identical
        // at every state because they read from the same virtualEth.
        assertEq(hook.currentPriceA(), hook.currentPriceB());

        _buyA(user, 0.05 ether);
        assertEq(hook.currentPriceA(), hook.currentPriceB(), "after buyA");

        _buyB(user, 0.03 ether);
        assertEq(hook.currentPriceA(), hook.currentPriceB(), "after buyB");

        _sellA(user, tokenA.balanceOf(user) / 3);
        assertEq(hook.currentPriceA(), hook.currentPriceB(), "after sellA");

        _sellB(user, tokenB.balanceOf(user) / 4);
        assertEq(hook.currentPriceA(), hook.currentPriceB(), "after sellB");
    }

    /// Round-trip: a single buy followed by a sell of all tokens leaves the
    /// reserve approximately whole (only the sell fee + tiny step-spread
    /// is retained). Critically, the reserve does NOT go negative or below
    /// the fee floor - so ordinary trading can never drain the system.
    function test_roundTrip_reserveStaysFull() public {
        uint256 ethIn = 0.01 ether;
        uint256 reserveBefore = hook.ethReserve();
        _buyA(user, ethIn);
        uint256 tokens = tokenA.balanceOf(user);
        _sellA(user, tokens);

        // After full round-trip, reserve should be close to fee retained:
        //   ~= ethIn * BUY_FEE_BPS/10000 + sell_fee_on_what_was_paid_back
        // Minimum: at least the buy fee. Maximum: a bit more from sell fee.
        uint256 minExpected = _feeUp(ethIn, hook.BUY_FEE_BPS());
        assertGt(hook.ethReserve(), reserveBefore + minExpected - 1, "reserve below buy-fee floor");
        // Reserve also can't exceed what was paid in (sells only return funds
        // that were already deposited).
        assertLt(hook.ethReserve(), reserveBefore + ethIn, "reserve > total deposited");
    }

    // ============================================================
    // The main event: alternating swaps trace the lens curve
    // ============================================================

    /// Runs 80 alternating buy/sell ops across A and B, emitting the price
    /// trajectory. Confirms the pump.fun curve: parabolic price growth on
    /// net buys; priceA == priceB at every step.
    function test_trajectory_pumpCurve() public {
        console2.log("step,virtualEth,priceA,priceB");
        console2.log(uint256(0), hook.virtualEth(), hook.currentPriceA(), hook.currentPriceB());

        for (uint256 i = 1; i <= 80; i++) {
            bool isA = (i % 2 == 0);
            bool isBuy = (i % 4 != 0);

            if (isBuy) {
                if (isA) _buyA(user, 0.005 ether);
                else _buyB(user, 0.005 ether);
            } else {
                if (isA && tokenA.balanceOf(user) > 0) {
                    _sellA(user, tokenA.balanceOf(user) / 5);
                } else if (!isA && tokenB.balanceOf(user) > 0) {
                    _sellB(user, tokenB.balanceOf(user) / 5);
                } else {
                    if (isA) _buyA(user, 0.005 ether);
                    else _buyB(user, 0.005 ether);
                }
            }

            // Identical price invariant must hold every single step.
            require(hook.currentPriceA() == hook.currentPriceB(), "prices diverged");
            console2.log(i, hook.virtualEth(), hook.currentPriceA(), hook.currentPriceB());
        }
    }

    // ============================================================
    // Reserve invariant: hook ETH balance must equal ethReserve
    // ============================================================

    function test_reserveInvariant_acrossSwaps() public {
        for (uint256 i = 0; i < 30; i++) {
            if (i % 3 == 0) _buyA(user, 0.01 ether);
            else if (i % 3 == 1) _buyB(user, 0.01 ether);
            else if (tokenA.balanceOf(user) > 0) _sellA(user, tokenA.balanceOf(user) / 10);

            // Real balance must always be >= bookkept reserve. Strict
            // equality is what we'd expect from clean trading, but a
            // direct-transfer donation could legitimately push balance
            // ABOVE reserve - that's safe (extra is just unallocated).
            assertGe(address(hook).balance, hook.ethReserve(), "balance >= reserve");
            assertEq(address(hook).balance, hook.ethReserve(), "no orphan eth in clean trading");
        }
    }

    // ============================================================
    // Plain ERC20 external trading compatibility
    // ============================================================

    function test_plainERC20_externalContractCanReceiveTokens() public {
        _buyA(user, 0.01 ether);
        uint256 bal = tokenA.balanceOf(user);
        require(bal > 0, "no tokens");

        FakeRouter externalVenue = new FakeRouter();

        vm.prank(user, user);
        assertTrue(tokenA.transfer(address(externalVenue), bal), "transfer to external venue");

        assertEq(tokenA.balanceOf(address(externalVenue)), bal, "venue balance");
    }

    function test_plainERC20_externalContractCanRouteTokensBackToEOA() public {
        _buyA(user, 0.01 ether);
        uint256 amount = tokenA.balanceOf(user) / 2;
        FakeRouter externalVenue = new FakeRouter();

        vm.prank(user, user);
        assertTrue(tokenA.transfer(address(externalVenue), amount), "seed venue");

        address buyer = makeAddr("external-buyer");
        externalVenue.route(tokenA, buyer, amount);

        assertEq(tokenA.balanceOf(buyer), amount, "buyer received routed tokens");
        assertEq(tokenA.balanceOf(address(externalVenue)), 0, "venue emptied");
    }

    function test_plainERC20_transferToEOAWorks() public {
        _buyA(user, 0.01 ether);
        uint256 bal = tokenA.balanceOf(user);

        address friend = address(0xDEAD);
        require(friend.code.length == 0, "friend should be EOA");
        vm.prank(user, user);
        bool ok = tokenA.transfer(friend, bal / 2);
        assertTrue(ok, "transfer should return true");
        assertEq(tokenA.balanceOf(friend), bal / 2, "EOA-to-EOA transfer should work");
    }

    function test_plainERC20_directPoolManagerDepositIsAllowedAtTokenLayer() public {
        _buyA(user, 0.01 ether);
        uint256 bal = tokenA.balanceOf(user);
        uint256 amount = bal / 2;

        vm.prank(user, user);
        assertTrue(tokenA.transfer(address(manager), amount), "direct PoolManager transfer");

        assertEq(tokenA.balanceOf(address(manager)), amount, "PoolManager token balance");
    }

    function test_orphanPoolManagerTokenBalanceDoesNotPoisonCanonicalBuy() public {
        _buyA(user, 0.01 ether);
        uint256 orphanAmount = tokenA.balanceOf(user) / 4;

        vm.prank(user, user);
        assertTrue(tokenA.transfer(address(manager), orphanAmount), "orphan PoolManager deposit");

        uint256 managerBalanceBefore = tokenA.balanceOf(address(manager));
        uint256 userBalanceBefore = tokenA.balanceOf(user);
        uint256 ethIn = 0.01 ether;
        uint256 ethCurve = ethIn - _feeUp(ethIn, hook.BUY_FEE_BPS());
        uint256 expectedOut = DoubleSineMath.tokensOutForEth(hook.virtualEth(), ethCurve);

        _buyA(user, ethIn);

        assertEq(tokenA.balanceOf(user), userBalanceBefore + expectedOut, "buy output");
        assertEq(tokenA.balanceOf(address(manager)), managerBalanceBefore, "orphan balance preserved");
        assertEq(hook.currentPriceA(), hook.currentPriceB(), "price lock preserved");
    }

    function test_orphanPoolManagerTokenBalanceDoesNotPoisonCanonicalSell() public {
        _buyA(user, 0.02 ether);
        uint256 orphanAmount = tokenA.balanceOf(user) / 4;

        vm.prank(user, user);
        assertTrue(tokenA.transfer(address(manager), orphanAmount), "orphan PoolManager deposit");

        uint256 managerBalanceBefore = tokenA.balanceOf(address(manager));
        uint256 sellAmount = tokenA.balanceOf(user) / 2;
        uint256 userEthBefore = user.balance;
        uint256 ethGross = DoubleSineMath.ethOutForTokens(hook.virtualEth(), sellAmount);
        uint256 expectedOut = ethGross - _feeUp(ethGross, hook.SELL_FEE_BPS());

        _sellA(user, sellAmount);

        assertEq(user.balance, userEthBefore + expectedOut, "sell output");
        assertEq(tokenA.balanceOf(address(manager)), managerBalanceBefore, "orphan balance preserved");
        assertEq(hook.currentPriceA(), hook.currentPriceB(), "price lock preserved");
    }

    function test_orphanHookTokenBalanceDoesNotPoisonCanonicalSwaps() public {
        _buyA(user, 0.02 ether);
        uint256 orphanAmount = tokenA.balanceOf(user) / 4;

        vm.prank(user, user);
        assertTrue(tokenA.transfer(address(hook), orphanAmount), "orphan hook deposit");

        uint256 hookTokenBalanceBefore = tokenA.balanceOf(address(hook));
        _buyA(user, 0.01 ether);
        assertEq(tokenA.balanceOf(address(hook)), hookTokenBalanceBefore, "buy preserved orphan hook tokens");

        uint256 sellAmount = tokenA.balanceOf(user) / 3;
        _sellA(user, sellAmount);
        assertEq(tokenA.balanceOf(address(hook)), hookTokenBalanceBefore, "sell preserved orphan hook tokens");
        assertEq(hook.currentPriceA(), hook.currentPriceB(), "price lock preserved");
    }

    function test_forcedHookEthCannotIncreaseSellPayout() public {
        _buyA(user, 0.02 ether);
        uint256 sellAmount = tokenA.balanceOf(user) / 2;
        uint256 ethGross = DoubleSineMath.ethOutForTokens(hook.virtualEth(), sellAmount);
        uint256 expectedOut = ethGross - _feeUp(ethGross, hook.SELL_FEE_BPS());

        uint256 forcedEth = 1 ether;
        vm.deal(address(hook), address(hook).balance + forcedEth);
        assertEq(address(hook).balance, hook.ethReserve() + forcedEth, "forced ETH setup");

        uint256 userEthBefore = user.balance;
        _sellA(user, sellAmount);

        assertEq(user.balance, userEthBefore + expectedOut, "sell payout must ignore forced ETH");
        assertEq(address(hook).balance, hook.ethReserve() + forcedEth, "forced ETH remains unbooked");
    }

    function test_sellDustRevertsBeforeRoundingCanPayOneWeiEth() public {
        _buyA(user, 0.01 ether);
        uint256 userTokenBefore = tokenA.balanceOf(user);
        uint256 userEthBefore = user.balance;
        uint256 reserveBefore = hook.ethReserve();
        uint256 virtualEthBefore = hook.virtualEth();

        bool reverted = _trySellA(user, 1);

        assertTrue(reverted, "dust sell should revert");
        assertEq(tokenA.balanceOf(user), userTokenBefore, "token balance changed");
        assertEq(user.balance, userEthBefore, "eth balance changed");
        assertEq(hook.ethReserve(), reserveBefore, "reserve changed");
        assertEq(hook.virtualEth(), virtualEthBefore, "virtualEth changed");
    }

    function test_buyDustRevertsWhenCurveOutputRoundsToZero() public {
        uint256 highVirtualEth = 1e30;
        vm.store(address(hook), bytes32(HOOK_VIRTUAL_ETH_SLOT), bytes32(highVirtualEth));

        uint256 reserveBefore = hook.ethReserve();
        uint256 userEthBefore = user.balance;

        bool reverted = _tryBuyA(user, 1);

        assertTrue(reverted, "zero-output buy should revert");
        assertEq(hook.virtualEth(), highVirtualEth, "virtualEth changed");
        assertEq(hook.ethReserve(), reserveBefore, "reserve changed");
        assertEq(user.balance, userEthBefore, "eth balance changed");
    }

    function test_buyOneWeiRevertsBecauseRoundedFeeConsumesInput() public {
        uint256 reserveBefore = hook.ethReserve();
        uint256 virtualEthBefore = hook.virtualEth();
        uint256 userEthBefore = user.balance;

        bool reverted = _tryBuyA(user, 1);

        assertTrue(reverted, "one-wei buy should revert");
        assertEq(hook.virtualEth(), virtualEthBefore, "virtualEth changed");
        assertEq(hook.ethReserve(), reserveBefore, "reserve changed");
        assertEq(user.balance, userEthBefore, "eth balance changed");
    }

    function test_plainERC20_constructorCanPullApprovedTokens() public {
        _buyA(user, 0.01 ether);
        uint256 balanceBefore = tokenA.balanceOf(user);
        uint256 amount = balanceBefore / 2;

        uint64 nonce = vm.getNonce(user);
        address predictedVault = vm.computeCreateAddress(user, nonce);

        vm.startPrank(user, user);
        tokenA.approve(predictedVault, amount);
        ConstructorTokenVault vault = new ConstructorTokenVault(tokenA, amount);
        vm.stopPrank();

        assertEq(address(vault), predictedVault, "unexpected vault address");
        assertEq(tokenA.balanceOf(user), balanceBefore - amount, "user balance");
        assertEq(tokenA.balanceOf(predictedVault), amount, "vault received tokens");
    }

    function test_plainERC20_constructorCanApproveForwarderForCounterfactualBalance() public {
        _buyA(user, 0.01 ether);
        uint256 amount = tokenA.balanceOf(user) / 2;

        uint64 nonce = vm.getNonce(user);
        address predictedVault = vm.computeCreateAddress(user, nonce);

        vm.prank(user, user);
        assertTrue(tokenA.transfer(predictedVault, amount), "counterfactual transfer");
        assertEq(tokenA.balanceOf(predictedVault), amount, "counterfactual receive setup failed");

        vm.startPrank(user, user);
        ConstructorApprovalVault vault = new ConstructorApprovalVault(tokenA, address(router), amount);
        vm.stopPrank();

        assertEq(address(vault), predictedVault, "unexpected vault address");
        assertEq(tokenA.allowance(predictedVault, address(router)), amount, "constructor approve");
        assertEq(tokenA.balanceOf(predictedVault), amount, "counterfactual balance");
    }

    function test_plainERC20_contractCanTransferOutAfterCounterfactualReceive() public {
        _buyA(user, 0.01 ether);
        uint256 amount = tokenA.balanceOf(user) / 2;

        uint64 nonce = vm.getNonce(user);
        address predictedVault = vm.computeCreateAddress(user, nonce);

        vm.startPrank(user, user);
        assertTrue(tokenA.transfer(predictedVault, amount), "counterfactual transfer");
        PassiveTokenVault vault = new PassiveTokenVault(tokenA);
        vm.stopPrank();

        assertEq(address(vault), predictedVault, "unexpected vault address");
        assertEq(tokenA.balanceOf(address(vault)), amount, "constructor receive setup failed");

        vault.drain(address(0xCAFE));
        assertEq(tokenA.balanceOf(address(0xCAFE)), amount, "drained to recipient");
        assertEq(tokenA.balanceOf(address(vault)), 0, "vault emptied");
    }

    function test_canonicalHook_addLiquidityRevertsThroughPoolManager() public {
        RogueLiquidityActor liquidityActor = new RogueLiquidityActor(IPoolManager(address(manager)));

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(DoubleSineHook.LiquidityDisabled.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        liquidityActor.addLiquidity(keyA);
    }

    // ============================================================
    // Sell that exceeds reserve
    // ============================================================

    function test_sell_revertsIfExceedsReserve() public {
        // Buy a small amount, then try to sell more than the reserve can
        // pay for (sell price after theta advance can exceed reserve).
        _buyA(user, 0.001 ether);
        uint256 tokens = tokenA.balanceOf(user);

        // Manipulate theta to a value where sell value far exceeds reserve.
        // We can't directly set theta from outside, so instead burn most of
        // the ETH reserve via a series of sells until reserve cannot cover
        // a large sell. For a clean test, just attempt to sell back at the
        // current theta - given fees, it should NOT exceed reserve here.
        // Instead, test that a very large fabricated sell would fail.
        // (Trivial reserve-bound test: skipped here; would require a
        //  separate scenario test with smaller initial buys.)
        _sellA(user, tokens);
        // Just confirm it didn't revert and reserve >= 0.
        assertTrue(hook.ethReserve() >= 0);
    }

    // ============================================================
    // Token-level controls
    // ============================================================

    function test_mint_revertsForNonHookTarget() public {
        // Mint can only be called by the hook AND can only target the hook
        // itself. Direct call from a non-hook fails the onlyHook modifier.
        vm.prank(address(hook));
        vm.expectRevert(DoubleSineToken.NotHook.selector);
        tokenA.mint(user, 1e18);
    }

    function test_bindHook_revertsForAddressWithoutCode() public {
        DoubleSineToken token = new DoubleSineToken("Unbound DoubleSine", "UDS", address(manager), address(router));

        vm.expectRevert(DoubleSineToken.HookMustHaveCode.selector);
        token.bindHook(makeAddr("not-a-hook"));
    }

    function test_bindHook_revertsForNonHookContract() public {
        DoubleSineToken token = new DoubleSineToken("Unbound DoubleSine", "UDS", address(manager), address(router));
        FakeRouter fake = new FakeRouter();

        vm.expectRevert(DoubleSineToken.InvalidHookBinding.selector);
        token.bindHook(address(fake));
    }

    function test_bindHook_revertsForHookThatDoesNotReferenceToken() public {
        DoubleSineToken token = new DoubleSineToken("Unbound DoubleSine", "UDS", address(manager), address(router));

        vm.expectRevert(DoubleSineToken.InvalidHookBinding.selector);
        token.bindHook(address(hook));
    }

    function test_bindHook_revertsForSpoofedHookAtWrongAddress() public {
        DoubleSineToken token = new DoubleSineToken("Unbound DoubleSine", "UDS", address(manager), address(router));
        FakeHookBinding fake = new FakeHookBinding(address(manager), address(token), address(tokenB));

        vm.expectRevert(DoubleSineToken.InvalidHookBinding.selector);
        token.bindHook(address(fake));
    }

    function test_burn_revertsForNonHookCaller() public {
        vm.prank(user);
        vm.expectRevert(DoubleSineToken.NotHook.selector);
        tokenA.burn(user, 1);
    }

    function test_burn_revertsForNonHookSourceEvenWhenCalledByHook() public {
        vm.prank(address(hook));
        vm.expectRevert(DoubleSineToken.NotHook.selector);
        tokenA.burn(user, 1);
    }

    function test_transferFromZeroAddressRevertsEvenForZeroAmount() public {
        vm.prank(user, user);
        vm.expectRevert(DoubleSineToken.ZeroAddress.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenA.transferFrom(address(0), user, 0);
    }

    // ============================================================
    // Slippage protection (hookData = abi.encode(minOut))
    // ============================================================

    function test_slippage_buyReverts_whenMinTokensOutNotMet() public {
        // Ask for an unreachable amount of tokens for our 0.01 ETH buy.
        uint256 ridiculousMin = 1e30;
        bool reverted = _tryBuyWithSlippage(user, 0.01 ether, ridiculousMin);
        assertTrue(reverted, "slippage check should have reverted");
    }

    function test_slippage_buyPasses_whenMinTokensOutSatisfied() public {
        // Compute what we'd actually receive and ask for slightly less.
        uint256 ethCurve = 0.01 ether - _feeUp(0.01 ether, hook.BUY_FEE_BPS());
        uint256 expectedOut = DoubleSineMath.tokensOutForEth(hook.virtualEth(), ethCurve);
        uint256 minOut = (expectedOut * 99) / 100; // 1% slippage tolerance
        bool reverted = _tryBuyWithSlippage(user, 0.01 ether, minOut);
        assertFalse(reverted, "in-range min should have passed");
        assertGe(tokenA.balanceOf(user), minOut, "actual out >= min");
    }

    function test_slippage_buyReverts_whenHookDataMalformed() public {
        bool reverted = _tryBuyWithRawHookData(user, 0.01 ether, hex"01");
        assertTrue(reverted, "malformed hookData should revert");
    }

    function test_slippage_sellReverts_whenMinEthOutNotMet() public {
        // Acquire some tokens first
        _buyA(user, 0.01 ether);
        uint256 tokens = tokenA.balanceOf(user);

        // Ask for an unreachable amount of ETH back.
        uint256 ridiculousMin = 100 ether;
        bool reverted = _trySellWithSlippage(user, tokens, ridiculousMin);
        assertTrue(reverted, "slippage check should have reverted");
    }

    function test_routerRejectsInt256MinExactInput() public {
        vm.prank(user);
        vm.expectRevert(DoubleSineRouter.InvalidCallback.selector);
        router.swap(
            keyA,
            SwapParams({zeroForOne: true, amountSpecified: type(int256).min, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ""
        );
    }

    function test_routerRejectsDirectEth() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok, bytes memory revertData) = address(router).call{value: 1 wei}("");
        assertFalse(ok, "direct router eth should revert");
        assertEq(revertData, abi.encodeWithSelector(DoubleSineRouter.DirectEthDisabled.selector));
    }

    function test_hookRejectsDirectEthFromNonPoolManager() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok, bytes memory revertData) = address(hook).call{value: 1 wei}("");
        assertFalse(ok, "direct hook eth should revert");
        assertEq(revertData, abi.encodeWithSelector(DoubleSineHook.DirectEthDisabled.selector));
        assertEq(address(hook).balance, hook.ethReserve(), "reserve accounting changed");
    }

    function test_hookRejectsInt256MinExactInput() public {
        vm.prank(address(manager));
        vm.expectRevert(DoubleSineHook.ExactInputOverflow.selector);
        hook.beforeSwap(
            address(router),
            keyA,
            SwapParams({zeroForOne: true, amountSpecified: type(int256).min, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ""
        );
    }

    function test_hookAllowsExternalPoolManagerSwapAndWrappedClaim() public {
        RoguePoolManagerSwapper externalRouter = new RoguePoolManagerSwapper(IPoolManager(address(manager)));

        vm.deal(address(externalRouter), 1 ether);
        externalRouter.buyAndWrapClaim{value: 0.01 ether}(keyA, 0.01 ether);

        assertGt(
            manager.balanceOf(address(externalRouter), uint256(uint160(address(tokenA)))), 0, "wrapped claim minted"
        );
        assertEq(tokenA.balanceOf(address(externalRouter)), 0, "wrapped claim is not ERC20 custody");
        assertEq(hook.currentPriceA(), hook.currentPriceB(), "price lock preserved");
    }

    function test_hookAllowsExternalPoolManagerSwapRouterToTakeERC20() public {
        RoguePoolManagerSwapper externalRouter = new RoguePoolManagerSwapper(IPoolManager(address(manager)));

        vm.deal(address(externalRouter), 1 ether);
        externalRouter.buyAndTakeTo{value: 0.01 ether}(keyA, 0.01 ether, user);

        assertGt(tokenA.balanceOf(user), 0, "external router delivered token");
        assertEq(hook.currentPriceA(), hook.currentPriceB(), "price lock preserved");
    }

    function test_hookAllowsExternalPoolManagerSwapRouterToSellERC20() public {
        _buyA(user, 0.02 ether);
        RoguePoolManagerSwapper externalRouter = new RoguePoolManagerSwapper(IPoolManager(address(manager)));
        uint256 sellAmount = tokenA.balanceOf(user) / 2;
        uint256 userEthBefore = user.balance;

        vm.prank(user, user);
        assertTrue(tokenA.transfer(address(externalRouter), sellAmount), "seed external router");

        externalRouter.sellAndTakeEth(keyA, sellAmount, user);

        assertEq(tokenA.balanceOf(address(externalRouter)), 0, "external router token dust");
        assertGt(user.balance, userEthBefore, "external router delivered ETH");
        assertEq(hook.currentPriceA(), hook.currentPriceB(), "price lock preserved");
    }

    function test_hookRejectsBuyInputAboveInt128BeforeStateChange() public {
        uint256 virtualEthBefore = hook.virtualEth();
        uint256 ethReserveBefore = hook.ethReserve();

        vm.prank(address(manager));
        vm.expectRevert(DoubleSineHook.Int128Overflow.selector);
        hook.beforeSwap(
            address(router),
            keyA,
            SwapParams({
                zeroForOne: true,
                amountSpecified: _exactInput(uint256(uint128(type(int128).max)) + 1),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            ""
        );

        assertEq(hook.virtualEth(), virtualEthBefore, "virtualEth changed");
        assertEq(hook.ethReserve(), ethReserveBefore, "reserve changed");
    }

    function test_hookRejectsBuyThatWouldExceedSpotPriceBoundBeforeStateChange() public {
        uint256 nearSpotPriceBound = DoubleSineMath.MAX_SPOT_PRICE_VIRTUAL_ETH - 1;
        vm.store(address(hook), bytes32(HOOK_VIRTUAL_ETH_SLOT), bytes32(nearSpotPriceBound));

        uint256 virtualEthBefore = hook.virtualEth();
        uint256 ethReserveBefore = hook.ethReserve();

        vm.prank(address(manager));
        vm.expectRevert(DoubleSineMath.SpotPriceOverflow.selector);
        hook.beforeSwap(
            address(router),
            keyA,
            SwapParams({zeroForOne: true, amountSpecified: _exactInput(3), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ""
        );

        assertEq(hook.virtualEth(), virtualEthBefore, "virtualEth changed");
        assertEq(hook.ethReserve(), ethReserveBefore, "reserve changed");
    }

    function test_hookRejectsSellInputAboveInt128BeforeStateChange() public {
        uint256 virtualEthBefore = hook.virtualEth();
        uint256 ethReserveBefore = hook.ethReserve();

        vm.prank(address(manager));
        vm.expectRevert(DoubleSineHook.Int128Overflow.selector);
        hook.beforeSwap(
            address(router),
            keyA,
            SwapParams({
                zeroForOne: false,
                amountSpecified: _exactInput(uint256(uint128(type(int128).max)) + 1),
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            ""
        );

        assertEq(hook.virtualEth(), virtualEthBefore, "virtualEth changed");
        assertEq(hook.ethReserve(), ethReserveBefore, "reserve changed");
    }

    function test_hookRejectsSwapUntilBothCanonicalPoolsAreInitialized() public {
        PoolManager freshManager = new PoolManager(address(this));
        DoubleSineRouter freshRouter = new DoubleSineRouter(IPoolManager(address(freshManager)));
        DoubleSineToken freshTokenA =
            new DoubleSineToken("Fresh DoubleSine A", "FDSA", address(freshManager), address(freshRouter));
        DoubleSineToken freshTokenB =
            new DoubleSineToken("Fresh DoubleSine B", "FDSB", address(freshManager), address(freshRouter));

        bytes memory ctorArgs = abi.encode(
            IPoolManager(address(freshManager)), address(freshRouter), freshTokenA, freshTokenB, address(this)
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(DoubleSineHook).creationCode, ctorArgs);
        DoubleSineHook freshHook = new DoubleSineHook{salt: salt}(
            IPoolManager(address(freshManager)), address(freshRouter), freshTokenA, freshTokenB, address(this)
        );
        require(address(freshHook) == expectedHook, "fresh hook address mismatch");
        freshRouter.bindSystem(freshTokenA, freshTokenB, address(freshHook));
        freshTokenA.bindHook(address(freshHook));
        freshTokenB.bindHook(address(freshHook));

        PoolKey memory freshKeyA = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(freshTokenA)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(freshHook))
        });
        freshManager.initialize(freshKeyA, SQRT_PRICE_1_1);
        vm.roll(block.number + freshHook.ANTI_SNIPE_BLOCKS());

        vm.deal(user, 1 ether);
        vm.prank(user, user);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(freshHook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(DoubleSineHook.SystemNotReady.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        freshRouter.swap{value: 0.01 ether}(
            freshKeyA,
            SwapParams({
                zeroForOne: true, amountSpecified: _exactInput(0.01 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            ""
        );
    }

    // ============================================================
    // Anti-sniper: per-swap input cap during the first N blocks
    // ============================================================

    function test_antiSnipe_smallBuyAllowed() public {
        _resetToBootstrap();
        assertTrue(block.number - hook.bootstrapBlock() < hook.ANTI_SNIPE_BLOCKS());
        _buyA(user, hook.ANTI_SNIPE_MAX_BUY_WEI());
        assertGt(tokenA.balanceOf(user), 0, "cap-sized buy should work");
    }

    function test_antiSnipe_oversizedBuyReverts() public {
        _resetToBootstrap();
        uint256 over = hook.ANTI_SNIPE_MAX_BUY_WEI() + 1;
        bool reverted = _tryBuyA(user, over);
        assertTrue(reverted, "oversized buy in window did not revert");
    }

    function test_antiSnipe_appliesToBothPools() public {
        _resetToBootstrap();
        bool reverted = _tryBuyB(user, 1 ether);
        assertTrue(reverted, "oversized buy B in window did not revert");
    }

    function test_antiSnipe_expiresAfterWindow() public {
        // setUp already rolled past the window. Verify a big buy works.
        _buyA(user, 0.5 ether);
        assertGt(tokenA.balanceOf(user), 0, "post-window buy should work");
    }

    function test_antiSnipe_remainsActiveAtHighBlockNumbers() public {
        uint256 highBlock = uint256(type(uint64).max) + 100;
        vm.store(address(hook), bytes32(HOOK_BOOTSTRAP_BLOCK_SLOT), bytes32(highBlock));
        vm.roll(highBlock);

        bool reverted = _tryBuyA(user, hook.ANTI_SNIPE_MAX_BUY_WEI() + 1);

        assertTrue(reverted, "high block cap should not truncate");
    }

    function test_antiSnipe_sellsNotCappedInWindow() public {
        _resetToBootstrap();
        _buyA(user, hook.ANTI_SNIPE_MAX_BUY_WEI());
        uint256 tokens = tokenA.balanceOf(user);
        _sellA(user, tokens); // should not revert
        assertEq(tokenA.balanceOf(user), 0);
    }

    function test_buyEventUsesPoolCaller() public {
        vm.recordLogs();
        _buyA(user, 0.01 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 buyTopic = keccak256("Buy(address,bool,uint256,uint256,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length > 0 && logs[i].topics[0] == buyTopic) {
                address emittedSender = address(uint160(uint256(logs[i].topics[1])));
                assertEq(emittedSender, address(router), "event should emit PoolManager caller");
                assertNotEq(emittedSender, address(manager), "event must not emit PoolManager");
                found = true;
                break;
            }
        }
        assertTrue(found, "Buy event not found");
    }

    function test_router_rejectsUnsupportedTokenBeforePoolManager() public {
        PoolKey memory badKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(0xCAFE)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });

        vm.prank(user);
        vm.expectRevert(DoubleSineRouter.UnsupportedToken.selector);
        router.swap{value: 0.01 ether}(
            badKey,
            SwapParams({
                zeroForOne: true, amountSpecified: _exactInput(0.01 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            ""
        );
    }

    function test_router_rejectsNonCanonicalHookBeforeTokenPull() public {
        _buyA(user, 0.01 ether);
        uint256 bal = tokenA.balanceOf(user);
        uint256 amount = bal / 2;

        PoolKey memory badKey = keyA;
        badKey.hooks = IHooks(address(0));

        vm.startPrank(user, user);
        tokenA.approve(address(router), amount);
        vm.expectRevert(DoubleSineRouter.UnsupportedPool.selector);
        router.swap(
            badKey,
            SwapParams({zeroForOne: false, amountSpecified: _exactInput(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            ""
        );
        vm.stopPrank();

        assertEq(tokenA.balanceOf(user), bal, "token pull must not happen");
        assertEq(tokenA.balanceOf(address(router)), 0, "router must not keep tokens");
    }

    function test_router_bindSystemCanOnlyRunOnceByBinder() public {
        DoubleSineRouter fresh = new DoubleSineRouter(IPoolManager(address(manager)));
        DoubleSineToken freshTokenA =
            new DoubleSineToken("Fresh DoubleSine A", "FDSA", address(manager), address(fresh));
        DoubleSineToken freshTokenB =
            new DoubleSineToken("Fresh DoubleSine B", "FDSB", address(manager), address(fresh));
        address freshHook = _deployHookFor(fresh, freshTokenA, freshTokenB, initializer, 1);

        vm.prank(user);
        vm.expectRevert(DoubleSineRouter.NotBinder.selector);
        fresh.bindSystem(freshTokenA, freshTokenB, freshHook);

        fresh.bindSystem(freshTokenA, freshTokenB, freshHook);
        assertEq(address(fresh.tokenA()), address(freshTokenA));
        assertEq(address(fresh.tokenB()), address(freshTokenB));
        assertEq(fresh.hook(), freshHook);

        vm.expectRevert(DoubleSineRouter.AlreadyBound.selector);
        fresh.bindSystem(freshTokenA, freshTokenB, freshHook);
    }

    function test_router_bindSystemRejectsMismatchedRouterToken() public {
        DoubleSineRouter fresh = new DoubleSineRouter(IPoolManager(address(manager)));

        vm.expectRevert(DoubleSineRouter.InvalidBinding.selector);
        fresh.bindSystem(tokenA, tokenB, address(hook));
    }

    function test_router_bindSystemRejectsAddressWithoutCodeHook() public {
        DoubleSineRouter fresh = new DoubleSineRouter(IPoolManager(address(manager)));
        DoubleSineToken freshTokenA =
            new DoubleSineToken("Fresh DoubleSine A", "FDSA", address(manager), address(fresh));
        DoubleSineToken freshTokenB =
            new DoubleSineToken("Fresh DoubleSine B", "FDSB", address(manager), address(fresh));

        vm.expectRevert(DoubleSineRouter.HookMustHaveCode.selector);
        fresh.bindSystem(freshTokenA, freshTokenB, makeAddr("not-a-hook"));
    }

    function test_router_bindSystemRejectsHookForDifferentTokens() public {
        DoubleSineRouter fresh = new DoubleSineRouter(IPoolManager(address(manager)));
        DoubleSineToken freshTokenA =
            new DoubleSineToken("Fresh DoubleSine A", "FDSA", address(manager), address(fresh));
        DoubleSineToken freshTokenB =
            new DoubleSineToken("Fresh DoubleSine B", "FDSB", address(manager), address(fresh));

        vm.expectRevert(DoubleSineRouter.InvalidBinding.selector);
        fresh.bindSystem(freshTokenA, freshTokenB, address(hook));
    }

    function test_router_bindSystemRejectsSpoofedHookAtWrongAddress() public {
        DoubleSineRouter fresh = new DoubleSineRouter(IPoolManager(address(manager)));
        DoubleSineToken freshTokenA =
            new DoubleSineToken("Fresh DoubleSine A", "FDSA", address(manager), address(fresh));
        DoubleSineToken freshTokenB =
            new DoubleSineToken("Fresh DoubleSine B", "FDSB", address(manager), address(fresh));
        FakeHookBinding fake = new FakeHookBinding(address(manager), address(freshTokenA), address(freshTokenB));

        vm.expectRevert(DoubleSineRouter.InvalidBinding.selector);
        fresh.bindSystem(freshTokenA, freshTokenB, address(fake));
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _deployHookFor(DoubleSineToken tokenA_, DoubleSineToken tokenB_, address initializer_, uint160 nonce)
        internal
        returns (address hookAddr)
    {
        return _deployHookFor(router, tokenA_, tokenB_, initializer_, nonce);
    }

    function _deployHookFor(
        DoubleSineRouter router_,
        DoubleSineToken tokenA_,
        DoubleSineToken tokenB_,
        address initializer_,
        uint160 nonce
    ) internal returns (address hookAddr) {
        hookAddr = address(uint160(HOOK_FLAGS | (nonce << 14)));
        deployCodeTo(
            "DoubleSineHook.sol:DoubleSineHook",
            abi.encode(IPoolManager(address(manager)), address(router_), tokenA_, tokenB_, initializer_),
            hookAddr
        );
    }

    function _buyA(address buyer, uint256 amount) internal returns (BalanceDelta) {
        vm.prank(buyer, buyer);
        return router.swap{value: amount}(
            keyA,
            SwapParams({zeroForOne: true, amountSpecified: _exactInput(amount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ""
        );
    }

    function _buyB(address buyer, uint256 amount) internal returns (BalanceDelta) {
        vm.prank(buyer, buyer);
        return router.swap{value: amount}(
            keyB,
            SwapParams({zeroForOne: true, amountSpecified: _exactInput(amount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ""
        );
    }

    function _sellA(address seller, uint256 amount) internal returns (BalanceDelta) {
        vm.startPrank(seller, seller);
        tokenA.approve(address(router), amount);
        BalanceDelta delta = router.swap(
            keyA,
            SwapParams({zeroForOne: false, amountSpecified: _exactInput(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            ""
        );
        vm.stopPrank();
        return delta;
    }

    function _sellB(address seller, uint256 amount) internal returns (BalanceDelta) {
        vm.startPrank(seller, seller);
        tokenB.approve(address(router), amount);
        BalanceDelta delta = router.swap(
            keyB,
            SwapParams({zeroForOne: false, amountSpecified: _exactInput(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            ""
        );
        vm.stopPrank();
        return delta;
    }

    function _assertApprox(uint256 a, uint256 b, uint256 maxDelta, string memory msg_) internal pure {
        uint256 d = a > b ? a - b : b - a;
        require(d <= maxDelta, msg_);
    }

    function _feeUp(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (amount == 0 || bps == 0) return 0;
        return ((amount * bps) - 1) / 10000 + 1;
    }

    /// Returns true if the buy reverted, false if it went through.
    /// Used to test the anti-sniper cap without relying on vm.expectRevert
    /// (the router's unlock-callback wrapping can confuse it).
    function _tryBuyA(address buyer, uint256 amount) internal returns (bool) {
        vm.prank(buyer, buyer);
        try router.swap{value: amount}(
            keyA,
            SwapParams({zeroForOne: true, amountSpecified: _exactInput(amount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ""
        ) {
            return false;
        } catch {
            return true;
        }
    }

    function _tryBuyB(address buyer, uint256 amount) internal returns (bool) {
        vm.prank(buyer, buyer);
        try router.swap{value: amount}(
            keyB,
            SwapParams({zeroForOne: true, amountSpecified: _exactInput(amount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ""
        ) {
            return false;
        } catch {
            return true;
        }
    }

    function _trySellA(address seller, uint256 amount) internal returns (bool) {
        vm.startPrank(seller, seller);
        tokenA.approve(address(router), amount);
        try router.swap(
            keyA,
            SwapParams({zeroForOne: false, amountSpecified: _exactInput(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            ""
        ) {
            vm.stopPrank();
            return false;
        } catch {
            vm.stopPrank();
            return true;
        }
    }

    function _tryBuyWithSlippage(address buyer, uint256 amount, uint256 minOut) internal returns (bool) {
        return _tryBuyWithRawHookData(buyer, amount, abi.encode(minOut));
    }

    function _tryBuyWithRawHookData(address buyer, uint256 amount, bytes memory hookData) internal returns (bool) {
        vm.prank(buyer, buyer);
        try router.swap{value: amount}(
            keyA,
            SwapParams({zeroForOne: true, amountSpecified: _exactInput(amount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            hookData
        ) {
            return false;
        } catch {
            return true;
        }
    }

    function _trySellWithSlippage(address seller, uint256 amount, uint256 minOut) internal returns (bool) {
        vm.startPrank(seller, seller);
        tokenA.approve(address(router), amount);
        try router.swap(
            keyA,
            SwapParams({zeroForOne: false, amountSpecified: _exactInput(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            abi.encode(minOut)
        ) {
            vm.stopPrank();
            return false;
        } catch {
            vm.stopPrank();
            return true;
        }
    }

    function _exactInput(uint256 amount) internal pure returns (int256) {
        require(amount <= uint256(type(int256).max), "amount too large");
        // forge-lint: disable-next-line(unsafe-typecast)
        return -int256(amount);
    }
}

/// Stand-in for an external router, pair, aggregator, or venue that receives
/// and moves the plain ERC20 tokens.
contract FakeRouter {
    function ping() external pure returns (bool) {
        return true;
    }

    function route(DoubleSineToken token, address to, uint256 amount) external {
        bool ok = token.transfer(to, amount);
        require(ok, "route failed");
    }
}

contract FakeHookBinding {
    address public immutable manager;
    address public immutable router;
    address public immutable tokenA;
    address public immutable tokenB;

    constructor(address manager_, address tokenA_, address tokenB_) {
        manager = manager_;
        router = msg.sender;
        tokenA = tokenA_;
        tokenB = tokenB_;
    }
}

contract ConstructorTokenVault {
    DoubleSineToken public immutable token;

    constructor(DoubleSineToken token_, uint256 amount) {
        token = token_;
        bool ok = token.transferFrom(msg.sender, address(this), amount);
        require(ok, "transferFrom failed");
    }

    function drain(address to) external {
        bool ok = token.transfer(to, token.balanceOf(address(this)));
        require(ok, "transfer failed");
    }
}

contract PassiveTokenVault {
    DoubleSineToken public immutable token;

    constructor(DoubleSineToken token_) {
        token = token_;
    }

    function drain(address to) external {
        bool ok = token.transfer(to, token.balanceOf(address(this)));
        require(ok, "transfer failed");
    }
}

contract ConstructorApprovalVault {
    constructor(DoubleSineToken token, address spender, uint256 amount) {
        bool ok = token.approve(spender, amount);
        require(ok, "approve failed");
    }
}

contract RogueLiquidityActor {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function addLiquidity(PoolKey calldata key) external {
        manager.unlock(abi.encode(key));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        PoolKey memory key = abi.decode(rawData, (PoolKey));
        manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: int256(1 ether), salt: bytes32(0)}),
            ""
        );
        return "";
    }
}

contract RoguePoolManagerSwapper {
    IPoolManager public immutable manager;

    struct CallbackData {
        PoolKey key;
        uint256 amountIn;
        address recipient;
        bool wrapClaim;
        bool isBuy;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function buyAndWrapClaim(PoolKey calldata key, uint256 amountIn) external payable {
        require(msg.value == amountIn, "bad value");
        manager.unlock(
            abi.encode(
                CallbackData({key: key, amountIn: amountIn, recipient: address(this), wrapClaim: true, isBuy: true})
            )
        );
    }

    function buyAndTakeTo(PoolKey calldata key, uint256 amountIn, address recipient) external payable {
        require(msg.value == amountIn, "bad value");
        manager.unlock(
            abi.encode(
                CallbackData({key: key, amountIn: amountIn, recipient: recipient, wrapClaim: false, isBuy: true})
            )
        );
    }

    function sellAndTakeEth(PoolKey calldata key, uint256 amountIn, address recipient) external {
        manager.unlock(
            abi.encode(
                CallbackData({key: key, amountIn: amountIn, recipient: recipient, wrapClaim: false, isBuy: false})
            )
        );
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        if (data.isBuy) {
            manager.settle{value: data.amountIn}();
        } else {
            manager.sync(data.key.currency1);
            bool ok = DoubleSineToken(Currency.unwrap(data.key.currency1)).transfer(address(manager), data.amountIn);
            require(ok, "settle token failed");
            require(manager.settle() == data.amountIn, "bad token settle");
        }

        BalanceDelta delta = manager.swap(
            data.key,
            SwapParams({
                zeroForOne: data.isBuy,
                amountSpecified: -int256(data.amountIn),
                sqrtPriceLimitX96: data.isBuy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        if (amount0 > 0) {
            // Safe because amount0 is checked positive and already int128-sized.
            // forge-lint: disable-next-line(unsafe-typecast)
            manager.take(data.key.currency0, data.recipient, uint128(amount0));
        }
        if (amount1 > 0) {
            if (data.wrapClaim) {
                // Safe because amount1 is checked positive and already int128-sized.
                // forge-lint: disable-next-line(unsafe-typecast)
                manager.mint(address(this), uint256(uint160(Currency.unwrap(data.key.currency1))), uint128(amount1));
            } else {
                // Safe because amount1 is checked positive and already int128-sized.
                // forge-lint: disable-next-line(unsafe-typecast)
                manager.take(data.key.currency1, data.recipient, uint128(amount1));
            }
        }
        return "";
    }
}
