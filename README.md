# DoubleSine

Twin-token system on Uniswap v4: two ERC20s (**DSA** and **DSB**) whose prices are mathematically locked to be equal at every moment, with no possibility of external pools or arbitrage.

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
                                          user / GMGN / aggregator
```

## Properties

- **Two tokens, one price** — any trade on either side moves both prices identically.
- **No arbitrage** — token transfers are gated so external pools (v2 Pair, v3 Pool, CEX deposits, lending markets) cannot receive A or B. The canonical hook pool is the only market.
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
└── DoubleSineRouter.sol     generic ETH-entry router (handles A and B by PoolKey)

test/
├── DoubleSineMath.t.sol     curve invariants, price monotonicity, trajectory dump
├── DoubleSineHook.t.sol     end-to-end swaps, no-arb gate, anti-sniper, slippage
└── DoubleSineDeploy.t.sol   full deployment flow rehearsal (CREATE2 + initialize + first-buy)

script/
├── DeployDoubleSine.s.sol   7-step deployment + atomic first-buy
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
forge install Uniswap/v4-core --no-commit

forge build
forge test
```

You should see **35 tests passing** across three suites.

## Deployment

The deploy script handles router + tokens + mined hook + pool init + atomic first-buy in one run.

```bash
# Sepolia
POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 \
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3 \
UNIVERSAL_ROUTER=<sepolia universal router> \
forge script script/DeployDoubleSine.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --private-key $DEPLOYER_PK \
  --broadcast

# Mainnet (submit via Flashbots Protect to evade sniper bots during the cap window)
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
| `PERMIT2` | unset | Whitelist Permit2 in token auth list (needed for Universal Router) |
| `UNIVERSAL_ROUTER` | unset | Whitelist Universal Router (needed for GMGN / aggregators) |

## Frontend

Local visualizer (simulation mode, no contract needed):

```bash
python3 -m http.server 8000 --directory frontend
# open http://localhost:8000
```

For live mode (after deploying), call `connectLive(rpcUrl, hookAddress, hookAbi)` in the dev console — it subscribes to `Buy` and `Sell` events and updates the chart in real time.

## What it can and can't do

✅ **Can**

- Trade DSA and DSB on the canonical hook pool through any caller (deployer, EOA, Universal Router, 1inch, GMGN, etc. — anything in the auth list at deploy time).
- Transfer DSA/DSB freely between EOAs.
- Be detected by DexScreener / DexTools / GMGN once Universal Router is in the auth list (recommended).

❌ **Can't**

- Deposit DSA/DSB to Aave, Compound, or most other DeFi protocols (transfer to their contracts reverts).
- List DSA/DSB on a CEX (deposit contracts can't hold the token).
- Open a v2 Pair / v3 Pool for DSA/DSB (the pool contract itself can't receive the token).

These trade-offs are how the no-arb property is enforced. The canonical hook pool is the only venue, so there's no second price to arbitrage against.

## Security

- **Reentrancy**: hook never makes external calls before state writes; PoolManager doesn't callback into the hook from take/settle.
- **No-arb gate**: enforced at `_transfer` via `to.code.length != 0 && !isAuthorized[to]`. The auth list is locked at construction (only `bindHook` can add the hook itself, once).
- **Mint authority**: `onlyHook` modifier + target check (`to == hook`) — even a buggy hook can't mint to arbitrary addresses.
- **Reserve invariant**: `address(hook).balance >= ethReserve` always holds. The accounting allows orphan ETH (direct donations) without breaking sells.
- **Anti-sniper**: 5-block window enforces 0.001 ETH cap on per-swap buys. Both pools share one bootstrap anchor.
- **CREATE2 mining**: the hook address self-encodes its permission flags, verified by Uniswap's `Hooks.validateHookPermissions` in the constructor.

Audited in-house. **Not yet independently audited** — recommend an external review before mainnet deployment with significant TVL.

## License

[MIT](./LICENSE)
