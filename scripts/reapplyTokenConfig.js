/**
 * Re-apply DStockHyperCoreComposer token configs on-chain (no npm deps).
 *
 * Uses `cast send` under the hood.
 * Before each transaction, queries the current on-chain tokenConfigs(address)
 * via eth_call. If a token is already correctly configured, it is skipped.
 *
 * Required env vars (load via: `set -a && source .env.hl && set +a`):
 * - RPC_URL
 * - COMPOSER_ADDRESS
 * - TOKEN_CONFIGS  (JSON array of objects; each: { coreIndexId, decimalDiff, oft, symbol })
 *
 * Signing (choose one):
 * - PRIVATE_KEY: 0x-prefixed 32-byte hex private key
 * - DEPLOYER_PK: 0x-prefixed 32-byte hex private key (alias)
 * - ADMIN_PK: integer private key (as used by forge scripts); will be converted to 0x...32bytes
 *
 * Optional:
 * - GAS_PRICE: e.g. "0.05gwei", passed to `cast send --gas-price`
 * - LEGACY_TX: "1" to force `--legacy`
 * - DRY_RUN: "1" to print commands without executing
 */

const { spawnSync } = require("node:child_process");

const BASE_ASSET_BRIDGE = 0x2000000000000000000000000000000000000000n;

// tokenConfigs(address) -> (uint64, int8, address, bool)
const SELECTOR_TOKEN_CONFIGS = "0x1b69dc5f";

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
  const bi = BigInt(String(pkDec).trim());
  if (bi <= 0n) throw new Error("ADMIN_PK must be > 0");
  let hex = bi.toString(16);
  if (hex.length > 64) throw new Error("ADMIN_PK is too large to be a 32-byte private key");
  hex = hex.padStart(64, "0");
  return "0x" + hex;
}

function getPrivateKeyHex() {
  // Check PRIVATE_KEY first, then DEPLOYER_PK, then ADMIN_PK
  for (const envName of ["PRIVATE_KEY", "DEPLOYER_PK"]) {
    const val = process.env[envName]?.trim();
    if (val && val.length > 0) {
      if (!/^0x[a-fA-F0-9]{64}$/.test(val)) throw new Error(`${envName} must be 0x + 64 hex chars`);
      return val;
    }
  }
  if (process.env.ADMIN_PK && process.env.ADMIN_PK.trim().length > 0) {
    return adminPkToHex(process.env.ADMIN_PK);
  }
  throw new Error("Provide PRIVATE_KEY, DEPLOYER_PK, or ADMIN_PK for signing");
}

function parseTokenConfigs() {
  const raw = requireEnv("TOKEN_CONFIGS");
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    throw new Error(`TOKEN_CONFIGS must be valid JSON. Parse error: ${e.message}`);
  }
  if (!Array.isArray(parsed)) throw new Error("TOKEN_CONFIGS must be a JSON array");

  return parsed.map((r, i) => {
    if (typeof r !== "object" || r === null) {
      throw new Error(`TOKEN_CONFIGS[${i}] must be an object`);
    }
    if (r.oft == null || r.coreIndexId == null || r.decimalDiff == null) {
      throw new Error(`TOKEN_CONFIGS[${i}] must have oft, coreIndexId, decimalDiff`);
    }
    return {
      idx: i,
      symbol: r.symbol || "",
      oft: normAddr(`TOKEN_CONFIGS[${i}].oft`, r.oft),
      coreIndexId: Number(r.coreIndexId),
      decimalDiff: Number(r.decimalDiff),
    };
  });
}

// --- on-chain read helpers ---

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

async function ethCallRaw(rpcUrl, to, data) {
  const result = await rpcCall(rpcUrl, "eth_call", [{ to, data }, "latest"]);
  if (typeof result !== "string" || !result.startsWith("0x")) {
    throw new Error(`Bad eth_call result: ${String(result)}`);
  }
  return result.replace(/^0x/, "");
}

function decodeTokenConfig(hex) {
  const padded = hex.padStart(256, "0");
  const coreIndexId = Number(BigInt("0x" + padded.slice(0, 64)));
  const diffRaw = BigInt("0x" + padded.slice(64, 128));
  let decimalDiff;
  if (diffRaw > 127n) {
    decimalDiff = diffRaw > 255n
      ? Number(BigInt.asIntN(256, diffRaw))
      : Number(diffRaw) - 256;
  } else {
    decimalDiff = Number(diffRaw);
  }
  const assetBridge = normAddr("assetBridge", "0x" + padded.slice(128 + 24, 192));
  const enabled = BigInt("0x" + padded.slice(192, 256)) !== 0n;
  return { coreIndexId, decimalDiff, assetBridge, enabled };
}

