const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("多签钱包测试", function () {
    let simpleMultiSig;
    let gnosisMultiSig;
    let owner1, owner2, owner3, nonOwner;
    let mockTarget;
    
    beforeEach(async function () {
        // 获取测试账户
        [owner1, owner2, owner3, nonOwner] = await ethers.getSigners();
        
        const owners = [owner1.address, owner2.address, owner3.address];
        const threshold = 2; // 3个人中需要2个签名
        
        // 部署简单多签合约
        const SimpleMultiSig = await ethers.getContractFactory("SimpleMultiSig");
        simpleMultiSig = await SimpleMultiSig.deploy(owners, threshold);
        await simpleMultiSig.deployed();
        
        // 部署 Gnosis 风格多签合约
        const GnosisStyleMultiSig = await ethers.getContractFactory("GnosisStyleMultiSig");
        gnosisMultiSig = await GnosisStyleMultiSig.deploy(owners, threshold);
        await gnosisMultiSig.deployed();
        
        // 部署一个模拟目标合约用于测试
        const MockTarget = await ethers.getContractFactory("MockERC20");
        mockTarget = await MockTarget.deploy("Test Token", "TEST", 18);
        await mockTarget.deployed();
        
        // 给多签钱包转一些 ETH
        await owner1.sendTransaction({
            to: simpleMultiSig.address,
            value: ethers.utils.parseEther("10")
        });
        
        await owner1.sendTransaction({
            to: gnosisMultiSig.address,
            value: ethers.utils.parseEther("10")
        });
    });
    
    describe("SimpleMultiSig 测试", function () {
        it("应该正确初始化", async function () {
            expect(await simpleMultiSig.getOwnerCount()).to.equal(3);
            expect(await simpleMultiSig.signaturesRequired()).to.equal(2);
            expect(await simpleMultiSig.isOwner(owner1.address)).to.be.true;
            expect(await simpleMultiSig.isOwner(owner2.address)).to.be.true;
            expect(await simpleMultiSig.isOwner(owner3.address)).to.be.true;
            expect(await simpleMultiSig.isOwner(nonOwner.address)).to.be.false;
        });
        
        it("只有所有者可以提交交易", async function () {
            const to = owner1.address;
            const value = ethers.utils.parseEther("1");
            const data = "0x";
            const description = "测试转账";
            
            // 所有者可以提交
            await expect(
                simpleMultiSig.connect(owner1).submitTransaction(to, value, data, description)
            ).to.emit(simpleMultiSig, "TransactionSubmitted");
            
            // 非所有者不能提交
            await expect(
                simpleMultiSig.connect(nonOwner).submitTransaction(to, value, data, description)
            ).to.be.revertedWith("Not an owner");
        });
        
        it("应该能够确认和执行交易", async function () {
            const to = owner1.address;
            const value = ethers.utils.parseEther("1");
            const data = "0x";
            const description = "测试转账";
            
            // 提交交易（owner1 自动确认）
            const tx = await simpleMultiSig.connect(owner1).submitTransaction(to, value, data, description);
            const receipt = await tx.wait();
            const transactionId = 0; // 第一个交易
            
            // 检查交易状态
            let txInfo = await simpleMultiSig.getTransaction(transactionId);
            expect(txInfo.confirmationCount).to.equal(1);
            expect(txInfo.executed).to.be.false;
            
            // owner2 确认交易
            const balanceBefore = await ethers.provider.getBalance(to);
            await expect(
                simpleMultiSig.connect(owner2).confirmTransaction(transactionId)
            ).to.emit(simpleMultiSig, "TransactionExecuted");
            
            // 检查交易已执行
            txInfo = await simpleMultiSig.getTransaction(transactionId);
            expect(txInfo.executed).to.be.true;
            
            // 检查余额变化
            const balanceAfter = await ethers.provider.getBalance(to);
            expect(balanceAfter.sub(balanceBefore)).to.equal(value);
        });
        
        it("应该能够撤销确认", async function () {
            const to = owner1.address;
            const value = ethers.utils.parseEther("1");
            const data = "0x";
            const description = "测试转账";
            
            // 提交交易
            await simpleMultiSig.connect(owner1).submitTransaction(to, value, data, description);
            const transactionId = 0;
            
            // 撤销确认
            await expect(
                simpleMultiSig.connect(owner1).revokeConfirmation(transactionId)
            ).to.emit(simpleMultiSig, "TransactionRevoked");
            
            // 检查确认数量
            const txInfo = await simpleMultiSig.getTransaction(transactionId);
            expect(txInfo.confirmationCount).to.equal(0);
        });
        
        it("应该能够管理所有者", async function () {
            const newOwner = nonOwner.address;
            
            // 准备添加所有者的交易数据
            const addOwnerData = simpleMultiSig.interface.encodeFunctionData("addOwner", [newOwner]);
            
            // 提交添加所有者的交易
            await simpleMultiSig.connect(owner1).submitTransaction(
                simpleMultiSig.address,
                0,
                addOwnerData,
                "添加新所有者"
            );
            
            // owner2 确认
            await simpleMultiSig.connect(owner2).confirmTransaction(0);
            
            // 检查新所有者已添加
            expect(await simpleMultiSig.isOwner(newOwner)).to.be.true;
            expect(await simpleMultiSig.getOwnerCount()).to.equal(4);
        });
    });
    
    describe("GnosisStyleMultiSig 测试", function () {
        it("应该正确初始化", async function () {
            expect(await gnosisMultiSig.getOwnerCount()).to.equal(3);
            expect(await gnosisMultiSig.threshold()).to.equal(2);
            expect(await gnosisMultiSig.isOwner(owner1.address)).to.be.true;
            expect(await gnosisMultiSig.isOwner(owner2.address)).to.be.true;
            expect(await gnosisMultiSig.isOwner(owner3.address)).to.be.true;
        });
        
        it("应该能够生成正确的交易哈希", async function () {
            const to = owner1.address;
            const value = ethers.utils.parseEther("1");
            const data = "0x";
            const nonce = await gnosisMultiSig.nonce();
            
            const txHash = await gnosisMultiSig.getTransactionHash(to, value, data, nonce);
            expect(txHash).to.match(/^0x[a-fA-F0-9]{64}$/); // 32 bytes = 64 hex chars + 0x
        });
        
        // 注意：完整的签名测试需要更复杂的设置，这里只测试基本功能
        it("应该能够接收 ETH", async function () {
            const balanceBefore = await ethers.provider.getBalance(gnosisMultiSig.address);
            
            await owner1.sendTransaction({
                to: gnosisMultiSig.address,
                value: ethers.utils.parseEther("1")
            });
            
            const balanceAfter = await ethers.provider.getBalance(gnosisMultiSig.address);
            expect(balanceAfter.sub(balanceBefore)).to.equal(ethers.utils.parseEther("1"));
        });
    });
    
    describe("对比测试：无时间锁 vs 有时间锁", function () {
        it("SimpleMultiSig 应该立即执行（无延迟）", async function () {
            const to = owner1.address;
            const value = ethers.utils.parseEther("1");
            const data = "0x";
            const description = "立即执行测试";
            
            const startTime = Date.now();
            
            // 提交并确认交易
            await simpleMultiSig.connect(owner1).submitTransaction(to, value, data, description);
            await simpleMultiSig.connect(owner2).confirmTransaction(0);
            
            const endTime = Date.now();
            const executionTime = endTime - startTime;
            
            // 检查交易已执行
            const txInfo = await simpleMultiSig.getTransaction(0);
            expect(txInfo.executed).to.be.true;
            
            // 执行时间应该很短（几秒内）
            console.log(`执行时间: ${executionTime}ms`);
            expect(executionTime).to.be.lessThan(10000); // 少于10秒
        });
        
        it("应该展示时间锁的问题（仅作对比）", async function () {
            // 这里我们不实际测试时间锁，只是说明问题
            console.log("传统时间锁问题:");
            console.log("- 需要等待 48 小时");
            console.log("- 交易可能被抢跑");
            console.log("- 用户体验差");
            console.log("");
            console.log("新的多签方案优势:");
            console.log("- 签够人数立即执行");
            console.log("- 无延迟等待");
            console.log("- 更好的用户体验");
            console.log("- 同样的安全性");
        });
    });
});