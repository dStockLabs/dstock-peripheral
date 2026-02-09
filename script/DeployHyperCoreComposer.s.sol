// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {DStockHyperCoreComposer} from "../src/DStockHyperCoreComposer.sol";

/// @notice Deploy DStockHyperCoreComposer on HyperEVM and configure BNB1 token.
/// @dev Run with --rpc-url <HYPEREVM_RPC> [--broadcast]
///
/// Required env:
/// - DEPLOYER_PK (or ADMIN_PK)
/// - LZ_ENDPOINT
/// - OWNER_ADDRESS
/// - BNB1_OFT_ADDRESS
///
/// Optional env (defaults shown):
/// - BNB1_TOKEN_INDEX (414)
/// - BNB1_DECIMAL_DIFF (9)
contract DeployHyperCoreComposer is Script {
    function run() external {
        uint256 adminPk = vm.envOr("DEPLOYER_PK", uint256(0));
        if (adminPk == 0) {
            adminPk = vm.envUint("ADMIN_PK");
        }
        address endpoint = vm.envAddress("LZ_ENDPOINT");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address bnb1Oft = vm.envAddress("BNB1_OFT_ADDRESS");

        uint64 bnb1Index = uint64(vm.envOr("BNB1_TOKEN_INDEX", uint256(414)));
        int8 bnb1DecimalDiff = int8(int256(vm.envOr("BNB1_DECIMAL_DIFF", uint256(9))));

        vm.startBroadcast(adminPk);

        DStockHyperCoreComposer composer = new DStockHyperCoreComposer(endpoint, owner);
        composer.configureToken(bnb1Oft, bnb1Index, bnb1DecimalDiff);

        vm.stopBroadcast();

        console2.log("DStockHyperCoreComposer:", address(composer));
        console2.log("Configured BNB1 OFT:", bnb1Oft);
        console2.log("BNB1 token index:", bnb1Index);
        console2.log("BNB1 decimal diff:", bnb1DecimalDiff);
    }
}
