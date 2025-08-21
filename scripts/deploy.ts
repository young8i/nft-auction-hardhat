import { ethers, upgrades } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // 1) Deploy 价格预言机
  const Oracle = await ethers.getContractFactory("PriceOracle");
  const oracle = await Oracle.deploy(deployer.address);
  await oracle.waitForDeployment();
  const oracleAddr = await oracle.getAddress();
  console.log("Oracle:", oracleAddr);

  // 2) Deploy 拍卖实现 (UUPS)
  const AuctionImpl = await ethers.getContractFactory("NftAuction");
  const impl = await AuctionImpl.deploy();
  await impl.waitForDeployment();
  const implAddr = await impl.getAddress();
  console.log("Auction implementation:", implAddr);

  // 👇 feeTo 地址：优先用 .env 的 FEE_TO，没有就用 deployer
  const feeToAddr = process.env.FEE_TO && process.env.FEE_TO !== ""
    ? process.env.FEE_TO
    : deployer.address;

  // 3) Deploy 拍卖工厂 (UUPS proxy)
  const Factory = await ethers.getContractFactory("NftAuctionFactory");
  const factory = await upgrades.deployProxy(
    Factory,
    [deployer.address, implAddr, oracleAddr, feeToAddr],
    { kind: "uups" }
  );
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("Factory (proxy):", factoryAddr);

  // 提示：这里记下地址，后续 setFeed 用
  // 例：await (await oracle.setFeed(ethers.ZeroAddress, "0x694AA1769...")).wait();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
