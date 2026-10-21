use beamtrace_release_tools::policy::{Action, Mode, decide};

#[test]
fn missing_authority_or_check_mode_never_publishes() {
    assert_eq!(decide(Mode::Check, true), Action::Confirm);
    assert_eq!(decide(Mode::Check, false), Action::Refuse);
    assert_eq!(decide(Mode::Publish, false), Action::Refuse);
    assert_eq!(decide(Mode::Publish, true), Action::Publish);
}
