//! Native shrink -> wrap_bn254 -> wrap_groth16_bn254, CPU only.
//! Usage: export_groth16 <guest.elf> <groth16 circuit dir> [u32 input]
use std::path::PathBuf;
use std::time::Instant;
use zkm_core_executor::ZKMContext;
use zkm_core_machine::io::ZKMStdin;
use zkm_pcs::ZKMProverOpts;
use zkm_prover::{components::DefaultProverComponents, NativeShrink, ZKMProver};

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    anyhow::ensure!(args.len() >= 2, "usage: export_groth16 <elf> <circuit dir> [input]");
    let elf = std::fs::read(&args[0])?;
    let circuit_dir = PathBuf::from(&args[1]);
    let input: u32 = args.get(2).map(|s| s.parse()).transpose()?.unwrap_or(10);

    let started = Instant::now();
    let prover = ZKMProver::<DefaultProverComponents>::uninitialized_with(Some(true));
    let (_, pk, program, vk) = prover.setup(&elf);
    eprintln!("[export] setup {:?}", started.elapsed());

    let mut stdin = ZKMStdin::new();
    stdin.write(&input);
    let opts = ZKMProverOpts::default();

    let core = prover.prove_core(&pk, program, &stdin, opts, ZKMContext::default())?;
    eprintln!("[export] core proved {:?}", started.elapsed());
    let compressed = prover.compress(&vk, core, vec![], opts)?;
    eprintln!("[export] compressed {:?}", started.elapsed());

    let shrink = prover.shrink_with::<NativeShrink>(compressed, opts)?;
    eprintln!("[export] native shrink {:?}", started.elapsed());

    let wrapped = prover.wrap_bn254(shrink, opts)?;
    eprintln!("[export] wrap_bn254 {:?}", started.elapsed());

    let groth16 = prover.wrap_groth16_bn254(wrapped, &circuit_dir);
    eprintln!("[export] wrap_groth16_bn254 {:?}", started.elapsed());
    let out = std::env::var("EXPORT_OUT").unwrap_or_else(|_| "groth16_proof.json".into());
    std::fs::write(&out, serde_json::to_vec_pretty(&groth16)?)?;
    println!("GROTH16_OK raw_proof_bytes={} out={out}", groth16.raw_proof.len());
    Ok(())
}
