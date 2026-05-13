# DoubleSine Frontend

Static trading console for the DoubleSine system.

## Run locally

Open `index.html` directly in a browser, or serve it:

```bash
python3 -m http.server 8000 --directory frontend
```

No build step. The page uses CDN-loaded Chart.js and ethers.js, with a
canvas fallback for the simulation charts if Chart.js is unavailable.

## Modes

**Simulation** is the default. It mirrors the on-chain curve math, including
conservative rounding, rounded-up fees, zero-output rejection, shared
`virtualEth`, and equal canonical hook prices for DSA and DSB.

**Live Read** connects to a deployed hook. Enter RPC URL and hook address in
the page, or call:

```js
connectLive(rpcUrl, hookAddress)
```

The page reads `virtualEth` / `ethReserve`, subscribes to `Buy` and `Sell`
events, and keeps the console charts and event table current.

## Market model

- Canonical ETH/DSA and ETH/DSB v4 pools are locked by the shared hook state.
- DSA and DSB remain plain transferable ERC20s for wallets, GMGN-style routes,
  DEX pools, custody, and other external venues.
- External venues can exist, but their reserves are independent from the
  canonical hook unless their route trades through the v4 PoolManager path.
