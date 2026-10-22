// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Generated entry of contracts/ziren-shrink-verifier. The guest's
///         application key, exit code and recursion root are compiled into
///         the entry, so one deployment serves one approved guest.
interface IZirenShrinkVerifier {
    function verify(bytes calldata proofPacket, bytes32 expectedOutputDigest) external view returns (bool);
}
