/**
 * DStockComposerRouter route config verifier (no dependencies).
 *
 * Requires env vars (typically via: `set -a && source .env && set +a`):
 * - RPC_URL: JSON-RPC endpoint
 * - ROUTER_ADDRESS: deployed DStockComposerRouter proxy address
 * - ROUTE_CONFIGS: JSON array of { underlying, wrapper, shareAdapter, ... }
 *
 * Optional:
 * - WRAPPED_NATIVE_ADDRESS
 * - WRAPPED_NATIVE_PAYOUT_HELPER_ADDRESS
 */

const SELECTORS = {
  underlyingToWrapper: "0x68712c81", // keccak256("underlyingToWrapper(address)")[:4]
  underlyingToShareAdapter: "0x175bb3d9", // keccak256("underlyingToShareAdapter(address)")[:4]
  shareAdapterToWrapper: "0x84102f59", // keccak256("shareAdapterToWrapper(address)")[:4]
  wrappedNative: "0xeb6d3a11", // keccak256("wrappedNative()")[:4]
  wrappedNativePayoutHelper: "0x2ef392e4" // keccak256("wrappedNativePayoutHelper()")[:4]
};

const ZERO = "0x0000000000000000000000000000000000000000";

function requireEnv(name) {
  const v = process.env[name];
  if (!v || String(v).trim().length === 0) throw new Error(`Missing required env var: ${name}`);
  return String(v).trim();
}

function isHexAddress(v) {
  return /^0x[a-fA-F0-9]{40}$/.test(v);
}

function normAddr(label, v) {
  const s = String(v ?? "").trim();
  if (!isHexAddress(s)) throw new Error(`Invalid address for ${label}: ${s}`);
  return s.toLowerCase();
}

function pad32(hexNo0x) {
  return hexNo0x.padStart(64, "0");
}

function encodeAddressArg(addr) {
  const a = normAddr("address arg", addr).slice(2);
  return pad32(a);
}

function encodeCall(selector, maybeAddressArg) {
  if (!/^0x[a-fA-F0-9]{8}$/.test(selector)) throw new Error(`Bad selector: ${selector}`);
  if (!maybeAddressArg) return selector;
  return selector + encodeAddressArg(maybeAddressArg);
}

async function rpcCall(rpcUrl, method, params) {
  const res = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params })
  });
  if (!res.ok) throw new Error(`RPC HTTP ${res.status}: ${await res.text()}`);
  const json = await res.json();
  if (json.error) throw new Error(`RPC error: ${JSON.stringify(json.error)}`);
  return json.result;
}

async function ethCallAddress(rpcUrl, to, data) {
  const result = await rpcCall(rpcUrl, "eth_call", [{ to, data }, "latest"]);
  if (typeof result !== "string" || !result.startsWith("0x")) {
    throw new Error(`Bad eth_call result: ${String(result)}`);
  }
  // ABI returns 32-byte word, address is right-most 20 bytes.
  const hex = result.toLowerCase().replace(/^0x/, "").padStart(64, "0");
  const addr = "0x" + hex.slice(24, 64);
  return normAddr("eth_call return address", addr);
}

function parseRoutes() {
  const raw = requireEnv("ROUTE_CONFIGS");
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    throw new Error(`ROUTE_CONFIGS must be valid JSON. Parse error: ${e.message}`);
  }
  if (!Array.isArray(parsed)) throw new Error("ROUTE_CONFIGS must be a JSON array");
  return parsed.map((r, i) => {
    // Preferred format: [underlying, wrapper, shareAdapter]
    if (Array.isArray(r)) {
      if (r.length !== 3) throw new Error(`ROUTE_CONFIGS[${i}] must be [underlying, wrapper, shareAdapter]`);
      return {
        idx: i,
        symbol: "",
        underlying: normAddr(`ROUTE_CONFIGS[${i}][0]`, r[0]),
        wrapper: normAddr(`ROUTE_CONFIGS[${i}][1]`, r[1]),
        shareAdapter: normAddr(`ROUTE_CONFIGS[${i}][2]`, r[2])
      };
    }

    // Backward-compatible format: { underlying, wrapper, shareAdapter, symbol? }
    if (typeof r !== "object" || r === null) throw new Error(`ROUTE_CONFIGS[${i}] must be an array or object`);
    return {
      idx: i,
      symbol: r.symbol ?? r.name ?? "",
      underlying: normAddr(`ROUTE_CONFIGS[${i}].underlying`, r.underlying),
      wrapper: normAddr(`ROUTE_CONFIGS[${i}].wrapper`, r.wrapper),
      shareAdapter: normAddr(`ROUTE_CONFIGS[${i}].shareAdapter`, r.shareAdapter)
    };
  });
}

