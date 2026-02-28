// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DStockHyperCoreComposer} from "../src/DStockHyperCoreComposer.sol";

/// @notice Deploy DStockHyperCoreComposer (UUPS proxy) on HyperEVM and configure OFT tokens.
/// @dev Run with --rpc-url <HYPEREVM_RPC> [--broadcast]
///
/// Required env:
/// - DEPLOYER_PK (or ADMIN_PK)
/// - LZ_ENDPOINT
/// - OWNER_ADDRESS
///
/// Optional env (initial token config):
/// - TOKEN_CONFIGS (JSON array of objects; one configureToken call per entry)
///   Format:
///     [
///       {"coreIndexId": 414, "decimalDiff": 9, "oft": "0xOFT_ADDRESS", "symbol": "BNB1"},
///       {"coreIndexId": 415, "decimalDiff": 9, "oft": "0xOFT_ADDRESS2", "symbol": "ETH1"}
///     ]
///   Notes:
///   - JSON object keys MUST be in alphabetical order for correct ABI decode:
///     coreIndexId < decimalDiff < oft < symbol
///   - coreIndexId: HyperCore spot token index (uint64)
///   - decimalDiff: EVM decimals - HyperCore weiDecimals, range [-128, 127] (int8)
///   - oft:         OFT contract address on HyperEVM
///   - symbol:      human-readable label (not sent on-chain, used for logging only)
contract DeployHyperCoreComposer is Script {
    /// @dev Struct field order MUST match alphabetical key order for vm.parseJson ABI decode.
    /// Alphabetical: coreIndexId (c) < decimalDiff (d) < oft (o) < symbol (s)
    struct TokenConfig {
        uint64 coreIndexId;
        int256 decimalDiff; // decoded as int256, cast to int8 when calling configureToken
        address oft;
        string symbol; // human-readable label, not sent on-chain
    }

    function run() external {
        uint256 adminPk = vm.envOr("DEPLOYER_PK", uint256(0));
        if (adminPk == 0) {
            adminPk = vm.envUint("ADMIN_PK");
        }
        address endpoint = vm.envAddress("LZ_ENDPOINT");
        address owner = vm.envAddress("OWNER_ADDRESS");
        string memory tokenConfigs = vm.envOr("TOKEN_CONFIGS", string(""));

        vm.startBroadcast(adminPk);

        // 1) deploy implementation
        DStockHyperCoreComposer impl = new DStockHyperCoreComposer();

        // 2) deploy proxy + initialize
        bytes memory initData = abi.encodeCall(DStockHyperCoreComposer.initialize, (endpoint, owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        DStockHyperCoreComposer composer = DStockHyperCoreComposer(payable(address(proxy)));

        // 3) optional: configure tokens
        if (bytes(tokenConfigs).length > 0) {
            // TOKEN_CONFIGS is a JSON array of objects; decoded via vm.parseJson into TokenConfig[].
            // Foundry ABI-encodes JSON object fields in alphabetical key order, so the struct
            // fields must follow the same order: coreIndexId, decimalDiff, oft.
            TokenConfig[] memory tokens = abi.decode(vm.parseJson(tokenConfigs, "."), (TokenConfig[]));

            for (uint256 i = 0; i < tokens.length; i++) {
                console2.log("  configureToken:", tokens[i].symbol, tokens[i].oft, tokens[i].coreIndexId);
                composer.configureToken(tokens[i].oft, tokens[i].coreIndexId, int8(tokens[i].decimalDiff));
            }
        }

        vm.stopBroadcast();

        console2.log("DStockHyperCoreComposer implementation:", address(impl));
        console2.log("DStockHyperCoreComposer proxy:", address(composer));
        console2.log("LZ Endpoint:", endpoint);
        console2.log("Owner:", owner);
        if (bytes(tokenConfigs).length > 0) {
            console2.log("Configured tokens (TOKEN_CONFIGS JSON):", tokenConfigs);
        }
    }
}
