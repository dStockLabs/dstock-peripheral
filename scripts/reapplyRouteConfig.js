/**
 * Re-apply DStockComposerRouter route configs on-chain (no npm deps).
 *
 * Uses `cast send` under the hood.
 * Before each transaction, queries the current on-chain state via eth_call.
 * If a route is already correctly configured, it is skipped with a notice.
 *
 * Required env vars (load via: `set -a && source .env && set +a`):
 * - RPC_URL
 * - ROUTER_ADDRESS
 * - ROUTE_CONFIGS  (JSON array; each entry: [underlying, wrapper, shareAdapter])
 *
 * Signing (choose one):
 * - PRIVATE_KEY: 0x-prefixed 32-byte hex private key
 * - ADMIN_PK: integer private key (as used by forge scripts); will be converted to 0x...32bytes
 *
 * Optional:
 * - GAS_PRICE: e.g. "0.05gwei" (recommended for BSC), passed to `cast send --gas-price`
 * - LEGACY_TX: "1" to force `--legacy` (recommended for BSC public RPCs)
 * - DRY_RUN: "1" to print commands without executing
 */

const { spawnSync } = require("node:child_process");

const ZERO = "0x0000000000000000000000000000000000000000";

// Function selectors for on-chain state queries (matches checkRouteConfig.js)
const SELECTORS = {
  underlyingToWrapper:      "0x68712c81",
  underlyingToShareAdapter: "0x175bb3d9",
  shareAdapterToWrapper:    "0x84102f59",
};

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

function adminPkToHex(pkDec) {
  // forge scripts sometimes use ADMIN_PK as a uint
  const bi = BigInt(String(pkDec).trim());
  if (bi <= 0n) throw new Error("ADMIN_PK must be > 0");
  let hex = bi.toString(16);
  if (hex.length > 64) throw new Error("ADMIN_PK is too large to be a 32-byte private key");
  hex = hex.padStart(64, "0");
  return "0x" + hex;
}

function getPrivateKeyHex() {
  if (process.env.PRIVATE_KEY && process.env.PRIVATE_KEY.trim().length > 0) {
    const pk = process.env.PRIVATE_KEY.trim();
    if (!/^0x[a-fA-F0-9]{64}$/.test(pk)) throw new Error("PRIVATE_KEY must be 0x + 64 hex chars");
    return pk;
  }
  if (process.env.ADMIN_PK && process.env.ADMIN_PK.trim().length > 0) {
    return adminPkToHex(process.env.ADMIN_PK);
  }
  throw new Error("Provide PRIVATE_KEY (preferred) or ADMIN_PK for signing");
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
    if (!Array.isArray(r) || r.length !== 3) {
      throw new Error(`ROUTE_CONFIGS[${i}] must be [underlying, wrapper, shareAdapter]`);
    }
    return {
      idx: i,
      underlying:   normAddr(`ROUTE_CONFIGS[${i}][0]`, r[0]),
      wrapper:      normAddr(`ROUTE_CONFIGS[${i}][1]`, r[1]),
      shareAdapter: normAddr(`ROUTE_CONFIGS[${i}][2]`, r[2])
    };
  });
}

// --- on-chain read helpers (no external deps, plain fetch) ---

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

async function ethCallAddress(rpcUrl, to, selector, addrArg) {
  const argHex = addrArg.toLowerCase().replace(/^0x/, "").padStart(64, "0");
  const data = selector + argHex;
  const result = await rpcCall(rpcUrl, "eth_call", [{ to, data }, "latest"]);
  if (typeof result !== "string" || !result.startsWith("0x")) {
    throw new Error(`Bad eth_call result: ${String(result)}`);
  }
  // ABI returns 32-byte word; address is the right-most 20 bytes.
  const hex = result.toLowerCase().replace(/^0x/, "").padStart(64, "0");
  return "0x" + hex.slice(24, 64);
}

/**
 * Returns true if the on-chain state already matches the desired route config.
 * Prints a summary of what was found.
 */
