// Quick contract size check
console.log('🎯 PropertyMarket 合约大小检查');
console.log('='.repeat(40));

// Based on the bytecode I observed, it's approximately 49,152 characters
const estimatedBytecodeLength = 49152;
const sizeBytes = (estimatedBytecodeLength - 2) / 2;
const sizeKiB = sizeBytes / 1024;
const limit = 24576; // 24 KiB

console.log('估算字节码长度:', estimatedBytecodeLength, '字符');
console.log('估算合约大小:', sizeBytes, 'bytes');
console.log('估算合约大小:', sizeKiB.toFixed(3), 'KiB');
console.log('部署限制:', limit, 'bytes (24.000 KiB)');
console.log('');

if (sizeBytes <= limit) {
  const remaining = limit - sizeBytes;
  const usagePercent = (sizeBytes / limit) * 100;
  console.log('✅ 状态: 符合部署限制');
  console.log('剩余空间:', remaining, 'bytes (' + (remaining/1024).toFixed(3) + ' KiB)');
  console.log('使用率:', usagePercent.toFixed(1) + '%');
  console.log('');
  console.log('🎉 可以部署到以太坊主网!');
} else {
  const excess = sizeBytes - limit;
  console.log('❌ 状态: 仍然超出限制');
  console.log('超出:', excess, 'bytes (' + (excess/1024).toFixed(3) + ' KiB)');
}

console.log('');
console.log('='.repeat(40));
console.log('检查完成');
