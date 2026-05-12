// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {DoubleSineToken} from "../src/DoubleSineToken.sol";
import {DoubleSineHook} from "../src/DoubleSineHook.sol";
import {DoubleSineRouter} from "../src/DoubleSineRouter.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Full DoubleSine deployment: router, both tokens, mined hook
/// address, both v4 pools initialized.
///
/// Env vars:
///   POOL_MANAGER     - v4 PoolManager on this chain (required)
///   PERMIT2          - optional, whitelisted for GMGN routing
///   UNIVERSAL_ROUTER - optional, whitelisted for GMGN routing
///   PRIVATE_KEY      - deployer signer (set via --private-key flag instead)
///
/// Run with:
///   forge script script/DeployDoubleSine.s.sol \
///     --rpc-url $RPC \
///     --private-key $PK \
///     --broadcast
contract DeployDoubleSine is Script {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        address poolManager     = vm.envAddress("POOL_MANAGER");
        address permit2         = vm.envOr("PERMIT2", address(0));
        address universalRouter = vm.envOr("UNIVERSAL_ROUTER", address(0));
        address deployer        = msg.sender;

        // ============================================================
        // 1. Deploy router
        // ============================================================
        vm.startBroadcast();
        DoubleSineRouter router = new DoubleSineRouter(IPoolManager(poolManager));
        vm.stopBroadcast();
        console2.log("DoubleSineRouter:", address(router));

        // ============================================================
        // 2. Build token authorization list & deploy tokens
        // ============================================================
        uint256 authLen = 2 + (permit2 != address(0) ? 1 : 0) + (universalRouter != address(0) ? 1 : 0);
        address[] memory auth = new address[](authLen);
        uint256 idx;
        auth[idx++] = poolManager;
        auth[idx++] = address(router);
        if (permit2 != address(0))         auth[idx++] = permit2;
        if (universalRouter != address(0)) auth[idx++] = universalRouter;

        vm.startBroadcast();
        DoubleSineToken tokenA = new DoubleSineToken("DoubleSine A", "DSA", auth);
        DoubleSineToken tokenB = new DoubleSineToken("DoubleSine B", "DSB", auth);
        vm.stopBroadcast();
        console2.log("TokenA:", address(tokenA));
        console2.log("TokenB:", address(tokenB));

        // ============================================================
        // 3. Mine a CREATE2 salt that lands the hook on an address whose
        //    low 14 bits encode the required permission flags.
        // ============================================================
        bytes memory ctorArgs = abi.encode(
            IPoolManager(poolManager), tokenA, tokenB, deployer
        );
        (address expectedHook, bytes32 salt) = HookMiner.find(
            deployer,
            HOOK_FLAGS,
            type(DoubleSineHook).creationCode,
            ctorArgs
        );
        console2.log("Mined hook address:", expectedHook);
        console2.logBytes32(salt);

        // ============================================================
        // 4. CREATE2-deploy the hook at the mined address
        // ============================================================
        vm.startBroadcast();
        DoubleSineHook hook = new DoubleSineHook{salt: salt}(
            IPoolManager(poolManager), tokenA, tokenB, deployer
        );
        require(address(hook) == expectedHook, "hook address mismatch");

        // ============================================================
        // 5. Bind hook to tokens (adds hook to authorization set, enables
        //    mint/burn). Both pools will be initialized below.
        // ============================================================
        tokenA.bindHook(address(hook));
        tokenB.bindHook(address(hook));

        // ============================================================
        // 6. Initialize both pools (msg.sender must equal `initializer`
        //    that we set at hook construction).
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
        IPoolManager(poolManager).initialize(keyA, SQRT_PRICE_1_1);
        IPoolManager(poolManager).initialize(keyB, SQRT_PRICE_1_1);

        // ============================================================
        // 7. ATOMIC FIRST-BUY (anti-sniper policy)
        //    Same broadcast: deployer buys at exactly the cap on each
        //    pool. This proves the cap doesn't lock the deployer out and
        //    seeds tiny initial inventory for both tokens before any
        //    sniper bot can react. Skip if FIRST_BUY=0 in env.
        // ============================================================
        uint256 firstBuyWei = vm.envOr("FIRST_BUY", uint256(hook.ANTI_SNIPE_MAX_BUY_WEI()));
        // The first-buy runs in the same block as pool init, so the
        // anti-sniper cap is active. Refuse to launch with a first-buy
        // larger than the cap - it would just revert and waste the launch.
        require(firstBuyWei <= hook.ANTI_SNIPE_MAX_BUY_WEI(), "FIRST_BUY > cap");
        if (firstBuyWei > 0) {
            router.swap{value: firstBuyWei}(
                keyA,
                // forge-lint: disable-next-line(unsafe-typecast)
                SwapParams({zeroForOne: true, amountSpecified: -int256(firstBuyWei), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                ""
            );
            router.swap{value: firstBuyWei}(
                keyB,
                // forge-lint: disable-next-line(unsafe-typecast)
                SwapParams({zeroForOne: true, amountSpecified: -int256(firstBuyWei), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                ""
            );
            console2.log("First-buy executed on both pools, each:", firstBuyWei, "wei");
        }
        vm.stopBroadcast();

        console2.log("=========================================");
        console2.log("DoubleSine system deployed:");
        console2.log("  Router:", address(router));
        console2.log("  TokenA:", address(tokenA));
        console2.log("  TokenB:", address(tokenB));
        console2.log("  Hook:",   address(hook));
        console2.log("  PoolManager:", poolManager);
        console2.log("  Deployer A bal:", tokenA.balanceOf(deployer));
        console2.log("  Deployer B bal:", tokenB.balanceOf(deployer));
        console2.log("=========================================");
        console2.log("REMINDER (per policy):");
        console2.log("  Submit this tx via Flashbots Protect to avoid");
        console2.log("  reorg / public mempool sniping during the window.");
    }
}
