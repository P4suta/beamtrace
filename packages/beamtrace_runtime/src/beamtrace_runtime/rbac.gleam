import gleam/list

pub type Role {
  Admin
  Investigator
  Viewer
  RawCaptureRole
}

pub type Action {
  ViewSession
  StartMetadataCapture
  DeepInspect
  RawCapture
  Annotate
  ManageProject
  ManageRelay
  ManageRetention
}

pub type AuditClass {
  ReadOnly
  Operational
  Sensitive
  Administrative
}

pub fn authorize(roles: List(Role), action: Action) -> Bool {
  case list.contains(roles, Admin) {
    True -> True
    False -> authorize_non_admin(roles, action)
  }
}

fn authorize_non_admin(roles: List(Role), action: Action) -> Bool {
  case action {
    ViewSession -> has_any(roles, [Viewer, Investigator, RawCaptureRole])
    StartMetadataCapture | DeepInspect | Annotate ->
      list.contains(roles, Investigator)
    RawCapture ->
      list.contains(roles, Investigator) && list.contains(roles, RawCaptureRole)
    ManageProject | ManageRelay | ManageRetention -> False
  }
}

fn has_any(roles: List(Role), wanted: List(Role)) -> Bool {
  list.any(wanted, fn(role) { list.contains(roles, role) })
}

pub fn audit_class(action: Action) -> AuditClass {
  case action {
    ViewSession -> ReadOnly
    StartMetadataCapture | DeepInspect | Annotate -> Operational
    RawCapture -> Sensitive
    ManageProject | ManageRelay | ManageRetention -> Administrative
  }
}
