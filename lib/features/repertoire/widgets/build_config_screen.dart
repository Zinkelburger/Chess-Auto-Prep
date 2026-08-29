/// Full-screen host for a job's configuration step.
///
/// "Plan a build" already worked this way — it takes the whole window while
/// you set it up, then hands off to a background job and gives the window
/// back. Generate and Audit used to cram the same kind of form into the
/// bottom pane instead, where it fought the board for room and read as a
/// different species of thing. This is that planner shape, reusable: an app
/// bar naming the repertoire and the step, the form filling the screen, and
/// a route that closes itself the moment the job it configures starts.
///
/// The host owns no configuration of its own. The child collects settings
/// and starts the run; [startSignal] and [hasStarted] are how the host
/// notices that it did.
library;

import 'package:flutter/material.dart';

class BuildConfigScreen extends StatefulWidget {
  const BuildConfigScreen({
    super.key,
    required this.repertoireName,
    required this.title,
    required this.child,
    this.startSignal,
    this.hasStarted,
  });

  /// Shown before the step name, matching the planner's
  /// `<repertoire> ▸ <step>` app-bar title.
  final String repertoireName;
  final String title;
  final Widget child;

  /// Fires whenever the job's state may have changed.
  final Listenable? startSignal;

  /// Whether the job this screen configures is now running. When it turns
  /// true the route pops, so the user is back in the builder watching
  /// progress rather than looking at the form that started it.
  final bool Function()? hasStarted;

  @override
  State<BuildConfigScreen> createState() => _BuildConfigScreenState();
}

class _BuildConfigScreenState extends State<BuildConfigScreen> {
  /// Guards against a second pop: the signal keeps ticking after the run
  /// starts (progress updates), and popping twice would take the builder
  /// down with it.
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    widget.startSignal?.addListener(_onSignal);
  }

  @override
  void dispose() {
    widget.startSignal?.removeListener(_onSignal);
    super.dispose();
  }

  void _onSignal() {
    if (_popped || !mounted) return;
    if (widget.hasStarted?.call() != true) return;
    _popped = true;
    // The signal can arrive mid-build; pop after the frame so we are not
    // tearing down a route from inside its own subtree's build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        // Title only. The step is already named in words; the icon beside
        // it was decoration, and a sparkle beside "Generate from here" read
        // as a claim about the output rather than a label.
        title: Text(
          '${widget.repertoireName} ▸ ${widget.title}',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
      body: widget.child,
    );
  }
}
