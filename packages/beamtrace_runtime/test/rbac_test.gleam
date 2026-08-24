import beamtrace_runtime/rbac
import gleeunit/should

pub fn viewer_is_read_only_test() {
  rbac.authorize([rbac.Viewer], rbac.ViewSession) |> should.be_true()
  rbac.authorize([rbac.Viewer], rbac.StartMetadataCapture) |> should.be_false()
  rbac.authorize([rbac.Viewer], rbac.RawCapture) |> should.be_false()
}

pub fn investigator_can_diagnose_but_not_capture_raw_test() {
  let roles = [rbac.Investigator]
  rbac.authorize(roles, rbac.StartMetadataCapture) |> should.be_true()
  rbac.authorize(roles, rbac.DeepInspect) |> should.be_true()
  rbac.authorize(roles, rbac.RawCapture) |> should.be_false()
  rbac.authorize(roles, rbac.ManageProject) |> should.be_false()
}

pub fn raw_capture_requires_separate_permission_test() {
  rbac.authorize([rbac.Investigator, rbac.RawCaptureRole], rbac.RawCapture)
  |> should.be_true()
  rbac.authorize([rbac.Admin], rbac.RawCapture) |> should.be_true()
}

pub fn raw_trace_reads_require_investigator_and_raw_roles_or_admin_test() {
  rbac.authorize([rbac.Viewer], rbac.ViewRawTrace) |> should.be_false()
  rbac.authorize([rbac.Investigator], rbac.ViewRawTrace) |> should.be_false()
  rbac.authorize([rbac.RawCaptureRole], rbac.ViewRawTrace) |> should.be_false()
  rbac.authorize([rbac.Investigator, rbac.RawCaptureRole], rbac.ViewRawTrace)
  |> should.be_true()
  rbac.authorize([rbac.Admin], rbac.ViewRawTrace) |> should.be_true()
}

pub fn audit_classifies_sensitive_actions_test() {
  rbac.audit_class(rbac.RawCapture) |> should.equal(rbac.Sensitive)
  rbac.audit_class(rbac.ViewRawTrace) |> should.equal(rbac.Sensitive)
  rbac.audit_class(rbac.ViewSession) |> should.equal(rbac.ReadOnly)
}
