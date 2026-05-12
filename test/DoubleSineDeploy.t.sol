// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {DoubleSineMath} from "../src/DoubleSineMath.sol";
import {DoubleSineToken} from "../src/DoubleSineToken.sol";
import {DoubleSineHook} from "../src/DoubleSineHook.sol";
import {DoubleSineRouter} from "../src/DoubleSineRouter.sol";
import {HookMiner} from "../script/utils/HookMiner.sol";

/// @notice Full-fidelity dry run of the production deployment flow. Exercises
/// the EXACT same sequence the deploy script will run on mainnet/Sepolia:
///   1. deploy router
///   2. deploy tokens with locked authorization list
///   3. mine a CREATE2 salt for the hook
///   4. CREATE2-deploy hook
///   5. bindHook on both tokens
///   6. initialize both v4 pools
///   7. confirm a buy works after the anti-sniper window
///
/// This is the local-only flavor (uses a fresh PoolManager). For a true fork
/// test, run:
///   forge script script/DeployDoubleSine.s.sol --fork-url $SEPOLIA_RPC
contract DoubleSineDeployTest is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant MIN_PRICE_LIMIT = 4295128740;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    receive() external payable {}

    function test_fullDeploymentFlow() public {
        // ============================================================
        // 1. Bedrock contracts
        // ============================================================
        PoolManager manager = new PoolManager(address(this));
        DoubleSineRouter router = new DoubleSineRouter(IPoolManager(address(manager)));

        // ============================================================
        // 2. Tokens with locked authorization list
        // ============================================================
        address[] memory auth = new address[](2);
        auth[0] = address(manager);
        auth[1] = address(router);
        DoubleSineToken tokenA = new DoubleSineToken("DoubleSine A", "DSA", auth);
        DoubleSineToken tokenB = new DoubleSineToken("DoubleSine B", "DSB", auth);

        // ============================================================
        // 3. Mine the CREATE2 salt
        // ============================================================
        bytes memory ctorArgs = abi.encode(
            IPoolManager(address(manager)), tokenA, tokenB, address(this)
        );
        (address expectedHook, bytes32 salt) = HookMiner.find(
            address(this), HOOK_FLAGS, type(DoubleSineHook).creationCode, ctorArgs
        );

        // ============================================================
        // 4. CREATE2 deploy
        // ============================================================
        DoubleSineHook hook = new DoubleSineHook{salt: salt}(
            IPoolManager(address(manager)), tokenA, tokenB, address(this)
        );
        require(address(hook) == expectedHook, "hook address mismatch");

        // ============================================================
        // 5. Bind hook on tokens
        // ============================================================
        tokenA.bindHook(address(hook));
        tokenB.bindHook(address(hook));

        // ============================================================
        // 6. Initialize both v4 pools
        // ============================================================
        PoolKey memory keyA = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(tokenA)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        PoolKey memory keyB = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(tokenB)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        manager.initialize(keyA, SQRT_PRICE_1_1);
        manager.initialize(keyB, SQRT_PRICE_1_1);

        assertTrue(hook.poolAInitialized());
        assertTrue(hook.poolBInitialized());
        assertEq(hook.virtualEth(), DoubleSineMath.VIRTUAL_ETH_INIT);
        assertEq(uint256(hook.bootstrapBlock()), block.number);

        // ============================================================
        // 7. Anti-snipe window enforced for first ANTI_SNIPE_BLOCKS
        // ============================================================
        // Within the window, oversized buy reverts.
        address user = makeAddr("user");
        vm.deal(user, 10 ether);
        bool overReverted = _tryBuy(router, keyA, user, hook.ANTI_SNIPE_MAX_BUY_WEI() + 1);
        assertTrue(overReverted, "anti-snipe cap not enforced");

        // Cap-sized buy goes through.
        bool capOk = !_tryBuy(router, keyA, user, hook.ANTI_SNIPE_MAX_BUY_WEI());
        assertTrue(capOk, "cap-sized buy should pass");
        assertGt(tokenA.balanceOf(user), 0, "user got A");
        assertEq(hook.currentPriceA(), hook.currentPriceB(), "priceA == priceB after buy A");

        // ============================================================
        // 8. After window, larger buys allowed
        // ============================================================
        vm.roll(block.number + hook.ANTI_SNIPE_BLOCKS());
        bool bigOk = !_tryBuy(router, keyB, user, 0.5 ether);
        assertTrue(bigOk, "post-window big buy should pass");
        assertGt(tokenB.balanceOf(user), 0, "user got B");
        assertEq(hook.currentPriceA(), hook.currentPriceB(), "priceA == priceB after buy B");

        // ============================================================
        // 9. Reserve never underwater
        // ============================================================
        assertGe(address(hook).balance, hook.ethReserve(), "balance >= bookkept reserve");
        // Allow 1 wei rounding: tracked reserve must equal actual balance.
        uint256 diff = address(hook).balance > hook.ethReserve()
            ? address(hook).balance - hook.ethReserve()
            : hook.ethReserve() - address(hook).balance;
        assertLe(diff, 1, "reserve bookkeeping tight");
    }

    function _tryBuy(DoubleSineRouter router, PoolKey memory key, address buyer, uint256 amount)
        internal
        returns (bool reverted)
    {
        vm.prank(buyer);
        try router.swap{value: amount}(
            key,
            // forge-lint: disable-next-line(unsafe-typecast)
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ""
        ) returns (BalanceDelta) {
            return false;
        } catch {
            return true;
        }
    }
}

