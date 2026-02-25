// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DStockComposerRouterV2, IOFTLike} from "../src/DStockComposerRouter.sol";
import {DStockHyperCoreComposer} from "../src/DStockHyperCoreComposer.sol";
import {MockComposerWrapper} from "./mocks/MockComposerWrapper.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface ICoreWriterLike {
    function sendRawAction(bytes calldata data) external;
}

contract CaptureOFTLikeAdapter is IOFTLike {
    uint256 public fixedNativeFee;
    address public immutable tokenToLock;

    uint32 public lastDstEid;
    bytes32 public lastTo;
    uint256 public lastAmountLD;
    bytes public lastComposeMsg;
    bytes public lastExtraOptions;

    constructor(address _tokenToLock) {
        tokenToLock = _tokenToLock;
    }

    function setFee(uint256 fee) external {
        fixedNativeFee = fee;
    }

    function quoteSend(SendParam calldata, bool) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: fixedNativeFee, lzTokenFee: 0});
    }

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address /*_refundAddress*/
    )
        external
        payable
        returns (bytes32 guid, uint64 nonce, MessagingFee memory fee, uint256 amountSentLD, uint256 amountReceivedLD)
    {
        require(msg.value >= _fee.nativeFee, "insufficient fee");
        require(IERC20(tokenToLock).transferFrom(msg.sender, address(this), _sendParam.amountLD), "lock_failed");

        lastDstEid = _sendParam.dstEid;
        lastTo = _sendParam.to;
        lastAmountLD = _sendParam.amountLD;
        lastComposeMsg = _sendParam.composeMsg;
        lastExtraOptions = _sendParam.extraOptions;

        guid = keccak256(abi.encodePacked(block.number, msg.sender, _sendParam.to, _sendParam.amountLD));
        nonce = uint64(block.number);
        fee = _fee;
        amountSentLD = _sendParam.amountLD;
        amountReceivedLD = _sendParam.amountLD;
    }
}

