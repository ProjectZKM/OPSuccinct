// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ZirenGroth16ProofVerifier, IZirenGroth16Verifier} from "../src/ZirenGroth16ProofVerifier.sol";

/// Accepts exactly one proof word and one public input vector, and reverts
/// otherwise, as the generated Groth16 verifier does.
contract MockGroth16Verifier is IZirenGroth16Verifier {
    uint256 public immutable acceptedFirstWord;
    uint256[3] public expectedInput;

    constructor(uint256 acceptedFirstWord_, uint256[3] memory expectedInput_) {
        acceptedFirstWord = acceptedFirstWord_;
        expectedInput = expectedInput_;
    }

    function Verify(uint256[8] calldata proof, uint256[3] calldata input) external view {
        if (proof[0] != acceptedFirstWord) revert("invalid proof");
        if (input[0] != expectedInput[0] || input[1] != expectedInput[1] || input[2] != expectedInput[2]) {
            revert("invalid public input");
        }
    }
}

contract ZirenGroth16ProofVerifierTest {
    bytes4 internal constant SELECTOR = 0xb3e14fe9;
    bytes32 internal constant APPLICATION_KEY = 0x002c7ab66df288215fdb30b7aa52652019e409667f9f3373af22b2d395238c53;
    uint256 internal constant RECURSION_ROOT = 0x007ad39482c4460fe91d19534ecc20e27d374c3e17c0fe5f44d7cf7cb0fd2349;
    bytes32 internal constant OUTPUT_DIGEST = 0xd0abd303eefe48a35a09197c8840467029bde2832f61695991207d60fb6a2354;
    uint256 internal constant MASKED_DIGEST = 0x10abd303eefe48a35a09197c8840467029bde2832f61695991207d60fb6a2354;
    uint256 internal constant FIRST_WORD = 0x1dd488d0ee908485258830fde6ef8e54162dddf06bf646df7dc089f227757de2;

    MockGroth16Verifier internal mock;
    ZirenGroth16ProofVerifier internal adapter;

    function setUp() public {
        uint256[3] memory expected = [uint256(APPLICATION_KEY), MASKED_DIGEST, RECURSION_ROOT];
        mock = new MockGroth16Verifier(FIRST_WORD, expected);
        adapter = new ZirenGroth16ProofVerifier(mock, SELECTOR, APPLICATION_KEY, RECURSION_ROOT);
    }

    function packet(uint256 firstWord) internal pure returns (bytes memory out) {
        out = abi.encodePacked(SELECTOR, firstWord);
        for (uint256 i = 1; i < 8; ++i) {
            out = abi.encodePacked(out, uint256(i));
        }
    }

    function testAcceptsValidPacket() public view {
        require(adapter.verify(packet(FIRST_WORD), OUTPUT_DIGEST), "valid packet rejected");
    }

    function testMasksOutputDigestTopBits() public view {
        require(adapter.verify(packet(FIRST_WORD), OUTPUT_DIGEST), "digest not masked");
        require(!adapter.verify(packet(FIRST_WORD), bytes32(uint256(OUTPUT_DIGEST) ^ 1)), "wrong digest accepted");
    }

    function testRejectsInvalidProof() public view {
        require(!adapter.verify(packet(FIRST_WORD + 1), OUTPUT_DIGEST), "invalid proof accepted");
    }

    function testRejectsWrongSelector() public view {
        bytes memory p = packet(FIRST_WORD);
        p[0] = 0x00;
        require(!adapter.verify(p, OUTPUT_DIGEST), "wrong selector accepted");
    }

    function testRejectsWrongLength() public view {
        bytes memory p = packet(FIRST_WORD);
        bytes memory shortPacket = new bytes(p.length - 1);
        for (uint256 i; i < shortPacket.length; ++i) shortPacket[i] = p[i];
        require(!adapter.verify(shortPacket, OUTPUT_DIGEST), "short packet accepted");
    }
}
