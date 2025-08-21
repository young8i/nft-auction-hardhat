
# NFT 拍卖市场（Hardhat + UUPS + Chainlink + 工厂 + CCIP 模块）

> 功能点：
> - ERC721 NFT 铸造与转移
> - 拍卖合约：ETH/任意 ERC20 出价，使用 Chainlink 汇率统一换算为 USD（8 位小数）比较
> - 动态手续费：根据出价金额（USD）使用分段费率（bps）
> - 工厂合约：类似 UniswapV2 的工厂，按 (nft, tokenId) 唯一映射创建拍卖（UUPS 可升级）
> - UUPS 升级：拍卖合约与工厂合约均可升级；给出 V2 示例
> - 价格预言机：可为 ETH 与多个 ERC20 配置 AggregatorV3Interface
> - CCIP 跨链拍卖（示例）：提供最简 Sender/Receiver 网关骨架，便于后续对接真实 Router
> - 完整测试：ETH 与 ERC20 出价、USD 比较、结束结算、升级测试

## 目录结构
```
contracts/
  MyNFT.sol
  PriceOracle.sol
  NftAuction.sol
  NftAuctionV2.sol
  NftAuctionFactory.sol
  crosschain/CrossChainGateway.sol
  mocks/MockERC20.sol
  mocks/MockV3Aggregator.sol
scripts/
  deploy.ts
test/
  auction.test.ts
hardhat.config.ts
```

## 快速开始

1. **安装依赖**
```bash
npm i
```

2. **编译 & 测试**
```bash
npm run build
npm test
```

3. **部署（Sepolia 示例）**
环境变量：
```
SEPOLIA_RPC=...
PRIVATE_KEY=0x...
ETHERSCAN_API=...
```
执行：
```bash
npm run deploy:sepolia
```
> 部署后，请调用 `PriceOracle.setFeed` 配置真实的 ETH/USD、ERC20/USD 预言机地址（不同网络地址不同）。

### 工厂创建拍卖
1. 由卖家铸造并持有 NFT。
2. 卖家 **批准 Factory** 转移该 tokenId：`nft.approve(factory, tokenId)` 或 `setApprovalForAll(factory, true)`。
3. 调用 `factory.createAuction(nft, tokenId, durationSec, startPriceUsd)`。
   - 工厂会以 **UUPS** 方式创建 Proxy（ERC1967Proxy），并把 NFT 从卖家转入拍卖合约。
   - 拍卖期间任何人都可用 ETH 或已配置价格源的 ERC20 出价。

### 出价规则（多币种 USD 对比）
- 通过 `PriceOracle.toUSD(token, amount)` 统一换算为 USD（8 位小数）。
- 第一笔出价必须 ≥ `startPriceUsd`。
- 后续出价必须 ≥ `当前最高USD + minIncrementUsd`（默认 $1，可由卖家或工厂所有者调整）。
- 如果产生更高出价，合约会 **自动按原路退回** 上一位最高出价者的资产（ETH 或相应 ERC20）。

### 结算 & 动态手续费
- 到期后任何人可调用 `endAuction()`：
  - 把 NFT 安全转移给最高出价者。
  - 根据最高出价的 USD 金额，从 **实付币种** 中按工厂的分段费率抽取手续费（bps），将剩余款项转给卖家。
- 默认费率：
  - `< $100`：200 bps (2%)
  - `≥ $1,000`：150 bps (1.5%)
  - `≥ $10,000`：100 bps (1%)
- 可通过 `setFeeTiers(thresholds, bps)` 自定义。`thresholds` 为 USD（8 位小数）。

### 升级（UUPS）
- 工厂本身使用 UUPS。
- 每个拍卖 Proxy 的 `_authorizeUpgrade` 仅允许 **工厂所有者** 调用。
- 演示合约 `NftAuctionV2` 新增 `version()`；测试中演示了升级流程：
  1. 部署新实现 `NftAuctionV2`
  2. 通过拍卖 Proxy 调用 `upgradeTo(newImpl)` 完成升级

### 价格预言机
- `PriceOracle.setFeed(token, aggregator)`，`token = address(0)` 表示原生 ETH。
- 强制要求价格喂价 **8 位小数**（Chainlink 常见配置），并带有**新鲜度检查**（默认 1 小时内）。

### CCIP 跨链拍卖（示例骨架）
- `CrossChainGateway` 提供 `sendBid/ccipReceive` 的最小闭环，仅用于演示消息与资产的流动。
- 生产中需要：
  - 配置真实的 Router 地址与受支持的 Token。
  - 在 `sendBid` 里把 Token 与消息一并交给 Router，由 Router 在目标链 `ccipReceive` 中把 Token/消息交付给网关，再调用拍卖合约出价。
- 测试可用自定义的 Mock Router 调用 `ccipReceive`。

## 注意事项（安全 & 最佳实践）
- 所有外部转账使用 `ReentrancyGuard` 保护；ERC20 使用 `SafeERC20`。
- 退款、结算均使用 **原路退回** 的资产类型。
- 工厂以 `(nft, tokenId)` 唯一映射拍卖地址，防止重复创建。
- 生产中建议：
  - 引入最小加价比例（按 USD 百分比）与延长时间（anti-sniping）。
  - 处理预言机异常（降级/暂停拍卖）。
  - 针对 ERC20 黑名单/税费 Token 做额外限制。

## 测试覆盖
- `auction.test.ts` 覆盖：
  - ETH/USDC 出价、USD 对比
  - 结束拍卖、手续费分配、NFT 转移
  - UUPS 升级到 `NftAuctionV2`
> 你可以 `npm run coverage`（已预留命令）集成覆盖率工具，比如 `solidity-coverage`。

## 常见问题
- **为什么可以用多币种出价？** 因为统一转换为 USD 做比较，并记录每次出价时的 USD 值用于比较/计费。
- **价格波动怎么办？** 以 **出价当下** 的汇率确定 USD 值，避免事后波动造成顺序反转；结算只基于最终最高出价的币种金额。
- **需要给谁授权？** 卖家需要把 NFT 的 `approve` 给工厂地址；ERC20 出价者需要 `approve` 拍卖地址。

---

### 部署到测试网示例（Sepolia）
1. 设置预言机地址（示意）：
   - ETH/USD：`0x694AA1769357215DE4FAC081bf1f309aDC325306`（Sepolia）
   - USDC/USD：查阅 Chainlink 文档或区块浏览器
2. 调用：
```ts
await oracle.setFeed(ethers.ZeroAddress, "ETH_USD_FEED");
await oracle.setFeed("USDC_ADDRESS", "USDC_USD_FEED");
```
3. 卖家：
```ts
await nft.approve(factory, tokenId);
await factory.createAuction(nft, tokenId, 3600, 100n * 10n ** 8n);
```

## 许可证
MIT
