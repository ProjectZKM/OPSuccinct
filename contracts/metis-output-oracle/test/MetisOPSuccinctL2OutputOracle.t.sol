// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MetisOPSuccinctL2OutputOracle as Oracle} from "../src/MetisOPSuccinctL2OutputOracle.sol";
import {IMVMStateCommitmentChain} from "../src/metis/IMVMStateCommitmentChain.sol";
import {Lib_OVMCodec} from "../src/metis/Lib_OVMCodec.sol";
import {MetisSCCHarness} from "./MetisSCCHarness.sol";

interface Vm {
    function warp(uint256) external;
    function roll(uint256) external;
    function prank(address) external;
    function setBlockhash(uint256, bytes32) external;
    function expectRevert(bytes calldata) external;
}

/// Accepts exactly one (packet, digest) pair, like an approved verifier entry
/// accepts exactly the proofs of its pinned guest.
contract MockVerifier {
    bytes32 public expectedDigest;
    bytes32 public expectedPacketHash;

    function expect(bytes calldata packet, bytes32 digest) external {
        expectedPacketHash = keccak256(packet);
        expectedDigest = digest;
    }

    function verify(bytes calldata packet, bytes32 digest) external view returns (bool) {
        return digest == expectedDigest && keccak256(packet) == expectedPacketHash;
    }
}

