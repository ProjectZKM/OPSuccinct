# Guest topology choice

This document compares two approaches to organizing the zkVM guests and gives the choice for the Metis design.

The decision is: **range / aggregation split**

## 1. The two approaches

### 1.1. Single-guest IVC (Incrementally Verifiable Computation)

There is only one guest. It both verifies its own proof from the previous step and processes a new batch of data.

- Input: previous proof + previous state + new batch data
- Execution: verify the previous proof → derive and execute the new batch
- Output: the new state, and the public values used for the next recursion step

### 1.2. range / aggregation split

Two independent guests: one program proves the state transition of one segment of data, and the other program verifies several segment proofs and merges them.

- range guest: proves that the execution of a segment of batches is correct.

  - Input: the starting state of the range + the new batch data of that range and the witness needed for verification.
  - Execution: verify the data source → derive and execute these batches → obtain the state at the end of the range.
  - Output: public values such as the start and end of the range; the prover generates the corresponding range proof.

  Multiple ranges can be generated independently and in parallel, without waiting for the previous range proof:

  ```text
  100 → 110: P₁
  110 → 120: P₂
  120 → 130: P₃
  ```

- aggregation guest: merges several segment proofs into one proof.

  - Input: multiple range proofs + their respective public values + the range program VK.
  - Execution: verify each range proof → check that the configuration is consistent → check that the end of each segment equals the start of the next.
  - Output: public values such as the start and end of the whole range and the range VK commitment; the prover generates the aggregation proof.

  ```text
  P₁: 100 → 110 ─┐
  P₂: 110 → 120 ─┼→ aggregation → proves 100 → 130
  P₃: 120 → 130 ─┘
  ```

---

## 2. IVC disadvantages

- **Finalize is permissionless, and IVC loses more when it is front-run**

  For example, the chain is initially finalized to batch 100, proving starts from there, and the proof has reached batch 130. At this point someone else submits a proof first and advances the on-chain finalized state to 120. The IVC proof covering 100 to 130 cannot be trimmed to 120 to 130, so the proof is invalidated, and the following proofs must be regenerated starting from the new on-chain finalized state, 120.

  With the range / aggregation split, what is stored independently is: 100 → 110    110 → 120    120 → 130

  After someone else finalizes to 120, the range proof for 120 to 130 can be reused directly, and one more aggregation is enough. If the new finalized point falls inside a range, the remaining part of that range, from the new finalized point to its original end, must be redone; the complete ranges after it can still be reused.

- **Cannot run in parallel**

  IVC must be strictly serial: step k must wait for step k-1 to complete. Ranges can run in parallel on several provers, and aggregation merges them in one pass.

  If demand-driven finalization falls dozens of commits behind, or when finalization is front-run, IVC can only catch up step by step, while the split topology can prove several segments at the same time.

  The proving time of a single step has not been measured. bridge.md only measured the instruction counts of blob verification and decoding (batched KZG verification is about 13.4M per blob, decoding about 6.4M); this excludes EVM execution and is not proving time.

- **Poor failure isolation**

  In the split topology, range proofs are independent of each other and a failure is local: the failed part can be split into smaller pieces and retried while the other parts keep running. In IVC, every step takes the previous step's proof as input and a failure is global: splitting cannot change the serial dependency, and all later steps can only wait.

## 3. IVC advantages

- **Simple scheduler**

  A linear chain; the proposer can drop the range cache, gap computation, link checks and the aggregation trigger policy

- **Simple governance**

  The contract does not need to store the range vk commitment

- **Can finalize at any time**

  Proofs are generated off-chain continuously. Provided that proof generation keeps up with L2 chain production, the proof of the latest step can be submitted directly when finalization is needed, with no extra merge to wait for.

  The split topology must first aggregate multiple range proofs into one proof, which adds the time of one aggregation proof; when too many ranges have accumulated, it also has to finalize in several rounds, see proposer.md.

## 4. What the two have in common

- **Similar Ziren upgrade cost**

  The guest changes, and the new program cannot verify the old program's proofs, so both must restart from "genesis" at the on-chain finalized state.

- **Same on-chain verification cost**

  Even if IVC has a proof at every step, not every step has to go on-chain. Both submit one proof of the same format to the chain at finalization, so the on-chain verification cost is the same.

---

## 5. Choice

All things considered, the range / aggregation split is chosen.
