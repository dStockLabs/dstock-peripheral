# DStock Peripheral

Peripheral contracts for the DStock ecosystem, providing LayerZero-integrated bridge and router functionality for cross-chain token operations.

## Overview

This repository contains contracts that enable:

- **One-click wrap and bridge**: Wrap underlying tokens (BSC-local ERC20 or OFT assets) and bridge shares to destination chains in a single transaction
- **One-click wrap and bridge (native)**: Wrap native gas token (BNB/ETH) into WBNB/WETH and bridge shares in a single transaction
- **Automatic unwrapping**: LayerZero compose messages can trigger unwrapping of shares into the configured underlying token (and optionally deliver locally on the same chain)

## Contracts

- **DStockComposerRouter**: Unified router that supports:
  - user-initiated wrap + bridge (`wrapAndBridge`, `quoteWrapAndBridge`)
  - user-initiated native wrap + bridge (`wrapAndBridgeNative`)
  - LayerZero compose handling for forward and reverse routes (`lzCompose`)
  - reverse local native delivery when `ReverseRouteMsg.underlying == wrappedNative` and `finalDstEid == chainEid`

## How it works (quick mental model)

`DStockComposerRouter` supports two kinds of entrypoints:

- **User entry (EOA calls)**:
  - `wrapAndBridge(underlying, amount, dstEid, to, extraOptions, minAmountLD)`
  - `quoteWrapAndBridge(underlying, amount, dstEid, to, extraOptions)`
  - `quoteWrapAndBridgeNative(amountNative, dstEid, to, extraOptions)`

- **Compose entry (LayerZero Endpoint calls)**:
  - `lzCompose(_oApp, _guid, _message, ...)`

### Forward vs Reverse (compose)

- **Forward compose**:
  - `_oApp == underlying` (the token that was credited to this router)
  - router wraps underlying into wrapper shares
  - router bridges shares via `shareAdapter`

- **Reverse compose**:
  - `_oApp == shareAdapter` (shares adapter credited shares to this router)
  - router unwraps shares into `underlying`
  - if `finalDstEid == chainEid`: deliver underlying locally to the EVM address encoded in `finalTo`
  - else: bridge underlying via `underlying.send(...)`

## Configuration (owner/admin)

The router uses a minimal registry. The owner configures routes via:

- `setRouteConfig(underlying, wrapper, shareAdapter)`
  - always sets reverse mapping: `shareAdapter -> wrapper`
  - if `underlying != address(0)`: also sets forward mapping: `underlying -> (wrapper, shareAdapter)`

Notes:
- A single `(wrapper, shareAdapter)` pair can be reused by multiple underlyings (call `setRouteConfig` multiple times).
- `underlying` can be a **BSC-local ERC20** or an **EVM OFT token/adapter** address, as long as the wrapper supports it.

### Wrapped native configuration (BNB/ETH)

To support native gas token flows:

- **User entry (native -> shares -> bridge)**:
  - Set wrapped native token: `setWrappedNative(WBNB_or_WETH)`
  - Register route for wrapped native (required by `wrapAndBridgeNative`): `setRouteConfig(WBNB_or_WETH, wrapper, shareAdapter)`

- **Reverse local native delivery (shares -> WBNB/WETH -> native payout)**:
  - Deploy helper contract `WrappedNativePayoutHelper`
  - Set it on router: `setWrappedNativePayoutHelper(helperAddress)`
  - In `ReverseRouteMsg`, set `underlying = WBNB_or_WETH` and `finalDstEid = chainEid`

Why the helper is required:
- Standard WETH9/WBNB `withdraw()` uses `transfer` (2300 gas). When the router is behind a proxy, receiving native via `transfer` can fail.
- The helper is a non-proxy contract that safely receives the native from `withdraw()` and forwards it to the final receiver.

## Compose payloads (RouteMsg / ReverseRouteMsg)

The router expects `composeMsg` to be ABI-encoded structs:

- **Forward**: `abi.encode(RouteMsg)`
  - `finalDstEid`: destination EID for shares (second hop)
  - `finalTo`: bytes32 recipient on destination
  - `refundBsc`: EVM address on this chain to receive refunds on failures
  - `minAmountLD2`: min shares for second hop (0 = accept full amount)

- **Reverse**: `abi.encode(ReverseRouteMsg)`
  - `underlying`: underlying token address to receive after unwrapping
  - `finalDstEid`: final destination EID for underlying (second hop); if equals `chainEid`, deliver locally
  - `finalTo`: bytes32 recipient; if delivering locally, it must encode an EVM address
  - `refundBsc`: EVM address on this chain to receive refunds on failures
  - `minAmountLD2`: min underlying for second hop (0 = accept full amount)
  - `extraOptions2`: LayerZero options for the second hop
  - `composeMsg2`: compose payload for the second hop (optional)

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

## Installation

```bash
git clone https://github.com/dstockofficial/dstock-peripheral.git
cd dstock-peripheral
forge install
```

## Usage

### Compile

```bash
forge build
```

### Test

```bash
forge test
```

If your environment blocks Foundry's network calls (or you hit `OpenChainClient` issues), use:

```bash
forge test --offline
```

### Deploy

#### Deploy DStockComposerRouter (UUPS implementation + proxy)