contract MetisOPSuccinctL2OutputOracleTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 constant CHAIN_ID = 1088;
    uint256 constant WINDOW = 604800;
    uint256 constant L1_BLOCK = 100;
    bytes32 constant L1_HASH = keccak256("l1 head");
    bytes32 constant RANGE_VKEY = keccak256("range vkey");
    bytes32 constant ROLLUP_CONFIG = keccak256("metis rollup config");
    address constant PROVER = address(0xBEEF);
    address constant OWNER = address(0xA11CE);
    bytes constant PACKET = hex"0102030405";
    bytes32 constant NAME = keccak256("opsuccinct_genesis");

    MetisSCCHarness scc;
    MockVerifier verifier;
    Oracle oracle;
    bytes32 genesis;
    Lib_OVMCodec.ChainBatchHeader[] headers;

    // Mainnet batches 47399 and 47400 of chain 1088, from StateBatchAppended
    // events of SCC 0xA2FaAAC9120c1Ff75814F0c6DdB119496a12eEA6 and the hashes
    // its storage container returns for them.
    function mainnetHeader(uint256 i) internal pure returns (Lib_OVMCodec.ChainBatchHeader memory h, bytes32 stored) {
        address proposer = 0xf3CEB4C2ef996CdBc95C4E18c6D0CA988CC09040;
        if (i == 47399) {
            h = Lib_OVMCodec.ChainBatchHeader(
                47399,
                0x3041f38011845a4ac76906ed79235b357331e9eaa15f10c8790540763c039202,
                0x88,
                0x163961f,
                abi.encode(
                    uint256(0x6ad96d17),
                    proposer,
                    bytes32(0x48127efa0f31e1151b3127fb38ae4e0efcfe4ad08df78470db9e0eb03eb4fd8b),
                    uint256(0x16396a7)
                )
            );
            stored = 0x03d7c8e73e5bdfac4863d6842745d1d46abeb25cea835fba67a7eb230f7d0766;
        } else {
            h = Lib_OVMCodec.ChainBatchHeader(
                47400,
                0x6f4733f7d16826637b41064cf2a7a0112466a8bebf890b2ce893ab228e040854,
                0x53,
                0x16396a7,
                abi.encode(
                    uint256(0x6ad9771f),
                    proposer,
                    bytes32(0x7459d053bb0865d304ae9fb6e39711348b8c1e43a2891771de1fd5210cc6881f),
                    uint256(0x16396fa)
                )
            );
            stored = 0xd23ae619159eaabb0ba62fe1e4ce2bac6889be35d0e39e1c018a1d0958a96441;
        }
    }

    function setUp() public {
        vm.warp(1_000_000);
        scc = new MetisSCCHarness(WINDOW);
        verifier = new MockVerifier();
        genesis = scc.append(CHAIN_ID, roots(0, 4), keccak256("block 4")).batchRoot;
        vm.warp(block.timestamp + WINDOW + 1);
        oracle = new Oracle(params(scc, startHeader()));
        vm.roll(L1_BLOCK + 1);
        vm.setBlockhash(L1_BLOCK, L1_HASH);
        oracle.checkpointBlockHash(L1_BLOCK);
    }

    function params(MetisSCCHarness _scc, Lib_OVMCodec.ChainBatchHeader memory _start)
        internal
        view
        returns (Oracle.InitParams memory)
    {
        return Oracle.InitParams({
            owner: OWNER,
            proposer: address(this),
            scc: IMVMStateCommitmentChain(address(_scc)),
            l2ChainId: CHAIN_ID,
            startingBatchHeader: _start,
            fallbackTimeout: 1 days,
            genesisConfig: Oracle.OpSuccinctConfig(address(verifier), RANGE_VKEY, ROLLUP_CONFIG)
        });
    }

    function startHeader() internal view returns (Lib_OVMCodec.ChainBatchHeader memory) {
        return Lib_OVMCodec.ChainBatchHeader(
            0, genesis, 4, 0, abi.encode(uint256(1_000_000), address(this), keccak256("block 4"), uint256(4))
        );
    }

    function roots(uint256 first, uint256 count) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            r[i] = keccak256(abi.encode("state root", first + i + 1));
        }
    }

    function appendBatches(uint256 count) internal {
        uint256 total = scc.totalElements(CHAIN_ID);
        for (uint256 i; i < count; ++i) {
            headers.push(scc.append(CHAIN_ID, roots(total, 3), keccak256(abi.encode("block", total + 3))));
            total += 3;
        }
    }

    /// The bytes the guest commits: nine 32-byte words in field order.
    function digest(bytes32 pre, uint256 start, uint256 end, bytes32 headers_, address prover)
        internal
        pure
        returns (bytes32)
    {
        return sha256(
            abi.encodePacked(
                L1_HASH, CHAIN_ID, pre, start, end, headers_, ROLLUP_CONFIG, RANGE_VKEY, uint256(uint160(prover))
            )
        );
    }

    function commitment(uint256 from, uint256 count) internal view returns (bytes32) {
        bytes memory packed;
        for (uint256 i; i < count; ++i) {
            packed = bytes.concat(packed, Lib_OVMCodec.hashBatchHeader(headers[from + i]));
        }
        return keccak256(packed);
    }

    function expectRange(uint256 from, uint256 count) internal {
        bytes32 pre = oracle.provenBatches(headers[from].batchIndex - 1);
        verifier.expect(
            PACKET,
            digest(pre, headers[from].batchIndex, headers[from + count - 1].batchIndex, commitment(from, count), PROVER)
        );
    }

    function propose(uint256 end) internal {
        oracle.proposeL2Output(NAME, end, L1_BLOCK, PACKET, PROVER);
    }

    function testRealMetisBatchHeaderHashes() public pure {
        for (uint256 i = 47399; i <= 47400; ++i) {
            (Lib_OVMCodec.ChainBatchHeader memory h, bytes32 stored) = mainnetHeader(i);
            require(Lib_OVMCodec.hashBatchHeader(h) == stored, "header hash differs from mainnet SCC");
        }
    }

    function testProvesMainnetBatchFromMainnetAnchor() public {
        MetisSCCHarness mainnet = new MetisSCCHarness(WINDOW);
        (Lib_OVMCodec.ChainBatchHeader memory anchor, bytes32 anchorHash) = mainnetHeader(47399);
        (Lib_OVMCodec.ChainBatchHeader memory next, bytes32 nextHash) = mainnetHeader(47400);
        mainnet.seed(CHAIN_ID, 47399, anchorHash);
        mainnet.seed(CHAIN_ID, 47400, nextHash);
        vm.warp(0x6ad96d17 + WINDOW + 1);
        Oracle o = new Oracle(params(mainnet, anchor));
        o.checkpointBlockHash(L1_BLOCK);

        verifier.expect(PACKET, digest(anchorHash, 47400, 47400, keccak256(abi.encodePacked(nextHash)), PROVER));
        o.proposeL2Output(NAME, 47400, L1_BLOCK, PACKET, PROVER);
        require(o.isProven(next) && o.latestBatchIndex() == 47400, "mainnet batch not proven");
    }

    function testProvesContiguousRange() public {
        appendBatches(3);
        expectRange(0, 3);
        propose(3);
        for (uint256 i; i < 3; ++i) {
            require(oracle.isProven(headers[i]), "batch not proven");
        }
        require(oracle.latestBatchIndex() == 3 && oracle.lastProposalTimestamp() == block.timestamp, "state");

        appendBatches(2);
        expectRange(3, 2);
        propose(5);
        require(oracle.isProven(headers[4]), "second range not proven");
    }

    function testUnprovenAndAlteredHeadersAreNotProven() public {
        appendBatches(2);
        expectRange(0, 1);
        propose(1);
        require(!oracle.isProven(headers[1]), "unproven batch reported proven");
        Lib_OVMCodec.ChainBatchHeader memory altered = headers[0];
        altered.batchSize += 1;
        require(!oracle.isProven(altered), "altered header reported proven");
        altered = headers[0];
        altered.batchIndex = 2;
        require(!oracle.isProven(altered), "header at another index reported proven");
    }

    function testPublicValuesBindEveryField() public {
        appendBatches(2);
        bytes32 pre = oracle.provenBatches(0);
        bytes32 c = commitment(0, 2);
        bytes32[5] memory wrong = [
            digest(pre, 1, 2, c, address(0xBAD)),
            digest(bytes32(uint256(1)), 1, 2, c, PROVER),
            digest(pre, 1, 1, c, PROVER),
            digest(pre, 1, 2, commitment(0, 1), PROVER),
            sha256(abi.encode(L1_HASH))
        ];
        for (uint256 i; i < wrong.length; ++i) {
            verifier.expect(PACKET, wrong[i]);
            vm.expectRevert(abi.encodeWithSelector(Oracle.InvalidProof.selector));
            propose(2);
        }
        verifier.expect(hex"ff", digest(pre, 1, 2, c, PROVER));
        vm.expectRevert(abi.encodeWithSelector(Oracle.InvalidProof.selector));
        propose(2);
    }

    function testRejectsInvalidRanges() public {
        appendBatches(2);
        expectRange(0, 2);
        vm.expectRevert(abi.encodeWithSelector(Oracle.BatchNotCanonical.selector, 3));
        propose(3);
        vm.expectRevert(abi.encodeWithSelector(Oracle.InvalidBatchRange.selector));
        propose(0);
        propose(2);
        vm.expectRevert(abi.encodeWithSelector(Oracle.InvalidBatchRange.selector));
        propose(2);
        uint256 max = oracle.MAX_BATCHES_PER_PROOF();
        appendBatches(max + 1);
        vm.expectRevert(abi.encodeWithSelector(Oracle.InvalidBatchRange.selector));
        propose(2 + max + 1);
    }

    function testRejectsUncheckpointedL1AndUnknownConfig() public {
        appendBatches(1);
        expectRange(0, 1);
        vm.expectRevert(abi.encodeWithSelector(Oracle.L1BlockHashNotCheckpointed.selector));
        oracle.proposeL2Output(NAME, 1, L1_BLOCK - 1, PACKET, PROVER);
        vm.expectRevert(abi.encodeWithSelector(Oracle.InvalidConfig.selector));
        oracle.proposeL2Output(keccak256("unknown"), 1, L1_BLOCK, PACKET, PROVER);
        vm.expectRevert(abi.encodeWithSelector(Oracle.L1BlockHashNotAvailable.selector));
        oracle.checkpointBlockHash(block.number + 1);
    }

    function testProposerPermissionAndFallbackTimeout() public {
        appendBatches(1);
        expectRange(0, 1);
        vm.prank(address(0xCAFE));
        vm.expectRevert(abi.encodeWithSelector(Oracle.NotApprovedProposer.selector));
        propose(1);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(address(0xCAFE));
        propose(1);
        require(oracle.isProven(headers[0]), "fallback proposal failed");
    }

    function testAnchorMustBeCanonicalAndFinal() public {
        Lib_OVMCodec.ChainBatchHeader memory start = startHeader();
        Lib_OVMCodec.ChainBatchHeader memory wrong = startHeader();
        wrong.batchRoot = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(Oracle.BatchNotCanonical.selector, 0));
        new Oracle(params(scc, wrong));
        wrong = startHeader();
        wrong.batchIndex = 7;
        vm.expectRevert(abi.encodeWithSelector(Oracle.BatchNotCanonical.selector, 7));
        new Oracle(params(scc, wrong));

        appendBatches(1);
        vm.expectRevert(abi.encodeWithSelector(Oracle.BatchNotFinal.selector));
        new Oracle(params(scc, headers[0]));

        scc.setDisputed(bytes32(uint256(1)), 4);
        vm.expectRevert(abi.encodeWithSelector(Oracle.BatchNotFinal.selector));
        new Oracle(params(scc, start));
        scc.setDisputed(Lib_OVMCodec.hashBatchHeader(start), 5);
        vm.expectRevert(abi.encodeWithSelector(Oracle.BatchNotFinal.selector));
        new Oracle(params(scc, start));
    }

    function testSccDeletionDoesNotTransferProof() public {
        appendBatches(2);
        expectRange(0, 1);
        propose(1);
        // Without the SCC upgrade, the fraud verifier can still delete and
        // replace a proven batch; the oracle keeps the proven header only.
        scc.deleteFrom(CHAIN_ID, 1, 4);
        Lib_OVMCodec.ChainBatchHeader memory replacement = scc.append(CHAIN_ID, roots(100, 3), keccak256("replacement"));
        require(replacement.batchIndex == 1, "replacement index");
        require(oracle.isProven(headers[0]) && !oracle.isProven(replacement), "proof moved to replacement");
    }

    function testOnlyOwnerAdministers() public {
        Oracle.OpSuccinctConfig memory config = Oracle.OpSuccinctConfig(address(verifier), RANGE_VKEY, ROLLUP_CONFIG);
        vm.expectRevert(abi.encodeWithSelector(Oracle.NotOwner.selector));
        oracle.addOpSuccinctConfig(keccak256("v2"), config);
        vm.expectRevert(abi.encodeWithSelector(Oracle.NotOwner.selector));
        oracle.addProposer(address(0xCAFE));

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Oracle.ConfigExists.selector));
        oracle.addOpSuccinctConfig(NAME, config);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Oracle.InvalidConfig.selector));
        oracle.addOpSuccinctConfig(keccak256("v2"), Oracle.OpSuccinctConfig(address(0x1234), RANGE_VKEY, ROLLUP_CONFIG));
        vm.prank(OWNER);
        oracle.deleteOpSuccinctConfig(NAME);

        appendBatches(1);
        expectRange(0, 1);
        vm.expectRevert(abi.encodeWithSelector(Oracle.InvalidConfig.selector));
        propose(1);
    }

    /// Oracle work besides proof verification must fit in the 3,109,177 gas
    /// left under the 16,777,216 cap after the 13,668,039-gas verification.
    function testMaxRangeOverheadFitsUnderCap() public {
        uint256 max = oracle.MAX_BATCHES_PER_PROOF();
        appendBatches(max);
        expectRange(0, max);
        uint256 before = gasleft();
        oracle.proposeL2Output(NAME, max, L1_BLOCK, PACKET, PROVER);
        uint256 used = before - gasleft();
        require(used < 3_109_177, "oracle overhead exceeds remaining cap");
        emit Gas(used);
    }

    event Gas(uint256 used);
}
