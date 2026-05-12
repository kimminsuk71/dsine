# DoubleSine

Twin-token system on Uniswap v4: two ERC20s (**DSA** and **DSB**) whose prices are mathematically locked to be equal at every moment. Deployed unauthorized contracts are blocked from receiving or moving the tokens, so the canonical hook pool is the only supported market.

```
                                    ┌──────────────────────────────┐
                                    │      DoubleSineHook          │
   ┌──────────────┐                 │  ┌────────────────────────┐  │                 ┌──────────────┐
   │  ETH/DSA     │ ◄── beforeSwap ─┤  │  shared virtualEth      │ ├─ beforeSwap ──► │  ETH/DSB     │
   │  pool        │                 │  │  K = vE * vT constant  │  │                 │  pool        │
   └──────────────┘                 │  │  reserve (real ETH)    │  │                 └──────────────┘
                                    │  └────────────────────────┘  │
                                    └──────────────────────────────┘
                                                  ▲
                                                  │
                                          DoubleSineRouter
                                                  ▲
                                                  │
                                          user / integration
```

## Properties

- **Two tokens, one price** — any trade on either side moves both prices identically.
- **No external venues by default** — token transfers are gated so deployed external pools (v2 Pair, v3 Pool, CEX deposits, lending markets) cannot receive or move A/B. The canonical hook pool is the only supported market.
- **Pump-style bonding curve** — single shared virtual reserve drives pricing; parabolic shape (flat at start, steeper as inflows accumulate).
- **Anti-sniper window** — first 5 blocks after init cap per-swap buys at 0.001 ETH on both pools.
- **No LP risk** — the hook *is* the AMM; `addLiquidity` reverts.
- **Reserve permanent** — every swap takes a 1% fee on each side; the reserve cannot drain below accumulated fees.
- **Slippage protection** — optional `minOut` in `hookData = abi.encode(uint256)`.

## Layout

```
src/                         contracts
├── DoubleSineMath.sol       pure curve math (constant product x*y=k)
├── DoubleSineToken.sol      restricted ERC20 (no-arb transfer gate)
├── DoubleSineHook.sol       single hook controlling both ETH/A and ETH/B pools
└── DoubleSineRouter.sol     bound ETH-entry router (serves only canonical PoolKeys)

test/
├── DoubleSineMath.t.sol     curve invariants, price monotonicity, trajectory dump
├── DoubleSineHook.t.sol     end-to-end swaps, no-arb gate, anti-sniper, slippage
└── DoubleSineDeploy.t.sol   full deployment flow rehearsal (CREATE2 + initialize + first-buy)

script/
├── DeployDoubleSine.s.sol   launcher deploy + one-tx market launch / first-buy
└── utils/HookMiner.sol      CREATE2 salt miner for hook permission bits

frontend/
├── index.html               self-contained simulation + chart visualization
└── README.md                how to run the local visualizer
```

## Setup

```bash
git clone <repo>
cd dsine

# Install Solidity dependencies (Uniswap v4-core bundles forge-std, solmate, oz)
forge install Uniswap/v4-core --no-git

forge build
forge test
```

You should see **53 tests passing** across three suites. The CI-style command excludes the two trajectory dump tests and should report **51 tests passing**:

```bash
forge test -vv --no-match-test "test_emitTrajectory|test_trajectory"
```

## Deployment

The deploy script first deploys an `AtomicDoubleSineDeployer`, predicts the launch-created addresses, mines the hook salt off-chain, then sends one `launch` transaction. That `launch` transaction deploys the router, tokens, hook, binds the router to the canonical tokens/hook, initializes both pools, and performs the optional first-buy atomically.

