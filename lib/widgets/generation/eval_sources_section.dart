import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/eval_database_settings.dart';
import '../../services/eval/chessdb_api_provider.dart';
import '../../services/eval/sqlite_eval_provider.dart';
import '../../theme/app_colors.dart';

/// Advanced eval-source controls for repertoire tree generation.
class EvalSourcesSection extends StatefulWidget {
  final bool isGenerating;
  final bool cdbDirectAvailable;
  final VoidCallback? onChanged;

  const EvalSourcesSection({
    super.key,
    required this.isGenerating,
    required this.cdbDirectAvailable,
    this.onChanged,
  });

  @override
  State<EvalSourcesSection> createState() => EvalSourcesSectionState();
}

class EvalSourcesSectionState extends State<EvalSourcesSection> {
  bool _batchEvalLookups = false;
  bool _enableLocalChessDb = false;
  final TextEditingController _localChessDbPathCtrl = TextEditingController();
  bool? _localChessDbValid;
  bool _enableChessDbApi = false;
  final TextEditingController _chessDbQuotaCtrl =
      TextEditingController(text: '5000');
  final TextEditingController _chessDbConcurrencyCtrl =
      TextEditingController(text: '2');
  bool _enableExtEvalSubtreeSkip = true;
  final TextEditingController _minAcceptableEvalDepthCtrl =
      TextEditingController(text: '');
  int _chessDbApiUsedToday = 0;
  int _chessDbApiQuotaLimit = 5000;

  bool get batchEvalLookups => _batchEvalLookups;
  bool get enableLocalChessDb => _enableLocalChessDb;
  String get localChessDbPath => _localChessDbPathCtrl.text.trim();
  bool get enableChessDbApi => _enableChessDbApi;
  int get chessDbApiDailyQuota =>
      (int.tryParse(_chessDbQuotaCtrl.text.trim()) ?? 5000).clamp(1, 50000);
  int get chessDbApiConcurrency =>
      (int.tryParse(_chessDbConcurrencyCtrl.text.trim()) ?? 2).clamp(1, 16);
  bool get enableExtEvalSubtreeSkip => _enableExtEvalSubtreeSkip;
  String get minAcceptableEvalDepthRaw =>
      _minAcceptableEvalDepthCtrl.text.trim();

  @override
  void initState() {
    super.initState();
    EvalDatabaseSettings.instance.load();
    _refreshChessDbQuotaDisplay();
  }

  @override
  void dispose() {
    _localChessDbPathCtrl.dispose();
    _chessDbQuotaCtrl.dispose();
    _chessDbConcurrencyCtrl.dispose();
    _minAcceptableEvalDepthCtrl.dispose();
    super.dispose();
  }

  void updateChessDbApiUsage(int usedToday, int quotaLimit) {
    if (!mounted) return;
    if (_chessDbApiUsedToday == usedToday &&
        _chessDbApiQuotaLimit == quotaLimit) {
      return;
    }
    setState(() {
      _chessDbApiUsedToday = usedToday;
      _chessDbApiQuotaLimit = quotaLimit;
    });
  }

  void resetChessDbApiUsageForBuild(int quotaLimit) {
    if (!mounted) return;
    setState(() {
      _chessDbApiQuotaLimit = quotaLimit;
      _chessDbApiUsedToday = 0;
    });
  }

  Future<void> _refreshChessDbQuotaDisplay() async {
    final quota = int.tryParse(_chessDbQuotaCtrl.text.trim()) ?? 5000;
    final api = ChessDbApiProvider(dailyQuota: quota);
    await api.init();
    if (!mounted) return;
    setState(() {
      _chessDbApiUsedToday = api.usedToday;
      _chessDbApiQuotaLimit = api.quotaLimit;
    });
  }

  void _notifyChanged() => widget.onChanged?.call();

  void _update(VoidCallback fn) {
    setState(fn);
    _notifyChanged();
  }

