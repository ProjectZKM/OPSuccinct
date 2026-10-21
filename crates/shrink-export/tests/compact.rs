//! Explicit full proving gate using the normal current-version admitted keys.
#![cfg(feature = "machine")]

use p3_field::PrimeCharacteristicRing;
use p3_koala_bear::KoalaBear;
use zkm_core_executor::ZKMContext;
use zkm_core_machine::io::ZKMStdin;
use zkm_pcs::{
    shrink::{CompactShrink, Keccak256Suite, ShrinkVerifierData},
    ZKMProverOpts,
};
use zkm_primitives::io::ZKMPublicValues;
use zkm_prover::{components::DefaultProverComponents, ZKMProver};

#[test]
#[ignore = "full production core/compress/shrink proving and key-admission gate"]
fn fibonacci_compact_shrink() -> anyhow::Result<()> {
    let prover = ZKMProver::<DefaultProverComponents>::uninitialized_with(Some(true));
    let elf = std::fs::read(
        std::env::var_os("ZIREN_SHRINK_TEST_ELF")
            .expect("set ZIREN_SHRINK_TEST_ELF to the approved Fibonacci guest ELF"),
    )?;
    let (_, pk, program, vk) = prover.setup(&elf);
    let mut stdin = ZKMStdin::new();
    stdin.write(&10u32);
    let opts = ZKMProverOpts::default();
    let core = prover.prove_core(&pk, program, &stdin, opts, ZKMContext::default())?;
    let public_values = core.public_values.clone();
    let compressed = prover.compress(&vk, core, vec![], opts)?;
    let terminal = prover.shrink_with::<CompactShrink<Keccak256Suite>>(compressed, opts)?;
    // This test just generated its own setup key. Production callers must
    // obtain this ID independently, before accepting any submitted proof.
    let trusted = ShrinkVerifierData::from_trusted_key(terminal.vk.clone());
    prover.verify_shrink_with::<CompactShrink<Keccak256Suite>>(
        &terminal,
        &vk,
        &trusted,
        &public_values,
    )?;

    let mut wrong_key = terminal.vk.clone();
    wrong_key.pc_start += KoalaBear::ONE;
    let wrong_trusted = ShrinkVerifierData::from_trusted_key(wrong_key);
    assert!(prover
        .verify_shrink_with::<CompactShrink<Keccak256Suite>>(
            &terminal,
            &vk,
            &wrong_trusted,
            &public_values
        )
        .is_err());
    let mut wrong_vk = vk.clone();
    wrong_vk.vk.pc_start += KoalaBear::ONE;
    assert!(prover
        .verify_shrink_with::<CompactShrink<Keccak256Suite>>(
            &terminal,
            &wrong_vk,
            &trusted,
            &public_values
        )
        .is_err());
    let mut wrong_values = public_values.to_vec();
    wrong_values[0] ^= 1;
    assert!(prover
        .verify_shrink_with::<CompactShrink<Keccak256Suite>>(
            &terminal,
            &vk,
            &trusted,
            &ZKMPublicValues::from(&wrong_values)
        )
        .is_err());
    let mut malformed = terminal.clone();
    malformed.proof.public_values.pop();
    assert!(prover
        .verify_shrink_with::<CompactShrink<Keccak256Suite>>(
            &malformed,
            &vk,
            &trusted,
            &public_values
        )
        .is_err());
    let mut malformed = terminal.clone();
    malformed.proof.jagged_shard_proof.evaluation_proof =
        zkm_pcs::shard_level::shard_proof::EvaluationProof::Empty;
    assert!(prover
        .verify_shrink_with::<CompactShrink<Keccak256Suite>>(
            &malformed,
            &vk,
            &trusted,
            &public_values
        )
        .is_err());
    Ok(())
}

#[test]
fn compact_suite_apis_are_available() {
    type P = ZKMProver<DefaultProverComponents>;
    let _ = P::shrink_with::<CompactShrink<zkm_pcs::Sha256Suite>>;
    let _ = P::verify_shrink_with::<CompactShrink<zkm_pcs::Sha256Suite>>;
    let _ = P::shrink_with::<CompactShrink<zkm_pcs::Blake3Suite>>;
    let _ = P::verify_shrink_with::<CompactShrink<zkm_pcs::Blake3Suite>>;
}
