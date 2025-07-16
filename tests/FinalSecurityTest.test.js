const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("🔒 最终安全修复验证", function () {
    let simpleMultiSig, gnosisMultiSig;
    let owner1, owner2, owner3, nonOwner;
    
    beforeEach(async function () {
        [owner1, owner2, owner3, nonOwner] = await ethers.getSigners();
        
        const owners = [owner1.address, owner2.address, owner3.address];
        const threshold = 2;
        
        const SimpleMultiSig = await ethers.getContractFactory("SimpleMultiSig");
        simpleMultiSig = await SimpleMultiSig.deploy(owners, threshold);
        await simpleMultiSig.deployed();
        
        const GnosisStyleMultiSig = await ethers.getContractFactory("GnosisStyleMultiSig");
        gnosisMultiSig = await GnosisStyleMultiSig.deploy(owners, threshold);
        await gnosisMultiSig.deployed();
        
        await owner1.sendTransaction({
            to: simpleMultiSig.address,
            value: ethers.utils.parseEther("10")
        });
        
        await owner1.sendTransaction({
            to: gnosisMultiSig.address,
            value: ethers.utils.parseEther("10")
        });
    });

    describe("✅ H-01: GnosisStyleMultiSig 签名验证修复", function () {
        it("应该能够正确验证签名并执行交易", async function () {
            const recipient = nonOwner.address;
            const amount = ethers.utils.parseEther("1");
            const data = "0x";
            const nonce = await gnosisMultiSig.nonce();
            
            const txHash = await gnosisMultiSig.getTransactionHash(recipient, amount, data, nonce);
            const signature1 = await owner1.signMessage(ethers.utils.arrayify(txHash));
            const signature2 = await owner2.signMessage(ethers.utils.arrayify(txHash));
            
            // 按恢复地址排序合并签名
            const ethSignedMessageHash = ethers.utils.hashMessage(ethers.utils.arrayify(txHash));
            const recovered1 = ethers.utils.recoverAddress(ethSignedMessageHash, signature1);
            const recovered2 = ethers.utils.recoverAddress(ethSignedMessageHash, signature2);
            
            let signatures;
            if (recovered1.toLowerCase() < recovered2.toLowerCase()) {
                signatures = signature1 + signature2.slice(2);
            } else {
                signatures = signature2 + signature1.slice(2);
            }
            
            const recipientBalanceBefore = await ethers.provider.getBalance(recipient);
            
            const tx = await gnosisMultiSig.execTransaction(recipient, amount, data, signatures);
            const receipt = await tx.wait();
            
            const recipientBalanceAfter = await ethers.provider.getBalance(recipient);
            expect(recipientBalanceAfter.sub(recipientBalanceBefore)).to.equal(amount);
            
            console.log("✅ GnosisStyleMultiSig 签名验证修复成功");
            console.log(`   Gas 消耗: ${receipt.gasUsed.toString()}`);
        });

        it("应该拒绝重复签名", async function () {
            const recipient = nonOwner.address;
            const amount = ethers.utils.parseEther("1");
            const data = "0x";
            const nonce = await gnosisMultiSig.nonce();
            
            const txHash = await gnosisMultiSig.getTransactionHash(recipient, amount, data, nonce);
            const signature1 = await owner1.signMessage(ethers.utils.arrayify(txHash));
            
            const duplicateSignatures = signature1 + signature1.slice(2);
            
            await expect(
                gnosisMultiSig.execTransaction(recipient, amount, data, duplicateSignatures)
            ).to.be.revertedWith("Duplicate signature");
            
            console.log("✅ 重复签名正确被拒绝");
        });
    });

    describe("✅ H-02: SimpleMultiSig 执行失败处理修复", function () {
        it("执行失败的交易应该正确抛出异常", async function () {
            const contractBalance = await ethers.provider.getBalance(simpleMultiSig.address);
            const excessiveAmount = contractBalance.add(ethers.utils.parseEther("1"));

            const txCount = await simpleMultiSig.transactionCount();
            await simpleMultiSig.connect(owner1).submitTransaction(
                nonOwner.address,
                excessiveAmount,
                "0x",
                "失败交易测试"
            );

            // 尝试执行应该失败并抛出异常
            await expect(
                simpleMultiSig.connect(owner2).confirmTransaction(txCount)
            ).to.be.revertedWith("Transaction execution failed");

            // 验证交易状态仍然是未执行（允许重试）
            const txInfo = await simpleMultiSig.getTransaction(txCount);
            expect(txInfo.executed).to.be.false;

            console.log("✅ 执行失败的交易正确抛出异常，允许重试");
        });
    });

    describe("✅ M-01: 交易过期机制", function () {
        it("应该拒绝过期的交易", async function () {
            const currentBlock = await ethers.provider.getBlock('latest');
            const deadline = currentBlock.timestamp + 10;
            const txCount = await simpleMultiSig.transactionCount();
            
            await simpleMultiSig.connect(owner1).submitTransactionWithDeadline(
                nonOwner.address,
                ethers.utils.parseEther("1"),
                "0x",
                "过期测试",
                deadline
            );
            
            // 推进时间使交易过期
            await ethers.provider.send("evm_increaseTime", [15]);
            await ethers.provider.send("evm_mine");
            
            await expect(
                simpleMultiSig.connect(owner2).confirmTransaction(txCount)
            ).to.be.revertedWith("Transaction expired");
            
            console.log("✅ 过期交易正确被拒绝");
        });

        it("应该正确检查交易是否过期", async function () {
            const currentBlock = await ethers.provider.getBlock('latest');
            const deadline = currentBlock.timestamp + 10;
            const txCount = await simpleMultiSig.transactionCount();
            
            await simpleMultiSig.connect(owner1).submitTransactionWithDeadline(
                nonOwner.address,
                ethers.utils.parseEther("1"),
                "0x",
                "过期检查测试",
                deadline
            );
            
            // 检查交易未过期
            expect(await simpleMultiSig.isExpired(txCount)).to.be.false;
            expect(await simpleMultiSig.isExecutable(txCount)).to.be.false;
            
            // 推进时间使交易过期
            await ethers.provider.send("evm_increaseTime", [15]);
            await ethers.provider.send("evm_mine");
            
            // 检查交易已过期
            expect(await simpleMultiSig.isExpired(txCount)).to.be.true;
            expect(await simpleMultiSig.isExecutable(txCount)).to.be.false;
            
            console.log("✅ 过期检查功能正常");
        });
    });

    describe("✅ 输入验证改进", function () {
        it("应该拒绝零地址目标", async function () {
            await expect(
                simpleMultiSig.connect(owner1).submitTransaction(
                    ethers.constants.AddressZero,
                    ethers.utils.parseEther("1"),
                    "0x",
                    "零地址测试"
                )
            ).to.be.revertedWith("Invalid target address");
            
            console.log("✅ 零地址检查正常");
        });

        it("应该拒绝空描述", async function () {
            await expect(
                simpleMultiSig.connect(owner1).submitTransaction(
                    nonOwner.address,
                    ethers.utils.parseEther("1"),
                    "0x",
                    ""
                )
            ).to.be.revertedWith("Description cannot be empty");
            
            console.log("✅ 空描述检查正常");
        });
    });

    describe("📊 性能验证", function () {
        it("测量修复后的 Gas 消耗", async function () {
            const txCount = await simpleMultiSig.transactionCount();
            const submitTx = await simpleMultiSig.connect(owner1).submitTransaction(
                nonOwner.address,
                ethers.utils.parseEther("1"),
                "0x",
                "Gas 测试"
            );
            const submitReceipt = await submitTx.wait();
            
            const confirmTx = await simpleMultiSig.connect(owner2).confirmTransaction(txCount);
            const confirmReceipt = await confirmTx.wait();
            
            console.log("📊 修复后 Gas 消耗:");
            console.log(`   SimpleMultiSig 提交: ${submitReceipt.gasUsed.toString()} gas`);
            console.log(`   SimpleMultiSig 确认执行: ${confirmReceipt.gasUsed.toString()} gas`);
            
            expect(submitReceipt.gasUsed.lt(250000)).to.be.true;
            expect(confirmReceipt.gasUsed.lt(200000)).to.be.true;
        });
    });
});
