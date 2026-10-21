#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Check,
    Publish,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Refuse,
    Confirm,
    Publish,
}

#[must_use]
pub const fn decide(mode: Mode, authenticated: bool) -> Action {
    match (mode, authenticated) {
        (_, false) => Action::Refuse,
        (Mode::Check, true) => Action::Confirm,
        (Mode::Publish, true) => Action::Publish,
    }
}

#[cfg(kani)]
mod proofs {
    use super::{Action, Mode, decide};

    #[kani::proof]
    fn checking_never_admits_publication() {
        assert!(decide(Mode::Check, kani::any()) != Action::Publish);
    }

    #[kani::proof]
    fn publication_requires_explicit_mode_and_authentication() {
        let mode = if kani::any() {
            Mode::Publish
        } else {
            Mode::Check
        };
        let authenticated = kani::any();
        assert_eq!(
            decide(mode, authenticated) == Action::Publish,
            mode == Mode::Publish && authenticated
        );
    }
}