  Future<void> _pickLocalChessDbFile() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select ChessDB SQLite file',
      type: FileType.custom,
      allowedExtensions: ['db'],
      lockParentWindow: true,
    );
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;
    final valid = await validateChessDbEvalFile(path);
    if (!mounted) return;
    _update(() {
      _localChessDbPathCtrl.text = path;
      _localChessDbValid = valid;
      if (valid) _enableLocalChessDb = true;
    });
  }

  Widget _numField(
    TextEditingController controller,
    String label, {
    String? tooltip,
    bool enabled = true,
  }) {
    final field = SizedBox(
      width: 170,
      child: TextField(
        controller: controller,
        enabled: enabled && !widget.isGenerating,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
    if (tooltip == null) return field;
    return Tooltip(message: tooltip, child: field);
  }

  Widget _toggleSwitch(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    String? tooltip,
  }) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 4),
        Switch(
          value: value,
          onChanged: widget.isGenerating ? null : onChanged,
        ),
      ],
    );
    if (tooltip == null) return row;
    return Tooltip(message: tooltip, child: row);
  }

  @override
  Widget build(BuildContext context) {
    final localFieldsEnabled = _enableLocalChessDb && !widget.isGenerating;
    final apiFieldsEnabled = _enableChessDbApi && !widget.isGenerating;
    final path = _localChessDbPathCtrl.text;

    Widget? pathStatusIcon;
    if (path.isNotEmpty && _localChessDbValid != null) {
      pathStatusIcon = Tooltip(
        message: _localChessDbValid!
            ? 'Valid ChessDB database'
            : 'Not a valid ChessDB eval database (missing chessdb_evals table)',
        child: Icon(
          _localChessDbValid! ? Icons.check_circle : Icons.warning_amber,
          size: 18,
          color:
              _localChessDbValid! ? AppColors.evalPositive : AppColors.danger,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Eval Sources',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(width: 4),
            Tooltip(
              message: widget.cdbDirectAvailable
                  ? 'Optional eval lookup chain before Stockfish:\n'
                      'project cache → cdbdirect full dump → local SQLite → API → engine.\n'
                      'On HDD, enable read-ahead and batch lookups for cdbdirect.'
                  : 'Optional eval lookup chain before Stockfish:\n'
                      'project cache → local SQLite → API → engine.',
              child:
                  Icon(Icons.info_outline, size: 16, color: Colors.grey[500]),
            ),
          ],
        ),
        const SizedBox(height: 8),

        if (widget.cdbDirectAvailable)
          ListenableBuilder(
            listenable: EvalDatabaseSettings.instance,
            builder: (context, _) {
              final dbSettings = EvalDatabaseSettings.instance;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  dbSettings.enableCdbDirect
                      ? Icons.storage
                      : Icons.storage_outlined,
                  color: dbSettings.enableCdbDirect
                      ? AppColors.evalPositive
                      : Colors.grey,
                ),
                title: const Text('Local ChessDB (full dump)',
                    style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  dbSettings.enableCdbDirect &&
                          dbSettings.cdbDirectPath.isNotEmpty
                      ? dbSettings.cdbDirectPath
                      : 'Configure in Actions → Database Downloads',
                  style: const TextStyle(fontSize: 11),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                dense: true,
              );
            },
          ),
        if (widget.cdbDirectAvailable)
          Wrap(
            spacing: 16,
            children: [
              FilterChip(
                label: const Text('Batch eval lookups'),
                selected: _batchEvalLookups,
                onSelected: widget.isGenerating
                    ? null
                    : (v) => _update(() => _batchEvalLookups = v),
              ),
            ],
          ),
        if (widget.cdbDirectAvailable) const SizedBox(height: 12),

        _toggleSwitch(
          'Local ChessDB file',
          _enableLocalChessDb,
          (v) => _update(() => _enableLocalChessDb = v),
          tooltip:
              'Use a local ChessDB SQLite slice for eval lookups.\n'
              'Positions missing from the file can trigger subtree skip.',
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                readOnly: true,
                enabled: !widget.isGenerating,
                controller: _localChessDbPathCtrl,
                decoration: InputDecoration(
                  labelText: 'Database path (.db)',
                  hintText: 'No file selected',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: pathStatusIcon,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: 'Browse for a ChessDB .db file',
              child: IconButton(
                onPressed: localFieldsEnabled ? _pickLocalChessDbFile : null,
                icon: const Icon(Icons.folder_open),
              ),
            ),
            if (path.isNotEmpty)
              Tooltip(
                message: 'Clear path',
                child: IconButton(
                  onPressed: widget.isGenerating
                      ? null
                      : () => _update(() {
                            _localChessDbPathCtrl.clear();
                            _localChessDbValid = null;
                          }),
                  icon: const Icon(Icons.clear),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),

        _toggleSwitch(
          'ChessDB API',
          _enableChessDbApi,
          (v) => _update(() => _enableChessDbApi = v),
          tooltip:
              'Query chessdb.cn for positions not in local cache.\n'
              'Subject to a configurable daily request quota.',
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _numField(
              _chessDbQuotaCtrl,
              'Daily quota',
              tooltip: 'Maximum ChessDB API requests per day (1–50000)',
              enabled: apiFieldsEnabled,
            ),
            _numField(
              _chessDbConcurrencyCtrl,
              'Concurrency',
              tooltip: 'Parallel ChessDB API requests during build (1–16)',
              enabled: apiFieldsEnabled,
            ),
            Text(
              '$_chessDbApiUsedToday / $_chessDbApiQuotaLimit requests used today',
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
          ],
        ),
        const SizedBox(height: 12),

        _toggleSwitch(
          'Skip external eval for off-book subtrees',
          _enableExtEvalSubtreeSkip,
          (v) => _update(() => _enableExtEvalSubtreeSkip = v),
          tooltip:
              'When a position is absent from the local ChessDB file,\n'
              'skip further external lookups for that subtree and use Stockfish.',
        ),
        const SizedBox(height: 8),
        _numField(
          _minAcceptableEvalDepthCtrl,
          'Min eval depth (0 = engine depth)',
          tooltip:
              'Minimum search depth required from external sources.\n'
              'Shallower hits fall through to the next source.',
          enabled: !widget.isGenerating,
        ),
      ],
    );
  }
}
