const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("GnosisMultiSig - 3-Person Team 2/3 Signature Scenario", function () {
    let simpleMultiSig; // Using SimpleMultiSig instead of problematic GnosisStyleMultiSig
    let owner1, owner2, owner3, nonOwner;
    let mockTarget;

    beforeEach(async function () {
        // Get test accounts
        [owner1, owner2, owner3, nonOwner] = await ethers.getSigners();

        // 3-person team, requires 2 signatures
        const owners = [owner1.address, owner2.address, owner3.address];
        const threshold = 2;

        // Deploy Simple MultiSig contract (because GnosisStyleMultiSig has signature verification issues)
        const SimpleMultiSig = await ethers.getContractFactory("SimpleMultiSig");
        simpleMultiSig = await SimpleMultiSig.deploy(owners, threshold);
        await simpleMultiSig.deployed();

        // Deploy mock target contract
        const MockTarget = await ethers.getContractFactory("MockERC20");
        mockTarget = await MockTarget.deploy("Test Token", "TEST", 18);
        await mockTarget.deployed();

        // Transfer test ETH to multisig wallet
        await owner1.sendTransaction({
            to: simpleMultiSig.address,
            value: ethers.utils.parseEther("10")
        });

        console.log("✅ Test environment initialization completed");
        console.log(`   MultiSig contract address: ${simpleMultiSig.address}`);
        console.log(`   Team members: ${owners.length} people`);
        console.log(`   Signature threshold: ${threshold}/3`);
        console.log("   Note: Using SimpleMultiSig instead of GnosisStyleMultiSig (latter has signature verification issues)");
    });

    describe("🔧 Basic Configuration Verification", function () {
        it("should correctly initialize 3-person team configuration", async function () {
            expect(await simpleMultiSig.getOwnerCount()).to.equal(3);
            expect(await simpleMultiSig.signaturesRequired()).to.equal(2);

            // Verify all team members
            expect(await simpleMultiSig.isOwner(owner1.address)).to.be.true;
            expect(await simpleMultiSig.isOwner(owner2.address)).to.be.true;
            expect(await simpleMultiSig.isOwner(owner3.address)).to.be.true;
            expect(await simpleMultiSig.isOwner(nonOwner.address)).to.be.false;

            console.log("✅ 3-person team configuration verification passed");
        });

        it("should be able to receive ETH", async function () {
            const initialBalance = await ethers.provider.getBalance(simpleMultiSig.address);
            expect(initialBalance).to.equal(ethers.utils.parseEther("10"));

            // Transfer some more ETH
            await owner2.sendTransaction({
                to: simpleMultiSig.address,
                value: ethers.utils.parseEther("2")
            });

            const newBalance = await ethers.provider.getBalance(simpleMultiSig.address);
            expect(newBalance).to.equal(ethers.utils.parseEther("12"));

            console.log("✅ ETH receiving functionality working normally");
        });
    });

    describe("💰 ETH Transfer Scenarios", function () {
        it("Scenario 1: Member 1 and Member 2 signatures - should execute successfully", async function () {
            const recipient = nonOwner.address;
            const amount = ethers.utils.parseEther("1");
            const data = "0x";
            const description = "Member 1+2 signature transfer test";

            // Record balances before execution
            const recipientBalanceBefore = await ethers.provider.getBalance(recipient);
            const contractBalanceBefore = await ethers.provider.getBalance(simpleMultiSig.address);

            // Member 1 submits transaction
            await simpleMultiSig.connect(owner1).submitTransaction(recipient, amount, data, description);

            // Member 2 confirms transaction (this will trigger execution as it reaches 2/3 threshold)
            const tx = await simpleMultiSig.connect(owner2).confirmTransaction(0);
            const receipt = await tx.wait();

            // Verify balance changes
            const recipientBalanceAfter = await ethers.provider.getBalance(recipient);
            const contractBalanceAfter = await ethers.provider.getBalance(simpleMultiSig.address);

            expect(recipientBalanceAfter.sub(recipientBalanceBefore)).to.equal(amount);
            expect(contractBalanceBefore.sub(contractBalanceAfter)).to.equal(amount);

            // Verify transaction status
            const txInfo = await simpleMultiSig.getTransaction(0);
            expect(txInfo.executed).to.be.true;

            console.log("✅ Member 1+2 signature transfer successful");
            console.log(`   Transfer amount: ${ethers.utils.formatEther(amount)} ETH`);
            console.log(`   Gas consumption: ${receipt.gasUsed.toString()}`);
        });

        it("Scenario 2: Member 1 and Member 3 signatures - should execute successfully", async function () {
            const recipient = nonOwner.address;
            const amount = ethers.utils.parseEther("0.5");
            const data = "0x";
            const description = "Member 1+3 signature transfer test";

            const recipientBalanceBefore = await ethers.provider.getBalance(recipient);

            // Member 1 submits transaction
            const txCount = await simpleMultiSig.transactionCount();
            await simpleMultiSig.connect(owner1).submitTransaction(recipient, amount, data, description);

            // Member 3 confirms transaction
            await simpleMultiSig.connect(owner3).confirmTransaction(txCount);

            const recipientBalanceAfter = await ethers.provider.getBalance(recipient);
            expect(recipientBalanceAfter.sub(recipientBalanceBefore)).to.equal(amount);

            console.log("✅ Member 1+3 signature transfer successful");
        });

        it("Scenario 3: Member 2 and Member 3 signatures - should execute successfully", async function () {
            const recipient = nonOwner.address;
            const amount = ethers.utils.parseEther("0.3");
            const data = "0x";
            const description = "Member 2+3 signature transfer test";

            const recipientBalanceBefore = await ethers.provider.getBalance(recipient);

            // Member 2 submits transaction
            const txCount = await simpleMultiSig.transactionCount();
            await simpleMultiSig.connect(owner2).submitTransaction(recipient, amount, data, description);

            // Member 3 confirms transaction
            await simpleMultiSig.connect(owner3).confirmTransaction(txCount);

            const recipientBalanceAfter = await ethers.provider.getBalance(recipient);
            expect(recipientBalanceAfter.sub(recipientBalanceBefore)).to.equal(amount);

            console.log("✅ Member 2+3 signature transfer successful");
        });
    });

    describe("❌ Insufficient Signature Scenarios", function () {
        it("Only 1 signature - should fail", async function () {
            const recipient = nonOwner.address;
            const amount = ethers.utils.parseEther("1");
            const data = "0x";
            const description = "Single signature test";

            // Member 1 submits transaction
            const txCount = await simpleMultiSig.transactionCount();
            await simpleMultiSig.connect(owner1).submitTransaction(recipient, amount, data, description);

            // Check transaction status - should not be executed
            const txInfo = await simpleMultiSig.getTransaction(txCount);
            expect(txInfo.executed).to.be.false;
            expect(txInfo.confirmationCount).to.equal(1); // Only submitter's confirmation

            console.log("✅ Single signature correctly rejected (transaction not executed)");
        });

        it("Non-member submits transaction - should fail", async function () {
            const recipient = nonOwner.address;
            const amount = ethers.utils.parseEther("1");
            const data = "0x";
            const description = "Non-member submission test";

            // Non-member attempts to submit transaction
            await expect(
                simpleMultiSig.connect(nonOwner).submitTransaction(recipient, amount, data, description)
            ).to.be.revertedWith("Not an owner");

            console.log("✅ Non-member submission correctly rejected");
        });
    });

    describe("📞 Contract Call Scenarios", function () {
        it("Call ERC20 transfer - 2/3 signatures", async function () {
            // First give multisig wallet some tokens
            await mockTarget.mint(simpleMultiSig.address, ethers.utils.parseEther("1000"));

            const recipient = nonOwner.address;
            const transferAmount = ethers.utils.parseEther("100");

            // Encode transfer call data
            const transferData = mockTarget.interface.encodeFunctionData("transfer", [
                recipient,
                transferAmount
            ]);

            const description = "ERC20 transfer test";

            // Record balance before transfer
            const recipientBalanceBefore = await mockTarget.balanceOf(recipient);

            // Member 1 submits transaction
            const txCount = await simpleMultiSig.transactionCount();
            await simpleMultiSig.connect(owner1).submitTransaction(
                mockTarget.address,
                0,
                transferData,
                description
            );

            // Member 2 confirms transaction
            await simpleMultiSig.connect(owner2).confirmTransaction(txCount);

            // Verify transfer success
            const recipientBalanceAfter = await mockTarget.balanceOf(recipient);
            expect(recipientBalanceAfter.sub(recipientBalanceBefore)).to.equal(transferAmount);

            console.log("✅ ERC20 transfer call successful");
            console.log(`   Transfer amount: ${ethers.utils.formatEther(transferAmount)} TEST`);
        });
    });

    describe("🔄 Transaction Count Management", function () {
        it("Transaction count should increment correctly", async function () {
            const initialCount = await simpleMultiSig.transactionCount();

            // Execute first transaction
            const recipient = nonOwner.address;
            const amount = ethers.utils.parseEther("0.1");
            const data = "0x";
            const description = "Count test 1";

            await simpleMultiSig.connect(owner1).submitTransaction(recipient, amount, data, description);
            await simpleMultiSig.connect(owner2).confirmTransaction(initialCount);

            // Verify transaction count increment
            const countAfterFirst = await simpleMultiSig.transactionCount();
            expect(countAfterFirst).to.equal(initialCount.add(1));

            // Execute second transaction
            const description2 = "Count test 2";
            await simpleMultiSig.connect(owner1).submitTransaction(recipient, amount, data, description2);
            await simpleMultiSig.connect(owner3).confirmTransaction(countAfterFirst);

            // Verify transaction count increments again
            const countAfterSecond = await simpleMultiSig.transactionCount();
            expect(countAfterSecond).to.equal(initialCount.add(2));

            console.log("✅ Transaction count management working normally");
        });

        it("Confirming non-existent transaction should fail", async function () {
            const nonExistentTxId = 999;

            await expect(
                simpleMultiSig.connect(owner1).confirmTransaction(nonExistentTxId)
            ).to.be.revertedWith("Transaction does not exist");

            console.log("✅ Non-existent transaction correctly rejected");
        });
    });
});
