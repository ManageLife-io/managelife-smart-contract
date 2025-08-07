const { ethers } = require("hardhat");

async function main() {
    console.log("开始部署多签钱包...");
    
    // 获取部署账户
    const [deployer] = await ethers.getSigners();
    console.log("部署账户:", deployer.address);
    console.log("账户余额:", ethers.utils.formatEther(await deployer.getBalance()));
    
    // 配置多签参数
    const owners = [
        "0x1234567890123456789012345678901234567890", // 张三的钱包地址
        "0x2345678901234567890123456789012345678901", // 李四的钱包地址
        "0x3456789012345678901234567890123456789012"  // 王五的钱包地址
    ];
    
    const signaturesRequired = 2; // 3个人中需要2个人签名
    
    console.log("多签配置:");
    console.log("- 所有者数量:", owners.length);
    console.log("- 需要签名数:", signaturesRequired);
    console.log("- 所有者地址:", owners);
    
    // 部署简单多签合约
    console.log("\n部署 SimpleMultiSig 合约...");
    const SimpleMultiSig = await ethers.getContractFactory("SimpleMultiSig");
    const simpleMultiSig = await SimpleMultiSig.deploy(owners, signaturesRequired);
    await simpleMultiSig.deployed();
    
    console.log("SimpleMultiSig 部署成功!");
    console.log("合约地址:", simpleMultiSig.address);
    
    // 验证部署
    console.log("\n验证部署结果...");
    const deployedOwners = await simpleMultiSig.getOwners();
    const deployedThreshold = await simpleMultiSig.signaturesRequired();
    
    console.log("部署的所有者:", deployedOwners);
    console.log("部署的签名阈值:", deployedThreshold.toString());
    
    // 部署 Gnosis 风格多签合约
    console.log("\n部署 GnosisStyleMultiSig 合约...");
    const GnosisStyleMultiSig = await ethers.getContractFactory("GnosisStyleMultiSig");
    const gnosisMultiSig = await GnosisStyleMultiSig.deploy(owners, signaturesRequired);
    await gnosisMultiSig.deployed();
    
    console.log("GnosisStyleMultiSig 部署成功!");
    console.log("合约地址:", gnosisMultiSig.address);
    
    // 验证 Gnosis 风格合约
    const gnosisOwners = await gnosisMultiSig.getOwners();
    const gnosisThreshold = await gnosisMultiSig.threshold();
    
    console.log("Gnosis 风格合约所有者:", gnosisOwners);
    console.log("Gnosis 风格合约签名阈值:", gnosisThreshold.toString());
    
    // 保存部署信息
    const deploymentInfo = {
        network: await ethers.provider.getNetwork(),
        deployer: deployer.address,
        contracts: {
            SimpleMultiSig: {
                address: simpleMultiSig.address,
                owners: deployedOwners,
                threshold: deployedThreshold.toString()
            },
            GnosisStyleMultiSig: {
                address: gnosisMultiSig.address,
                owners: gnosisOwners,
                threshold: gnosisThreshold.toString()
            }
        },
        timestamp: new Date().toISOString()
    };
    
    console.log("\n=== 部署完成 ===");
    console.log("部署信息:", JSON.stringify(deploymentInfo, null, 2));
    
    // 使用说明
    console.log("\n=== 使用说明 ===");
    console.log("1. SimpleMultiSig 使用方法:");
    console.log("   - 提交交易: submitTransaction(to, value, data, description)");
    console.log("   - 确认交易: confirmTransaction(transactionId)");
    console.log("   - 撤销确认: revokeConfirmation(transactionId)");
    console.log("   - 达到签名阈值后自动执行，无需等待时间锁");
    
    console.log("\n2. GnosisStyleMultiSig 使用方法:");
    console.log("   - 需要离线签名，然后调用 execTransaction()");
    console.log("   - 更接近真实的 Gnosis Safe 体验");
    
    console.log("\n3. 关键特性:");
    console.log("   - ✅ 无时间锁延迟");
    console.log("   - ✅ 签够人数立即执行");
    console.log("   - ✅ 支持硬件钱包签名");
    console.log("   - ✅ 完全去中心化");
    
    return deploymentInfo;
}

// 错误处理
main()
    .then((info) => {
        console.log("\n部署脚本执行成功!");
        process.exit(0);
    })
    .catch((error) => {
        console.error("部署失败:", error);
        process.exit(1);
    });