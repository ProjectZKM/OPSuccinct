# Aggregation program design

This document designs the **aggregation program** (zkVM guest) of the Metis validity bridge.
It verifies several consecutive range proofs, checks that they connect end to start, and outputs the `MetisAggregationOutputs` that the contract's `finalize` verifies.
It touches no L1 data: the L1 origin anchor is folded into the batch hash at commit; see l1-anchor.md.

---

## 1. Why it is needed

- **L1 verifies only once.** The cost of verifying a proof on L1 is fixed and does not depend on how much data the proof covers. After merging, L1 pays the verification fee only once, no matter how many ranges one finalize covers.
- **Ranges can run in parallel.** Range proofs are independent of each other and can be generated on several machines at the same time, then merged by aggregation.
- **Range proofs can stay cheap.** Ranges use the zkVM's internal compressed proof format; only the aggregation result needs to be converted into a format that L1 can verify.

For why the two are not built as one self-recursive program, see guest-topology.md.

---

## 2. Inputs and outputs

**Inputs**

| Input | Description |
| --- | --- |
| Public values of each range | In order, at least one |
| Proof of each range | Passed in through the zkVM's recursive verification mechanism |
| Range program key | Identifies which range program these proofs come from |

**Outputs** (seven public values, checked by the L1 contract)

| Public value | Taken from |
| --- | --- |
| L2 chain ID, rollup config hash | The first range; all ranges must have the same values |
| Range program key | Input |
| Start batch hash, start output root | The start of the first range |
| End batch hash, end output root | The end of the last range |

---

## 3. Execution flow

1. **Check non-empty.** There is at least one range.
2. **Check that ranges connect end to start.** For every pair of adjacent ranges, the end of the earlier one must equal the start of the later one. Both the batch hash and the output root must be equal.
3. **Check consistency.** All ranges have the same chain ID and rollup config hash.
4. **Verify each range proof.** Compute the digest of each range's public values and pass it, together with the range program key, to the zkVM's recursive verification.
5. **Output the public values.**

**Why compare both the batch hash and the output root.** Comparing only the batch hash would allow joining two ranges whose data intervals are correct but whose execution starting points differ. Comparing only the output root would allow skipping a stretch of data, because equal state does not mean the data was executed. Only when both are equal are the data and the state both continuous. The output root contains the deposit-sync chain, so this step also guarantees that every deposit root L2 accepted within the interval is in the chain, and the contract can later check all of them at once.

**Why compute the digest.** A proof only states that "some program executed correctly and output public values whose hash is a certain value". Only when the program itself hashes the public values it holds, and then lets verification pass, is it certain that these public values really come from that proof. Otherwise a real proof could be paired with tampered public values.

**Why output the range program key.** The aggregation program does not know which range program is the "correct" one; it only reports faithfully which one it used for verification. The contract compares this value with the registered configuration, which rules out "generating proofs with a fake range program and then merging them".

**Why no L1 data is needed.** The aggregation of op-succinct has to verify a segment of L1 block headers, to link the L1 blocks that each range chose for itself to a checkpoint the contract recognizes. Metis's L1 anchor is written into the batch hash at commit, so connected batch hashes mean that every anchor is already bound; see l1-anchor.md.

---

## 4. Optional: batched KZG pairing

bridge.md measured that batched verification saves about 18% compared with verifying one by one. To extend this gain across ranges:

- The range does no pairing. It only checks `versioned_hash == 0x01 || sha256(commitment)[1..]`, hashes the `(commitment, z, y, proof)` of every blob in the range (160 bytes per blob) into one 32-byte commitment, and exports it as one additional public value.
- Aggregation takes the openings of all ranges as input, first checks that they match the commitment each range exported, then does one batched pairing.
- Cost: the range's public values gain one item, and aggregation gains work proportional to the number of blobs; a range proof is no longer self-contained, and a single range proof on its own cannot prove that the blob contents are correct.

The first version does not adopt this. The reason is that a self-contained range is friendlier to debugging, cache reuse and bisection retry, and an 18% gain is not worth giving that up. The range's public values stay the six items listed in range.md, with no field reserved. If this is adopted later, one item `kzgOpeningsCommitment: bytes32` is added then, and the range program and the aggregation program are upgraded together.

---

## 5. Security checklist

| Threat | Defense |
| --- | --- |
| Merging proofs from a fake range program | The range program key goes into the public values, and the contract compares it with the configuration |
| Joining ranges with different execution starting points | Output roots connect, and they include the block hash |
| Skipping a stretch of data | Batch hashes connect |
| Hiding one sync of a fake deposit root | The output root includes the deposit-sync chain, and the contract rebuilds the whole of it |
| A range used a different L1 anchor | The anchor is in the batch hash, which the contract checks |
| Mixing ranges of different chains or different configurations | The chain ID and config hash must all be the same |
| An empty merge | At least one range |
| Submitting an old proof after someone else finalized first | The contract requires the start to equal the currently finalized position |
