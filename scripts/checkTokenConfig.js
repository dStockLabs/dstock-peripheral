/**
 * DStockHyperCoreComposer token config verifier (no dependencies).
 *
 * Queries on-chain tokenConfigs(address) for each entry in TOKEN_CONFIGS
 * and compares against the expected values. Reports which tokens are
 * correctly configured and which are missing or mismatched.
 *
 * Requires env vars (typically via: `set -a && source .env.hl && set +a`):
 * - RPC_URL: HyperEVM JSON-RPC endpoint
 * - COMPOSER_ADDRESS: deployed DStockHyperCoreComposer proxy address
 * - TOKEN_CONFIGS: JSON array of objects { coreIndexId, decimalDiff, oft, symbol }
 */

// Function selectors
const SELECTORS = {
  tokenConfigs: "0x1b69dc5f", // keccak256("tokenConfigs(address)")[:4]
  endpoint:     "0x5e280f11", // keccak256("endpoint()")[:4]
};

const BASE_ASSET_BRIDGE = 0x2000000000000000000000000000000000000000n;

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

function encodeAddressArg(addr) {
  return normAddr("address arg", addr).slice(2).padStart(64, "0");
}

function encodeCall(selector, maybeAddressArg) {
  if (!maybeAddressArg) return selector;
  return selector + encodeAddressArg(maybeAddressArg);
}

// --- RPC helpers ---

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

async function ethCallAddress(rpcUrl, to, data) {
  const hex = await ethCallRaw(rpcUrl, to, data);
  const padded = hex.padStart(64, "0");
  return normAddr("eth_call address", "0x" + padded.slice(24, 64));
}

// --- Token config parsing ---

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

/**
 * Decode tokenConfigs(address) return: (uint64 coreIndexId, int8 decimalDiff, address assetBridge, bool enabled)
 * Each field occupies one 32-byte ABI word.
 */
function decodeTokenConfig(hex) {
  const padded = hex.padStart(256, "0");
  // Word 0: uint64 coreIndexId
  const coreIndexId = Number(BigInt("0x" + padded.slice(0, 64)));
  // Word 1: int8 decimalDiff (sign-extended to 32 bytes)
  const diffRaw = BigInt("0x" + padded.slice(64, 128));
  // Convert uint256 to signed int8: if >= 128, it's negative
  let decimalDiff;
  if (diffRaw > 127n) {
    // Two's complement: value = diffRaw - 256 (for int8 semantics)
    // But ABI encodes int8 sign-extended to int256, so check high bit
    decimalDiff = Number(diffRaw) - 256;
    if (diffRaw > 255n) {
      // Full int256 sign extension: interpret as signed
      decimalDiff = Number(BigInt.asIntN(256, diffRaw));
    }
  } else {
    decimalDiff = Number(diffRaw);
  }
  // Word 2: address assetBridge
  const assetBridge = normAddr("assetBridge", "0x" + padded.slice(128 + 24, 192));
  // Word 3: bool enabled
  const enabled = BigInt("0x" + padded.slice(192, 256)) !== 0n;

  return { coreIndexId, decimalDiff, assetBridge, enabled };
}

function computeAssetBridge(coreIndexId) {
  const bridge = BASE_ASSET_BRIDGE + BigInt(coreIndexId);
  return "0x" + bridge.toString(16).padStart(40, "0");
}

async function main() {
  const rpcUrl = requireEnv("RPC_URL");
  const composer = normAddr("COMPOSER_ADDRESS", requireEnv("COMPOSER_ADDRESS"));
  const tokens = parseTokenConfigs();

  console.log(`Composer: ${composer}`);
  console.log(`RPC: ${rpcUrl}`);
  console.log(`Tokens to check: ${tokens.length}`);
  console.log();

  let ok = true;
  let configured = 0;
  let missing = 0;

  for (const t of tokens) {
    const label = t.symbol ? `${t.symbol} ` : "";
    const data = encodeCall(SELECTORS.tokenConfigs, t.oft);
    const rawHex = await ethCallRaw(rpcUrl, composer, data);
    const onchain = decodeTokenConfig(rawHex);

    const expectedBridge = computeAssetBridge(t.coreIndexId);
    const isNotConfigured = onchain.coreIndexId === 0 && !onchain.enabled;

    if (isNotConfigured) {
      console.log(`- ${label}[${t.idx}] ❌ NOT CONFIGURED`);
      console.log(`  oft         = ${t.oft}`);
      console.log(`  expected    : coreIndexId=${t.coreIndexId} decimalDiff=${t.decimalDiff}`);
      console.log();
      ok = false;
      missing++;
      continue;
    }

    const idxOk = onchain.coreIndexId === t.coreIndexId;
    const diffOk = onchain.decimalDiff === t.decimalDiff;
    const bridgeOk = onchain.assetBridge === expectedBridge;
    const enabledOk = onchain.enabled === true;
    const pass = idxOk && diffOk && bridgeOk && enabledOk;
    ok &&= pass;

    if (pass) {
      configured++;
    } else {
      missing++;
    }

    console.log(`- ${label}[${t.idx}] ${pass ? "✅" : "❌"}`);
    console.log(`  oft         = ${t.oft}`);
    console.log(`  coreIndexId : expected=${t.coreIndexId} onchain=${onchain.coreIndexId} ${idxOk ? "✅" : "❌"}`);
    console.log(`  decimalDiff : expected=${t.decimalDiff} onchain=${onchain.decimalDiff} ${diffOk ? "✅" : "❌"}`);
    console.log(`  assetBridge : expected=${expectedBridge} onchain=${onchain.assetBridge} ${bridgeOk ? "✅" : "❌"}`);
    console.log(`  enabled     : ${onchain.enabled} ${enabledOk ? "✅" : "❌"}`);
    console.log();
  }

  console.log(`Summary: ${configured} configured, ${missing} missing/mismatched, ${tokens.length} total`);

  if (!ok) {
    console.error("\nOne or more token config checks FAILED.");
    process.exitCode = 1;
  } else {
    console.log("\nAll token config checks PASSED.");
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
