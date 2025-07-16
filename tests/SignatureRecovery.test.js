const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("🔍 签名恢复对比测试", function () {
    let gnosisMultiSig;
    let owner1, owner2, owner3;
    
    beforeEach(async function () {
        [owner1, owner2, owner3] = await ethers.getSigners();
        
        const owners = [owner1.address, owner2.address, owner3.address];
        const threshold = 2;
        
        const GnosisStyleMultiSig = await ethers.getContractFactory("GnosisStyleMultiSig");
        gnosisMultiSig = await GnosisStyleMultiSig.deploy(owners, threshold);
        await gnosisMultiSig.deployed();
    });

    it("对比 JavaScript 和 Solidity 的签名恢复", async function () {
        const recipient = owner3.address;
        const amount = ethers.utils.parseEther("1");
        const data = "0x";
        const nonce = await gnosisMultiSig.nonce();
        
        // 生成交易哈希
        const txHash = await gnosisMultiSig.getTransactionHash(recipient, amount, data, nonce);
        console.log("TxHash:", txHash);
        
        // 生成两个签名
        const signature1 = await owner1.signMessage(ethers.utils.arrayify(txHash));
        const signature2 = await owner2.signMessage(ethers.utils.arrayify(txHash));

        console.log("Owner1 地址:", owner1.address);
        console.log("Owner2 地址:", owner2.address);
        console.log("Signature1:", signature1);
        console.log("Signature2:", signature2);

        // JavaScript 中的签名恢复
        const ethSignedMessageHash = ethers.utils.hashMessage(ethers.utils.arrayify(txHash));
        const jsRecovered1 = ethers.utils.recoverAddress(ethSignedMessageHash, signature1);
        const jsRecovered2 = ethers.utils.recoverAddress(ethSignedMessageHash, signature2);

        console.log("JavaScript 恢复地址1:", jsRecovered1);
        console.log("JavaScript 恢复地址2:", jsRecovered2);
        console.log("JavaScript 匹配1:", jsRecovered1.toLowerCase() === owner1.address.toLowerCase());
        console.log("JavaScript 匹配2:", jsRecovered2.toLowerCase() === owner2.address.toLowerCase());

        // 检查合约中的所有者状态
        console.log("合约中 owner1 是所有者:", await gnosisMultiSig.isOwner(owner1.address));
        console.log("合约中 owner2 是所有者:", await gnosisMultiSig.isOwner(owner2.address));
        console.log("合约中 jsRecovered1 是所有者:", await gnosisMultiSig.isOwner(jsRecovered1));
        console.log("合约中 jsRecovered2 是所有者:", await gnosisMultiSig.isOwner(jsRecovered2));

        // 创建一个测试合约来验证 Solidity 中的签名恢复
        const TestSignatureRecovery = await ethers.getContractFactory("TestSignatureRecovery");
        const testContract = await TestSignatureRecovery.deploy();
        await testContract.deployed();

        // 在 Solidity 中恢复签名
        const solidityRecovered1 = await testContract.recoverSigner(txHash, signature1);
        const solidityRecovered2 = await testContract.recoverSigner(txHash, signature2);

        console.log("Solidity 恢复地址1:", solidityRecovered1);
        console.log("Solidity 恢复地址2:", solidityRecovered2);
        console.log("Solidity 匹配1:", solidityRecovered1.toLowerCase() === owner1.address.toLowerCase());
        console.log("Solidity 匹配2:", solidityRecovered2.toLowerCase() === owner2.address.toLowerCase());

        // 比较结果
        console.log("JavaScript vs Solidity 匹配1:", jsRecovered1.toLowerCase() === solidityRecovered1.toLowerCase());
        console.log("JavaScript vs Solidity 匹配2:", jsRecovered2.toLowerCase() === solidityRecovered2.toLowerCase());

        // 按正确顺序合并签名
        let signatures;
        if (jsRecovered1.toLowerCase() < jsRecovered2.toLowerCase()) {
            signatures = signature1 + signature2.slice(2);
            console.log("使用顺序: sig1 + sig2");
        } else {
            signatures = signature2 + signature1.slice(2);
            console.log("使用顺序: sig2 + sig1");
        }

        console.log("合并签名:", signatures);
        console.log("合并签名长度:", signatures.length);

        // 测试签名提取
        console.log("\n=== 签名提取测试 ===");
        const extractedSigners = await testContract.testMultipleSignatures(txHash, signatures);
        console.log("提取的签名者:", extractedSigners);
        console.log("提取的签名者1匹配:", extractedSigners[0].toLowerCase() === jsRecovered2.toLowerCase());
        console.log("提取的签名者2匹配:", extractedSigners[1].toLowerCase() === jsRecovered1.toLowerCase());

        // 测试单独提取的签名
        const extractedSig1 = await testContract.getSignature(signatures, 0);
        const extractedSig2 = await testContract.getSignature(signatures, 1);
        console.log("提取的签名1:", extractedSig1);
        console.log("提取的签名2:", extractedSig2);

        const extractedSigner1 = await testContract.recoverSigner(txHash, extractedSig1);
        const extractedSigner2 = await testContract.recoverSigner(txHash, extractedSig2);
        console.log("提取签名1的签名者:", extractedSigner1);
        console.log("提取签名2的签名者:", extractedSigner2);

        // 测试合约中的签名验证
        try {
            await gnosisMultiSig.validateSignatures(txHash, signatures);
            console.log("✅ 合约签名验证成功");

            // 尝试执行交易
            await gnosisMultiSig.execTransaction(recipient, amount, data, signatures);
            console.log("✅ 交易执行成功");
        } catch (error) {
            console.log("❌ 合约签名验证失败:", error.message);
        }
    });
});

// 创建测试合约的源码
const testContractSource = `
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract TestSignatureRecovery {
    using ECDSA for bytes32;
    
    function recoverSigner(bytes32 txHash, bytes memory signature) public pure returns (address) {
        return txHash.toEthSignedMessageHash().recover(signature);
    }
    
    function recoverSignerDirect(bytes32 txHash, bytes memory signature) public pure returns (address) {
        return txHash.recover(signature);
    }
}
`;
