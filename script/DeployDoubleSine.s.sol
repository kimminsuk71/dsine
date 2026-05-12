// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
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
///   PERMIT2          - optional token auth entry for integrations
///   UNIVERSAL_ROUTER - optional token auth entry for integrations
///   PRIVATE_KEY      - deployer signer (set via --private-key flag instead)
///
/// Run with:
///   forge script script/DeployDoubleSine.s.sol \
///     --rpc-url $RPC \
///     --private-key $PK \
///     --broadcast
contract DeployDoubleSine is Script {
    uint256 internal constant ANTI_SNIPE_MAX_BUY_WEI = 0.001 ether;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    error FirstBuyTooLarge();

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address permit2 = vm.envOr("PERMIT2", address(0));
        address universalRouter = vm.envOr("UNIVERSAL_ROUTER", address(0));
        uint256 firstBuyWei = vm.envOr("FIRST_BUY", ANTI_SNIPE_MAX_BUY_WEI);
        address deployer = msg.sender;

        // ============================================================
        // 1. Deploy the launch executor. This transaction is not market
        //    sensitive because no tokens or pools exist yet.
        // ============================================================
        vm.startBroadcast();
        AtomicDoubleSineDeployer launcher = new AtomicDoubleSineDeployer();
        vm.stopBroadcast();
        console2.log("AtomicDoubleSineDeployer:", address(launcher));

        // ============================================================
        // 2. Predict launch-created addresses and mine the hook salt
        //    off-chain. The launch transaction only deploys with this
        //    precomputed salt, avoiding expensive on-chain salt mining.
        // ============================================================
        address predictedRouter = vm.computeCreateAddress(address(launcher), 1);
        address predictedTokenA = vm.computeCreateAddress(address(launcher), 2);
        address predictedTokenB = vm.computeCreateAddress(address(launcher), 3);

        bytes memory ctorArgs = abi.encode(
            IPoolManager(poolManager),
            DoubleSineToken(predictedTokenA),
            DoubleSineToken(predictedTokenB),
            address(launcher)
        );
        // slither-disable-next-line too-many-digits
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(launcher), HOOK_FLAGS, type(DoubleSineHook).creationCode, ctorArgs);
        console2.log("Predicted router:", predictedRouter);
        console2.log("Predicted tokenA:", predictedTokenA);
        console2.log("Predicted tokenB:", predictedTokenB);
        console2.log("Mined hook address:", expectedHook);
        console2.logBytes32(salt);

        // The first-buy runs inside the same transaction as pool init, so
        // refuse to launch with an amount that would hit the anti-snipe cap.
        if (firstBuyWei > ANTI_SNIPE_MAX_BUY_WEI) revert FirstBuyTooLarge();

        // ============================================================
        // 3. Atomic launch: router + tokens + hook + binding + both pool
        //    initializations + optional first-buy all happen in one tx.
        // ============================================================
        vm.startBroadcast();
        AtomicDoubleSineDeployer.Deployment memory deployment = launcher.launch{value: firstBuyWei * 2}(
            AtomicDoubleSineDeployer.LaunchParams({
                poolManager: poolManager,
                permit2: permit2,
                universalRouter: universalRouter,
                beneficiary: deployer,
                hookSalt: salt,
                expectedHook: expectedHook,
                firstBuyWei: firstBuyWei
            })
        );
        vm.stopBroadcast();

        console2.log("=========================================");
        console2.log("DoubleSine system deployed:");
        console2.log("  Launcher:", address(launcher));
        console2.log("  Router:", deployment.router);
        console2.log("  TokenA:", deployment.tokenA);
        console2.log("  TokenB:", deployment.tokenB);
        console2.log("  Hook:", deployment.hook);
        console2.log("  PoolManager:", poolManager);
        console2.log("  Deployer A bal:", DoubleSineToken(deployment.tokenA).balanceOf(deployer));
        console2.log("  Deployer B bal:", DoubleSineToken(deployment.tokenB).balanceOf(deployer));
        console2.log("=========================================");
        console2.log("REMINDER (per policy):");
        console2.log("  Submit the launch tx via Flashbots Protect to reduce");
        console2.log("  public mempool sniping and reorg exposure.");
    }
}

