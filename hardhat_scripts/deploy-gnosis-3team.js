const { ethers } = require("hardhat");

async function main() {
    console.log("🚀 部署 GnosisStyleMultiSig - 3人团队 2/3 签名方案");
    console.log("=" .repeat(60));
    
    // 获取部署账户
    const [deployer] = await ethers.getSigners();
    console.log("部署账户:", deployer.address);
    console.log("账户余额:", ethers.utils.formatEther(await deployer.getBalance()), "ETH");
    
    // 3人团队配置 - 请替换为实际的钱包地址
    const teamConfig = {
        owners: [
            "0x1234567890123456789012345678901234567890", // 团队成员1 - 张三
            "0x2345678901234567890123456789012345678901", // 团队成员2 - 李四  
            "0x3456789012345678901234567890123456789012"  // 团队成员3 - 王五
        ],
        threshold: 2, // 3个人中需要2个签名
        teamNames: ["张三", "李四", "王五"]
    };
    
    console.log("\n📋 团队配置:");
    console.log("- 团队规模: 3人");
    console.log("- 签名阈值: 2/3 (需要2个人签名)");
    console.log("- 安全级别: 高 (67%同意率)");
    
    console.log("\n👥 团队成员:");
    teamConfig.owners.forEach((address, index) => {
        console.log(`  ${index + 1}. ${teamConfig.teamNames[index]}: ${address}`);
    });
    
    // 部署 GnosisStyleMultiSig 合约
    console.log("\n🔨 开始部署 GnosisStyleMultiSig 合约...");
    const GnosisStyleMultiSig = await ethers.getContractFactory("GnosisStyleMultiSig");
    
    console.log("正在部署合约...");
    const multiSig = await GnosisStyleMultiSig.deploy(teamConfig.owners, teamConfig.threshold);
    
    console.log("等待合约确认...");
    await multiSig.deployed();
    
    console.log("✅ 合约部署成功!");
    console.log("合约地址:", multiSig.address);
    
    // 验证部署结果
    console.log("\n🔍 验证部署结果...");
    const deployedOwners = await multiSig.getOwners();
    const deployedThreshold = await multiSig.threshold();
    const ownerCount = await multiSig.getOwnerCount();
    
    console.log("✓ 所有者数量:", ownerCount.toString());
    console.log("✓ 签名阈值:", deployedThreshold.toString());
    console.log("✓ 所有者地址验证:");
    deployedOwners.forEach((address, index) => {
        const isMatch = address.toLowerCase() === teamConfig.owners[index].toLowerCase();
        console.log(`  ${index + 1}. ${teamConfig.teamNames[index]}: ${address} ${isMatch ? '✓' : '✗'}`);
    });
    
    // 获取网络信息
    const network = await ethers.provider.getNetwork();
    const blockNumber = await ethers.provider.getBlockNumber();
    
    // 生成部署报告
    const deploymentReport = {
        contractInfo: {
            name: "GnosisStyleMultiSig",
            address: multiSig.address,
            deployer: deployer.address,
            network: {
                name: network.name,
                chainId: network.chainId,
                blockNumber: blockNumber
            }
        },
        teamConfig: {
            owners: teamConfig.owners,
            ownerNames: teamConfig.teamNames,
            threshold: teamConfig.threshold,
            securityLevel: "高 (2/3 = 67%)"
        },
        deployment: {
            timestamp: new Date().toISOString(),
            gasUsed: "待确认",
            status: "成功"
        }
    };
    
    console.log("\n📊 部署报告:");
    console.log(JSON.stringify(deploymentReport, null, 2));
    
    // 使用指南
    console.log("\n" + "=".repeat(60));
    console.log("🎯 GnosisStyleMultiSig 使用指南 (3人团队 2/3签名)");
    console.log("=".repeat(60));
    
    console.log("\n📝 核心特性:");
    console.log("✅ 无时间锁延迟 - 签够2个人立即执行");
    console.log("✅ 硬件钱包支持 - 兼容 Ledger、Trezor");
    console.log("✅ EIP-712 标准 - 安全的离线签名");
    console.log("✅ Gas 优化 - 批量签名验证");
    
    console.log("\n🔄 日常使用流程:");
    console.log("1️⃣  生成交易哈希");
    console.log("2️⃣  团队成员离线签名 (需要2个签名)");
    console.log("3️⃣  提交签名并立即执行");
    
    console.log("\n💡 代码示例:");
    console.log(`
// 1. 生成交易哈希
const txHash = await multiSig.getTransactionHash(
    "0x目标地址",
    ethers.utils.parseEther("1"), // 1 ETH
    "0x", // 转账数据为空
    await multiSig.nonce()
);

// 2. 团队成员签名 (至少2个)
const signature1 = await 张三.signMessage(ethers.utils.arrayify(txHash));
const signature2 = await 李四.signMessage(ethers.utils.arrayify(txHash));

// 3. 合并签名并执行 (按地址排序)
const signatures = signature1 + signature2.slice(2);
await multiSig.execTransaction(
    "0x目标地址",
    ethers.utils.parseEther("1"),
    "0x",
    signatures
);
    `);
    
    console.log("\n🔐 硬件钱包集成:");
    console.log("- Ledger: 使用 @ledgerhq/hw-app-eth");
    console.log("- Trezor: 使用 trezor-connect");
    console.log("- MetaMask: 直接支持 EIP-712 签名");
    
    console.log("\n⚠️  重要提醒:");
    console.log("1. 请将示例地址替换为实际的团队成员地址");
    console.log("2. 建议先用小额测试交易验证流程");
    console.log("3. 确保所有成员都配置好硬件钱包");
    console.log("4. 保存好合约地址和部署信息");
    
    console.log("\n🛡️  安全建议:");
    console.log("- 使用硬件钱包存储私钥");
    console.log("- 定期轮换团队成员地址");
    console.log("- 建立应急联系机制");
    console.log("- 制定私钥丢失处理预案");
    
    console.log("\n📞 技术支持:");
    console.log("- 合约源码: contracts/governance/GnosisStyleMultiSig.sol");
    console.log("- 测试文件: tests/MultiSig.test.js");
    console.log("- 使用文档: docs/MultiSig-Usage-Guide.md");
    
    console.log("\n🎉 部署完成! 合约地址:", multiSig.address);
    
    return {
        contractAddress: multiSig.address,
        deploymentReport: deploymentReport
    };
}

// 错误处理
main()
    .then((result) => {
        console.log("\n✅ 部署脚本执行成功!");
        console.log("合约地址:", result.contractAddress);
        process.exit(0);
    })
    .catch((error) => {
        console.error("\n❌ 部署失败:", error);
        process.exit(1);
    });