// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Groth16Verifier} from "../src/Groth16Verifier.sol";
import {ZirenGroth16ProofVerifier, IZirenGroth16Verifier} from "../src/ZirenGroth16ProofVerifier.sol";

/// Runs the real Groth16Verifier on the fibonacci proof (input 10) exported by
/// scripts/groth16_verify.py's pipeline. The proof, public inputs and packet are the
/// values printed by scripts/groth16_args.py for that run.
contract Groth16VerifierTest {
    bytes4 internal constant SELECTOR = 0xb3e14fe9;
    bytes32 internal constant APPLICATION_KEY = 0x002c7ab66df288215fdb30b7aa52652019e409667f9f3373af22b2d395238c53;
    uint256 internal constant RECURSION_ROOT = 0x007ad39482c4460fe91d19534ecc20e27d374c3e17c0fe5f44d7cf7cb0fd2349;
    bytes32 internal constant OUTPUT_DIGEST = 0xd0abd303eefe48a35a09197c8840467029bde2832f61695991207d60fb6a2354;

    function fixtureProof() internal pure returns (uint256[8] memory p) {
        p[0] = 0x1dd488d0ee908485258830fde6ef8e54162dddf06bf646df7dc089f227757de2;
        p[1] = 0x16ccc680820d8ba2ffb36c7aa0625c345330f2ad5fb2142e42561457b7726a67;
        p[2] = 0x16e07d92f9107bbda27d8cc10d9bc8a6f41d9411c42594b499fea8b56c67c16b;
        p[3] = 0x2eb0b7e64fc6a6f9bba6752614116710fdae3213ddfc3a8f2902cfa6b04282a9;
        p[4] = 0x0930e89b73eb2da6fc2c24b68dbed6b3bb9a5d2088b9c4b69050232d65958ce3;
        p[5] = 0x1a2ff75b95fae521a3192f48baabf70e810ab0a1505b8b0d7a811fa802374ef9;
        p[6] = 0x1c8f66bed48abb80a6a936dc71464784119d0a6ce4c7248fb97ea17c9680381e;
        p[7] = 0x1bfd49c53b9ebbce0509560a42d571ebbbecbaedf84a6d0ed47e362575444ee6;
    }

    function fixtureInputs() internal pure returns (uint256[3] memory i) {
        i[0] = uint256(APPLICATION_KEY);
        i[1] = 0x10abd303eefe48a35a09197c8840467029bde2832f61695991207d60fb6a2354;
        i[2] = RECURSION_ROOT;
    }

    function testVerifierAcceptsFixtureProof() public {
        Groth16Verifier verifier = new Groth16Verifier();
        verifier.Verify(fixtureProof(), fixtureInputs());
    }

    function testVerifierRejectsTamperedProof() public {
        Groth16Verifier verifier = new Groth16Verifier();
        uint256[8] memory proof = fixtureProof();
        proof[0] ^= 1;
        try verifier.Verify(proof, fixtureInputs()) {
            revert("tampered proof accepted");
        } catch {}
    }

    function testVerifierRejectsWrongPublicInput() public {
        Groth16Verifier verifier = new Groth16Verifier();
        uint256[3] memory inputs = fixtureInputs();
        inputs[2] ^= 1;
        try verifier.Verify(fixtureProof(), inputs) {
            revert("wrong public input accepted");
        } catch {}
    }

    function testAdapterAcceptsFixturePacketWithRealVerifier() public {
        Groth16Verifier verifier = new Groth16Verifier();
        ZirenGroth16ProofVerifier adapter = new ZirenGroth16ProofVerifier(
            IZirenGroth16Verifier(address(verifier)), SELECTOR, APPLICATION_KEY, RECURSION_ROOT
        );
        bytes memory packet = abi.encodePacked(SELECTOR, abi.encode(fixtureProof()));
        require(adapter.verify(packet, OUTPUT_DIGEST), "adapter rejected fixture packet");
    }
}
