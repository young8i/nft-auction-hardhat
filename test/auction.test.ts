import { expect } from "chai";
import { ethers, upgrades } from "hardhat";

function getEventArg<T = any>(
  receipt: any,
  iface: any,
  eventName: string,
  arg: string
): T {
  for (const log of receipt!.logs) {
    try {
      const parsed = iface.parseLog(log);
      if (parsed && parsed.name === eventName) {
        return parsed.args[arg] as T;
      }
    } catch {}
  }
  throw new Error(`Event ${eventName} not found in receipt`);
}

describe("NFT Auction Market", function () {
  it("ETH & ERC20 bidding, USD comparison, end & payout", async () => {
    const [deployer, seller, bidder1, bidder2, feeTo] = await ethers.getSigners();

    // Oracle + feeds: ETH/USD = $3000, USDC/USD = $1
    const Oracle = await ethers.getContractFactory("PriceOracle");
    const oracle = await Oracle.deploy(deployer.address);
    await oracle.waitForDeployment();

    const MockAgg = await ethers.getContractFactory("MockV3Aggregator");
    const ethAgg = await MockAgg.deploy(8, 3000n * 10n ** 8n); // $3000
    const usdcAgg = await MockAgg.deploy(8, 1n * 10n ** 8n);   // $1
    await oracle.setFeed(ethers.ZeroAddress, await ethAgg.getAddress());

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20.deploy("Mock USDC", "USDC", 6);
    await oracle.setFeed(await usdc.getAddress(), await usdcAgg.getAddress());

    // Deploy Auction impl + Factory (UUPS)
    const AuctionImpl = await ethers.getContractFactory("NftAuction");
    const impl = await AuctionImpl.deploy();
    await impl.waitForDeployment();

    const Factory = await ethers.getContractFactory("NftAuctionFactory");
    const factory = await upgrades.deployProxy(
      Factory,
      [deployer.address, await impl.getAddress(), await oracle.getAddress(), feeTo.address],
      { kind: "uups" }
    );
    await factory.waitForDeployment();

    // NFT
    const MyNFT = await ethers.getContractFactory("MyNFT");
    const nft = await MyNFT.deploy("MyNFT", "MNFT", "");
    await nft.waitForDeployment();

    // ✅ 由 deployer（当前 owner）把所有权移交给 seller，然后由 seller 铸造
    await nft.transferOwnership(seller.address);
    await nft.connect(seller).mint(seller.address);

    const tokenId = 1;
    await nft.connect(seller).approve(await factory.getAddress(), tokenId);

    // Create auction: duration 1 hour, start price $100
    const startPriceUsd = 100n * 10n ** 8n;
    const tx = await factory
      .connect(seller)
      .createAuction(await nft.getAddress(), tokenId, 3600, startPriceUsd);
    const receipt = await tx.wait();

    // ✅ 用接口安全解析事件，拿到拍卖地址
    const auctionAddr = getEventArg<string>(
      receipt,
      Factory.interface,
      "AuctionCreated",
      "auction"
    );
    const auction = await ethers.getContractAt("NftAuction", auctionAddr);

    // Bidder1 bids 0.05 ETH ($150) -> should be highest
    await auction.connect(bidder1).bidETH({ value: ethers.parseEther("0.05") });

    // Bidder2 bids 120 USDC ($120) -> lower than 150 -> revert
    await usdc.connect(deployer).transfer(bidder2.address, 1_000_000n * 10n ** 6n);
    await usdc.connect(bidder2).approve(auctionAddr, 10n ** 24n);
    await expect(
      auction.connect(bidder2).bidERC20(await usdc.getAddress(), 120n * 10n ** 6n)
    ).to.be.revertedWith("too low");

    // Bidder2 bids 0.06 ETH ($180) -> becomes highest, refund previous
    await expect(
      auction.connect(bidder2).bidETH({ value: ethers.parseEther("0.06") })
    ).to.emit(auction, "BidPlaced");

    // Fast-forward time and end
    await ethers.provider.send("evm_increaseTime", [4000]);
    await ethers.provider.send("evm_mine", []);

    const feeToBalBefore = await ethers.provider.getBalance(feeTo.address);
    await expect(auction.endAuction()).to.emit(auction, "AuctionEnded");
    const feeToBalAfter = await ethers.provider.getBalance(feeTo.address);

    expect(feeToBalAfter).to.be.gt(feeToBalBefore);
    expect(await nft.ownerOf(tokenId)).to.eq(bidder2.address);
  });

  it("Upgrade auction proxy to V2", async () => {
    const [deployer, seller, feeTo] = await ethers.getSigners();

    const Oracle = await ethers.getContractFactory("PriceOracle");
    const oracle = await Oracle.deploy(deployer.address);
    await oracle.waitForDeployment();

    const MockAgg = await ethers.getContractFactory("MockV3Aggregator");
    const ethAgg = await MockAgg.deploy(8, 3000n * 10n ** 8n);
    await oracle.setFeed(ethers.ZeroAddress, await ethAgg.getAddress());

    const AuctionImpl = await ethers.getContractFactory("NftAuction");
    const impl = await AuctionImpl.deploy();
    await impl.waitForDeployment();

    const Factory = await ethers.getContractFactory("NftAuctionFactory");
    const factory = await upgrades.deployProxy(
      Factory,
      [deployer.address, await impl.getAddress(), await oracle.getAddress(), feeTo.address],
      { kind: "uups" }
    );
    await factory.waitForDeployment();

    const MyNFT = await ethers.getContractFactory("MyNFT");
    const nft = await MyNFT.deploy("MyNFT", "MNFT", "");
    await nft.waitForDeployment();

    // ✅ 由 deployer 把 owner 移交给 seller，然后 seller mint
    await nft.transferOwnership(seller.address);
    await nft.connect(seller).mint(seller.address);
    await nft.connect(seller).approve(await factory.getAddress(), 1);

    const tx = await factory
      .connect(seller)
      .createAuction(await nft.getAddress(), 1, 3600, 100n * 10n ** 8n);
    const rc = await tx.wait();

    // 解析 AuctionCreated 事件拿到拍卖地址
    const auctionAddr = (function () {
      for (const log of rc!.logs) {
        try {
          const parsed = Factory.interface.parseLog(log);
          if (parsed && parsed.name === "AuctionCreated") return parsed.args["auction"] as string;
        } catch {}
      }
      throw new Error("AuctionCreated not found");
    })();

    // 部署 V2
    const AuctionV2 = await ethers.getContractFactory("NftAuctionV2");
    const v2 = await AuctionV2.deploy();
    await v2.waitForDeployment();

    // ✅ 用最小 ABI 调用 UUPS 升级（由 factory.owner() 调用）
    const UUPS_MIN_ABI = ["function upgradeToAndCall(address newImplementation, bytes data)"];
    const upgrader = new ethers.Contract(auctionAddr, UUPS_MIN_ABI, deployer);
    await upgrader.upgradeToAndCall(await v2.getAddress(), "0x");

    // 验证已是 V2
    const auctionAsV2 = await ethers.getContractAt("NftAuctionV2", auctionAddr);
    expect(await auctionAsV2.version()).to.eq("NftAuctionV2");
  });

});
