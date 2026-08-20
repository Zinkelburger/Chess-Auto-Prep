/// Decides what pressing "Audit" should actually show.
///
/// An audit that is already running — or has findings waiting — should show
/// those findings rather than the config form that would start it over. The
/// explicit "configure a new run" paths (the rerun button, the findings
/// panel's own start action) pass [forceConfig] to say so.
///
/// Pure state-free routing: it names the destination, the screen opens it.
/// This used to be [InlineConfigRouter], which additionally tracked whether
/// each config form was open on the Jobs tab; both forms are full-screen
/// routes now, so the Navigator holds that state and the booleans are gone.
library;

/// Where the Audit entry point should land.
enum AuditEntry {
  /// The full-screen audit configuration step.
  config,

  /// The findings panel, with a run in progress or results already in.
  findings,
}

class AuditEntryRouter {
  const AuditEntryRouter();

  AuditEntry resolve({
    required bool auditHasSomethingToShow,
    bool forceConfig = false,
  }) {
    if (!forceConfig && auditHasSomethingToShow) return AuditEntry.findings;
    return AuditEntry.config;
  }
}
