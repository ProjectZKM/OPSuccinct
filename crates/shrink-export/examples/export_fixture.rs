//! Prove a guest with the pinned Ziren (or replay a saved proof) and export a
//! complete verifier fixture: `machine/` (trusted metadata and markers),
//! `raw.bin` (profile-encoded proof) and `statement.json`.
//!
//! The trusted verifier data is derived from the proof's own key, which is
//! only acceptable for local reproduction. Production exports must use the
//! independently approved key and statement.
//!
//! Usage:
//!   export_fixture prove <guest.elf> <out> [u32 input] [--derived]
//!   export_fixture replay <dir with shrink.bin application_vk.bin public_values.bin> <out> [--derived]
//!   export_fixture shrink <compressed proof.bin> <guest.elf> <public_values.bin> <out> [--derived]
//!
//! `shrink` accepts a saved SDK `ZKMProofWithPublicValues` holding a compressed
//! proof (such as an EthProofs block proof) and runs only the compact shrink.
use opsuccinct_shrink_export::{
    machine,
    wire::{Mode, Profile},
};
use std::path::{Path, PathBuf};
use zkm_core_executor::ZKMContext;
use zkm_core_machine::io::ZKMStdin;
use zkm_core_machine::reduce::ZKMReduceProof;
use zkm_pcs::{
    shrink::{CompactShrink, Keccak256Suite, ShrinkVerifierData},
    ZKMProverOpts,
};
use zkm_primitives::io::ZKMPublicValues;
use zkm_prover::{components::DefaultProverComponents, CompressedSC, ZKMProver, ZKMVerifyingKey};

type Shrink = CompactShrink<Keccak256Suite>;

fn main() -> anyhow::Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let derived = args.iter().any(|a| a == "--derived");
    args.retain(|a| a != "--derived");
    anyhow::ensure!(
        args.len() >= 3,
        "usage: export_fixture prove <elf> <out> [input] [--derived] | replay <dir> <out> [--derived]"
    );
    let out = PathBuf::from(if args[0] == "shrink" {
        &args[4]
    } else {
        &args[2]
    });
    std::fs::create_dir_all(&out)?;
    let started = std::time::Instant::now();
    let prover = ZKMProver::<DefaultProverComponents>::uninitialized_with(Some(true));
    let (shrink, vk, public_values): (ZKMReduceProof<Shrink>, ZKMVerifyingKey, ZKMPublicValues) =
        match args[0].as_str() {
            "prove" => {
                let elf = std::fs::read(&args[1])?;
                let input: u32 = args.get(3).map(|s| s.parse()).transpose()?.unwrap_or(10);
                let (_, pk, program, vk) = prover.setup(&elf);
                let mut stdin = ZKMStdin::new();
                stdin.write(&input);
                let opts = ZKMProverOpts::default();
                let core = prover.prove_core(&pk, program, &stdin, opts, ZKMContext::default())?;
                eprintln!("core proved in {:?}", started.elapsed());
                let public_values = core.public_values.clone();
                let compressed = prover.compress(&vk, core, vec![], opts)?;
                eprintln!("compressed in {:?}", started.elapsed());
                let shrink = prover.shrink_with::<Shrink>(compressed, opts)?;
                eprintln!("shrunk in {:?}", started.elapsed());
                (shrink, vk, public_values)
            }
            "shrink" => {
                anyhow::ensure!(
                    args.len() >= 5,
                    "shrink <proof.bin> <elf> <public_values.bin> <out>"
                );
                let bytes = std::fs::read(&args[1])?;
                // SDK wrapper: ZKMProof enum tag (1 = Compressed) precedes the
                // boxed reduce proof; public values and version follow it.
                let tag = u32::from_le_bytes(bytes[..4].try_into()?);
                let compressed: ZKMReduceProof<CompressedSC> = match tag {
                    1 => bincode::deserialize(&bytes[4..])?,
                    _ => bincode::deserialize(&bytes)?,
                };
                let elf = std::fs::read(&args[2])?;
                let (_, _, _, vk) = prover.setup(&elf);
                eprintln!("guest setup done in {:?}", started.elapsed());
                let public_values = read_public_values(Path::new(&args[3]))?;
                let opts = ZKMProverOpts::default();
                let shrink = prover.shrink_with::<Shrink>(compressed, opts)?;
                eprintln!("shrunk in {:?}", started.elapsed());
                (shrink, vk, public_values)
            }
            "replay" => {
                let dir = Path::new(&args[1]);
                let shrink = bincode::deserialize(&std::fs::read(dir.join("shrink.bin"))?)?;
                let vk = bincode::deserialize(&std::fs::read(dir.join("application_vk.bin"))?)?;
                let public_values = read_public_values(&dir.join("public_values.bin"))?;
                (shrink, vk, public_values)
            }
            other => anyhow::bail!("unknown mode {other}"),
        };

    let trusted = ShrinkVerifierData::from_trusted_key(shrink.vk.clone());
    prover.verify_shrink_with::<Shrink>(&shrink, &vk, &trusted, &public_values)?;
    eprintln!("native verification passed in {:?}", started.elapsed());
    // Keep the shrunk proof and keys so later exports can `replay` without proving.
    std::fs::write(out.join("shrink.bin"), bincode::serialize(&shrink)?)?;
    std::fs::write(out.join("application_vk.bin"), bincode::serialize(&vk)?)?;
    std::fs::write(
        out.join("public_values.bin"),
        bincode::serialize(&public_values)?,
    )?;
    machine::export(
        &out.join("machine"),
        &prover,
        &shrink,
        &vk,
        &trusted,
        &public_values,
        derived,
    )?;
    let profile = Profile::from_trusted_proof(&shrink.vk, &shrink.proof, Mode::Raw, derived)?;
    let packet = profile.encode(&shrink.proof)?;
    std::fs::write(out.join("raw.bin"), &packet)?;
    let statement = serde_json::json!({
        "output_digest": format!("0x{}", hex::encode(public_values.hash())),
        "profile_id": format!("0x{}", hex::encode(profile.id())),
        "field_count": profile.field_count,
        "hash_count": profile.digest_references,
        "derived_sumchecks": derived,
        "packet_bytes": packet.len(),
    });
    std::fs::write(
        out.join("statement.json"),
        serde_json::to_vec_pretty(&statement)?,
    )?;
    eprintln!(
        "exported {} packet bytes ({} fields, {} hashes) to {} in {:?}",
        packet.len(),
        profile.field_count,
        profile.digest_references,
        out.display(),
        started.elapsed()
    );
    Ok(())
}

/// Public values saved either bincode-encoded (SDK and this tool) or as the raw
/// committed buffer (older fixtures).
fn read_public_values(path: &Path) -> anyhow::Result<ZKMPublicValues> {
    let raw = std::fs::read(path)?;
    Ok(bincode::deserialize::<ZKMPublicValues>(&raw)
        .unwrap_or_else(|_| ZKMPublicValues::from(&raw)))
}
