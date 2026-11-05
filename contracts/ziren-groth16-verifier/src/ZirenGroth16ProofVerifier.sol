// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IZirenProofVerifier} from "./interfaces/IZirenProofVerifier.sol";

interface IZirenGroth16Verifier {
    function Verify(uint256[8] calldata proof, uint256[3] calldata input) external view;
}

/// Serves the Ziren Groth16 terminal behind the IZirenProofVerifier interface.
///
/// The packet is the 4-byte verifier selector followed by the 256-byte gnark
/// proof encoding (eight big-endian words). The Groth16 public inputs are
/// `[application key, committed-value digest, recursion root]`, where the
/// committed-value digest is the output digest with its top three bits cleared.
/// The recursion root is the prover's `recursion_vk_root` for the Ziren revision
/// pinned by this repository, as committed by the shrink. Exit code zero is enforced inside
/// the recursion core circuit rather than by a public input, so this adapter
/// does not bind it separately.
contract ZirenGroth16ProofVerifier is IZirenProofVerifier {
    uint256 internal constant DIGEST_MASK = (1 << 253) - 1;
    uint256 internal constant PACKET_LENGTH = 4 + 32 * 8;

    IZirenGroth16Verifier public immutable groth16Verifier;
    bytes4 public immutable verifierSelector;
    bytes32 public immutable applicationKey;
    uint256 public immutable recursionRoot;

    constructor(
        IZirenGroth16Verifier verifier,
        bytes4 selector,
        bytes32 applicationKey_,
        uint256 recursionRoot_
    ) {
        groth16Verifier = verifier;
        verifierSelector = selector;
        applicationKey = applicationKey_;
        recursionRoot = recursionRoot_;
    }

    function verify(bytes calldata proofPacket, bytes32 expectedOutputDigest) external view returns (bool) {
        if (proofPacket.length != PACKET_LENGTH) return false;
        if (bytes4(proofPacket[:4]) != verifierSelector) return false;

        uint256[8] memory proof = abi.decode(proofPacket[4:], (uint256[8]));
        uint256[3] memory inputs;
        inputs[0] = uint256(applicationKey);
        inputs[1] = uint256(expectedOutputDigest) & DIGEST_MASK;
        inputs[2] = recursionRoot;

        try groth16Verifier.Verify(proof, inputs) {
            return true;
        } catch {
            return false;
        }
    }
}
