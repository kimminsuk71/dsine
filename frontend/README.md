# DoubleSine Frontend

Self-contained visualization for the DoubleSine price trajectory.

## Run locally

Just open `index.html` in a browser, or serve it:

```
python3 -m http.server 8000 --directory frontend
# then visit http://localhost:8000
```

No build step. Uses CDN-loaded Chart.js + ethers.js.

## Modes

**Simulation** (default): in-browser state machine using the same math as
`DoubleSineMath.sol`. Click `Buy A` / `Buy B` / `Sell A` / `Sell B` to
advance theta and watch the lens-shaped intertwining emerge in both the
time-series chart and the phase plot.

**Live**: call `connectLive(rpcUrl, hookAddress, hookAbi)` from the browser
console (with the deployed hook's address + ABI). The page subscribes to
`Buy` and `Sell` events and updates the charts in real time.

## What you should see

- Time series: priceA (red) and priceB (teal) trend upward, interlocking
  like a DNA double helix viewed from the side.
- Phase plot: trajectory point traces a sinusoid drifting diagonally up
  through (priceA, priceB) space. The "tilted sine wave on 45-degree
  axes" the design targets.