```bash
# Sepolia
POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 \
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3 \
UNIVERSAL_ROUTER=<sepolia universal router> \
forge script script/DeployDoubleSine.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --private-key $DEPLOYER_PK \
  --broadcast

# Mainnet (submit the launch tx via Flashbots Protect to reduce sniper exposure)
POOL_MANAGER=0x000000000004444c5dc75cB358380D2e3dE08A90 \
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3 \
UNIVERSAL_ROUTER=0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af \
forge script script/DeployDoubleSine.s.sol \
  --rpc-url https://rpc.flashbots.net \
  --private-key $DEPLOYER_PK \
  --broadcast
```

### Optional env vars

| Var | Default | Meaning |
|-----|---------|---------|
| `FIRST_BUY` | `1_000_000_000_000_000` (0.001 ETH) | Atomic first-buy size per pool; must be `<= ANTI_SNIPE_MAX_BUY_WEI`. Set to `0` to skip. |
| `PERMIT2` | unset | Optional token auth entry for integrations that custody/forward tokens. Does not permit direct PoolManager deposits. |
| `UNIVERSAL_ROUTER` | unset | Optional token auth entry for integrations that custody/forward tokens. Direct v4 PoolManager deposits remain blocked. |

## Frontend

Local visualizer (simulation mode, no contract needed):

```bash
python3 -m http.server 8000 --directory frontend
# open http://localhost:8000
```

For live mode (after deploying), call `connectLive(rpcUrl, hookAddress, hookAbi)` in the dev console. It subscribes to `Buy` and `Sell` events and updates the chart in real time.

## What it can and can't do

✅ **Can**

- Trade DSA and DSB on the canonical hook pool through `DoubleSineRouter`.
- Transfer DSA/DSB freely between EOAs.
- Allow approved integration contracts to custody/forward tokens when explicitly included in the auth list.

❌ **Can't**

- Deposit DSA/DSB to Aave, Compound, or most other DeFi protocols (transfer to their contracts reverts).
- List DSA/DSB on a CEX (deposit contracts can't hold the token).
- Open a deployed v2 Pair / v3 Pool for DSA/DSB (the pool contract itself can't receive or move the token).
- Seed an alternate v4 pool through the singleton PoolManager; deposits into PoolManager are restricted to the canonical router/hook settlement path.

These trade-offs are how the no-external-venue property is enforced. The canonical hook pool is the only supported venue, so there should be no persistent second market to arbitrage against.

## Security

- **Reentrancy**: hook never makes external calls before state writes; PoolManager doesn't callback into the hook from take/settle.
- **No-arb gate**: enforced at `_transfer` via contract-code checks on both `from` and `to`. Deployed contracts must be in the locked authorization list; only `bindHook` can add the hook itself, once.
- **Router key gate**: `DoubleSineRouter` is one-time bound to tokenA/tokenB plus the canonical hook and rejects non-canonical PoolKeys before pulling user tokens.
- **Hook binding guard**: token and router binding reject hook addresses without deployed code and verify the hook's `manager/tokenA/tokenB` getters match the system being bound.
- **PoolManager singleton guard**: v4 PoolManager is authorized for canonical settlement, but token deposits into PoolManager are only accepted from this system's bound router or hook. This blocks alternate v4 pools from being seeded with DSA/DSB.
- **Code-length caveat**: the EVM cannot distinguish an EOA from an address that will deploy code in the future. Such an address can receive while it has no code, but once code exists it cannot move tokens unless authorized.
- **Mint authority**: `onlyHook` modifier + target check (`to == hook`) — even a buggy hook can't mint to arbitrary addresses.
- **Reserve invariant**: `address(hook).balance >= ethReserve` always holds. The accounting allows orphan ETH (direct donations) without breaking sells.
- **Anti-sniper**: 5-block window enforces 0.001 ETH cap on per-swap buys. Both pools share one bootstrap anchor.
- **CREATE2 mining**: the hook address self-encodes its permission flags, verified by Uniswap's `Hooks.validateHookPermissions` in the constructor.

Audited in-house. **Not yet independently audited** — recommend an external review before mainnet deployment with significant TVL.

## License

[MIT](./LICENSE)
