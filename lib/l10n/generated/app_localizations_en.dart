// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get cancel => 'Cancel';

  @override
  String get retry => 'Retry';

  @override
  String get refresh => 'Refresh';

  @override
  String get restore => 'Restore';

  @override
  String get delete => 'Delete';

  @override
  String get rename => 'Rename';

  @override
  String get importPgn => 'Import PGN';

  @override
  String get importAction => 'Import';

  @override
  String get importing => 'Importing…';

  @override
  String get working => 'Working…';

  @override
  String get white => 'White';

  @override
  String get black => 'Black';

  @override
  String get openPgnFile => 'Open PGN file…';

  @override
  String get pastePgn => 'Paste PGN';

  @override
  String get clearSearch => 'Clear search';

  @override
  String get createRepertoire => 'Create repertoire';

  @override
  String get createNewRepertoire => 'Create new repertoire';

  @override
  String get creationHeading => 'Bring your lines. Start training.';

  @override
  String get repertoireName => 'Repertoire name';

  @override
  String get repertoireNameHint => 'My Sicilian';

  @override
  String get playingSide => 'Playing side';

  @override
  String get emptyRepertoire => 'Empty repertoire';

  @override
  String get emptyRepertoireHelp =>
      'Create a place for chapters and lines. Add moves before training.';

  @override
  String get pgnMoves => 'PGN moves';

  @override
  String get pgnPasteHint => 'Paste your PGN here';

  @override
  String get pgnExample => '1. e4 e5 2. Nf3 Nc6…';

  @override
  String get pasteHelp =>
      'Add your moves now. You can rename the repertoire later.';

  @override
  String get fileReadFailed => 'Could not read that file.';

  @override
  String get fileOpenFailed => 'Could not open that file. Try again.';

  @override
  String get creationNeedsMoves => 'Open or paste a PGN with moves to train.';

  @override
  String get importNeedsMoves => 'That PGN has no moves to train.';

  @override
  String get pasteNeedsMoves => 'Paste PGN with moves to train.';

  @override
  String get creationFailed =>
      'Could not create the repertoire. Your input is still here; try again.';

  @override
  String get importFailed =>
      'Could not import the repertoire. Please try again.';

  @override
  String get pasteFailed =>
      'Could not import. Your PGN is still here; try again.';

  @override
  String repertoireExists(String name) {
    return 'A repertoire named \"$name\" already exists.';
  }

  @override
  String get creationUncertain =>
      'The file may already be saved. Keep this draft and reload the library before retrying.';

  @override
  String get preparationFailed =>
      'Import preparation failed. No repertoire was published. Keep this draft and retry.';

  @override
  String get recoveryRequired =>
      'The folder may have moved, but its references could not be confirmed. Reload the library to recover this operation before making another change.';

  @override
  String get catalogLoadFailed =>
      'Could not load repertoires. Please try again.';

  @override
  String get recoverLibrary => 'Recover library';

  @override
  String get restoreFailed =>
      'Restore failed. Your recovery files are retained. Refresh the list or choose another name.';

  @override
  String get recoveryEmpty => 'Recovery is empty';

  @override
  String get recoveryEmptyHelp => 'Deleted repertoires will appear here.';

  @override
  String get recoveryFilesChanged => 'Recovery files are missing or changed';

  @override
  String deletedAt(String time) {
    return 'Deleted $time';
  }

  @override
  String get catalogEmpty => 'No repertoires yet';

  @override
  String get catalogEmptyHelp =>
      'Open a PGN file or create a repertoire to get started.';

  @override
  String nothingMatches(String query) {
    return 'Nothing matches \"$query\".';
  }

  @override
  String get repertoires => 'Repertoires';

  @override
  String get studiesTactics => 'Studies — custom tactics';

  @override
  String get repertoireRecovery => 'Repertoire recovery';

  @override
  String get yourRepertoires => 'Your repertoires';

  @override
  String get backToLibrary => 'Back to library';

  @override
  String get recovery => 'Recovery';

  @override
  String get searchRepertoires => 'Search repertoires';

  @override
  String chapterCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString chapters',
      one: '1 chapter',
    );
    return '$_temp0';
  }

  @override
  String repertoireDetails(String chapters, String time) {
    return '$chapters · Modified $time';
  }

  @override
  String get browseChapters => 'Browse chapters';

  @override
  String get renameRepertoire => 'Rename repertoire';

  @override
  String get deleteRepertoire => 'Delete repertoire';

  @override
  String createdRepertoire(String name) {
    return 'Created “$name”. Add moves before training.';
  }

  @override
  String importedRepertoire(String name) {
    return 'Imported “$name”. Rename it from your repertoire list.';
  }

  @override
  String get restoreRepertoire => 'Restore repertoire';

  @override
  String get restoreNamePrompt => 'Choose a name for the restored repertoire:';

  @override
  String get duplicateRepertoireName =>
      'A repertoire with this name already exists.';

  @override
  String deleteRepertoirePrompt(String name) {
    return 'Delete repertoire \"$name\"?';
  }

  @override
  String get deleteRepertoireHelp =>
      'Its files and training history will be kept. Restore it from Recovery in the library.';

  @override
  String get deleteLegacyRepertoireHelp =>
      'Its files will be moved to Chess Auto Prep recovery trash.';

  @override
  String get deleteRepertoireFailed => 'Could not delete repertoire.';

  @override
  String get renameRepertoirePrompt => 'Enter new name for the repertoire:';

  @override
  String get renameRepertoireFailed => 'Could not rename repertoire.';

  @override
  String get nameRequired => 'Please enter a name.';

  @override
  String get nameTrailingDotOrSpace => 'Names cannot end with a dot or space.';

  @override
  String get nameReserved => 'That name is reserved.';

  @override
  String get nameIllegalCharacters =>
      'Names cannot contain < > : \" / \\ | ? * or control characters.';

  @override
  String get nameSystemReserved =>
      'That name is reserved by the operating system.';

  @override
  String nameTooLong(int maxLength) {
    final intl.NumberFormat maxLengthNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String maxLengthString = maxLengthNumberFormat.format(maxLength);

    return 'Names must be $maxLengthString characters or fewer.';
  }

  @override
  String get justNow => 'just now';

  @override
  String minutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}m ago';
  }

  @override
  String hoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}h ago';
  }

  @override
  String daysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}d ago';
  }

  @override
  String get saveChanges => 'Save';

  @override
  String get saveCopy => 'Save a copy…';

  @override
  String get keepEditing => 'Keep editing';

  @override
  String get inspectCurrentDocument => 'Inspect current file';

  @override
  String get reloadPreservingDraft => 'Reload and keep draft';

  @override
  String get restoreRetainedDraft => 'Restore retained draft';

  @override
  String get documentClean => 'No unsaved changes';

  @override
  String get documentDirty => 'Unsaved changes';

  @override
  String get documentSaving => 'Saving…';

  @override
  String get documentSaved => 'Saved';

  @override
  String get documentReloading => 'Reading current file…';

  @override
  String get documentConflict =>
      'The file changed or was removed. Your draft is unchanged. Inspect the current file or save a copy.';

  @override
  String get documentCollision =>
      'That destination already exists. Nothing was replaced. Choose another name for your copy.';

  @override
  String get documentSaveFailed =>
      'Could not save. Your draft is unchanged. You can retry or save a copy.';

  @override
  String get documentSaveUncertain =>
      'The file may have been saved. Your draft is retained. Inspect and reload before saving again, or save a copy.';

  @override
  String get documentReadFailed =>
      'Could not read the current file. Your draft and loaded revision are unchanged.';

  @override
  String get documentMissing =>
      'The file no longer exists. Your draft is unchanged.';

  @override
  String get documentDraftRetained =>
      'Your previous draft is kept in this session. Restore it or save it before closing the document.';

  @override
  String get chooseAnotherName => 'Choose another name';

  @override
  String get closeDocumentInspection => 'Close';

  @override
  String get copyDestination => 'Copy destination';

  @override
  String restoreRetainedDraftNumber(int number) {
    return 'Restore draft $number';
  }

  @override
  String get backToPreviousView => 'Back to previous view';

  @override
  String get selectRepertoire => 'Select repertoire';

  @override
  String get back => 'Back';

  @override
  String get appearance => 'Appearance';

  @override
  String get appearanceDark => 'Dark';

  @override
  String get appearanceLight => 'Light';

  @override
  String get appearanceSystem => 'System';

  @override
  String get appearanceLoading => 'Loading appearance…';

  @override
  String get appearanceSaving => 'Saving appearance…';

  @override
  String get appearanceFailed =>
      'Could not confirm the appearance setting. Your last confirmed appearance is still applied.';

  @override
  String get appearanceReload => 'Reload saved choice';

  @override
  String get appearanceSystemHelp =>
      'System follows your desktop’s light or dark appearance.';

  @override
  String get studySaveRecovery => 'Save and recovery…';

  @override
  String get studyCopyName => 'Copy name';

  @override
  String get studyCopyPrompt =>
      'The copy will open as your current study. The original file is kept.';

  @override
  String studyCopyInitial(String name) {
    return '$name copy';
  }

  @override
  String studySaveDialogTitle(String name) {
    return 'Save $name';
  }

  @override
  String get studyExportTitle => 'Export study PGN';

  @override
  String get studyExportDirectory => 'Choose export folder';

  @override
  String get studyExportName => 'File name';

  @override
  String get studyInvalidName =>
      'Enter a file name without path separators or reserved characters.';

  @override
  String get closeApplicationTitle => 'Close application?';

  @override
  String get keepApplicationOpen => 'Keep app open';

  @override
  String get documentChangedWhileClosing =>
      'A document changed while closing. The app has stayed open so you can review the latest changes.';

  @override
  String get documentCloseFailed =>
      'The close request could not finish. The app has stayed open. Review any save or recovery errors, then try again.';

  @override
  String get windowCloseUnavailable =>
      'Close protection could not start. Save your changes before closing the window.';

  @override
  String get studyCloseUnsaved =>
      'This study has unsaved changes or retained drafts. Save the work you want to keep before closing.';

  @override
  String get studyCloseReady => 'Your study is saved. You can close the app.';

  @override
  String get closeWithoutSaving => 'Close without saving';

  @override
  String get closeApplication => 'Close application';

  @override
  String get documentCopyPrompt =>
      'Choose a new PGN filename. Existing files are kept.';

  @override
  String get documentCopyName => 'File name';

  @override
  String get documentCopyFolder => 'Folder';

  @override
  String get documentBrowseFolder => 'Browse folders';

  @override
  String get documentCopyInvalidName => 'Enter a file name without folders.';

  @override
  String get documentCopyInvalidFolder => 'Enter an absolute folder path.';

  @override
  String get documentFolderPickerFailed =>
      'The folder picker could not open. You can enter the folder path.';

  @override
  String get documentSaveRecovery => 'Save and recovery…';

  @override
  String get documentCollectionSaveTitle => 'Save PGN collection';

  @override
  String get documentExportTitle => 'Export PGN collection';

  @override
  String get documentOpenExport => 'Open';

  @override
  String documentExported(String name) {
    return 'Exported $name';
  }

  @override
  String workspaceRecoveryTitle(String workspace) {
    return 'Recover $workspace work';
  }

  @override
  String get workspaceRecoveryExplanation =>
      'These checkpoints contain work from previous sessions. Restoring opens the captured draft without writing to its original file. Save or make a copy after reviewing it.';

  @override
  String get workspaceRecoveryActionFailed =>
      'Recovery could not finish. Your checkpoint is still preserved. Retry or save the current draft as a copy.';

  @override
  String get restoreWorkspaceRecovery => 'Restore draft';

  @override
  String get dismissWorkspaceRecovery => 'Dismiss recovery';

  @override
  String get dismissWorkspaceRecoveryQuestion =>
      'Remove this checkpoint from the recovery list? Its archived bytes remain on disk, but the app will no longer offer to restore it.';

  @override
  String workspaceRecoveryUnavailable(String workspace) {
    return '$workspace recovery is unavailable. Save your work explicitly; recent edits may not survive a restart.';
  }

  @override
  String workspaceRecoveryUnreadable(String workspace) {
    return 'Some $workspace recovery files could not be read. Their files have been preserved.';
  }

  @override
  String workspaceRecoveryAvailable(String workspace, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$workspace work from $count previous sessions is available.',
      one: '$workspace work from a previous session is available.',
    );
    return '$_temp0';
  }

  @override
  String get reviewWorkspaceRecovery => 'Review recovery';

  @override
  String get retryWorkspaceRecovery => 'Retry recovery';

  @override
  String workspaceRecoveryTimestamp(String date, String time) {
    return '$date · $time';
  }

  @override
  String get studyWorkspaceName => 'Study';

  @override
  String get pgnWorkspaceName => 'PGN Viewer';

  @override
  String get untitledPgnWorkspace => 'Untitled PGN';

  @override
  String get generationRecoveryTitle => 'Recover generated outputs';

  @override
  String get generationRecoveryAction => 'Recover generated outputs…';

  @override
  String get generationRecoveryProvenance =>
      'These older files have no recorded source revision. Inspect or export them here; they do not replace the current chapter or its verified analysis. Original files stay unchanged.';

  @override
  String get generationRecoveryTree => 'Saved tree';

  @override
  String get generationRecoveryProbes => 'Saved probes';

  @override
  String get generationRecoveryTraps => 'Saved traps';

  @override
  String get generationRecoveryPartial => 'Unfinished build';

  @override
  String get generationRecoveryExport => 'Export original file…';

  @override
  String get generationRecoveryExportDirectory =>
      'Choose a folder for the recovered file';

  @override
  String get generationRecoveryEmpty =>
      'No saved files were found in this output. Choose another retained output or refresh.';

  @override
  String get generationRecoverySelect =>
      'Select a saved artifact to inspect its contents.';

  @override
  String get generationRecoveryNoEntries => 'No saved entries';

  @override
  String get generationRecoveryUnreadable => 'Could not read this entry';

  @override
  String get generationRecoveryResumeUnavailable =>
      'Automatic resume is unavailable: this unfinished build has no verifiable source revision. You can inspect its explored positions, export the original file, or start a fresh build from the chapter.';

  @override
  String get generationRecoveryConfig => 'Saved configuration';

  @override
  String get generationRecoveryParent => 'Previous position';

  @override
  String generationRecoveryExported(String path) {
    return 'Original file exported to $path';
  }

  @override
  String generationRecoveryEntry(int number) {
    return 'Entry $number';
  }

  @override
  String generationRecoveryNodes(int nodes, int depth) {
    return '$nodes saved nodes · depth $depth';
  }

  @override
  String get generationRecoveryDiagnostics => 'Technical details';

  @override
  String get generationRecoveryLoadFailed =>
      'Saved outputs could not be loaded. Try refreshing.';

  @override
  String get generationRecoveryReadFailed =>
      'This file could not be read safely. Other saved files remain available.';

  @override
  String get generationRecoveryDecodeFailed =>
      'This entry could not be decoded. You can still export its original file.';

  @override
  String get generationRecoveryCollision =>
      'A file already exists at that destination. Choose a different location; nothing was replaced.';

  @override
  String get generationRecoveryExportFailed =>
      'The original file could not be exported. Choose another location or try again.';

  @override
  String get generationRecoveryExportUncertain =>
      'The export may have been saved, but completion could not be confirmed. Inspect the destination below before trying again.';

  @override
  String generationRecoveryDestination(String path) {
    return 'Destination: $path';
  }

  @override
  String get generationRecoveryPopularMove => 'Popular reply';

  @override
  String get generationRecoveryBestMove => 'Best reply';

  @override
  String get generationRecoveryProbability => 'Move probability';

  @override
  String get generationRecoveryGain => 'Evaluation gain';

  @override
  String get generationRecoveryEvaluation => 'Evaluation (side to move)';

  @override
  String get generationRecoveryExpectedScore => 'Expected score';

  @override
  String get generationRecoveryPv => 'Engine principal variation (UCI)';

  @override
  String get generationRecoveryNotSaved => 'Not saved';

  @override
  String get generationRecoveryReadOnly =>
      'Inspect or export saved outputs. Recovery does not change the chapter, select analysis or resume a build. Original files stay unchanged.';

  @override
  String get generationRecoveryChooseOutput => 'Choose saved output';

  @override
  String get generationRecoveryLegacyFiles => 'Older files beside this chapter';

  @override
  String get generationRecoveryCourse => 'Generated PGN proposal';

  @override
  String get generationRecoveryModelGames => 'Model games';

  @override
  String get generationRecoveryManifest => 'Run record';

  @override
  String get generationRecoveryReceipt => 'Publication receipt';

  @override
  String get generationRecoveryRun => 'Recorded run';

  @override
  String get generationRecoverySource => 'Recorded source';

  @override
  String get generationRecoverySourceUnknown =>
      'The source revision was not recorded or could not be decoded.';

  @override
  String get generationRecoverySourceMatches =>
      'The recorded source revision matches the chapter observed now. This alone does not verify the saved analysis.';

  @override
  String get generationRecoverySourceChanged =>
      'The recorded source differs from the chapter observed now.';

  @override
  String get generationRecoverySourceUnavailable =>
      'The current chapter could not be read, so its source revision could not be compared.';

  @override
  String get generationRecoverySelectionNames =>
      'The current selection record names this output. Recovery does not certify it as current analysis.';

  @override
  String get generationRecoverySelectionUnknown =>
      'No current selection evidence was found for this output. It may have been selected previously.';

  @override
  String get generationRecoveryReceiptAbsent =>
      'No publication receipt was found. The PGN write may still have succeeded; inspect the chapter before generating again.';

  @override
  String get generationRecoveryReceiptPresent =>
      'A publication receipt was recorded. It does not prove that this output is the current chapter.';

  @override
  String get generationRecoveryReceiptUnreadable =>
      'A publication receipt exists but could not be verified. The PGN write may have succeeded.';

  @override
  String get generationRecoveryResumeRetained =>
      'Recovery does not resume retained builds. Use the normal generation flow only when its current source and saved configuration are validated.';

  @override
  String get generationRecoveryIntegrityChanged =>
      'This file differs from its recorded checksum. Inspect or export it as edited data.';

  @override
  String get generationRecoveryIntegrityMatches =>
      'This file matches the checksum in its run record; that record is not proof of publication.';

  @override
  String get generationRecoveryListFailed =>
      'Retained outputs could not be listed. Older files remain accessible. Try refreshing.';
}
