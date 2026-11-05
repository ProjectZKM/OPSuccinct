// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Verifies a proof packet against the output digest the caller expects.
///         The packet layout and how the digest is bound to the proof are defined
///         by the implementing contract.
interface IZirenProofVerifier {
    function verify(bytes calldata proofPacket, bytes32 expectedOutputDigest) external view returns (bool);
}
