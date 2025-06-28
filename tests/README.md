# MLife Smart Contracts Test Suite

This directory contains comprehensive test cases for all MLife smart contracts. The test suite covers core functionality, edge cases, and integration scenarios.

## Test Files Overview

### 1. LifeToken.test.js
Tests for the LifeToken contract including:
- **Deployment**: Owner setup, initial supply verification
- **Initial Distribution**: Token distribution to addresses, access controls
- **Rebase Functionality**: Supply adjustments, timing restrictions, balance updates
- **Transfer Operations**: Standard ERC20 transfers, balance validations
- **Admin Functions**: Operator management, exclusion lists
- **View Functions**: Balance queries, supply calculations

### 2. NFT.test.js
Tests for both NFTi (Investment) and NFTm (Membership) contracts:
- **Deployment**: Contract initialization, admin control setup
- **Minting**: Authorized minting, access restrictions, metadata handling
- **Transfer Operations**: Ownership transfers, approval mechanisms
- **Burning**: Token destruction, authorization checks
- **Batch Operations**: Multiple token operations
- **ERC721 Compliance**: Interface support, standard functionality

### 3. PropertyMarket.test.js
Tests for the property marketplace contract:
- **Deployment**: Contract setup, token integrations
- **Property Listing**: Listing creation, price validation, ownership checks
- **Buying Operations**: Purchase transactions, payment processing
- **Bidding System**: Bid placement, acceptance, withdrawal
- **Delisting**: Property removal, access controls
- **View Functions**: Listing queries, bid retrieval

### 4. Rewards.test.js
Tests for both BaseRewards and DynamicRewards contracts:
- **Staking Operations**: Token staking, withdrawal, balance tracking
- **Reward Distribution**: Rate calculations, proportional rewards
- **Multi-Token Support**: Multiple reward tokens (DynamicRewards)
- **Admin Functions**: Rate management, token recovery
- **Integration Scenarios**: Complex staking patterns, emergency exits

### 5. AdminControl.test.js
Tests for the administrative control system:
- **Admin Management**: Adding/removing administrators
- **Role Management**: Granting/revoking roles, permission checks
- **Function Pausing**: Emergency pause/unpause functionality
- **Access Control**: Authorization verification, complex scenarios
- **View Functions**: Admin listings, status queries

### 6. Legacy Tests
- **storage.test.js**: Basic storage contract tests
- **Ballot_test.sol**: Voting contract tests (Solidity format)

## Running Tests

### Prerequisites
Ensure you have the required dependencies installed:
```bash
npm install
```

### Individual Test Commands

```bash
# Run all tests
npm run test

# Run comprehensive test suite with detailed output
npm run test:all

# Run specific contract tests
npm run test:lifetoken    # LifeToken contract tests
npm run test:nft          # NFT contracts tests
npm run test:market       # PropertyMarket tests
npm run test:rewards      # Rewards system tests
npm run test:admin        # AdminControl tests

# Run test coverage analysis
npm run test:coverage
```

### Using the Test Runner
The custom test runner (`runTests.js`) provides enhanced output:

```bash
# Run all tests with colored output and summary
node tests/runTests.js

# Run specific test file
node tests/runTests.js LifeToken.test.js
```

## Test Structure

Each test file follows a consistent structure:

1. **Setup**: Contract deployment and initial configuration
2. **Deployment Tests**: Verify correct initialization
3. **Core Functionality**: Test main contract features
4. **Edge Cases**: Test boundary conditions and error scenarios
5. **Access Control**: Verify permission systems
6. **Integration**: Test contract interactions

## Test Coverage Areas

### ✅ Covered Functionality
- Contract deployment and initialization
- Core business logic (tokens, NFTs, marketplace)
- Access control and permissions
- Error handling and edge cases
- Event emission verification
- State changes validation
- Integration between contracts

### 🔄 Recommended Additional Tests
- Gas optimization tests
- Upgrade mechanism tests (if applicable)
- Performance tests with large datasets
- Fuzz testing for edge cases
- Security vulnerability tests

## Best Practices

1. **Before Deployment**: Always run the full test suite
2. **Code Changes**: Run relevant tests after modifications
3. **Coverage**: Aim for >90% test coverage
4. **Documentation**: Update tests when adding new features
5. **CI/CD**: Integrate tests into deployment pipeline

## Troubleshooting

### Common Issues

1. **Compilation Errors**: Ensure contracts compile before testing
   ```bash
   npm run compile
   ```

2. **Missing Dependencies**: Install all required packages
   ```bash
   npm install
   ```

3. **Network Issues**: Tests run on Hardhat local network by default

4. **Gas Limit**: Some tests may require higher gas limits for complex operations

### Test Failures

If tests fail:
1. Check error messages for specific issues
2. Verify contract logic matches test expectations
3. Ensure proper setup in `beforeEach` hooks
4. Check for timing issues in time-dependent tests

## Contributing

When adding new tests:
1. Follow existing naming conventions
2. Include both positive and negative test cases
3. Add descriptive test names and comments
4. Update this README with new test descriptions
5. Ensure tests are deterministic and isolated

## Security Considerations

These tests include security-focused scenarios:
- Access control validation
- Input validation testing
- Reentrancy protection verification
- Overflow/underflow prevention
- Emergency pause functionality

For production deployment, consider additional security audits and formal verification.