const { ethers } = require("hardhat");

/**
 * GnosisStyleMultiSig 助手工具
 * 专为3人团队2/3签名方案设计
 */
class GnosisMultiSigHelper {
    constructor(contractAddress, signers) {
        this.contractAddress = contractAddress;
        this.signers = signers; // [signer1, signer2, signer3]
        this.contract = null;
    }
    
    async init() {
        const GnosisStyleMultiSig = await ethers.getContractFactory("GnosisStyleMultiSig");
        this.contract = GnosisStyleMultiSig.attach(this.contractAddress);
        console.log("✅ 多签合约已连接:", this.contractAddress);
    }
    
    /**
     * 生成交易哈希
     */
    async generateTransactionHash(to, value, data) {
        const nonce = await this.contract.nonce();
        const txHash = await this.contract.getTransactionHash(to, value, data, nonce);
        
        console.log("📝 交易信息:");
        console.log("- 目标地址:", to);
        console.log("- 转账金额:", ethers.utils.formatEther(value), "ETH");
        console.log("- 调用数据:", data);
        console.log("- 当前nonce:", nonce.toString());
        console.log("- 交易哈希:", txHash);
        
        return { txHash, nonce };
    }
    
    /**
     * 收集团队签名 (需要至少2个签名)
     */
    async collectSignatures(txHash, signerIndices = [0, 1]) {
        console.log("\n🖊️  开始收集签名...");
        const signatures = [];
        const signerAddresses = [];
        
        for (const index of signerIndices) {
            if (index >= this.signers.length) {
                throw new Error(`签名者索引 ${index} 超出范围`);
            }
            
            const signer = this.signers[index];
            const address = await signer.getAddress();
            
            console.log(`正在获取签名者 ${index + 1} (${address}) 的签名...`);
            
            // 使用 EIP-191 标准签名
            const signature = await signer.signMessage(ethers.utils.arrayify(txHash));
            signatures.push(signature);
            signerAddresses.push(address);
            
            console.log(`✓ 签名者 ${index + 1} 签名完成`);
        }
        
        // 按地址排序签名 (Gnosis Safe 要求)
        const sortedSignatures = this.sortSignaturesByAddress(signatures, signerAddresses);
        const concatenatedSignatures = this.concatenateSignatures(sortedSignatures);
        
        console.log("✅ 签名收集完成!");
        console.log("- 签名数量:", signatures.length);
        console.log("- 合并签名:", concatenatedSignatures);
        
        return concatenatedSignatures;
    }
    
    /**
     * 按地址排序签名
     */
    sortSignaturesByAddress(signatures, addresses) {
        const combined = signatures.map((sig, index) => ({
            signature: sig,
            address: addresses[index]
        }));
        
        // 按地址排序
        combined.sort((a, b) => a.address.toLowerCase().localeCompare(b.address.toLowerCase()));
        
        return combined.map(item => item.signature);
    }
    
    /**
     * 合并签名
     */
    concatenateSignatures(signatures) {
        return signatures.reduce((acc, sig) => acc + sig.slice(2), "0x");
    }
    
    /**
     * 执行交易
     */
    async executeTransaction(to, value, data, signatures) {
        console.log("\n🚀 执行交易...");
        
        try {
            // 验证签名
            const txHash = await this.generateTransactionHash(to, value, data);
            const isValid = await this.contract.checkSignatures(txHash.txHash, signatures);
            
            if (!isValid) {
                throw new Error("签名验证失败");
            }
            
            console.log("✓ 签名验证通过");
            
            // 执行交易
            const tx = await this.contract.execTransaction(to, value, data, signatures);
            console.log("交易已提交，等待确认...");
            console.log("交易哈希:", tx.hash);
            
            const receipt = await tx.wait();
            console.log("✅ 交易执行成功!");
            console.log("- Gas 使用:", receipt.gasUsed.toString());
            console.log("- 区块号:", receipt.blockNumber);
            
            return receipt;
            
        } catch (error) {
            console.error("❌ 交易执行失败:", error.message);
            throw error;
        }
    }
    
