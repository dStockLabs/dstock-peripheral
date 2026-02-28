// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DStockComposerRouterV2} from "../src/DStockComposerRouter.sol";
import {WrappedNativePayoutHelperV2} from "../src/WrappedNativePayoutHelper.sol";

/// @notice Deploys the UUPS implementation + ERC1967Proxy for DStockComposerRouterV2 and optionally registers routes.
///
/// Env vars:
/// - Required:
///   - ADMIN_PK
///   - ENDPOINT_ADDRESS
///   - CHAIN_EID
///   - OWNER_ADDRESS (initial ADMIN_ROLE address)
/// - Optional (initial route config):
///   - ROUTE_CONFIGS (JSON array; one setRouteConfig call per entry)
///     - Format (array-of-arrays; positional to avoid JSON key ordering issues):
///       [
///         ["0xUNDERLYING","0xWRAPPER","0xSHARE_ADAPTER"],
///         ["0xUNDERLYING2","0xWRAPPER2","0xSHARE_ADAPTER2"]
///       ]
///     - You may set underlying=0x0000000000000000000000000000000000000000 to only set reverse mapping (shareAdapter->wrapper)
/// - Optional (wrapped native support):
///   - WRAPPED_NATIVE_ADDRESS (e.g., WBNB/WETH on this chain)
///   - WRAPPED_NATIVE_PAYOUT_HELPER_ADDRESS (optional; if unset and WRAPPED_NATIVE_ADDRESS is set, script deploys a helper)
contract DeployComposerRouterProxy is Script {
    using stdJson for string;

    function run() external {
        uint256 adminPk = vm.envUint("ADMIN_PK");

        address endpoint = vm.envAddress("ENDPOINT_ADDRESS");
        uint32 chainEid = uint32(vm.envUint("CHAIN_EID"));
        address owner = vm.envAddress("OWNER_ADDRESS");

        // optional: initial route registration
        string memory routeConfigs = vm.envOr("ROUTE_CONFIGS", string(""));
        address wrappedNative = vm.envOr("WRAPPED_NATIVE_ADDRESS", address(0));
        address wrappedNativeHelper = vm.envOr("WRAPPED_NATIVE_PAYOUT_HELPER_ADDRESS", address(0));

        vm.startBroadcast(adminPk);

        // 1) deploy implementation
        DStockComposerRouterV2 impl = new DStockComposerRouterV2();

        // 2) deploy proxy + initialize
        bytes memory initData = abi.encodeCall(DStockComposerRouterV2.initialize, (endpoint, chainEid, owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        // 3) optional: configure routes / wrapped native
        DStockComposerRouterV2 router = DStockComposerRouterV2(payable(address(proxy)));

        // Route configuration:
        if (bytes(routeConfigs).length > 0) {
            // ROUTE_CONFIGS is a JSON array-of-arrays: address[][]
            // Each entry is: [underlying, wrapper, shareAdapter]
            // NOTE: stdJson/parseRaw encodes inner arrays as dynamic address[] (with length prefix),
            //       so we must decode as address[][] not address[3][].
            bytes memory raw = routeConfigs.parseRaw(".");
            address[][] memory routes = abi.decode(raw, (address[][]));

            for (uint256 i = 0; i < routes.length; i++) {
                if (routes[i].length < 3) continue;
                address underlying = routes[i][0];
                address wrapper = routes[i][1];
                address shareAdapter = routes[i][2];
                if (wrapper == address(0) || shareAdapter == address(0)) continue;
                router.setRouteConfig(underlying, wrapper, shareAdapter);
            }
        }

        // Wrapped native support:
        // - Deploy a helper bound to this router (if not provided)
        // - Configure router with wrapped native + helper
        if (wrappedNative != address(0)) {
            router.setWrappedNative(wrappedNative);

            if (wrappedNativeHelper == address(0)) {
                WrappedNativePayoutHelperV2 helper = new WrappedNativePayoutHelperV2(address(proxy));
                wrappedNativeHelper = address(helper);
            }
            router.setWrappedNativePayoutHelper(wrappedNativeHelper);
        }

        vm.stopBroadcast();

        console2.log("DStockComposerRouter implementation:", address(impl));
        console2.log("DStockComposerRouter proxy:", address(proxy));
        console2.log("Endpoint:", endpoint);
        console2.log("ChainEid:", chainEid);
        console2.log("Owner:", owner);
        if (bytes(routeConfigs).length > 0) {
            console2.log("Initial routes (ROUTE_CONFIGS JSON):", routeConfigs);
        }
        if (wrappedNative != address(0)) {
            console2.log("Wrapped native:", wrappedNative);
            console2.log("Wrapped native payout helper:", wrappedNativeHelper);
        }
    }
}

