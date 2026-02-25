// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {DStockComposerRouterV2 as DStockComposerRouter} from "../src/DStockComposerRouter.sol";

/// @notice Mainnet experiment for direct BSC native -> HyperCore via router + composer.
/// @dev Calls router.wrapAndBridgeNativeToComposer(...).
///
/// Required env:
/// - DEPLOYER_PK
/// - ROUTER_PROXY
/// - COMPOSER_ADDRESS
///
/// Optional env (defaults shown):
/// - RECEIVER_ADDRESS (deployer)
/// - DST_EID (30367)
/// - BRIDGE_AMOUNT_WEI (100000000000000) // 0.0001 BNB
/// - MIN_AMOUNT_LD (0)
/// - MIN_MSG_VALUE (0)
/// - EXTRA_OPTIONS_HEX (required for compose execution; must include lzReceive + lzCompose)
contract MainnetRouterBridgeToHyperCoreExperiment is Script {
    struct RunConfig {
        address routerAddr;
        address composer;
        address receiver;
        uint32 dstEid;
        uint256 amountNative;
        uint256 minAmountLD;
        uint256 minMsgValue;
        bytes options;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);

        RunConfig memory cfg;
        cfg.routerAddr = vm.envAddress("ROUTER_PROXY");
        cfg.composer = vm.envAddress("COMPOSER_ADDRESS");
        cfg.receiver = vm.envOr("RECEIVER_ADDRESS", deployer);
        cfg.dstEid = uint32(vm.envOr("DST_EID", uint256(30367)));
        cfg.amountNative = vm.envOr("BRIDGE_AMOUNT_WEI", uint256(100_000_000_000_000));
        cfg.minAmountLD = vm.envOr("MIN_AMOUNT_LD", uint256(0));
        cfg.minMsgValue = vm.envOr("MIN_MSG_VALUE", uint256(0));
        cfg.options = vm.envBytes("EXTRA_OPTIONS_HEX");

        DStockComposerRouter router = DStockComposerRouter(payable(cfg.routerAddr));

        uint256 fee = router.quoteWrapAndBridgeNativeToComposer(
            cfg.amountNative,
            cfg.dstEid,
            bytes32(uint256(uint160(cfg.composer))),
            cfg.options,
            cfg.minMsgValue,
            cfg.receiver
        );

        uint256 totalValue = cfg.amountNative + fee;

        console2.log("Router:", cfg.routerAddr);
        console2.log("Composer:", cfg.composer);
        console2.log("Receiver:", cfg.receiver);
        console2.log("Amount Native:", cfg.amountNative);
        console2.log("Quoted LZ Fee:", fee);
        console2.log("Total msg.value:", totalValue);

        vm.startBroadcast(pk);

        uint256 amountSentLD = router.wrapAndBridgeNativeToComposer{value: totalValue}(
            cfg.amountNative,
            cfg.dstEid,
            bytes32(uint256(uint160(cfg.composer))),
            cfg.options,
            cfg.minAmountLD,
            cfg.minMsgValue,
            cfg.receiver
        );

        vm.stopBroadcast();

        console2.log("Bridged share amountLD:", amountSentLD);
    }
}
