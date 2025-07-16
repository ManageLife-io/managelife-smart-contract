// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract TestSignatureRecovery {
    using ECDSA for bytes32;

    uint256 private constant SIGNATURE_LENGTH = 65;

    function recoverSigner(bytes32 txHash, bytes memory signature) public pure returns (address) {
        return txHash.toEthSignedMessageHash().recover(signature);
    }

    function recoverSignerDirect(bytes32 txHash, bytes memory signature) public pure returns (address) {
        return txHash.recover(signature);
    }

    function getSignature(bytes memory signatures, uint256 index) public pure returns (bytes memory signature) {
        require(signatures.length >= (index + 1) * SIGNATURE_LENGTH, "Invalid signature index");

        signature = new bytes(SIGNATURE_LENGTH);
        uint256 offset = index * SIGNATURE_LENGTH;

        assembly {
            let src := add(add(signatures, 0x20), offset)
            let dest := add(signature, 0x20)

            // Copy 32 bytes (r)
            mstore(dest, mload(src))
            // Copy 32 bytes (s)
            mstore(add(dest, 0x20), mload(add(src, 0x20)))
            // Copy 1 byte (v)
            mstore8(add(dest, 0x40), byte(0, mload(add(src, 0x40))))
        }
    }

    function testMultipleSignatures(bytes32 txHash, bytes memory signatures) public pure returns (address[] memory) {
        uint256 signatureCount = signatures.length / SIGNATURE_LENGTH;
        address[] memory signers = new address[](signatureCount);

        for (uint256 i = 0; i < signatureCount; i++) {
            bytes memory signature = getSignature(signatures, i);
            signers[i] = txHash.toEthSignedMessageHash().recover(signature);
        }

        return signers;
    }
}
