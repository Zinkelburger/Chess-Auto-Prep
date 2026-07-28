/// Decides what "open Generate" and "open Audit" should actually show.
///
/// Both buttons lead to the bottom pane, but not always to the same tab: an
/// audit that is already running (or has results waiting) should show its
/// findings rather than the config form that would start it again — which is
/// why the audit entry point grew a `forceConfig` flag. Keeping the rule in
/// the screen meant two booleans, four callers, and no way to check it.
///
/// This is pure state: it names the tab to open, and the screen opens it.
library;

/// Bottom-pane tab an entry point wants brought forward.
enum InlineConfigTarget { jobs, findings }

class InlineConfigRouter {
  bool _showGeneration = false;
  bool _showAudit = false;

  /// Whether the inline generation config form is open on the Jobs tab.
  bool get showGeneration => _showGeneration;

  /// Whether the inline audit config form is open on the Jobs tab.
  bool get showAudit => _showAudit;

  bool get anyOpen => _showGeneration || _showAudit;

  /// Opens the generation config. The two forms share the Jobs tab, so
  /// showing one always hides the other.
  InlineConfigTarget openGeneration() {
    _showGeneration = true;
    _showAudit = false;
    return InlineConfigTarget.jobs;
  }

  /// Opens the audit config — unless an audit is already running or has
  /// results, in which case the useful thing to show is what it found.
  /// [forceConfig] is the explicit "configure a new run" path (the rerun
  /// button, the findings panel's own start action).
  InlineConfigTarget openAudit({
    required bool auditHasSomethingToShow,
    bool forceConfig = false,
  }) {
    if (!forceConfig && auditHasSomethingToShow) {
      return InlineConfigTarget.findings;
    }
    _showAudit = true;
    _showGeneration = false;
    return InlineConfigTarget.jobs;
  }

  /// Closes both forms. Returns whether anything was open, so the caller can
  /// skip a needless repaint.
  bool clear() {
    if (!anyOpen) return false;
    _showGeneration = false;
    _showAudit = false;
    return true;
  }

  /// A build has started: its config form has served its purpose and would
  /// otherwise sit on top of the progress it kicked off. Returns whether the
  /// form was open.
  bool onGenerationStarted() {
    if (!_showGeneration) return false;
    _showGeneration = false;
    return true;
  }

  /// An audit has started, for the same reason.
  bool onAuditStarted() {
    if (!_showAudit) return false;
    _showAudit = false;
    return true;
  }
}
