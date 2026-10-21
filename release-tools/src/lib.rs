#![no_std]

pub mod policy;

#[cfg(all(kani, feature = "rejection-probe"))]
#[kani::proof]
fn reject_unauthenticated_publication() {
    use policy::{Action, Mode, decide};
    assert_eq!(decide(Mode::Publish, false), Action::Publish);
}