function computeAssetBridge(coreIndexId) {
  const bridge = BASE_ASSET_BRIDGE + BigInt(coreIndexId);
  return "0x" + bridge.toString(16).padStart(40, "0");
}

/**
 * Returns true if the on-chain tokenConfigs(oft) matches the expected config.
 */
async function isAlreadySet(rpcUrl, composer, t) {
  const argHex = t.oft.replace(/^0x/, "").padStart(64, "0");
  const data = SELECTOR_TOKEN_CONFIGS + argHex;
  const rawHex = await ethCallRaw(rpcUrl, composer, data);
  const onchain = decodeTokenConfig(rawHex);

  const expectedBridge = computeAssetBridge(t.coreIndexId);

  const idxOk     = onchain.coreIndexId === t.coreIndexId;
  const diffOk    = onchain.decimalDiff === t.decimalDiff;
  const bridgeOk  = onchain.assetBridge === expectedBridge;
  const enabledOk = onchain.enabled === true;

  const isNotConfigured = onchain.coreIndexId === 0 && !onchain.enabled;

  if (isNotConfigured) {
    console.log(`  [check] not configured on-chain`);
    return false;
  }

  console.log(`  [check] coreIndexId : expected=${t.coreIndexId} onchain=${onchain.coreIndexId} ${idxOk ? "✅" : "❌"}`);
  console.log(`  [check] decimalDiff : expected=${t.decimalDiff} onchain=${onchain.decimalDiff} ${diffOk ? "✅" : "❌"}`);
  console.log(`  [check] assetBridge : expected=${expectedBridge} onchain=${onchain.assetBridge} ${bridgeOk ? "✅" : "❌"}`);
  console.log(`  [check] enabled     : ${onchain.enabled} ${enabledOk ? "✅" : "❌"}`);

  return idxOk && diffOk && bridgeOk && enabledOk;
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
  const rpcUrl   = requireEnv("RPC_URL");
  const composer = normAddr("COMPOSER_ADDRESS", requireEnv("COMPOSER_ADDRESS"));
  const pk       = getPrivateKeyHex();

  const gasPrice = process.env.GAS_PRICE?.trim();
  const legacy   = process.env.LEGACY_TX?.trim() === "1";
  const dryRun   = process.env.DRY_RUN?.trim() === "1";

  const tokens = parseTokenConfigs();
  if (tokens.length === 0) {
    console.log("TOKEN_CONFIGS is empty; nothing to send.");
    return;
  }

  console.log(`RPC_URL=${rpcUrl}`);
  console.log(`COMPOSER_ADDRESS=${composer}`);
  console.log(`tokens=${tokens.length}`);
  console.log(`legacy=${legacy ? "yes" : "no"}`);
  if (gasPrice) console.log(`gasPrice=${gasPrice}`);
  if (dryRun)   console.log("DRY_RUN enabled; no transactions will be sent.");

  let skipped = 0;
  let sent    = 0;

  for (const t of tokens) {
    const label = t.symbol ? `${t.symbol} ` : "";
    console.log(`\n[${t.idx}] ${label}configureToken(${t.oft}, ${t.coreIndexId}, ${t.decimalDiff})`);

    const alreadySet = await isAlreadySet(rpcUrl, composer, t);
    if (alreadySet) {
      console.log(`  => already correctly configured on-chain, skipping.`);
      skipped++;
      continue;
    }

    console.log(`  => not configured or mismatched, sending transaction...`);

    const args = [
      "send",
      "--rpc-url",     rpcUrl,
      "--private-key", pk
    ];
    if (legacy)   args.push("--legacy");
    if (gasPrice) args.push("--gas-price", gasPrice);

    args.push(
      composer,
      "configureToken(address,uint64,int8)",
      t.oft,
      String(t.coreIndexId),
      String(t.decimalDiff)
    );

    run("cast", args, { dryRun });
    sent++;
  }

  console.log(`\nDone. sent=${sent} skipped=${skipped}`);
  console.log("Verify: node scripts/checkTokenConfig.js");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
