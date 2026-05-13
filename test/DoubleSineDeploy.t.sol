// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
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
import {AtomicDoubleSineDeployer} from "../script/DeployDoubleSine.s.sol";

/// @notice Full-fidelity dry run of the production deployment flow. Exercises
/// the EXACT same sequence the deploy script will run on mainnet/Sepolia:
///   1. deploy router
///   2. deploy plain ERC20 tokens
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
    uint256 internal constant ANTI_SNIPE_MAX_BUY_WEI = 0.001 ether;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    receive() external payable {}

    function test_atomicLaunchFlow() public {
        PoolManager manager = new PoolManager(address(this));
        address owner = makeAddr("launch-owner");
        vm.prank(owner, owner);
        AtomicDoubleSineDeployer launcher = new AtomicDoubleSineDeployer();
        address beneficiary = owner;

        address predictedRouter = vm.computeCreateAddress(address(launcher), 1);
        address predictedTokenA = vm.computeCreateAddress(address(launcher), 2);
        address predictedTokenB = vm.computeCreateAddress(address(launcher), 3);
        bytes memory ctorArgs = abi.encode(
            IPoolManager(address(manager)),
            predictedRouter,
            DoubleSineToken(predictedTokenA),
            DoubleSineToken(predictedTokenB),
            address(launcher)
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(launcher), HOOK_FLAGS, type(DoubleSineHook).creationCode, ctorArgs);

        uint256 firstBuyWei = ANTI_SNIPE_MAX_BUY_WEI;
        vm.deal(owner, firstBuyWei * 2);
        vm.prank(owner, owner);
        AtomicDoubleSineDeployer.Deployment memory deployment = launcher.launch{value: firstBuyWei * 2}(
            AtomicDoubleSineDeployer.LaunchParams({
                poolManager: address(manager),
                beneficiary: beneficiary,
                hookSalt: salt,
                expectedHook: expectedHook,
                firstBuyWei: firstBuyWei
            })
        );

        assertEq(deployment.router, predictedRouter, "router prediction");
        assertEq(deployment.tokenA, predictedTokenA, "tokenA prediction");
        assertEq(deployment.tokenB, predictedTokenB, "tokenB prediction");
        assertEq(deployment.hook, expectedHook, "hook prediction");

        DoubleSineToken tokenA = DoubleSineToken(deployment.tokenA);
        DoubleSineToken tokenB = DoubleSineToken(deployment.tokenB);
        DoubleSineHook hook = DoubleSineHook(payable(deployment.hook));

        assertTrue(hook.poolAInitialized(), "pool A initialized");
        assertTrue(hook.poolBInitialized(), "pool B initialized");
        assertEq(hook.bootstrapBlock(), block.number, "bootstrap block");
        assertEq(hook.currentPriceA(), hook.currentPriceB(), "locked price");
        assertGt(tokenA.balanceOf(beneficiary), 0, "beneficiary got A");
        assertGt(tokenB.balanceOf(beneficiary), 0, "beneficiary got B");
        assertEq(tokenA.balanceOf(address(launcher)), 0, "launcher A swept");
        assertEq(tokenB.balanceOf(address(launcher)), 0, "launcher B swept");
        assertGe(address(hook).balance, hook.ethReserve(), "balance >= reserve");
    }

    function test_hookConstructorRejectsDuplicateTokens() public {
        PoolManager manager = new PoolManager(address(this));
        DoubleSineRouter router = new DoubleSineRouter(IPoolManager(address(manager)));
        DoubleSineToken token = new DoubleSineToken("DoubleSine A", "DSA", address(manager), address(router));

        address hookAddr = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
        vm.expectRevert(DoubleSineHook.DuplicateToken.selector);
        deployCodeTo(
            "DoubleSineHook.sol:DoubleSineHook",
            abi.encode(IPoolManager(address(manager)), address(router), token, token, address(this)),
            hookAddr
        );
    }

    function test_tokenConstructorRejectsSystemAddressWithoutCode() public {
        PoolManager manager = new PoolManager(address(this));
        DoubleSineRouter router = new DoubleSineRouter(IPoolManager(address(manager)));

        vm.expectRevert(DoubleSineToken.SystemAddressMustHaveCode.selector);
        new DoubleSineToken("DoubleSine A", "DSA", makeAddr("fake-manager"), address(router));

        vm.expectRevert(DoubleSineToken.SystemAddressMustHaveCode.selector);
        new DoubleSineToken("DoubleSine A", "DSA", address(manager), makeAddr("fake-router"));
    }

    function test_routerConstructorRejectsManagerWithoutCode() public {
        vm.expectRevert(DoubleSineRouter.SystemAddressMustHaveCode.selector);
        new DoubleSineRouter(IPoolManager(makeAddr("fake-manager")));
    }

    function test_hookConstructorRejectsSystemAddressWithoutCode() public {
        PoolManager manager = new PoolManager(address(this));
        DoubleSineRouter router = new DoubleSineRouter(IPoolManager(address(manager)));
        DoubleSineToken token = new DoubleSineToken("DoubleSine A", "DSA", address(manager), address(router));
        DoubleSineToken tokenB = new DoubleSineToken("DoubleSine B", "DSB", address(manager), address(router));

        vm.expectRevert(DoubleSineHook.SystemAddressMustHaveCode.selector);
        new DoubleSineHook(IPoolManager(makeAddr("fake-manager")), address(router), token, tokenB, address(this));
    }

    function test_hookRejectsNonOneToOneInitialPoolPrice() public {
        PoolManager manager = new PoolManager(address(this));
        DoubleSineRouter router = new DoubleSineRouter(IPoolManager(address(manager)));
        DoubleSineToken tokenA = new DoubleSineToken("DoubleSine A", "DSA", address(manager), address(router));
        DoubleSineToken tokenB = new DoubleSineToken("DoubleSine B", "DSB", address(manager), address(router));

        bytes memory ctorArgs =
            abi.encode(IPoolManager(address(manager)), address(router), tokenA, tokenB, address(this));
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(DoubleSineHook).creationCode, ctorArgs);
        DoubleSineHook hook = new DoubleSineHook{salt: salt}(
            IPoolManager(address(manager)), address(router), tokenA, tokenB, address(this)
        );
        require(address(hook) == expectedHook, "hook address mismatch");
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

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(DoubleSineHook.InvalidInitialPrice.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(keyA, SQRT_PRICE_1_1 + 1);
    }

    function test_atomicLaunchTokensArePlainERC20ForExternalContracts() public {
        PoolManager manager = new PoolManager(address(this));
        address owner = makeAddr("launch-owner");
        vm.prank(owner, owner);
        AtomicDoubleSineDeployer launcher = new AtomicDoubleSineDeployer();
        FakeIntegration externalVenue = new FakeIntegration();

        address predictedRouter = vm.computeCreateAddress(address(launcher), 1);
        address predictedTokenA = vm.computeCreateAddress(address(launcher), 2);
        address predictedTokenB = vm.computeCreateAddress(address(launcher), 3);
        bytes memory ctorArgs = abi.encode(
            IPoolManager(address(manager)),
            predictedRouter,
            DoubleSineToken(predictedTokenA),
            DoubleSineToken(predictedTokenB),
            address(launcher)
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(launcher), HOOK_FLAGS, type(DoubleSineHook).creationCode, ctorArgs);

        vm.deal(owner, ANTI_SNIPE_MAX_BUY_WEI * 2);
        vm.prank(owner, owner);
        AtomicDoubleSineDeployer.Deployment memory deployment = launcher.launch{value: ANTI_SNIPE_MAX_BUY_WEI * 2}(
            AtomicDoubleSineDeployer.LaunchParams({
                poolManager: address(manager),
                beneficiary: owner,
                hookSalt: salt,
                expectedHook: expectedHook,
                firstBuyWei: ANTI_SNIPE_MAX_BUY_WEI
            })
        );

        DoubleSineToken tokenA = DoubleSineToken(deployment.tokenA);
        uint256 amount = tokenA.balanceOf(owner) / 2;

        vm.prank(owner, owner);
        assertTrue(tokenA.transfer(address(externalVenue), amount), "transfer to external venue");

        externalVenue.route(tokenA, owner, amount);
        assertEq(tokenA.balanceOf(address(externalVenue)), 0, "external venue emptied");
        assertGt(tokenA.balanceOf(owner), 0, "owner recovered tokens");
    }

    function test_atomicLaunchRequiresOwnerBeneficiary() public {
        PoolManager manager = new PoolManager(address(this));
        AtomicDoubleSineDeployer launcher = new AtomicDoubleSineDeployer();

        address predictedRouter = vm.computeCreateAddress(address(launcher), 1);
        address predictedTokenA = vm.computeCreateAddress(address(launcher), 2);
        address predictedTokenB = vm.computeCreateAddress(address(launcher), 3);
        bytes memory ctorArgs = abi.encode(
            IPoolManager(address(manager)),
            predictedRouter,
            DoubleSineToken(predictedTokenA),
            DoubleSineToken(predictedTokenB),
            address(launcher)
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(launcher), HOOK_FLAGS, type(DoubleSineHook).creationCode, ctorArgs);

        vm.expectRevert(AtomicDoubleSineDeployer.BeneficiaryMustBeOwner.selector);
        launcher.launch{value: ANTI_SNIPE_MAX_BUY_WEI * 2}(
            AtomicDoubleSineDeployer.LaunchParams({
                poolManager: address(manager),
                beneficiary: makeAddr("not-owner-beneficiary"),
                hookSalt: salt,
                expectedHook: expectedHook,
                firstBuyWei: ANTI_SNIPE_MAX_BUY_WEI
            })
        );
    }

    function test_atomicLaunchOnlyOwnerCanLaunch() public {
        PoolManager manager = new PoolManager(address(this));
        AtomicDoubleSineDeployer launcher = new AtomicDoubleSineDeployer();

        address predictedRouter = vm.computeCreateAddress(address(launcher), 1);
        address predictedTokenA = vm.computeCreateAddress(address(launcher), 2);
        address predictedTokenB = vm.computeCreateAddress(address(launcher), 3);
        bytes memory ctorArgs = abi.encode(
            IPoolManager(address(manager)),
            predictedRouter,
            DoubleSineToken(predictedTokenA),
            DoubleSineToken(predictedTokenB),
            address(launcher)
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(launcher), HOOK_FLAGS, type(DoubleSineHook).creationCode, ctorArgs);

        vm.deal(address(0xA11CE), ANTI_SNIPE_MAX_BUY_WEI * 2);
        vm.prank(address(0xA11CE));
        vm.expectRevert(AtomicDoubleSineDeployer.OnlyOwner.selector);
        launcher.launch{value: ANTI_SNIPE_MAX_BUY_WEI * 2}(
            AtomicDoubleSineDeployer.LaunchParams({
                poolManager: address(manager),
                beneficiary: address(this),
                hookSalt: salt,
                expectedHook: expectedHook,
                firstBuyWei: ANTI_SNIPE_MAX_BUY_WEI
            })
        );
    }

    function test_atomicLaunchRequiresExpectedHook() public {
        PoolManager manager = new PoolManager(address(this));
        AtomicDoubleSineDeployer launcher = new AtomicDoubleSineDeployer();

        vm.expectRevert(AtomicDoubleSineDeployer.ExpectedHookRequired.selector);
        launcher.launch{value: ANTI_SNIPE_MAX_BUY_WEI * 2}(
            AtomicDoubleSineDeployer.LaunchParams({
                poolManager: address(manager),
                beneficiary: address(this),
                hookSalt: bytes32(0),
                expectedHook: address(0),
                firstBuyWei: ANTI_SNIPE_MAX_BUY_WEI
            })
        );
    }

    function test_atomicLaunchRejectsIncorrectEth() public {
        PoolManager manager = new PoolManager(address(this));
        AtomicDoubleSineDeployer launcher = new AtomicDoubleSineDeployer();

        address predictedRouter = vm.computeCreateAddress(address(launcher), 1);
        address predictedTokenA = vm.computeCreateAddress(address(launcher), 2);
        address predictedTokenB = vm.computeCreateAddress(address(launcher), 3);
        bytes memory ctorArgs = abi.encode(
            IPoolManager(address(manager)),
            predictedRouter,
            DoubleSineToken(predictedTokenA),
            DoubleSineToken(predictedTokenB),
            address(launcher)
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(launcher), HOOK_FLAGS, type(DoubleSineHook).creationCode, ctorArgs);

        vm.expectRevert(AtomicDoubleSineDeployer.IncorrectEth.selector);
        launcher.launch{value: ANTI_SNIPE_MAX_BUY_WEI * 2 + 1}(
            AtomicDoubleSineDeployer.LaunchParams({
                poolManager: address(manager),
                beneficiary: address(this),
                hookSalt: salt,
                expectedHook: expectedHook,
                firstBuyWei: ANTI_SNIPE_MAX_BUY_WEI
            })
        );
    }

    function test_atomicLaunchCanOnlyRunOnce() public {
        PoolManager manager = new PoolManager(address(this));
        AtomicDoubleSineDeployer launcher = new AtomicDoubleSineDeployer();

        address predictedRouter = vm.computeCreateAddress(address(launcher), 1);
        address predictedTokenA = vm.computeCreateAddress(address(launcher), 2);
        address predictedTokenB = vm.computeCreateAddress(address(launcher), 3);
        bytes memory ctorArgs = abi.encode(
            IPoolManager(address(manager)),
            predictedRouter,
            DoubleSineToken(predictedTokenA),
            DoubleSineToken(predictedTokenB),
            address(launcher)
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(launcher), HOOK_FLAGS, type(DoubleSineHook).creationCode, ctorArgs);

        launcher.launch{value: ANTI_SNIPE_MAX_BUY_WEI * 2}(
            AtomicDoubleSineDeployer.LaunchParams({
                poolManager: address(manager),
                beneficiary: address(this),
                hookSalt: salt,
                expectedHook: expectedHook,
                firstBuyWei: ANTI_SNIPE_MAX_BUY_WEI
            })
        );

        vm.expectRevert(AtomicDoubleSineDeployer.AlreadyLaunched.selector);
        launcher.launch{value: 0}(
            AtomicDoubleSineDeployer.LaunchParams({
                poolManager: address(manager),
                beneficiary: address(this),
                hookSalt: salt,
                expectedHook: expectedHook,
                firstBuyWei: 0
            })
        );
    }

    function test_atomicLauncherRejectsDirectEth() public {
        AtomicDoubleSineDeployer launcher = new AtomicDoubleSineDeployer();

        (bool ok, bytes memory revertData) = address(launcher).call{value: 1 wei}("");
        assertFalse(ok, "direct eth should revert");
        assertEq(revertData, abi.encodeWithSelector(AtomicDoubleSineDeployer.DirectEthDisabled.selector));
    }

    function test_fullDeploymentFlow() public {
        // ============================================================
        // 1. Bedrock contracts
        // ============================================================
        PoolManager manager = new PoolManager(address(this));
        DoubleSineRouter router = new DoubleSineRouter(IPoolManager(address(manager)));

        // ============================================================
        // 2. Plain ERC20 tokens
        // ============================================================
        DoubleSineToken tokenA = new DoubleSineToken("DoubleSine A", "DSA", address(manager), address(router));
        DoubleSineToken tokenB = new DoubleSineToken("DoubleSine B", "DSB", address(manager), address(router));

        // ============================================================
        // 3. Mine the CREATE2 salt
        // ============================================================
        bytes memory ctorArgs =
            abi.encode(IPoolManager(address(manager)), address(router), tokenA, tokenB, address(this));
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(DoubleSineHook).creationCode, ctorArgs);

        // ============================================================
        // 4. CREATE2 deploy
        // ============================================================
        DoubleSineHook hook = new DoubleSineHook{salt: salt}(
            IPoolManager(address(manager)), address(router), tokenA, tokenB, address(this)
        );
        require(address(hook) == expectedHook, "hook address mismatch");
        router.bindSystem(tokenA, tokenB, address(hook));

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
        ) returns (
            BalanceDelta
        ) {
            return false;
        } catch {
            return true;
        }
    }
}

contract FakeIntegration {
    function route(DoubleSineToken token, address to, uint256 amount) external {
        bool ok = token.transfer(to, amount);
        require(ok, "route failed");
    }
}