    /**
     * 转账 ETH
     */
    async transferETH(to, amount, signerIndices = [0, 1]) {
        console.log("\n💰 执行 ETH 转账");
        console.log("=".repeat(40));
        
        const value = ethers.utils.parseEther(amount.toString());
        const data = "0x";
        
        // 生成交易哈希
        const { txHash } = await this.generateTransactionHash(to, value, data);
        
        // 收集签名
        const signatures = await this.collectSignatures(txHash, signerIndices);
        
        // 执行交易
        return await this.executeTransaction(to, value, data, signatures);
    }
    
    /**
     * 调用合约函数
     */
    async callContract(targetContract, functionName, params, signerIndices = [0, 1]) {
        console.log("\n📞 调用合约函数");
        console.log("=".repeat(40));
        
        const value = 0;
        const data = targetContract.interface.encodeFunctionData(functionName, params);
        
        console.log("- 目标合约:", targetContract.address);
        console.log("- 函数名称:", functionName);
        console.log("- 参数:", params);
        
        // 生成交易哈希
        const { txHash } = await this.generateTransactionHash(targetContract.address, value, data);
        
        // 收集签名
        const signatures = await this.collectSignatures(txHash, signerIndices);
        
        // 执行交易
        return await this.executeTransaction(targetContract.address, value, data, signatures);
    }
    
    /**
     * 添加新的团队成员
     */
    async addTeamMember(newMemberAddress, newThreshold, signerIndices = [0, 1]) {
        console.log("\n👥 添加新团队成员");
        console.log("=".repeat(40));
        
        const data = this.contract.interface.encodeFunctionData("addOwnerWithThreshold", [
            newMemberAddress,
            newThreshold
        ]);
        
        console.log("- 新成员地址:", newMemberAddress);
        console.log("- 新签名阈值:", newThreshold);
        
        return await this.executeTransaction(this.contractAddress, 0, data, 
            await this.collectSignatures(
                (await this.generateTransactionHash(this.contractAddress, 0, data)).txHash,
                signerIndices
            )
        );
    }
    
    /**
     * 获取合约状态
     */
    async getStatus() {
        console.log("\n📊 多签钱包状态");
        console.log("=".repeat(40));
        
        const owners = await this.contract.getOwners();
        const threshold = await this.contract.threshold();
        const nonce = await this.contract.nonce();
        const balance = await ethers.provider.getBalance(this.contractAddress);
        
        console.log("- 合约地址:", this.contractAddress);
        console.log("- 所有者数量:", owners.length);
        console.log("- 签名阈值:", threshold.toString());
        console.log("- 当前nonce:", nonce.toString());
        console.log("- ETH余额:", ethers.utils.formatEther(balance), "ETH");
        
        console.log("\n👥 所有者列表:");
        owners.forEach((owner, index) => {
            console.log(`  ${index + 1}. ${owner}`);
        });
        
        return {
            owners,
            threshold: threshold.toNumber(),
            nonce: nonce.toNumber(),
            balance: ethers.utils.formatEther(balance)
        };
    }
}

/**
 * 使用示例
 */
async function example() {
    console.log("🎯 GnosisStyleMultiSig 使用示例");
    console.log("=".repeat(50));
    
    // 假设的合约地址和签名者
    const contractAddress = "0x你的合约地址";
    const [signer1, signer2, signer3] = await ethers.getSigners();
    
    // 创建助手实例
    const helper = new GnosisMultiSigHelper(contractAddress, [signer1, signer2, signer3]);
    await helper.init();
    
    // 查看状态
    await helper.getStatus();
    
    // 示例1: 转账 ETH
    // await helper.transferETH("0x接收地址", "1.0", [0, 1]); // 使用签名者1和2
    
    // 示例2: 调用合约函数
    // const targetContract = await ethers.getContractAt("ERC20", "0x代币地址");
    // await helper.callContract(targetContract, "transfer", ["0x接收地址", "1000"], [0, 2]); // 使用签名者1和3
    
    console.log("\n✅ 示例完成!");
}

module.exports = {
    GnosisMultiSigHelper,
    example
};

// 如果直接运行此脚本
if (require.main === module) {
    example()
        .then(() => process.exit(0))
        .catch((error) => {
            console.error(error);
            process.exit(1);
        });
}