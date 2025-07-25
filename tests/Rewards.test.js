const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Rewards System", function () {
  let BaseRewards, DynamicRewards, LifeToken;
  let baseRewards, dynamicRewards, lifeToken, stakingToken;
  let owner, user1, user2, rewardDistributor;
  let adminControl;

  beforeEach(async function () {
    [owner, user1, user2, rewardDistributor] = await ethers.getSigners();

    // Deploy AdminControl
    const AdminControl = await ethers.getContractFactory("AdminControl");
    adminControl = await AdminControl.deploy();
    await adminControl.deployed();

    // Deploy LifeToken (reward token)
    LifeToken = await ethers.getContractFactory("LifeToken");
    lifeToken = await LifeToken.deploy(owner.address);
    await lifeToken.deployed();

    // Deploy another token for staking
    stakingToken = await LifeToken.deploy(owner.address);
    await stakingToken.deployed();

    // Deploy Rewards contracts
    BaseRewards = await ethers.getContractFactory("BaseRewards");
    baseRewards = await BaseRewards.deploy(
      stakingToken.address,
      lifeToken.address,
      adminControl.address
    );
    await baseRewards.deployed();

    DynamicRewards = await ethers.getContractFactory("DynamicRewards");
    dynamicRewards = await DynamicRewards.deploy(
      stakingToken.address,
      adminControl.address
    );
    await dynamicRewards.deployed();

    // Setup initial token distributions
    await lifeToken.initialDistribution(owner.address, ethers.utils.parseEther("1000000"));
    await stakingToken.initialDistribution(user1.address, ethers.utils.parseEther("10000"));
    await stakingToken.initialDistribution(user2.address, ethers.utils.parseEther("5000"));
    
    // Transfer reward tokens to rewards contracts
    await lifeToken.transfer(baseRewards.address, ethers.utils.parseEther("100000"));
    await lifeToken.transfer(dynamicRewards.address, ethers.utils.parseEther("100000"));
  });

  describe("BaseRewards Contract", function () {
    describe("Deployment", function () {
      it("Should set correct staking token", async function () {
        expect(await baseRewards.stakingToken()).to.equal(stakingToken.address);
      });

      it("Should set correct reward token", async function () {
        expect(await baseRewards.rewardToken()).to.equal(lifeToken.address);
      });

      it("Should set correct admin control", async function () {
        expect(await baseRewards.adminControl()).to.equal(adminControl.address);
      });
    });

    describe("Staking", function () {
      const stakeAmount = ethers.utils.parseEther("1000");

      beforeEach(async function () {
        await stakingToken.connect(user1).approve(baseRewards.address, stakeAmount);
      });

      it("Should allow user to stake tokens", async function () {
        await expect(
          baseRewards.connect(user1).stake(stakeAmount)
        ).to.emit(baseRewards, "Staked")
          .withArgs(user1.address, stakeAmount);
        
        expect(await baseRewards.balanceOf(user1.address)).to.equal(stakeAmount);
        expect(await baseRewards.totalSupply()).to.equal(stakeAmount);
      });

      it("Should not allow staking zero amount", async function () {
        await expect(
          baseRewards.connect(user1).stake(0)
        ).to.be.revertedWith("Cannot stake 0");
      });

      it("Should not allow staking without sufficient balance", async function () {
        const excessiveAmount = ethers.utils.parseEther("20000");
        await stakingToken.connect(user1).approve(baseRewards.address, excessiveAmount);
        
        await expect(
          baseRewards.connect(user1).stake(excessiveAmount)
        ).to.be.revertedWith("ERC20: transfer amount exceeds balance");
      });
    });

    describe("Withdrawing", function () {
      const stakeAmount = ethers.utils.parseEther("1000");
      const withdrawAmount = ethers.utils.parseEther("500");

      beforeEach(async function () {
        await stakingToken.connect(user1).approve(baseRewards.address, stakeAmount);
        await baseRewards.connect(user1).stake(stakeAmount);
      });

      it("Should allow user to withdraw staked tokens", async function () {
        await expect(
          baseRewards.connect(user1).withdraw(withdrawAmount)
        ).to.emit(baseRewards, "Withdrawn")
          .withArgs(user1.address, withdrawAmount);
        
        expect(await baseRewards.balanceOf(user1.address)).to.equal(
          stakeAmount.sub(withdrawAmount)
        );
      });

      it("Should not allow withdrawing more than staked", async function () {
        const excessiveAmount = ethers.utils.parseEther("2000");
        
        await expect(
          baseRewards.connect(user1).withdraw(excessiveAmount)
        ).to.be.revertedWith("Cannot withdraw more than staked");
      });

      it("Should not allow withdrawing zero amount", async function () {
        await expect(
          baseRewards.connect(user1).withdraw(0)
        ).to.be.revertedWith("Cannot withdraw 0");
      });
    });

    describe("Reward Distribution", function () {
      const stakeAmount = ethers.utils.parseEther("1000");
      const rewardAmount = ethers.utils.parseEther("100");

      beforeEach(async function () {
        // Set reward rate
        await baseRewards.setRewardRate(ethers.utils.parseEther("1")); // 1 token per second
        
        // User stakes tokens
        await stakingToken.connect(user1).approve(baseRewards.address, stakeAmount);
        await baseRewards.connect(user1).stake(stakeAmount);
      });

      it("Should accumulate rewards over time", async function () {
        // Wait some time (simulate by advancing blocks)
        await ethers.provider.send("evm_increaseTime", [3600]); // 1 hour
        await ethers.provider.send("evm_mine");
        
        const earned = await baseRewards.earned(user1.address);
        expect(earned).to.be.gt(0);
      });

      it("Should allow claiming rewards", async function () {
        // Wait some time
        await ethers.provider.send("evm_increaseTime", [3600]);
        await ethers.provider.send("evm_mine");
        
        const initialBalance = await lifeToken.balanceOf(user1.address);
        
        await expect(
          baseRewards.connect(user1).getReward()
        ).to.emit(baseRewards, "RewardPaid");
        
        const finalBalance = await lifeToken.balanceOf(user1.address);
        expect(finalBalance).to.be.gt(initialBalance);
      });

      it("Should distribute rewards proportionally", async function () {
        // Second user stakes different amount
        const stakeAmount2 = ethers.utils.parseEther("2000");
        await stakingToken.connect(user2).approve(baseRewards.address, stakeAmount2);
        await baseRewards.connect(user2).stake(stakeAmount2);
        
        // Wait some time
        await ethers.provider.send("evm_increaseTime", [3600]);
        await ethers.provider.send("evm_mine");
        
        const earned1 = await baseRewards.earned(user1.address);
        const earned2 = await baseRewards.earned(user2.address);
        
        // User2 should earn approximately twice as much (staked 2x more)
        expect(earned2.div(earned1)).to.be.closeTo(2, 0.1);
      });
    });

    describe("Admin Functions", function () {
      it("Should allow owner to set reward rate", async function () {
        const newRate = ethers.utils.parseEther("2");
        
        await expect(
          baseRewards.setRewardRate(newRate)
        ).to.emit(baseRewards, "RewardRateUpdated")
          .withArgs(newRate);
        
        expect(await baseRewards.rewardRate()).to.equal(newRate);
      });

      it("Should not allow non-owner to set reward rate", async function () {
        const newRate = ethers.utils.parseEther("2");
        
        await expect(
          baseRewards.connect(user1).setRewardRate(newRate)
        ).to.be.revertedWith("AdminControl: caller is not authorized");
      });

      it("Should allow owner to recover excess tokens", async function () {
        const recoverAmount = ethers.utils.parseEther("1000");
        
        await expect(
          baseRewards.recoverERC20(lifeToken.address, recoverAmount)
        ).to.emit(baseRewards, "Recovered")
          .withArgs(lifeToken.address, recoverAmount);
      });
    });
  });

  describe("DynamicRewards Contract", function () {
    describe("Deployment", function () {
      it("Should set correct staking token", async function () {
        expect(await dynamicRewards.stakingToken()).to.equal(stakingToken.address);
      });

      it("Should set correct admin control", async function () {
        expect(await dynamicRewards.adminControl()).to.equal(adminControl.address);
      });
    });

    describe("Multi-Token Rewards", function () {
      const stakeAmount = ethers.utils.parseEther("1000");

      beforeEach(async function () {
        // Add reward tokens
        await dynamicRewards.addRewardToken(lifeToken.address, ethers.utils.parseEther("1"));
        
        // User stakes tokens
        await stakingToken.connect(user1).approve(dynamicRewards.address, stakeAmount);
        await dynamicRewards.connect(user1).stake(stakeAmount);
      });

      it("Should allow adding reward tokens", async function () {
        const rewardTokens = await dynamicRewards.getRewardTokens();
        expect(rewardTokens).to.include(lifeToken.address);
      });

      it("Should accumulate rewards for multiple tokens", async function () {
        // Wait some time
        await ethers.provider.send("evm_increaseTime", [3600]);
        await ethers.provider.send("evm_mine");
        
        const earned = await dynamicRewards.earned(user1.address, lifeToken.address);
        expect(earned).to.be.gt(0);
      });

      it("Should allow claiming specific token rewards", async function () {
        // Wait some time
        await ethers.provider.send("evm_increaseTime", [3600]);
        await ethers.provider.send("evm_mine");
        
        const initialBalance = await lifeToken.balanceOf(user1.address);
        
        await expect(
          dynamicRewards.connect(user1).getReward(lifeToken.address)
        ).to.emit(dynamicRewards, "RewardPaid");
        
        const finalBalance = await lifeToken.balanceOf(user1.address);
        expect(finalBalance).to.be.gt(initialBalance);
      });

      it("Should allow claiming all rewards", async function () {
        // Wait some time
        await ethers.provider.send("evm_increaseTime", [3600]);
        await ethers.provider.send("evm_mine");
        
        await expect(
          dynamicRewards.connect(user1).getAllRewards()
        ).to.emit(dynamicRewards, "RewardPaid");
      });
    });

    describe("Dynamic Rate Management", function () {
      beforeEach(async function () {
        await dynamicRewards.addRewardToken(lifeToken.address, ethers.utils.parseEther("1"));
      });

      it("Should allow updating reward rates", async function () {
        const newRate = ethers.utils.parseEther("2");
        
        await expect(
          dynamicRewards.updateRewardRate(lifeToken.address, newRate)
        ).to.emit(dynamicRewards, "RewardRateUpdated")
          .withArgs(lifeToken.address, newRate);
      });

      it("Should allow removing reward tokens", async function () {
        await expect(
          dynamicRewards.removeRewardToken(lifeToken.address)
        ).to.emit(dynamicRewards, "RewardTokenRemoved")
          .withArgs(lifeToken.address);
        
        const rewardTokens = await dynamicRewards.getRewardTokens();
        expect(rewardTokens).to.not.include(lifeToken.address);
      });
    });
  });

  describe("Integration Tests", function () {
    it("Should handle complex staking scenarios", async function () {
      const stakeAmount1 = ethers.utils.parseEther("1000");
      const stakeAmount2 = ethers.utils.parseEther("2000");
      
      // Set up base rewards
      await baseRewards.setRewardRate(ethers.utils.parseEther("1"));
      
      // User1 stakes
      await stakingToken.connect(user1).approve(baseRewards.address, stakeAmount1);
      await baseRewards.connect(user1).stake(stakeAmount1);
      
      // Wait some time
      await ethers.provider.send("evm_increaseTime", [1800]); // 30 minutes
      await ethers.provider.send("evm_mine");
      
      // User2 stakes
      await stakingToken.connect(user2).approve(baseRewards.address, stakeAmount2);
      await baseRewards.connect(user2).stake(stakeAmount2);
      
      // Wait more time
      await ethers.provider.send("evm_increaseTime", [1800]); // Another 30 minutes
      await ethers.provider.send("evm_mine");
      
      // Check rewards
      const earned1 = await baseRewards.earned(user1.address);
      const earned2 = await baseRewards.earned(user2.address);
      
      expect(earned1).to.be.gt(0);
      expect(earned2).to.be.gt(0);
      expect(earned1).to.be.gt(earned2); // User1 staked earlier
    });

    it("Should handle emergency scenarios", async function () {
      const stakeAmount = ethers.utils.parseEther("1000");
      
      // User stakes
      await stakingToken.connect(user1).approve(baseRewards.address, stakeAmount);
      await baseRewards.connect(user1).stake(stakeAmount);
      
      // Emergency exit
      await expect(
        baseRewards.connect(user1).exit()
      ).to.emit(baseRewards, "Withdrawn");
      
      expect(await baseRewards.balanceOf(user1.address)).to.equal(0);
    });
  });
});