/**
 * Re-apply DStockComposerRouter route configs on-chain (no npm deps).
 *
 * Uses `cast send` under the hood.
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

import { spawnSync } from "node:child_process";

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
  return s;
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
      underlying: normAddr(`ROUTE_CONFIGS[${i}][0]`, r[0]),
      wrapper: normAddr(`ROUTE_CONFIGS[${i}][1]`, r[1]),
      shareAdapter: normAddr(`ROUTE_CONFIGS[${i}][2]`, r[2])
    };
  });
}

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
  const rpcUrl = requireEnv("RPC_URL");
  const router = normAddr("ROUTER_ADDRESS", requireEnv("ROUTER_ADDRESS"));
  const pk = getPrivateKeyHex();

  const gasPrice = process.env.GAS_PRICE?.trim();
  const legacy = process.env.LEGACY_TX?.trim() === "1";
  const dryRun = process.env.DRY_RUN?.trim() === "1";

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
  if (dryRun) console.log("DRY_RUN enabled; no transactions will be sent.");

  for (const r of routes) {
    const reverseOnly = r.underlying.toLowerCase() === ZERO;
    console.log(`\n[${r.idx}] setRouteConfig(${reverseOnly ? "reverse-only" : "forward+reverse"})`);
    console.log(`  underlying=${r.underlying}`);
    console.log(`  wrapper   =${r.wrapper}`);
    console.log(`  adapter   =${r.shareAdapter}`);

    const args = [
      "send",
      "--rpc-url",
      rpcUrl,
      "--private-key",
      pk
    ];
    if (legacy) args.push("--legacy");
    if (gasPrice) args.push("--gas-price", gasPrice);

    args.push(
      router,
      "setRouteConfig(address,address,address)",
      r.underlying,
      r.wrapper,
      r.shareAdapter
    );

    run("cast", args, { dryRun });
  }

  console.log("\nDone. Re-run:");
  console.log("  node scripts/checkRouteConfig.js");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

