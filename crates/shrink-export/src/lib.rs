//! Optional transport and trusted verifier-data export for the Keccak256 compact shrink consumer.
//! No exported witness or acceptance flag replaces on-chain verification.
#[cfg(feature = "machine")]
pub mod machine;
pub mod wire;
