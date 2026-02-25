// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DStockHyperCoreComposer
/// @notice LayerZero compose receiver that bridges OFT tokens arriving on HyperEVM into HyperCore.
///
/// Modelled after LayerZero's official `HyperLiquidComposer` (deployed for USDe at
/// 0xfb67615bff54078322e758efbeb5db27fdf873d8) but adapted for the DStock ecosystem:
///
///   • Supports **multiple OFT tokens** via an admin-managed registry instead of being
///     bound to a single OFT at construction time.
///   • Stores each token's `decimalDiff` (= EVM decimals − HyperCore weiDecimals) so that
///     the EVM→Core conversion is always correct regardless of the token.
///   • Provides recovery helpers (retrieve from Core, recover from EVM) gated to ADMIN_ROLE.
///
/// ### Compose message format (64 bytes, matches LZ standard)
/// ```
/// abi.encode(uint256 minMsgValue, address receiver)
/// ```
///
/// ### End-to-end flow
/// 1. BSC user calls the OFT adapter with `composeMsg` targeting this contract.
/// 2. HyperEVM LZ endpoint calls `lzCompose`; the OFT has already minted tokens to this
///    contract.
/// 3. This contract:
///    a. Transfers the ERC-20 to the token's **asset bridge** (`0x2000…00 | tokenIndex`),
///       which credits the composer's HyperCore spot account.
///    b. Calls **CoreWriter** `sendRawAction` with a `spotSend` payload to transfer the
///       core-denominated amount from the composer to the receiver.
/// 4. If any step fails the tokens are refunded to the receiver on HyperEVM (or stored for
///    cross-chain refund if the compose message itself cannot be decoded).
contract DStockHyperCoreComposer is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Admin role for privileged operations (token registry, asset recovery, upgrades).
    /// @dev Self-administered: an ADMIN can grant/revoke ADMIN to/from others to rotate privileges.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ──────────────────────────────────────────────────────────────
    //  HyperLiquid system addresses & constants
    // ──────────────────────────────────────────────────────────────

    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address internal constant HYPE_ASSET_BRIDGE = 0x2222222222222222222222222222222222222222;
    address internal constant SPOT_BALANCE_PRECOMPILE = 0x0000000000000000000000000000000000000801;
    address internal constant CORE_USER_EXISTS_PRECOMPILE = 0x0000000000000000000000000000000000000810;
    address internal constant BASE_ASSET_BRIDGE = 0x2000000000000000000000000000000000000000;

    bytes4 public constant SPOT_SEND_HEADER = 0x01000006;

    uint256 public constant VALID_COMPOSE_MSG_LEN = 64;

    int8 public constant MIN_DECIMAL_DIFF = -2;
    int8 public constant MAX_DECIMAL_DIFF = 18;
    int8 public constant HYPE_DECIMAL_DIFF = 10;

    uint64 public constant HYPE_CHAIN_ID_MAINNET = 999;
    uint64 public constant HYPE_CORE_INDEX_MAINNET = 150;
    uint64 public constant HYPE_CORE_INDEX_TESTNET = 1105;

    uint256 public constant MIN_GAS = 150_000;
    uint256 public constant MIN_GAS_WITH_VALUE = 200_000;

    // ──────────────────────────────────────────────────────────────
    //  OFT compose-message codec offsets (mirrors OFTComposeMsgCodec)
    // ──────────────────────────────────────────────────────────────

    uint256 private constant _NONCE_OFFSET      = 8;
    uint256 private constant _SRC_EID_OFFSET    = 12;
    uint256 private constant _AMOUNT_LD_OFFSET  = 44;
    uint256 private constant _COMPOSE_FROM_OFFSET = 76;

    // ──────────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────────

    /// @notice LayerZero EndpointV2 address on HyperEVM.
    address public endpoint;

    struct TokenConfig {
        uint64  coreIndexId;
        int8    decimalDiff;   // EVM decimals − HyperCore weiDecimals
        address assetBridge;   // 0x2000…00 | coreIndexId
        bool    enabled;
    }

    /// @notice OFT address → token configuration.
    mapping(address => TokenConfig) public tokenConfigs;

    struct FailedMessage {
        address oft;
        uint32  srcEid;
        bytes32 composeFrom;
        uint256 amountLD;
        uint256 msgValue;
    }

    mapping(bytes32 => FailedMessage) public failedMessages;

    uint256[47] private __gap;

    // ──────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────

    event TokenConfigured(address indexed oft, uint64 coreIndexId, int8 decimalDiff, address assetBridge);
    event TokenRemoved(address indexed oft);
    event BridgedToHyperCore(bytes32 indexed guid, address indexed receiver, address indexed oft, uint256 evmAmount, uint64 coreAmount);
    event RefundedOnHyperEVM(bytes32 indexed guid, address indexed receiver, address indexed oft, uint256 amount);
    event FailedMessageStored(bytes32 indexed guid, address indexed oft, bytes32 composeFrom, uint256 amountLD);
    event RefundedToSource(bytes32 indexed guid);
    event Retrieved(uint64 indexed coreIndexId, uint64 amount, address indexed assetBridge);
    event Recovered(address indexed token, address indexed to, uint256 amount);

    // ──────────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────────

    error ZeroAddress();
    error NotEndpoint();
    error TokenNotConfigured(address oft);
    error InvalidDecimalDiff(int8 diff);
    error CoreUserNotActivated(address user);
    error TransferExceedsBridgeBalance(uint256 requested, uint256 available);
    error ComposeMsgLengthInvalid(uint256 actual, uint256 expected);
    error InsufficientMsgValue(uint256 provided, uint256 required);
    error InsufficientGas(uint256 provided, uint256 required);
    error FailedMessageNotFound(bytes32 guid);
    error NativeTransferFailed(uint256 amount);
    error OFTEndpointMismatch(address oft, address oftEndpoint);

    // ──────────────────────────────────────────────────────────────
    //  Constructor / Initializer
    // ──────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice UUPS initializer (called once via proxy).
    /// @param _endpoint LayerZero EndpointV2 address on HyperEVM
    /// @param _admin    Initial admin that can configure tokens and upgrade
    function initialize(address _endpoint, address _admin) external initializer {
        if (_endpoint == address(0) || _admin == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        endpoint = _endpoint;

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _grantRole(ADMIN_ROLE, _admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    // ──────────────────────────────────────────────────────────────
    //  Admin – token registry
    // ──────────────────────────────────────────────────────────────

    /// @notice Register (or update) a supported OFT token.
    /// @param _oft         OFT contract on HyperEVM (the `_from` parameter in `lzCompose`)
    /// @param _coreIndexId HyperCore spot token index (e.g. 414 for BNB1)
    /// @param _decimalDiff EVM decimals − HyperCore weiDecimals (e.g. 18 − 9 = 9 for BNB1)
    function configureToken(address _oft, uint64 _coreIndexId, int8 _decimalDiff) external onlyRole(ADMIN_ROLE) {
        if (_decimalDiff < MIN_DECIMAL_DIFF || _decimalDiff > MAX_DECIMAL_DIFF) {
            revert InvalidDecimalDiff(_decimalDiff);
        }
        address oftEndpoint = IOFTMinimal(_oft).endpoint();
        if (oftEndpoint != endpoint) revert OFTEndpointMismatch(_oft, oftEndpoint);
        address bridge = address(uint160(uint256(uint160(BASE_ASSET_BRIDGE)) + _coreIndexId));
        tokenConfigs[_oft] = TokenConfig({
            coreIndexId: _coreIndexId,
            decimalDiff: _decimalDiff,
            assetBridge: bridge,
            enabled: true
        });
        emit TokenConfigured(_oft, _coreIndexId, _decimalDiff, bridge);
    }

    /// @notice Disable an OFT token (compose calls will revert).
    function removeToken(address _oft) external onlyRole(ADMIN_ROLE) {
        delete tokenConfigs[_oft];
        emit TokenRemoved(_oft);
    }

    // ──────────────────────────────────────────────────────────────
    //  lzCompose – LayerZero entry point
    // ──────────────────────────────────────────────────────────────

    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) external payable nonReentrant {
        if (msg.sender != endpoint) revert NotEndpoint();

        TokenConfig memory cfg = tokenConfigs[_from];
        if (!cfg.enabled) revert TokenNotConfigured(_from);

        uint256 amountLD = _amountLD(_message);

        bytes memory composeMsg = _composeMsg(_message);
        if (composeMsg.length != VALID_COMPOSE_MSG_LEN) {
            _storeFailedMessage(_guid, _from, _message, amountLD);
            return;
        }

        (uint256 minMsgValue, address receiver) = abi.decode(composeMsg, (uint256, address));
        if (msg.value < minMsgValue) revert InsufficientMsgValue(msg.value, minMsgValue);
        uint256 minGas = msg.value > 0 ? MIN_GAS_WITH_VALUE : MIN_GAS;
        if (gasleft() < minGas) revert InsufficientGas(gasleft(), minGas);

        try this._handleBridgeToHyperCore{value: msg.value}(
            _from,
            cfg.coreIndexId,
            cfg.decimalDiff,
            cfg.assetBridge,
            receiver,
            amountLD
        ) returns (uint256 evmAmount, uint64 coreAmount) {
            emit BridgedToHyperCore(_guid, receiver, _from, evmAmount, coreAmount);
        } catch {
            _refundOnHyperEVM(_guid, _from, receiver, amountLD, msg.value);
        }
    }

    // ──────────────────────────────────────────────────────────────
    //  Internal – bridge logic
    // ──────────────────────────────────────────────────────────────

    function _handleBridgeToHyperCore(
        address _oft,
        uint64 _coreIndexId,
        int8 _decimalDiff,
        address _assetBridge,
        address _receiver,
        uint256 _amountLD
    ) external payable returns (uint256 evmAmount, uint64 coreAmount) {
        require(msg.sender == address(this), "only self");

        (evmAmount, coreAmount) = quoteHyperCoreAmount(
            _coreIndexId,
            _decimalDiff,
            _assetBridge,
            _amountLD
        );

        if (evmAmount != 0 || msg.value != 0) {
            if (!_coreUserExists(_receiver)) revert CoreUserNotActivated(_receiver);
        }

        if (evmAmount != 0) {
            IERC20(_oft).safeTransfer(_assetBridge, evmAmount);
            _submitCoreWriterTransfer(_receiver, _coreIndexId, coreAmount);
        }

        if (msg.value > 0) {
            _transferNativeToHyperCore(_receiver);
        }
    }

    function _transferNativeToHyperCore(address _receiver) internal {
        uint64 coreIndex = block.chainid == HYPE_CHAIN_ID_MAINNET ? HYPE_CORE_INDEX_MAINNET : HYPE_CORE_INDEX_TESTNET;

        (uint256 nativeEvmAmount, uint64 nativeCoreAmount) = quoteHyperCoreAmount(
            coreIndex,
            HYPE_DECIMAL_DIFF,
            HYPE_ASSET_BRIDGE,
            msg.value
        );

        if (nativeEvmAmount == 0) {
            if (msg.value > 0) {
                (bool refundOk, ) = _receiver.call{value: msg.value}("");
                if (!refundOk) {
                    (bool fallbackOk, ) = tx.origin.call{value: msg.value}("");
                    if (!fallbackOk) revert NativeTransferFailed(msg.value);
                }
            }
            return;
        }

        (bool ok, ) = payable(HYPE_ASSET_BRIDGE).call{value: nativeEvmAmount}("");
        if (!ok) revert NativeTransferFailed(nativeEvmAmount);

        _submitCoreWriterTransfer(_receiver, coreIndex, nativeCoreAmount);

        uint256 nativeDust = msg.value - nativeEvmAmount;
        if (nativeDust > 0) {
            (bool refundOk, ) = _receiver.call{value: nativeDust}("");
            if (!refundOk) {
                (bool fallbackOk, ) = tx.origin.call{value: nativeDust}("");
                if (!fallbackOk) revert NativeTransferFailed(nativeDust);
            }
        }
    }

    function _submitCoreWriterTransfer(address _to, uint64 _coreIndex, uint64 _coreAmount) internal {
        bytes memory action = abi.encode(_to, _coreIndex, _coreAmount);
        bytes memory payload = abi.encodePacked(SPOT_SEND_HEADER, action);
        ICoreWriter(CORE_WRITER).sendRawAction(payload);
    }

    function _refundOnHyperEVM(
        bytes32 _guid,
        address _oft,
        address _receiver,
        uint256 _erc20Amount,
        uint256 _nativeAmount
    ) internal {
        if (_nativeAmount > 0) {
            uint256 nativeRefund = address(this).balance < _nativeAmount ? address(this).balance : _nativeAmount;
            if (nativeRefund > 0) {
                (bool okReceiver, ) = _receiver.call{value: nativeRefund}("");
                if (!okReceiver) {
                    (bool okOrigin, ) = tx.origin.call{value: nativeRefund}("");
                    if (!okOrigin) revert NativeTransferFailed(nativeRefund);
                }
            }
        }

        uint256 bal = IERC20(_oft).balanceOf(address(this));
        uint256 refundAmt = bal < _erc20Amount ? bal : _erc20Amount;
        if (refundAmt > 0) {
            IERC20(_oft).safeTransfer(_receiver, refundAmt);
        }
        emit RefundedOnHyperEVM(_guid, _receiver, _oft, refundAmt);
    }

    function _storeFailedMessage(bytes32 _guid, address _oft, bytes calldata _message, uint256 _amountLD) internal {
        failedMessages[_guid] = FailedMessage({
            oft: _oft,
            srcEid: _srcEid(_message),
            composeFrom: _composeFrom(_message),
            amountLD: _amountLD,
            msgValue: msg.value
        });
        emit FailedMessageStored(_guid, _oft, _composeFrom(_message), _amountLD);
    }

    // ──────────────────────────────────────────────────────────────
    //  Decimal conversion (mirrors HyperLiquidComposerCodec)
    // ──────────────────────────────────────────────────────────────

    /// @notice Convert an EVM-denominated amount to the HyperCore equivalent, validating
    ///         against the asset bridge's current balance.
    /// @return evmAmount  Dust-stripped amount to transfer to the asset bridge (EVM decimals)
    /// @return coreAmount Equivalent amount in HyperCore weiDecimals
    function quoteHyperCoreAmount(
        uint64 _coreIndexId,
        int8 _decimalDiff,
        address _bridgeAddress,
        uint256 _amountLD
    ) public view returns (uint256 evmAmount, uint64 coreAmount) {
        uint64 bridgeBalance = _spotBalance(_bridgeAddress, _coreIndexId);

        if (_decimalDiff > 0) {
            (evmAmount, coreAmount) = _convertDecimalDiffPositive(_amountLD, bridgeBalance, uint8(_decimalDiff));
        } else {
            (evmAmount, coreAmount) = _convertDecimalDiffNonPositive(_amountLD, bridgeBalance, uint8(-1 * _decimalDiff));
        }
    }

    /// @dev EVM has MORE decimals than Core (common case: 18 vs 8/9).
    ///      Strip dust so the amount is evenly divisible by 10^diff.
    function _convertDecimalDiffPositive(
        uint256 _amount,
        uint64 _maxCoreBal,
        uint8 _diff
    ) internal pure returns (uint256 evmAmount, uint64 coreAmount) {
        uint256 scale = 10 ** _diff;
        uint256 maxEvm = uint256(_maxCoreBal) * scale;

        unchecked {
            evmAmount = _amount - (_amount % scale);
            if (evmAmount > maxEvm) revert TransferExceedsBridgeBalance(evmAmount, maxEvm);
            coreAmount = uint64(evmAmount / scale);
        }
    }

    /// @dev Core has MORE (or equal) decimals than EVM.  No dust to strip.
    function _convertDecimalDiffNonPositive(
        uint256 _amount,
        uint64 _maxCoreBal,
        uint8 _diff
    ) internal pure returns (uint256 evmAmount, uint64 coreAmount) {
        uint256 scale = 10 ** _diff;
        uint256 maxEvm = uint256(_maxCoreBal) / scale;

        evmAmount = _amount;
        if (evmAmount > maxEvm) revert TransferExceedsBridgeBalance(evmAmount, maxEvm);
        coreAmount = uint64(evmAmount * scale);
    }

    // ──────────────────────────────────────────────────────────────
    //  HyperCore precompile helpers
    // ──────────────────────────────────────────────────────────────

    function _spotBalance(address _user, uint64 _token) internal view returns (uint64) {
        (bool ok, bytes memory result) = SPOT_BALANCE_PRECOMPILE.staticcall(abi.encode(_user, _token));
        if (!ok || result.length < 32) return 0;
        (uint64 total,,) = abi.decode(result, (uint64, uint64, uint64));
        return total;
    }

    function _coreUserExists(address _user) internal view returns (bool) {
        (bool ok, bytes memory result) = CORE_USER_EXISTS_PRECOMPILE.staticcall(abi.encode(_user));
        if (!ok || result.length < 32) return false;
        return abi.decode(result, (bool));
    }

    // ──────────────────────────────────────────────────────────────
    //  OFT compose-message codec (inline, no external dependency)
    // ──────────────────────────────────────────────────────────────

    function _amountLD(bytes calldata _msg) internal pure returns (uint256) {
        return uint256(bytes32(_msg[_SRC_EID_OFFSET:_AMOUNT_LD_OFFSET]));
    }

    function _srcEid(bytes calldata _msg) internal pure returns (uint32) {
        return uint32(bytes4(_msg[_NONCE_OFFSET:_SRC_EID_OFFSET]));
    }

    function _composeFrom(bytes calldata _msg) internal pure returns (bytes32) {
        return bytes32(_msg[_AMOUNT_LD_OFFSET:_COMPOSE_FROM_OFFSET]);
    }

    function _composeMsg(bytes calldata _msg) internal pure returns (bytes memory) {
        return _msg[_COMPOSE_FROM_OFFSET:];
    }

    // ──────────────────────────────────────────────────────────────
    //  Recovery – failed compose refund
    // ──────────────────────────────────────────────────────────────

    /// @notice Retry a failed compose by refunding the OFT tokens back to the source chain.
    /// @dev Caller must supply enough `msg.value` for the LayerZero return fee.
    function refundToSrc(bytes32 _guid) external payable onlyRole(ADMIN_ROLE) {
        FailedMessage memory fm = failedMessages[_guid];
        if (fm.amountLD == 0) revert FailedMessageNotFound(_guid);
        delete failedMessages[_guid];

        uint256 totalValue = fm.msgValue + msg.value;

        IOFTMinimal(fm.oft).send{value: totalValue}(
            IOFTMinimal.SendParam({
                dstEid: fm.srcEid,
                to: fm.composeFrom,
                amountLD: fm.amountLD,
                minAmountLD: 0,
                extraOptions: "",
                composeMsg: "",
                oftCmd: ""
            }),
            IOFTMinimal.MessagingFee({nativeFee: totalValue, lzTokenFee: 0}),
            address(this)
        );
        emit RefundedToSource(_guid);
    }

    // ──────────────────────────────────────────────────────────────
    //  Recovery – admin asset rescue
    // ──────────────────────────────────────────────────────────────

    /// @notice Pull tokens from the composer's HyperCore account back to the asset bridge
    ///         (making them available as ERC-20 on HyperEVM).
    function retrieveCoreTokens(address _oft, uint64 _coreAmount) external onlyRole(ADMIN_ROLE) {
        TokenConfig memory cfg = tokenConfigs[_oft];
        if (!cfg.enabled) revert TokenNotConfigured(_oft);

        uint64 bal = _spotBalance(address(this), cfg.coreIndexId);
        uint64 amt = _coreAmount == 0 ? bal : _coreAmount;
        if (amt > bal) amt = bal;
        if (amt == 0) return;

        bytes memory action = abi.encode(cfg.assetBridge, cfg.coreIndexId, amt);
        bytes memory payload = abi.encodePacked(SPOT_SEND_HEADER, action);
        ICoreWriter(CORE_WRITER).sendRawAction(payload);
        emit Retrieved(cfg.coreIndexId, amt, cfg.assetBridge);
    }

    /// @notice Pull native HYPE from the composer's HyperCore spot account back to the HYPE asset
    ///         bridge, making it available as native ETH on HyperEVM (retrievable via recoverNative).
    function retrieveCoreNative() external onlyRole(ADMIN_ROLE) {
        uint64 coreIndex = block.chainid == HYPE_CHAIN_ID_MAINNET ? HYPE_CORE_INDEX_MAINNET : HYPE_CORE_INDEX_TESTNET;
        uint64 bal = _spotBalance(address(this), coreIndex);
        if (bal == 0) return;

        bytes memory action = abi.encode(HYPE_ASSET_BRIDGE, coreIndex, bal);
        bytes memory payload = abi.encodePacked(SPOT_SEND_HEADER, action);
        ICoreWriter(CORE_WRITER).sendRawAction(payload);
        emit Retrieved(coreIndex, bal, HYPE_ASSET_BRIDGE);
    }

    /// @notice Rescue ERC-20 tokens stuck on this contract (HyperEVM side).
    function recoverERC20(address _token, address _to, uint256 _amount) external onlyRole(ADMIN_ROLE) {
        uint256 bal = IERC20(_token).balanceOf(address(this));
        uint256 amt = _amount == 0 ? bal : _amount;
        if (amt > bal) amt = bal;
        if (amt == 0) return;
        IERC20(_token).safeTransfer(_to, amt);
        emit Recovered(_token, _to, amt);
    }

    /// @notice Rescue native gas token stuck on this contract.
    function recoverNative(address _to, uint256 _amount) external onlyRole(ADMIN_ROLE) {
        uint256 bal = address(this).balance;
        uint256 amt = _amount == 0 ? bal : _amount;
        if (amt > bal) amt = bal;
        if (amt == 0) return;
        (bool ok,) = _to.call{value: amt}("");
        if (!ok) revert NativeTransferFailed(amt);
    }

    receive() external payable {}
}

// ──────────────────────────────────────────────────────────────
//  Minimal interfaces (avoids external dependencies)
// ──────────────────────────────────────────────────────────────

interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

interface IOFTMinimal {
    function endpoint() external view returns (address);

    struct SendParam {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes extraOptions;
        bytes composeMsg;
        bytes oftCmd;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    function send(SendParam calldata _sp, MessagingFee calldata _fee, address _refund) external payable;
}
