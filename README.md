# DoubleSine

Twin-token system on Uniswap v4: two plain ERC20s (**DSA** and **DSB**) whose canonical hook prices are mathematically locked to be equal at every moment. Tokens are freely transferable so wallets, DEX pools, aggregators, and GMGN-style routes can hold and move them normally. The entanglement invariant lives in the canonical v4 hook/Collider path, not in transfer restrictions.

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

- **Two tokens, one canonical price** — any trade through the canonical v4 hook on either side moves both hook prices identically.
- **Plain ERC20 external trading** — DSA/DSB can be transferred to EOAs, contracts, DEX pools, aggregator routers, and custody venues without an owner authorization list.
- **Canonical v4 Collider** — the official ETH/DSA and ETH/DSB v4 pools share one `virtualEth` state, so the hook enforces hard synchronization inside that path.
- **Pump-style bonding curve** — single shared virtual reserve drives pricing; parabolic shape (flat at start, steeper as inflows accumulate).
- **Anti-sniper window** — first 5 blocks after init cap per-swap buys at 0.001 ETH on both pools.
- **No LP risk** — the hook *is* the AMM; `addLiquidity` reverts.
- **Reserve permanent** — every swap takes a 1% fee on each side; the reserve cannot drain below accumulated fees.
- **Slippage protection** — optional `minOut` in `hookData = abi.encode(uint256)`.

## Layout

```
src/                         contracts
├── DoubleSineMath.sol       pure curve math (constant product x*y=k)
├── DoubleSineToken.sol      plain ERC20 with hook-only mint/burn
├── DoubleSineHook.sol       single hook controlling both ETH/A and ETH/B pools
└── DoubleSineRouter.sol     bound ETH-entry router (serves only canonical PoolKeys)

test/
├── DoubleSineMath.t.sol     curve invariants, price monotonicity, trajectory dump
├── DoubleSineHook.t.sol     end-to-end swaps, ERC20 compatibility, anti-sniper, slippage
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

You should see **85 tests passing** across three suites. The CI-style command excludes the two trajectory dump tests and should report **83 tests passing**:

```bash
forge test -vv --no-match-test "test_emitTrajectory|test_trajectory"
```

## Deployment

The deploy script first deploys an `AtomicDoubleSineDeployer`, predicts the launch-created addresses, mines the hook salt off-chain, then sends one `launch` transaction. That `launch` transaction deploys the router, tokens, hook, binds the router to the canonical tokens/hook, initializes both pools, and performs the optional first-buy atomically.

```bash
# Sepolia
POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 \
forge script script/DeployDoubleSine.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --private-key $DEPLOYER_PK \
  --broadcast

# Mainnet (submit the launch tx via Flashbots Protect to reduce sniper exposure)
POOL_MANAGER=0x000000000004444c5dc75cB358380D2e3dE08A90 \
forge script script/DeployDoubleSine.s.sol \
  --rpc-url https://rpc.flashbots.net \
  --private-key $DEPLOYER_PK \
  --broadcast
```

### Optional env vars

| Var | Default | Meaning |
|-----|---------|---------|
| `FIRST_BUY` | `1_000_000_000_000_000` (0.001 ETH) | Atomic first-buy size per pool; must be `<= ANTI_SNIPE_MAX_BUY_WEI`. Set to `0` to skip. |

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
- Route canonical v4 swaps through external PoolManager callers that settle correctly.
- Transfer DSA/DSB freely between EOAs and contracts.
- Seed external DEX pools or custody venues with ordinary ERC20 transfers.

❌ **Can't**

- Force an external V2/V3/CEX pool's independent reserves to update unless the trade goes through the canonical hook/Collider path.
- Prevent third parties from creating external markets. That is intentional for GMGN/aggregator compatibility.
- Add LP liquidity to the canonical v4 hook pools; the hook is the AMM and `addLiquidity` reverts.

This mirrors the ANTI/PRO-style pattern more closely than a transfer blacklist: the tokens remain ordinary transferable assets, while the coupling logic lives in a separate AMM/Collider mechanism.

### Aggregator compatibility

DSA/DSB are standard transferable ERC20s, so aggregators and GMGN-style routers are not blocked at the token layer. The canonical v4 hook accepts swaps from any PoolManager caller, including third-party routers, as long as the caller settles the v4 deltas correctly. For best price synchronization, primary liquidity should live in the canonical v4 hook pools; external pools can exist and be traded, but their reserves are separate markets.

## Security

- **Reentrancy**: hook never makes external calls before state writes; PoolManager doesn't callback into the hook from take/settle.
- **Plain ERC20 transfer surface**: transfers and approvals follow ordinary ERC20 rules; external DEXs and routers are not gated by owner authorization.
- **Router key gate**: `DoubleSineRouter` is one-time bound to tokenA/tokenB plus the canonical hook and rejects non-canonical PoolKeys before pulling user tokens.
- **Hook/router binding guard**: token and router binding reject hook addresses without deployed code and verify the hook's `manager/router/tokenA/tokenB` getters match the system being bound.
- **Open canonical v4 swaps**: canonical hook swaps accept arbitrary PoolManager callers for the canonical PoolKeys. This allows third-party v4 routers while relying on PoolManager settlement invariants.
- **Orphan balance handling**: direct token transfers to PoolManager or the hook are allowed at the ERC20 layer, but canonical buy/sell settlement syncs before transferring and preserves orphan balances instead of counting them as swap input.
- **Launcher binding**: `launch` is owner-only, and the first-buy beneficiary must be the owner.
- **Direct ETH guard**: router and launcher reject raw ETH transfers; hook only accepts ETH sent by PoolManager settlement, keeping reserve accounting from being externally polluted.
- **Forced ETH isolation**: ETH forced into the hook is not added to `ethReserve`, so sell payouts remain bounded by bookkept reserve rather than raw balance.
- **System address guard**: PoolManager, router, token, and hook addresses must already have deployed code before they can be bound.
- **Launcher ownership**: the atomic launcher can only be executed by its deployer, preventing a public-mempool caller from front-running `launch` and taking the first-buy allocation.
- **Exact-input bounds**: swap entrypoints explicitly reject `type(int256).min` amount values instead of relying on arithmetic panic behavior.
- **Curve math bounds**: spot price checks its safe multiplication domain before squaring, buy math avoids large intermediate products, and invalid virtual-reserve domains revert with explicit errors.
- **v4 delta bounds**: hook swaps reject amounts that cannot fit in v4 `int128` balance deltas before state changes or settlement.
- **Initial pool price guard**: canonical v4 pools must initialize at 1:1 tick 0, so the registered pool state cannot drift from deployment assumptions or external indexer expectations.
- **Mint authority**: `onlyHook` modifier + target check (`to == hook`) — even a buggy hook can't mint to arbitrary addresses.
- **Reserve invariant**: `address(hook).balance == ethReserve` for clean trading paths. Direct ETH transfers to the hook are rejected unless they come from PoolManager settlement.
- **Anti-sniper**: 5-block window enforces 0.001 ETH cap on per-swap buys. Both pools share one bootstrap anchor.
- **CREATE2 mining**: the hook address self-encodes its permission flags, verified by Uniswap's `Hooks.validateHookPermissions` in the constructor.

Audited in-house. **Not yet independently audited** — recommend an external review before mainnet deployment with significant TVL.

## License

[MIT](./LICENSE)
