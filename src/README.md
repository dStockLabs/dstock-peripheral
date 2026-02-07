# DStock Peripheral 合约说明

本目录包含了 DStock 生态系统的周边合约，主要提供基于 LayerZero 的跨链桥接和路由功能，支持代币的一键包装与跨链传输。

## 目录结构

- `interfaces/`: 合约接口定义
    - `IDStockWrapper.sol`: DStock 包装合约接口，定义了 `wrap` (包装) 和 `unwrap` (解包) 的核心逻辑。
    - `IOFTAdapter.sol`: LayerZero OFT 适配器接口，用于跨链消息发送和费用查询。
- `DStockComposerRouter.sol`: 统一路由合约，生态系统的核心入口。
- `WrappedNativePayoutHelper.sol`: 原生代币 (BNB/ETH) 支付助手合约。

## 核心合约详解

### 1. DStockComposerRouter.sol

这是一个基于 UUPS 的可升级路由合约，集成了以下功能：

- **用户入口 (BSC端)**:
    - `wrapAndBridge`: 将基础代币包装成 DStock 份额并桥接到目标链。
    - `wrapAndBridgeNative`: 将原生代币 (BNB/ETH) 包装为 WBNB/WETH，再包装成份额并桥接。
    - 提供相应的费用查询接口 (`quoteWrapAndBridge`, `quoteWrapAndBridgeNative`)。
- **LayerZero 组合消息处理 (`lzCompose`)**:
    - **正向路径**: 接收基础代币 -> 包装为份额 -> 桥接到目标链。
    - **反向路径**: 接收份额 -> 解包为基础代币 -> 本地交付或继续桥接基础代币。
- **故障处理**: 大多数组合路径的失败不会导致交易回滚，而是会发出 `RouteFailed` 事件并尝试将代币退回到指定的退款地址 (`refundBsc`)。

### 2. WrappedNativePayoutHelper.sol

专门用于处理反向路径中原生代币 (WBNB/WETH) 的解包与支付：

- **解决代理限制**: 由于 `DStockComposerRouter` 通常部署在代理合约之后，直接调用 WETH 的 `withdraw()` 可能会因为 2300 gas 限制导致接收原生代币失败。
- **安全支付**: 该助手合约是一个非代理的独立合约，能够安全地接收从 WETH 解包出来的原生代币，并使用 `call` 转发给最终接收者。
- **退款保障**: 如果接收者拒绝接收原生代币，助手会尝试将其重新包装并退回到指定的退款地址。

## 工作流程简述

1. **正向 (Forward)**: 用户或跨链消息将 `Underlying` 代币发送至 Router -> Router 调用 `Wrapper.wrap` 获得份额 -> Router 调用 `shareAdapter.send` 将份额发送至目标链。
2. **反向 (Reverse)**: 跨链消息将份额发送至 Router -> Router 调用 `Wrapper.unwrap` 获得 `Underlying` -> 如果目标是当前链，则本地交付；否则调用 `Underlying.send` 继续桥接。