contract DStockHyperCoreComposerE2ETest is Test {
    address internal constant ENDPOINT = address(0xE11D);

    address internal constant SPOT_BALANCE_PRECOMPILE = 0x0000000000000000000000000000000000000801;
    address internal constant CORE_USER_EXISTS_PRECOMPILE = 0x0000000000000000000000000000000000000810;
    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address internal constant BASE_ASSET_BRIDGE = 0x2000000000000000000000000000000000000000;
    bytes4 internal constant SPOT_SEND_HEADER = 0x01000006;

    uint32 internal constant HYPE_EID = 30367;
    uint64 internal constant BNB1_TOKEN_INDEX = 414;
    int8 internal constant BNB1_DECIMAL_DIFF = 9;

    DStockComposerRouterV2 internal router;
    DStockComposerRouterV2 internal impl;
    DStockHyperCoreComposer internal composer;

    MockERC20 internal underlying;
    MockComposerWrapper internal shareToken;
    CaptureOFTLikeAdapter internal adapter;

    function setUp() public {
        impl = new DStockComposerRouterV2();
        bytes memory initData = abi.encodeCall(DStockComposerRouterV2.initialize, (ENDPOINT, uint32(12345), address(this)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = DStockComposerRouterV2(payable(address(proxy)));

        underlying = new MockERC20("Underlying", "UND", 6);
        shareToken = new MockComposerWrapper();
        shareToken.setUnderlyingDecimals(address(underlying), 6);

        adapter = new CaptureOFTLikeAdapter(address(shareToken));

        router.setRouteConfig(address(underlying), address(shareToken), address(adapter));

        DStockHyperCoreComposer composerImpl = new DStockHyperCoreComposer();
        bytes memory composerInitData = abi.encodeCall(DStockHyperCoreComposer.initialize, (ENDPOINT, address(this)));
        ERC1967Proxy composerProxy = new ERC1967Proxy(address(composerImpl), composerInitData);
        composer = DStockHyperCoreComposer(payable(address(composerProxy)));

        composer.configureToken(address(shareToken), BNB1_TOKEN_INDEX, BNB1_DECIMAL_DIFF);
    }

    function test_e2e_bscRouter_to_hyperCoreComposer_success() public {
        address user = address(0xCAFE);
        address receiver = address(0xB0B);
        uint256 amount = 100e6; // 100 tokens at 6 decimals

        underlying.mint(user, amount);

        vm.startPrank(user);
        underlying.approve(address(router), amount);
        uint256 sent = router.wrapAndBridgeToComposer(
            address(underlying),
            amount,
            HYPE_EID,
            bytes32(uint256(uint160(address(composer)))),
            "",
            0,
            0,
            receiver
        );
        vm.stopPrank();

        uint256 expectedShares = amount * 1e12;
        assertEq(sent, expectedShares);
        assertEq(adapter.lastTo(), bytes32(uint256(uint160(address(composer)))));

        (uint256 minMsgValue, address decodedReceiver) = abi.decode(adapter.lastComposeMsg(), (uint256, address));
        assertEq(minMsgValue, 0);
        assertEq(decodedReceiver, receiver);

        // Simulate destination OFT credit: shares minted to composer before lzCompose executes.
        shareToken.mintShares(address(composer), adapter.lastAmountLD());

        address assetBridge = address(uint160(uint256(uint160(BASE_ASSET_BRIDGE)) + BNB1_TOKEN_INDEX));
        vm.mockCall(
            SPOT_BALANCE_PRECOMPILE,
            abi.encode(assetBridge, BNB1_TOKEN_INDEX),
            abi.encode(uint64(1_000_000_000_000), uint64(0), uint64(0))
        );
        vm.mockCall(CORE_USER_EXISTS_PRECOMPILE, abi.encode(receiver), abi.encode(true));

        uint64 coreAmount = uint64(adapter.lastAmountLD() / 1e9);
        bytes memory payload = abi.encodePacked(SPOT_SEND_HEADER, abi.encode(receiver, BNB1_TOKEN_INDEX, coreAmount));
        vm.mockCall(CORE_WRITER, abi.encodeWithSelector(ICoreWriterLike.sendRawAction.selector, payload), "");
        vm.expectCall(CORE_WRITER, abi.encodeWithSelector(ICoreWriterLike.sendRawAction.selector, payload));

        bytes memory message = _compose(adapter.lastAmountLD(), bytes32(uint256(uint160(user))), adapter.lastComposeMsg());
        vm.prank(ENDPOINT);
        composer.lzCompose(address(shareToken), bytes32("guid-success"), message, address(0), "");

        assertEq(shareToken.balanceOf(address(composer)), 0);
        assertEq(shareToken.balanceOf(assetBridge), adapter.lastAmountLD());
    }

    function test_e2e_bscRouter_to_hyperCoreComposer_refundsOnCoreUserInactive() public {
        address user = address(0xA11CE);
        address receiver = address(0xB0B);
        uint256 amount = 10e6;

        underlying.mint(user, amount);

        vm.startPrank(user);
        underlying.approve(address(router), amount);
        router.wrapAndBridgeToComposer(
            address(underlying),
            amount,
            HYPE_EID,
            bytes32(uint256(uint160(address(composer)))),
            "",
            0,
            0,
            receiver
        );
        vm.stopPrank();

        shareToken.mintShares(address(composer), adapter.lastAmountLD());

        address assetBridge = address(uint160(uint256(uint160(BASE_ASSET_BRIDGE)) + BNB1_TOKEN_INDEX));
        vm.mockCall(
            SPOT_BALANCE_PRECOMPILE,
            abi.encode(assetBridge, BNB1_TOKEN_INDEX),
            abi.encode(uint64(1_000_000_000_000), uint64(0), uint64(0))
        );
        vm.mockCall(CORE_USER_EXISTS_PRECOMPILE, abi.encode(receiver), abi.encode(false));

        bytes memory message = _compose(adapter.lastAmountLD(), bytes32(uint256(uint160(user))), adapter.lastComposeMsg());
        vm.prank(ENDPOINT);
        composer.lzCompose(address(shareToken), bytes32("guid-refund"), message, address(0), "");

        assertEq(shareToken.balanceOf(receiver), adapter.lastAmountLD());
        assertEq(shareToken.balanceOf(address(composer)), 0);
        assertEq(shareToken.balanceOf(assetBridge), 0);
    }

    function _compose(uint256 amountLD, bytes32 composeFrom, bytes memory composeMsg) internal pure returns (bytes memory) {
        return abi.encodePacked(uint64(1), uint32(56), bytes32(amountLD), composeFrom, composeMsg);
    }
}
