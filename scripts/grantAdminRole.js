/**
 * Grant ADMIN_ROLE to a multisig/admin address (no npm deps).
 *
 * Uses `cast call` + `cast send` under the hood.
 *
 * Required env vars (load via: `set -a && source .env && set +a`):
 * - RPC_URL
 * - ROUTER_ADDRESS
 *
 * Signing (choose one):
 * - PRIVATE_KEY: 0x-prefixed 32-byte hex private key
 * - ADMIN_PK: integer private key (as used by forge scripts); will be converted to 0x...32bytes
 *
 * Optional:
 * - MULTISIG_ADDRESS: defaults to 0x06be597d2ACFbF37c64F0c9ED4888389bE65b9f7
 * - GAS_PRICE: e.g. "0.05gwei" (recommended for BSC)
 * - LEGACY_TX: "1" to force `--legacy`
 * - DRY_RUN: "1" to print commands without executing
 *
 * Usage:
 *   set -a && source .env && set +a
 *   LEGACY_TX=1 GAS_PRICE=0.05gwei node scripts/grantAdminRole.js
 */

import { spawnSync } from "node:child_process";

const DEFAULT_MULTISIG = "0x1C7680D90143A3917096E5B02a4D3AB6A05d04EF";

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

function readAdminRole({ rpcUrl, router, dryRun }) {
  // ADMIN_ROLE is a public constant -> getter ADMIN_ROLE()(bytes32)
  const args = ["call", "--rpc-url", rpcUrl, router, "ADMIN_ROLE()(bytes32)"];
  const out = run("cast", args, { dryRun });
  const role = String(out.stdout || "").trim();
  if (!/^0x[a-fA-F0-9]{64}$/.test(role)) {
    throw new Error(`Unexpected ADMIN_ROLE() return: ${role}`);
  }
  return role;
}

async function main() {
  const rpcUrl = requireEnv("RPC_URL");
  const router = normAddr("ROUTER_ADDRESS", requireEnv("ROUTER_ADDRESS"));
  const pk = getPrivateKeyHex();

  const multisig = normAddr("MULTISIG_ADDRESS", process.env.MULTISIG_ADDRESS || DEFAULT_MULTISIG);
  const gasPrice = process.env.GAS_PRICE?.trim();
  const legacy = process.env.LEGACY_TX?.trim() === "1";
  const dryRun = process.env.DRY_RUN?.trim() === "1";

  console.log(`RPC_URL=${rpcUrl}`);
  console.log(`ROUTER_ADDRESS=${router}`);
  console.log(`MULTISIG_ADDRESS=${multisig}`);
  console.log(`legacy=${legacy ? "yes" : "no"}`);
  if (gasPrice) console.log(`gasPrice=${gasPrice}`);
  if (dryRun) console.log("DRY_RUN enabled; no transactions will be sent.");

  const role = readAdminRole({ rpcUrl, router, dryRun });
  console.log(`ADMIN_ROLE=${role}`);

  const sendArgs = ["send", "--rpc-url", rpcUrl, "--private-key", pk];
  if (legacy) sendArgs.push("--legacy");
  if (gasPrice) sendArgs.push("--gas-price", gasPrice);

  sendArgs.push(router, "grantRole(bytes32,address)", role, multisig);
  run("cast", sendArgs, { dryRun });

  console.log("\nDone.");
  console.log("Optional verify:");
  console.log(`  cast call --rpc-url ${rpcUrl} ${router} "hasRole(bytes32,address)(bool)" ${role} ${multisig}`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

