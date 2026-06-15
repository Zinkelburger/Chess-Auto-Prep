/// User-arrangeable column/stack layout for [EditContextZone].
library;

import 'package:chess_auto_prep/widgets/layout/repertoire_mode.dart';

EditContextView? _viewFromName(String name) {
  for (final v in EditContextView.values) {
    if (v.name == name) return v;
  }
  return null;
}

/// One horizontal pane with a vertical stack of context views.
class EditContextColumnLayout {
  final List<EditContextView> views;
  final double horizontalFlex;
  final List<double> verticalFlex;

  const EditContextColumnLayout({
    required this.views,
    this.horizontalFlex = 1,
    List<double>? verticalFlex,
  }) : verticalFlex = verticalFlex ?? const [];

  EditContextColumnLayout copyWith({
    List<EditContextView>? views,
    double? horizontalFlex,
    List<double>? verticalFlex,
  }) {
    return EditContextColumnLayout(
      views: views ?? this.views,
      horizontalFlex: horizontalFlex ?? this.horizontalFlex,
      verticalFlex: verticalFlex ?? this.verticalFlex,
    );
  }

  List<double> normalizedVerticalFlex() {
    if (views.isEmpty) return const [];
    if (verticalFlex.length == views.length) {
      final sum = verticalFlex.fold<double>(0, (a, b) => a + b);
      if (sum > 0) return verticalFlex.map((f) => f / sum).toList();
    }
    return List<double>.filled(views.length, 1 / views.length);
  }

  Map<String, dynamic> toJson() => {
        'views': views.map((v) => v.name).toList(),
        'hFlex': horizontalFlex,
        if (verticalFlex.isNotEmpty) 'vFlex': verticalFlex,
      };

  factory EditContextColumnLayout.fromJson(Map<String, dynamic> json) {
    final rawViews = json['views'] as List<dynamic>? ?? const [];
    final views = <EditContextView>[];
    for (final name in rawViews) {
      final v = _viewFromName(name.toString());
      if (v != null && !views.contains(v)) views.add(v);
    }
    final vFlex = (json['vFlex'] as List<dynamic>?)
        ?.map((e) => (e as num).toDouble())
        .toList();
    return EditContextColumnLayout(
      views: views,
      horizontalFlex: (json['hFlex'] as num?)?.toDouble() ?? 1,
      verticalFlex: vFlex,
    );
  }
}

/// Full layout: 1–N resizable columns, each with a vertical view stack.
class EditContextLayout {
  final List<EditContextColumnLayout> columns;

  const EditContextLayout({required this.columns});

  /// Default placement when no saved layout exists.
  static EditContextLayout get defaultLayout => EditContextLayout(
        columns: [
          EditContextColumnLayout(
            views: [
              EditContextView.browse,
              EditContextView.engine,
              EditContextView.expectimax,
              EditContextView.tree,
            ],
            horizontalFlex: 1,
          ),
          EditContextColumnLayout(
            views: [EditContextView.lines],
            horizontalFlex: 0.42,
          ),
        ],
      );

  Set<EditContextView> get allPlacedViews =>
      columns.expand((c) => c.views).toSet();

  List<double> normalizedHorizontalFlex() {
    if (columns.isEmpty) return const [];
    final flexes = columns.map((c) => c.horizontalFlex).toList();
    final sum = flexes.fold<double>(0, (a, b) => a + b);
    if (sum <= 0) {
      return List<double>.filled(columns.length, 1 / columns.length);
    }
    return flexes.map((f) => f / sum).toList();
  }

  /// Ensures every [visible] view appears exactly once; preserves order where possible.
  EditContextLayout syncVisible(Set<EditContextView> visible) {
    final placed = <EditContextView>[];
    final newColumns = <EditContextColumnLayout>[];

    for (final col in columns) {
      final kept = <EditContextView>[];
      for (final v in col.views) {
        if (visible.contains(v) && !placed.contains(v)) {
          kept.add(v);
          placed.add(v);
        }
      }
      if (kept.isNotEmpty) {
        newColumns.add(col.copyWith(views: kept));
      }
    }

    for (final v in visible) {
      if (!placed.contains(v)) {
        if (newColumns.isEmpty) {
          newColumns.add(EditContextColumnLayout(views: [v]));
        } else {
          final last = newColumns.last;
          newColumns[newColumns.length - 1] =
              last.copyWith(views: [...last.views, v]);
        }
        placed.add(v);
      }
    }

    if (newColumns.isEmpty && visible.isNotEmpty) {
      return EditContextLayout(
        columns: [EditContextColumnLayout(views: visible.toList())],
      );
    }

    return EditContextLayout(columns: newColumns);
  }

  EditContextLayout placeView(
    EditContextView view, {
    required int columnIndex,
    int? stackIndex,
  }) {
    var cols = columns
        .map(
          (c) => c.copyWith(
            views: c.views.where((v) => v != view).toList(),
          ),
        )
        .where((c) => c.views.isNotEmpty)
        .toList();

    if (columnIndex < 0) columnIndex = 0;
    if (columnIndex > cols.length) columnIndex = cols.length;

    if (columnIndex == cols.length) {
      cols = [
        ...cols,
        EditContextColumnLayout(views: [view])
      ];
      return EditContextLayout(columns: cols);
    }

    final col = cols[columnIndex];
    final views = List<EditContextView>.from(col.views);
    final idx = stackIndex?.clamp(0, views.length) ?? views.length;
    views.insert(idx, view);
    cols[columnIndex] = col.copyWith(views: views);
    return EditContextLayout(columns: cols);
  }

  EditContextLayout addColumn() {
    return EditContextLayout(
      columns: [...columns, const EditContextColumnLayout(views: [])],
    );
  }

  EditContextLayout setHorizontalFlex(int columnIndex, double flex) {
    if (columnIndex < 0 || columnIndex >= columns.length) return this;
    final cols = List<EditContextColumnLayout>.from(columns);
    cols[columnIndex] = cols[columnIndex].copyWith(horizontalFlex: flex);
    return EditContextLayout(columns: cols);
  }

  EditContextLayout setVerticalFlex(
    int columnIndex,
    List<double> flex,
  ) {
    if (columnIndex < 0 || columnIndex >= columns.length) return this;
    final cols = List<EditContextColumnLayout>.from(columns);
    cols[columnIndex] = cols[columnIndex].copyWith(verticalFlex: flex);
    return EditContextLayout(columns: cols);
  }

  Map<String, dynamic> toJson() => {
        'columns': columns.map((c) => c.toJson()).toList(),
      };

  factory EditContextLayout.fromJson(Map<String, dynamic> json) {
    final raw = json['columns'] as List<dynamic>? ?? const [];
    final cols = raw
        .map((e) => EditContextColumnLayout.fromJson(
              Map<String, dynamic>.from(e as Map),
            ))
        .where((c) => c.views.isNotEmpty)
        .toList();
    if (cols.isEmpty) return defaultLayout;
    return EditContextLayout(columns: cols);
  }
}