async function main() {
  const rpcUrl = requireEnv("RPC_URL");
  const router = normAddr("ROUTER_ADDRESS", requireEnv("ROUTER_ADDRESS"));
  const routes = parseRoutes();

  console.log(`Router: ${router}`);
  console.log(`RPC: ${rpcUrl}`);

  let ok = true;

  if (process.env.WRAPPED_NATIVE_ADDRESS) {
    const expected = normAddr("WRAPPED_NATIVE_ADDRESS", process.env.WRAPPED_NATIVE_ADDRESS);
    const onchain = await ethCallAddress(rpcUrl, router, encodeCall(SELECTORS.wrappedNative));
    const pass = expected === onchain;
    ok &&= pass;
    console.log(`wrappedNative: ${pass ? "✅" : "❌"} expected=${expected} onchain=${onchain}`);
  }

  if (process.env.WRAPPED_NATIVE_PAYOUT_HELPER_ADDRESS) {
    const expected = normAddr(
      "WRAPPED_NATIVE_PAYOUT_HELPER_ADDRESS",
      process.env.WRAPPED_NATIVE_PAYOUT_HELPER_ADDRESS
    );
    const onchain = await ethCallAddress(rpcUrl, router, encodeCall(SELECTORS.wrappedNativePayoutHelper));
    const pass = expected === onchain;
    ok &&= pass;
    console.log(`wrappedNativePayoutHelper: ${pass ? "✅" : "❌"} expected=${expected} onchain=${onchain}`);
  }

  console.log("\nRoutes:");
  for (const r of routes) {
    const label = r.symbol ? `${r.symbol} ` : "";
    const reverseOnchain = await ethCallAddress(
      rpcUrl,
      router,
      encodeCall(SELECTORS.shareAdapterToWrapper, r.shareAdapter)
    );
    const reverseOk = reverseOnchain === r.wrapper;

    let forwardWrapperOk = true;
    let forwardAdapterOk = true;
    let forwardWrapperOnchain = ZERO;
    let forwardAdapterOnchain = ZERO;

    if (r.underlying !== ZERO) {
      forwardWrapperOnchain = await ethCallAddress(
        rpcUrl,
        router,
        encodeCall(SELECTORS.underlyingToWrapper, r.underlying)
      );
      forwardAdapterOnchain = await ethCallAddress(
        rpcUrl,
        router,
        encodeCall(SELECTORS.underlyingToShareAdapter, r.underlying)
      );
      forwardWrapperOk = forwardWrapperOnchain === r.wrapper;
      forwardAdapterOk = forwardAdapterOnchain === r.shareAdapter;
    }

    const pass = reverseOk && forwardWrapperOk && forwardAdapterOk;
    ok &&= pass;

    console.log(
      `- ${label}[${r.idx}] ${pass ? "✅" : "❌"}\n` +
        `  underlying=${r.underlying}${r.underlying === ZERO ? " (reverse-only)" : ""}\n` +
        `  wrapper   =${r.wrapper}\n` +
        `  adapter   =${r.shareAdapter}\n` +
        `  check reverse (adapter->wrapper): onchain=${reverseOnchain}\n` +
        (r.underlying === ZERO
          ? ""
          : `  check forward (underlying->wrapper): onchain=${forwardWrapperOnchain}\n` +
            `  check forward (underlying->adapter): onchain=${forwardAdapterOnchain}\n`)
    );
  }

  if (!ok) {
    console.error("\nOne or more route checks FAILED.");
    process.exitCode = 1;
  } else {
    console.log("All route checks PASSED.");
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