```bash
ADMIN_PK=<deployer_private_key> \
ENDPOINT_ADDRESS=<layerzero_endpoint_v2_address> \
CHAIN_EID=<this_chain_eid> \
OWNER_ADDRESS=<router_owner_address> \
WRAPPER_ADDRESS=<dstock_wrapper_address_optional> \
SHARE_ADAPTER_ADDRESS=<shares_oft_adapter_address_optional> \
UNDERLYING_ADDRESS=<underlying_token_address_optional> \
WRAPPED_NATIVE_ADDRESS=<wbnb_or_weth_optional> \
WRAPPED_NATIVE_PAYOUT_HELPER_ADDRESS=<optional_predeployed_helper_address> \
forge script script/DeployComposerRouterProxy.s.sol:DeployComposerRouterProxy \
  --rpc-url <your_rpc_url> \
  --broadcast \
  --verify
```
```
forge script script/DeployComposerRouterProxy.s.sol:DeployComposerRouterProxy --rpc-url https://bsc-rpc.publicnode.com --chain-id 56 --legacy --broadcast -vvvv
```

After deploying, you can register more routes by calling `setRouteConfig(underlying, wrapper, shareAdapter)` as owner.

### Post-deploy: Apply / Verify Route Configs

Two Node.js scripts are provided for managing routes after deployment. They require no npm dependencies and use `fetch` + `cast` from Foundry.

#### `scripts/reapplyRouteConfig.js` — Apply missing routes

Reads `ROUTE_CONFIGS` and calls `setRouteConfig` for each entry that is not yet correctly configured on-chain. Already-correct routes are skipped automatically.

**Required env vars:**

| Variable | Description |
|---|---|
| `RPC_URL` | JSON-RPC endpoint |
| `ROUTER_ADDRESS` | Deployed router proxy address |
| `ROUTE_CONFIGS` | JSON array of `[underlying, wrapper, shareAdapter]` tuples |
| `PRIVATE_KEY` or `ADMIN_PK` | Admin signing key (`PRIVATE_KEY`: `0x`-prefixed hex; `ADMIN_PK`: integer as used by forge) |

**Optional env vars:**

| Variable | Description | Example |
|---|---|---|
| `GAS_PRICE` | Custom gas price (recommended for BSC) | `3gwei` |
| `LEGACY_TX` | Force legacy transactions (recommended for BSC public RPCs) | `1` |
| `DRY_RUN` | Print commands without sending transactions | `1` |

**`ROUTE_CONFIGS` format** (array of 3-element arrays):

```bash
ROUTE_CONFIGS='[
  ["0xUNDERLYING", "0xWRAPPER", "0xSHARE_ADAPTER"],
  ["0x0000000000000000000000000000000000000000", "0xWRAPPER2", "0xSHARE_ADAPTER2"]
]'
```

> Set `underlying` to the zero address (`0x000...0`) to register only the reverse mapping (`shareAdapter -> wrapper`), without a forward mapping.

**Usage:**

```bash
# Load env vars
set -a && source .env && set +a

# Dry-run first (no transactions sent)
DRY_RUN=1 node scripts/reapplyRouteConfig.js

# Execute
node scripts/reapplyRouteConfig.js
```

**Example output:**

```
[0] setRouteConfig(forward+reverse)
  underlying=0x992879...
  wrapper   =0x8ede6a...
  adapter   =0xf351fa...
  [check] shareAdapterToWrapper:    onchain=0x000...0  expected=0x8ede6a...  ❌
  [check] underlyingToWrapper:      onchain=0x000...0  expected=0x8ede6a...  ❌
  [check] underlyingToShareAdapter: onchain=0x000...0  expected=0xf351fa...  ❌
  => not fully set, sending transaction...

[1] setRouteConfig(forward+reverse)
  ...
  => already correctly configured on-chain, skipping.

Done. sent=12 skipped=1
```

---

#### `scripts/checkRouteConfig.js` — Verify on-chain route state

Queries the router contract for all routes in `ROUTE_CONFIGS` and reports which are correctly set.

**Required env vars:** `RPC_URL`, `ROUTER_ADDRESS`, `ROUTE_CONFIGS`

**Optional env vars:** `WRAPPED_NATIVE_ADDRESS`, `WRAPPED_NATIVE_PAYOUT_HELPER_ADDRESS`

```bash
set -a && source .env && set +a
node scripts/checkRouteConfig.js
```

**Example output:**

```
Router: 0x7597fd...
wrappedNative: ✅ expected=0xbb4cdb... onchain=0xbb4cdb...

Routes:
- [0] ✅
  underlying=0x992879...
  ...
- [1] ❌
  underlying=0x8b8727...
  check reverse (adapter->wrapper): onchain=0x000...  expected=0x208aad...
  ...

One or more route checks FAILED.
```

Exit code is `0` if all checks pass, `1` if any check fails — suitable for use in CI pipelines.

---

#### Recommended workflow

```bash
# 1. Deploy the router
forge script script/DeployComposerRouterProxy.s.sol:DeployComposerRouterProxy \
  --rpc-url $RPC_URL --broadcast --legacy -vvvv

# 2. Apply all routes (skips already-set ones)
node scripts/reapplyRouteConfig.js

# 3. Verify
node scripts/checkRouteConfig.js
```
