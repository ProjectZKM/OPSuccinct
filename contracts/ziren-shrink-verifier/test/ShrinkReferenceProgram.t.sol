// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {ShrinkReferenceVerifier} from "../src/ShrinkReferenceVerifier.sol";

/// Fixture-free checks of the interpreter's own statement gate: a program is
/// not allowed to reach the WHIR tail unless it asserted all 32 bytes of the
/// expected output digest, whatever the approved program hash says.
contract ShrinkReferenceProgramTest {
    bytes32 constant PROFILE = keccak256("test profile");
    bytes32 constant DIGEST = keccak256("expected output digest");

    function header() private pure returns (bytes memory) {
        return abi.encodePacked(bytes4(0x4b564532), PROFILE, uint32(0), uint32(0), uint32(0));
    }

    function wire() private pure returns (bytes memory) {
        return abi.encodePacked(bytes4(0x5a4b4554), bytes1(0x01), bytes1(0x00), PROFILE);
    }

    function assertByte(uint256 index, uint256 value) private pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x11), bytes4(uint32(0x80000000 | value)), bytes1(uint8(index)));
    }

    function run(bytes memory program) private returns (bytes4 selector) {
        ShrinkReferenceVerifier verifier = new ShrinkReferenceVerifier(keccak256(program));
        (bool ok, bytes memory error) =
            address(verifier).staticcall(abi.encodeCall(verifier.verify, (program, wire(), DIGEST)));
        require(!ok && error.length >= 4, "program unexpectedly accepted or OOG");
        selector = bytes4(error);
    }

    function testProgramWithoutDigestAssertionsCannotReachWhir() public {
        bytes memory program = bytes.concat(header(), bytes1(0xff));
        require(run(program) == ShrinkReferenceVerifier.IncompleteOutputBinding.selector, "missing binding");
    }

    function testProgramMissingOneDigestByteCannotReachWhir() public {
        bytes memory program = header();
        for (uint256 i; i < 32; ++i) {
            if (i == 7) continue;
            program = bytes.concat(program, assertByte(i, uint8(DIGEST[i])));
        }
        program = bytes.concat(program, bytes1(0xff));
        require(run(program) == ShrinkReferenceVerifier.IncompleteOutputBinding.selector, "partial binding");
    }

    function testRepeatedDigestByteDoesNotCountAsComplete() public {
        bytes memory program = header();
        for (uint256 i; i < 32; ++i) {
            program = bytes.concat(program, assertByte(0, uint8(DIGEST[0])));
        }
        program = bytes.concat(program, bytes1(0xff));
        require(run(program) == ShrinkReferenceVerifier.IncompleteOutputBinding.selector, "repeated binding");
    }

    function testWrongDigestByteFailsAssertion() public {
        bytes memory program = header();
        for (uint256 i; i < 32; ++i) {
            uint256 value = uint8(DIGEST[i]);
            program = bytes.concat(program, assertByte(i, i == 3 ? value ^ 1 : value));
        }
        program = bytes.concat(program, bytes1(0xff));
        require(run(program) == ShrinkReferenceVerifier.AssertionFailed.selector, "wrong byte");
    }

    function testCompleteBindingProceedsToWhirTail() public {
        bytes memory program = header();
        for (uint256 i; i < 32; ++i) {
            program = bytes.concat(program, assertByte(i, uint8(DIGEST[i])));
        }
        program = bytes.concat(program, bytes1(0xff));
        // All 32 bytes are bound, so the interpreter enters the WHIR tail and
        // only then rejects this program for having no WHIR section at all.
        require(run(program) == ShrinkReferenceVerifier.InvalidProgram.selector, "gate passed");
    }
}