async function isAlreadySet(rpcUrl, router, r) {
  const reverseOnly = r.underlying === ZERO;

  // Always check reverse mapping: shareAdapter -> wrapper
  const onchainWrapper = await ethCallAddress(rpcUrl, router, SELECTORS.shareAdapterToWrapper, r.shareAdapter);
  const reverseOk = onchainWrapper === r.wrapper;

  if (reverseOnly) {
    console.log(`  [check] shareAdapterToWrapper: onchain=${onchainWrapper} expected=${r.wrapper} ${reverseOk ? "✅" : "❌"}`);
    return reverseOk;
  }

  // Forward mappings: underlying -> wrapper, underlying -> shareAdapter
  const onchainFwdWrapper  = await ethCallAddress(rpcUrl, router, SELECTORS.underlyingToWrapper,      r.underlying);
  const onchainFwdAdapter  = await ethCallAddress(rpcUrl, router, SELECTORS.underlyingToShareAdapter, r.underlying);
  const fwdWrapperOk = onchainFwdWrapper === r.wrapper;
  const fwdAdapterOk = onchainFwdAdapter === r.shareAdapter;

  console.log(`  [check] shareAdapterToWrapper:    onchain=${onchainWrapper}    expected=${r.wrapper}      ${reverseOk    ? "✅" : "❌"}`);
  console.log(`  [check] underlyingToWrapper:      onchain=${onchainFwdWrapper} expected=${r.wrapper}      ${fwdWrapperOk ? "✅" : "❌"}`);
  console.log(`  [check] underlyingToShareAdapter: onchain=${onchainFwdAdapter} expected=${r.shareAdapter} ${fwdAdapterOk ? "✅" : "❌"}`);

  return reverseOk && fwdWrapperOk && fwdAdapterOk;
}

// --- cast send helper ---

function run(cmd, args, { dryRun } = {}) {
  const pretty = [cmd, ...args].join(" ");
  if (dryRun) {
    console.log(`[dry-run] ${pretty}`);
    return { status: 0, stdout: "", stderr: "" };
  }
  const out = spawnSync(cmd, args, { encoding: "utf8" });
  if (out.status !== 0) {
    console.error(out.stdout || "");
    console.error(out.stderr || "");
    throw new Error(`Command failed (${out.status}): ${pretty}`);
  }
  return out;
}

async function main() {
  const rpcUrl  = requireEnv("RPC_URL");
  const router  = normAddr("ROUTER_ADDRESS", requireEnv("ROUTER_ADDRESS"));
  const pk      = getPrivateKeyHex();

  const gasPrice = process.env.GAS_PRICE?.trim();
  const legacy   = process.env.LEGACY_TX?.trim() === "1";
  const dryRun   = process.env.DRY_RUN?.trim() === "1";

  const routes = parseRoutes();
  if (routes.length === 0) {
    console.log("ROUTE_CONFIGS is empty; nothing to send.");
    return;
  }

  console.log(`RPC_URL=${rpcUrl}`);
  console.log(`ROUTER_ADDRESS=${router}`);
  console.log(`routes=${routes.length}`);
  console.log(`legacy=${legacy ? "yes" : "no"}`);
  if (gasPrice) console.log(`gasPrice=${gasPrice}`);
  if (dryRun)   console.log("DRY_RUN enabled; no transactions will be sent.");

  let skipped = 0;
  let sent    = 0;

  for (const r of routes) {
    const reverseOnly = r.underlying === ZERO;
    console.log(`\n[${r.idx}] setRouteConfig(${reverseOnly ? "reverse-only" : "forward+reverse"})`);
    console.log(`  underlying=${r.underlying}`);
    console.log(`  wrapper   =${r.wrapper}`);
    console.log(`  adapter   =${r.shareAdapter}`);

    // Pre-check: query current on-chain state before sending.
    const alreadySet = await isAlreadySet(rpcUrl, router, r);
    if (alreadySet) {
      console.log(`  => already correctly configured on-chain, skipping.`);
      skipped++;
      continue;
    }

    console.log(`  => not fully set, sending transaction...`);

    const args = [
      "send",
      "--rpc-url",    rpcUrl,
      "--private-key", pk
    ];
    if (legacy)   args.push("--legacy");
    if (gasPrice) args.push("--gas-price", gasPrice);

    args.push(
      router,
      "setRouteConfig(address,address,address)",
      r.underlying,
      r.wrapper,
      r.shareAdapter
    );

    run("cast", args, { dryRun });
    sent++;
  }

  console.log(`\nDone. sent=${sent} skipped=${skipped}`);
  console.log("  node scripts/checkRouteConfig.js");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