/// @notice One-call launcher for the market-sensitive deployment section.
/// The outer script may deploy this helper in a prior transaction, but `launch`
/// performs token deployment, hook deployment, pool initialization, and first
/// buys atomically.
contract AtomicDoubleSineDeployer {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint256 internal constant ANTI_SNIPE_MAX_BUY_WEI = 0.001 ether;
    address public immutable owner;

    struct LaunchParams {
        address poolManager;
        address permit2;
        address universalRouter;
        address beneficiary;
        bytes32 hookSalt;
        address expectedHook;
        uint256 firstBuyWei;
    }

    struct Deployment {
        address router;
        address tokenA;
        address tokenB;
        address hook;
    }

    event Launched(
        address indexed beneficiary, address router, address tokenA, address tokenB, address hook, uint256 firstBuyWei
    );

    error ZeroAddress();
    error FirstBuyTooLarge();
    error InsufficientEth();
    error HookAddressMismatch();
    error UnexpectedInitialTick();
    error FirstBuyFailed();
    error TokenTransferFailed();
    error EthTransferFailed();
    error OnlyOwner();

    receive() external payable {}

    constructor() {
        owner = msg.sender;
    }

    // slither-disable-next-line cyclomatic-complexity
    function launch(LaunchParams calldata params) external payable returns (Deployment memory deployment) {
        if (msg.sender != owner) revert OnlyOwner();
        if (params.poolManager == address(0) || params.beneficiary == address(0)) revert ZeroAddress();
        if (params.firstBuyWei > ANTI_SNIPE_MAX_BUY_WEI) revert FirstBuyTooLarge();
        if (msg.value < params.firstBuyWei * 2) revert InsufficientEth();

        DoubleSineRouter router = new DoubleSineRouter(IPoolManager(params.poolManager));

        uint256 authLen = 1 + (params.permit2 != address(0) ? 1 : 0) + (params.universalRouter != address(0) ? 1 : 0);
        address[] memory auth = new address[](authLen);
        uint256 idx = 0;
        auth[idx++] = address(this);
        if (params.permit2 != address(0)) auth[idx++] = params.permit2;
        if (params.universalRouter != address(0)) auth[idx++] = params.universalRouter;

        DoubleSineToken tokenA = new DoubleSineToken("DoubleSine A", "DSA", params.poolManager, address(router), auth);
        DoubleSineToken tokenB = new DoubleSineToken("DoubleSine B", "DSB", params.poolManager, address(router), auth);

        DoubleSineHook hook =
            new DoubleSineHook{salt: params.hookSalt}(IPoolManager(params.poolManager), tokenA, tokenB, address(this));
        if (params.expectedHook != address(0) && address(hook) != params.expectedHook) revert HookAddressMismatch();

        router.bindSystem(tokenA, tokenB, address(hook));
        tokenA.bindHook(address(hook));
        tokenB.bindHook(address(hook));

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
        int24 tickA = IPoolManager(params.poolManager).initialize(keyA, SQRT_PRICE_1_1);
        int24 tickB = IPoolManager(params.poolManager).initialize(keyB, SQRT_PRICE_1_1);
        if (tickA != 0 || tickB != 0) revert UnexpectedInitialTick();

        if (params.firstBuyWei > 0) {
            BalanceDelta firstBuyA = router.swap{value: params.firstBuyWei}(
                keyA,
                // forge-lint: disable-next-line(unsafe-typecast)
                SwapParams({
                    zeroForOne: true, amountSpecified: -int256(params.firstBuyWei), sqrtPriceLimitX96: MIN_PRICE_LIMIT
                }),
                ""
            );
            BalanceDelta firstBuyB = router.swap{value: params.firstBuyWei}(
                keyB,
                // forge-lint: disable-next-line(unsafe-typecast)
                SwapParams({
                    zeroForOne: true, amountSpecified: -int256(params.firstBuyWei), sqrtPriceLimitX96: MIN_PRICE_LIMIT
                }),
                ""
            );
            if (BalanceDelta.unwrap(firstBuyA) == 0 || BalanceDelta.unwrap(firstBuyB) == 0) revert FirstBuyFailed();

            uint256 balanceA = tokenA.balanceOf(address(this));
            uint256 balanceB = tokenB.balanceOf(address(this));
            if (balanceA > 0 && !tokenA.transfer(params.beneficiary, balanceA)) revert TokenTransferFailed();
            if (balanceB > 0 && !tokenB.transfer(params.beneficiary, balanceB)) revert TokenTransferFailed();
        }

        uint256 refund = msg.value - params.firstBuyWei * 2;
        if (refund > 0) _sendETH(msg.sender, refund);

        deployment = Deployment({
            router: address(router), tokenA: address(tokenA), tokenB: address(tokenB), hook: address(hook)
        });
        // slither-disable-next-line reentrancy-events
        emit Launched(
            params.beneficiary, address(router), address(tokenA), address(tokenB), address(hook), params.firstBuyWei
        );
    }

    function _sendETH(address to, uint256 amount) internal {
        // slither-disable-next-line low-level-calls
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
