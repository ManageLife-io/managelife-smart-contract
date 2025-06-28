const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LifeToken", function () {
  let LifeToken;
  let lifeToken;
  let owner;
  let addr1;
  let addr2;
  let addrs;

  beforeEach(async function () {
    // Get the ContractFactory and Signers here.
    LifeToken = await ethers.getContractFactory("LifeToken");
    [owner, addr1, addr2, ...addrs] = await ethers.getSigners();

    // Deploy a new LifeToken contract for each test
    lifeToken = await LifeToken.deploy(owner.address);
    await lifeToken.deployed();
  });

  describe("Deployment", function () {
    it("Should set the right owner", async function () {
      expect(await lifeToken.owner()).to.equal(owner.address);
    });

    it("Should set the right rebaser", async function () {
      expect(await lifeToken.rebaser()).to.equal(owner.address);
    });

    it("Should set the right distributor", async function () {
      expect(await lifeToken.distributor()).to.equal(owner.address);
    });

    it("Should have correct token name and symbol", async function () {
      expect(await lifeToken.name()).to.equal("ManageLife Token");
      expect(await lifeToken.symbol()).to.equal("Life");
    });

    it("Should have initial supply in contract", async function () {
      const contractBalance = await lifeToken.balanceOf(lifeToken.address);
      const expectedInitialSupply = ethers.utils.parseEther("2000000000"); // 2 billion
      expect(contractBalance).to.equal(expectedInitialSupply);
    });
  });

  describe("Rebase Functionality", function () {
    it("Should allow rebaser to perform rebase after interval", async function () {
      // Fast forward time by 31 days
      await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");

      const newFactor = ethers.utils.parseEther("1.1"); // 10% increase
      await expect(lifeToken.connect(owner).rebase(newFactor))
        .to.emit(lifeToken, "Rebase");
    });

    it("Should not allow rebase before interval", async function () {
      const newFactor = ethers.utils.parseEther("1.1");
      await expect(lifeToken.connect(owner).rebase(newFactor))
        .to.be.revertedWith("Rebase interval not met");
    });

    it("Should not allow non-rebaser to rebase", async function () {
      await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");

      const newFactor = ethers.utils.parseEther("1.1");
      await expect(lifeToken.connect(addr1).rebase(newFactor))
        .to.be.revertedWith("Caller is not the rebaser");
    });

    it("Should reject invalid rebase factors", async function () {
      await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");

      const tooHighFactor = ethers.utils.parseEther("11"); // 11x, exceeds MAX_REBASE_FACTOR
      await expect(lifeToken.connect(owner).rebase(tooHighFactor))
        .to.be.revertedWith("Rebase factor too high");
    });
  });

  describe("Minting Functionality", function () {
    it("Should allow owner to mint remaining supply", async function () {
      const initialBalance = await lifeToken.balanceOf(addr1.address);
      await expect(lifeToken.connect(owner).mintRemainingSupply(addr1.address))
        .to.emit(lifeToken, "Mint");
      
      const finalBalance = await lifeToken.balanceOf(addr1.address);
      expect(finalBalance).to.be.gt(initialBalance);
    });

    it("Should not allow non-owner to mint", async function () {
      await expect(lifeToken.connect(addr1).mintRemainingSupply(addr1.address))
        .to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("Should not allow minting to zero address", async function () {
      await expect(lifeToken.connect(owner).mintRemainingSupply(ethers.constants.AddressZero))
        .to.be.revertedWith("Cannot mint to zero address");
    });
  });

  describe("Transfer Operations", function () {
    beforeEach(async function () {
      // Mint some tokens to addr1 for testing
      await lifeToken.connect(owner).mintRemainingSupply(addr1.address);
    });

    it("Should transfer tokens between accounts", async function () {
      const transferAmount = ethers.utils.parseEther("1000");
      const initialBalance1 = await lifeToken.balanceOf(addr1.address);
      const initialBalance2 = await lifeToken.balanceOf(addr2.address);

      await lifeToken.connect(addr1).transfer(addr2.address, transferAmount);

      const finalBalance1 = await lifeToken.balanceOf(addr1.address);
      const finalBalance2 = await lifeToken.balanceOf(addr2.address);

      expect(finalBalance1).to.equal(initialBalance1.sub(transferAmount));
      expect(finalBalance2).to.equal(initialBalance2.add(transferAmount));
    });

    it("Should fail if sender doesn't have enough tokens", async function () {
      const transferAmount = ethers.utils.parseEther("10000000000"); // Very large amount
      await expect(lifeToken.connect(addr1).transfer(addr2.address, transferAmount))
        .to.be.revertedWith("Insufficient balance");
    });
  });

  describe("Admin Functions", function () {
    it("Should allow owner to set new rebaser", async function () {
      await expect(lifeToken.connect(owner).setRebaser(addr1.address))
        .to.emit(lifeToken, "RebaserUpdated")
        .withArgs(addr1.address);
      
      expect(await lifeToken.rebaser()).to.equal(addr1.address);
    });

    it("Should not allow non-owner to set rebaser", async function () {
      await expect(lifeToken.connect(addr1).setRebaser(addr1.address))
        .to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("Should allow owner to exclude address from rebase", async function () {
      await expect(lifeToken.connect(owner).excludeFromRebase(addr1.address))
        .to.emit(lifeToken, "ExcludedFromRebase");
      
      expect(await lifeToken.isExcludedFromRebase(addr1.address)).to.be.true;
    });

    it("Should allow owner to include address in rebase", async function () {
      // First exclude
      await lifeToken.connect(owner).excludeFromRebase(addr1.address);
      expect(await lifeToken.isExcludedFromRebase(addr1.address)).to.be.true;
      
      // Then include back
      await expect(lifeToken.connect(owner).includeInRebase(addr1.address))
        .to.emit(lifeToken, "ExcludedFromRebase");
      
      expect(await lifeToken.isExcludedFromRebase(addr1.address)).to.be.false;
    });
  });

  describe("View Functions", function () {
    it("Should return correct total supply", async function () {
      const totalSupply = await lifeToken.totalSupply();
      const expectedInitialSupply = ethers.utils.parseEther("2000000000"); // 2 billion
      expect(totalSupply).to.equal(expectedInitialSupply);
    });

    it("Should return correct balance for excluded addresses", async function () {
      // Mint tokens to addr1
      await lifeToken.connect(owner).mintRemainingSupply(addr1.address);
      const balanceBeforeExclusion = await lifeToken.balanceOf(addr1.address);
      
      // Exclude addr1 from rebase
      await lifeToken.connect(owner).excludeFromRebase(addr1.address);
      
      // Balance should remain the same for excluded address
      const balanceAfterExclusion = await lifeToken.balanceOf(addr1.address);
      expect(balanceAfterExclusion).to.equal(balanceBeforeExclusion);
    });

    it("Should return base balance history", async function () {
      // Mint tokens to addr1 to create history
      await lifeToken.connect(owner).mintRemainingSupply(addr1.address);
      
      const history = await lifeToken.getBaseBalanceHistory(addr1.address);
      expect(history.length).to.be.gt(0);
    });
  });

  describe("Ownership Transfer", function () {
    it("Should initiate ownership transfer", async function () {
      await expect(lifeToken.connect(owner).transferOwnership(addr1.address))
        .to.emit(lifeToken, "OwnershipTransferStarted")
        .withArgs(addr1.address);
    });

    it("Should complete ownership transfer after delay", async function () {
      // Initiate transfer
      await lifeToken.connect(owner).transferOwnership(addr1.address);
      
      // Fast forward time by 3 days (more than 2-day delay)
      await ethers.provider.send("evm_increaseTime", [3 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");
      
      // Accept ownership
      await lifeToken.connect(addr1).acceptOwnership();
      
      expect(await lifeToken.owner()).to.equal(addr1.address);
    });

    it("Should not allow ownership renunciation", async function () {
      await expect(lifeToken.connect(owner).renounceOwnership())
        .to.be.revertedWith("Ownership renunciation disabled");
    });
  });
});