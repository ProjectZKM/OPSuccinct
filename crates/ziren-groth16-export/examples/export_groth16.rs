//! Export a Groth16 terminal proof on the CPU: native shrink, `wrap_bn254`, then
//! `wrap_groth16_bn254`.
//!
//! Usage:
//!   export_groth16 prove <guest.elf> <circuit dir> <out dir> [u32 input]
//!   export_groth16 groth16 <compressed proof.bin> <circuit dir> <out.json>
//!   export_groth16 replay <prove out dir>
//!
//! `prove` runs core proving, compression, native shrink and both wraps. It
//! writes `compressed.bin` and `public_values.bin` (for `groth16_verify.py`) and
//! `groth16_proof.json` to `<out dir>`. `groth16` takes a saved compressed proof,
//! such as `compressed.bin` or an SDK compressed proof, and runs the shrink and
//! both wraps. `replay` reads the Groth16 proof that `prove` wrote to its out
//! dir and checks its layout, without running any proving.
use std::path::Path;
use std::time::Instant;
use zkm_core_executor::ZKMContext;
use zkm_core_machine::io::ZKMStdin;
use zkm_core_machine::reduce::ZKMReduceProof;
use zkm_pcs::ZKMProverOpts;
use zkm_primitives::io::ZKMPublicValues;
use zkm_prover::{
    components::DefaultProverComponents, CompressedSC, Groth16Bn254Proof, NativeShrink, ZKMProver,
};

/// Hex digits in the 256-byte `encoded_proof` field of the Groth16 proof.
const ENCODED_PROOF_HEX_LEN: usize = 512;

const USAGE: &str = "usage:
  export_groth16 prove <guest.elf> <circuit dir> <out dir> [u32 input]
  export_groth16 groth16 <compressed proof.bin> <circuit dir> <out.json>
  export_groth16 replay <prove out dir>";

type Prover = ZKMProver<DefaultProverComponents>;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    anyhow::ensure!(args.len() >= 2, USAGE);
    let started = Instant::now();
    let prover = Prover::uninitialized_with(Some(true));

    match args[0].as_str() {
        "prove" => {
            anyhow::ensure!(args.len() >= 4, USAGE);
            let input = args.get(4).map(|s| s.parse()).transpose()?.unwrap_or(10);
            prove(
                &prover,
                Path::new(&args[1]),
                Path::new(&args[2]),
                Path::new(&args[3]),
                input,
                started,
            )?;
        }
        "groth16" => {
            anyhow::ensure!(args.len() >= 4, USAGE);
            let compressed = read_compressed(Path::new(&args[1]))?;
            groth16_from_compressed(
                &prover,
                compressed,
                Path::new(&args[2]),
                Path::new(&args[3]),
                started,
            )?;
        }
        "replay" => {
            let path = Path::new(&args[1]).join("groth16_proof.json");
            let groth16: Groth16Bn254Proof = serde_json::from_slice(&std::fs::read(&path)?)?;
            anyhow::ensure!(
                groth16.encoded_proof.len() == ENCODED_PROOF_HEX_LEN,
                "encoded_proof is {} hex digits, expected {ENCODED_PROOF_HEX_LEN}",
                groth16.encoded_proof.len()
            );
            println!(
                "REPLAY_OK selector=0x{} public_inputs={} raw_proof_bytes={} path={}",
                hex_prefix(&groth16.groth16_vkey_hash),
                groth16.public_inputs.len(),
                groth16.raw_proof.len(),
                path.display()
            );
        }
        other => anyhow::bail!("unknown mode {other}\n{USAGE}"),
    }
    Ok(())
}

/// Proves the guest and compresses the core proof.
fn prove_compressed(
    prover: &Prover,
    elf_path: &Path,
    input: u32,
    started: Instant,
) -> anyhow::Result<(ZKMReduceProof<CompressedSC>, ZKMPublicValues)> {
    let elf = std::fs::read(elf_path)?;
    let (_, pk, program, vk) = prover.setup(&elf);
    eprintln!("[export] setup {:?}", started.elapsed());

    let mut stdin = ZKMStdin::new();
    stdin.write(&input);
    let opts = ZKMProverOpts::default();

    let core = prover.prove_core(&pk, program, &stdin, opts, ZKMContext::default())?;
    eprintln!("[export] core proved {:?}", started.elapsed());
    let public_values = core.public_values.clone();
    let compressed = prover.compress(&vk, core, vec![], opts)?;
    eprintln!("[export] compressed {:?}", started.elapsed());
    Ok((compressed, public_values))
}

/// Proves the guest end to end and writes its artifacts to `out_dir`:
/// `compressed.bin`, `public_values.bin` and `groth16_proof.json`.
fn prove(
    prover: &Prover,
    elf_path: &Path,
    circuit_dir: &Path,
    out_dir: &Path,
    input: u32,
    started: Instant,
) -> anyhow::Result<()> {
    std::fs::create_dir_all(out_dir)?;
    let (compressed, public_values) = prove_compressed(prover, elf_path, input, started)?;
    std::fs::write(
        out_dir.join("compressed.bin"),
        bincode::serialize(&compressed)?,
    )?;
    std::fs::write(
        out_dir.join("public_values.bin"),
        bincode::serialize(&public_values)?,
    )?;
    groth16_from_compressed(
        prover,
        compressed,
        circuit_dir,
        &out_dir.join("groth16_proof.json"),
        started,
    )
}

/// Reads a bincode compressed proof, accepting the SDK wrapper that prefixes
/// it with a `ZKMProof` enum tag (1 = Compressed).
fn read_compressed(path: &Path) -> anyhow::Result<ZKMReduceProof<CompressedSC>> {
    const COMPRESSED_TAG: u32 = 1;
    let bytes = std::fs::read(path)?;
    anyhow::ensure!(
        bytes.len() >= 4,
        "{} is too short to be a proof",
        path.display()
    );
    let tag = u32::from_le_bytes(bytes[..4].try_into()?);
    Ok(match tag {
        COMPRESSED_TAG => bincode::deserialize(&bytes[4..])?,
        _ => bincode::deserialize(&bytes)?,
    })
}

/// The first four bytes of the verifier hash as lowercase hex.
fn hex_prefix(hash: &[u8; 32]) -> String {
    hash[..4].iter().map(|b| format!("{b:02x}")).collect()
}

/// Runs the native shrink, `wrap_bn254` and `wrap_groth16_bn254`, and writes
/// the Groth16 proof as JSON.
fn groth16_from_compressed(
    prover: &Prover,
    compressed: ZKMReduceProof<CompressedSC>,
    circuit_dir: &Path,
    out: &Path,
    started: Instant,
) -> anyhow::Result<()> {
    let shrink = prover.shrink_with::<NativeShrink>(compressed, ZKMProverOpts::default())?;
    eprintln!("[export] native shrink {:?}", started.elapsed());
    let wrapped = prover.wrap_bn254(shrink, ZKMProverOpts::default())?;
    eprintln!("[export] wrap_bn254 {:?}", started.elapsed());

    let groth16 = prover.wrap_groth16_bn254(wrapped, circuit_dir);
    eprintln!("[export] wrap_groth16_bn254 {:?}", started.elapsed());
    std::fs::write(out, serde_json::to_vec_pretty(&groth16)?)?;
    println!(
        "GROTH16_OK raw_proof_bytes={} out={}",
        groth16.raw_proof.len(),
        out.display()
    );
    Ok(())
}
