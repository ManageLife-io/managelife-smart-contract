const { execSync } = require('child_process');
const path = require('path');

/**
 * Test runner script for all contract tests
 * This script runs all test files and provides a summary
 */

const testFiles = [
  'LifeToken.test.js',
  'NFT.test.js',
  'PropertyMarket.test.js',
  'Rewards.test.js',
  'AdminControl.test.js',
  'storage.test.js',
  'Ballot_test.sol'
];

const colors = {
  reset: '\x1b[0m',
  bright: '\x1b[1m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
  cyan: '\x1b[36m'
};

function log(message, color = 'reset') {
  console.log(`${colors[color]}${message}${colors.reset}`);
}

function runTest(testFile) {
  try {
    log(`\n${'='.repeat(60)}`, 'cyan');
    log(`Running tests for: ${testFile}`, 'bright');
    log(`${'='.repeat(60)}`, 'cyan');
    
    const command = testFile.endsWith('.sol') 
      ? `npx hardhat test tests/${testFile}`
      : `npx hardhat test tests/${testFile}`;
    
    const output = execSync(command, { 
      encoding: 'utf8',
      cwd: path.resolve(__dirname, '..')
    });
    
    log(output, 'green');
    log(`✅ ${testFile} - PASSED`, 'green');
    return { file: testFile, status: 'PASSED', error: null };
    
  } catch (error) {
    log(`❌ ${testFile} - FAILED`, 'red');
    log(`Error: ${error.message}`, 'red');
    return { file: testFile, status: 'FAILED', error: error.message };
  }
}

function runAllTests() {
  log('🚀 Starting comprehensive test suite...', 'bright');
  log(`Testing ${testFiles.length} test files\n`, 'blue');
  
  const results = [];
  
  for (const testFile of testFiles) {
    const result = runTest(testFile);
    results.push(result);
  }
  
  // Summary
  log('\n' + '='.repeat(80), 'magenta');
  log('TEST SUMMARY', 'bright');
  log('='.repeat(80), 'magenta');
  
  const passed = results.filter(r => r.status === 'PASSED').length;
  const failed = results.filter(r => r.status === 'FAILED').length;
  
  log(`\nTotal Tests: ${results.length}`, 'blue');
  log(`Passed: ${passed}`, 'green');
  log(`Failed: ${failed}`, failed > 0 ? 'red' : 'green');
  
  if (failed > 0) {
    log('\nFailed Tests:', 'red');
    results.filter(r => r.status === 'FAILED').forEach(result => {
      log(`  ❌ ${result.file}`, 'red');
    });
  }
  
  log('\nTest Coverage Areas:', 'blue');
  log('  📊 LifeToken - Rebase functionality, transfers, admin controls', 'cyan');
  log('  🎨 NFT Contracts - Minting, transfers, approvals, burning', 'cyan');
  log('  🏠 PropertyMarket - Listing, buying, bidding, delisting', 'cyan');
  log('  🎁 Rewards System - Staking, reward distribution, multi-token', 'cyan');
  log('  🔐 AdminControl - Role management, pausing, emergency functions', 'cyan');
  log('  📦 Basic Contracts - Storage and Ballot functionality', 'cyan');
  
  if (failed === 0) {
    log('\n🎉 All tests passed! Your contracts are ready for deployment.', 'green');
  } else {
    log('\n⚠️  Some tests failed. Please review and fix the issues before deployment.', 'yellow');
  }
  
  log('\n' + '='.repeat(80), 'magenta');
  
  return failed === 0;
}

// Run specific test if provided as argument
if (process.argv[2]) {
  const testFile = process.argv[2];
  if (testFiles.includes(testFile)) {
    runTest(testFile);
  } else {
    log(`Test file "${testFile}" not found.`, 'red');
    log('Available test files:', 'blue');
    testFiles.forEach(file => log(`  - ${file}`, 'cyan'));
  }
} else {
  // Run all tests
  const success = runAllTests();
  process.exit(success ? 0 : 1);
}

module.exports = { runAllTests, runTest };