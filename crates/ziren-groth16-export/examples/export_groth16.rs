//! Export a Groth16 terminal proof: native shrink, `wrap_bn254`, then
//! `wrap_groth16_bn254`. Runs on the CPU.
//!
//! Usage:
//!   export_groth16 prove <guest.elf> <out dir> [u32 input]
//!   export_groth16 replay <dir with shrink.bin> <circuit dir> <out.json>
//!   export_groth16 groth16 <guest.elf> <circuit dir> <out.json> [u32 input]
//!
//! `prove` writes `shrink.bin` and `public_values.bin` to `<out dir>`. `replay`
//! wraps a saved `shrink.bin` without proving again. `groth16` proves and wraps
//! in one run. Each Groth16 mode writes the proof as JSON for
//! `scripts/groth16_args.py`.
use std::path::{Path, PathBuf};
use std::time::Instant;
use zkm_core_executor::ZKMContext;
use zkm_core_machine::io::ZKMStdin;
use zkm_core_machine::reduce::ZKMReduceProof;
use zkm_pcs::ZKMProverOpts;
use zkm_primitives::io::ZKMPublicValues;
use zkm_prover::{components::DefaultProverComponents, NativeShrink, ShrinkSC, ZKMProver};

const USAGE: &str = "usage:
  export_groth16 prove <guest.elf> <out dir> [u32 input]
  export_groth16 replay <dir with shrink.bin> <circuit dir> <out.json>
  export_groth16 groth16 <guest.elf> <circuit dir> <out.json> [u32 input]";

type Prover = ZKMProver<DefaultProverComponents>;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    anyhow::ensure!(args.len() >= 3, USAGE);
    let started = Instant::now();
    let prover = Prover::uninitialized_with(Some(true));

    match args[0].as_str() {
        "prove" => {
            let out_dir = PathBuf::from(&args[2]);
            std::fs::create_dir_all(&out_dir)?;
            let (shrink, public_values) =
                prove_shrink(&prover, Path::new(&args[1]), input_arg(&args, 3)?, started)?;
            std::fs::write(out_dir.join("shrink.bin"), bincode::serialize(&shrink)?)?;
            std::fs::write(
                out_dir.join("public_values.bin"),
                bincode::serialize(&public_values)?,
            )?;
            println!("SHRINK_OK out={}", out_dir.display());
        }
        "replay" => {
            anyhow::ensure!(args.len() >= 4, USAGE);
            let shrink: ZKMReduceProof<ShrinkSC> =
                bincode::deserialize(&std::fs::read(Path::new(&args[1]).join("shrink.bin"))?)?;
            wrap_to_json(
                &prover,
                shrink,
                Path::new(&args[2]),
                Path::new(&args[3]),
                started,
            )?;
        }
        "groth16" => {
            anyhow::ensure!(args.len() >= 4, USAGE);
            let (shrink, _) =
                prove_shrink(&prover, Path::new(&args[1]), input_arg(&args, 4)?, started)?;
            wrap_to_json(
                &prover,
                shrink,
                Path::new(&args[2]),
                Path::new(&args[3]),
                started,
            )?;
        }
        other => anyhow::bail!("unknown mode {other}\n{USAGE}"),
    }
    Ok(())
}

/// The optional guest input at `index`, defaulting to 10.
fn input_arg(args: &[String], index: usize) -> anyhow::Result<u32> {
    Ok(args
        .get(index)
        .map(|s| s.parse())
        .transpose()?
        .unwrap_or(10))
}

/// Proves the guest and runs the native shrink.
fn prove_shrink(
    prover: &Prover,
    elf_path: &Path,
    input: u32,
    started: Instant,
) -> anyhow::Result<(ZKMReduceProof<ShrinkSC>, ZKMPublicValues)> {
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

    let shrink = prover.shrink_with::<NativeShrink>(compressed, opts)?;
    eprintln!("[export] native shrink {:?}", started.elapsed());
    Ok((shrink, public_values))
}

/// Wraps a shrink proof to BN254 and Groth16, and writes the proof as JSON.
fn wrap_to_json(
    prover: &Prover,
    shrink: ZKMReduceProof<ShrinkSC>,
    circuit_dir: &Path,
    out: &Path,
    started: Instant,
) -> anyhow::Result<()> {
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
