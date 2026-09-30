/// What the user chose about updates, and what the app remembers between
/// launches to honour it: when it last asked GitHub and the one version the
/// user said to skip.
final class UpdateChoices {
  const UpdateChoices({
    this.checkAutomatically = true,
    this.downloadAutomatically = true,
    this.lastChecked,
    this.skipped,
  });

  final bool checkAutomatically;
  final bool downloadAutomatically;

  /// When GitHub last answered a check, successful or not.
  final DateTime? lastChecked;

  /// The release tag the user said to skip; a newer one is offered again.
  final String? skipped;

  static const defaults = UpdateChoices();

  UpdateChoices copyWith({
    bool? checkAutomatically,
    bool? downloadAutomatically,
    DateTime? lastChecked,
    String? skipped,
  }) => UpdateChoices(
    checkAutomatically: checkAutomatically ?? this.checkAutomatically,
    downloadAutomatically: downloadAutomatically ?? this.downloadAutomatically,
    lastChecked: lastChecked ?? this.lastChecked,
    skipped: skipped ?? this.skipped,
  );

  Map<String, Object> toJson() => {
    'checkAutomatically': checkAutomatically,
    'downloadAutomatically': downloadAutomatically,
    if (lastChecked case final checked?)
      'lastChecked': checked.toUtc().toIso8601String(),
    'skipped': ?skipped,
  };

  factory UpdateChoices.fromJson(Object? value) {
    if (value is! Map<String, Object?>) return defaults;
    final checked = value['lastChecked'];
    final skipped = value['skipped'];
    return UpdateChoices(
      checkAutomatically: value['checkAutomatically'] is bool
          ? value['checkAutomatically'] as bool
          : true,
      downloadAutomatically: value['downloadAutomatically'] is bool
          ? value['downloadAutomatically'] as bool
          : true,
      lastChecked: checked is String ? DateTime.tryParse(checked) : null,
      skipped: skipped is String ? skipped : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UpdateChoices &&
      checkAutomatically == other.checkAutomatically &&
      downloadAutomatically == other.downloadAutomatically &&
      lastChecked == other.lastChecked &&
      skipped == other.skipped;

  @override
  int get hashCode => Object.hash(
    checkAutomatically,
    downloadAutomatically,
    lastChecked,
    skipped,
  );
}
