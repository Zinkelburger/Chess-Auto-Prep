// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get trainingReloadProgress => 'Reload saved progress';

  @override
  String get trainingProgressPartial =>
      'Training progress may be partly saved. Reload saved progress before training again. History and PGN updates may be incomplete. Reloading does not retry the changes.';

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
      'This folder could not be inspected. Available outputs remain accessible. Try refreshing.';

  @override
  String get generationRecoveryAllSources => 'All retained chapter outputs';

  @override
  String get generationRecoveryNoSources =>
      'No retained chapter namespaces were found in the repertoire library.';

  @override
  String get generationRecoveryDeletedRepertoire =>
      'Deleted chapter files can be recovered here. If the entire repertoire was deleted, restore its folder from library recovery first.';

  @override
  String studyImportJob(String name) {
    return 'Import: $name';
  }

  @override
  String get studyImportStarting => 'Starting…';

  @override
  String get studyImportCancelling => 'Cancelling…';

  @override
  String studyImportFetching(int game, int total) {
    return 'Fetching game $game/$total';
  }

  @override
  String studyImportWaiting(int game, int seconds, int total) {
    return 'Game $game/$total · next in ${seconds}s';
  }

  @override
  String studyImportRetrying(int game, int seconds, int total) {
    return 'Rate-limited — retrying game $game/$total in ${seconds}s';
  }

  @override
  String studyImportDownloaded(int count) {
    return 'Downloaded $count';
  }

  @override
  String studyImportSkipped(String id) {
    return 'Skipped game $id';
  }

  @override
  String studyImportChapters(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chapters',
      one: '1 chapter',
    );
    return '$_temp0';
  }

  @override
  String get studyImportClosed => 'The study importer is closed.';

  @override
  String get studyImportAlreadyRunning =>
      'A collection download is already running.';

  @override
  String get studyImportEmpty => 'No games found in that collection.';

  @override
  String get studyImportInvalidIds => 'Collection game IDs must be numeric.';

  @override
  String get studyImportStartupFailed =>
      'Could not start the collection download. Try again.';

  @override
  String get studyImportDownloadFailed =>
      'Collection download stopped. Downloaded games remain cached.';

  @override
  String get studyImportThrottled =>
      'chessgames.com is refusing requests. Downloaded games are cached — start the same collection again later to resume.';

  @override
  String get studyImportPublicationFailed =>
      'Downloaded games could not be saved. Review the downloaded content or try again later.';

  @override
  String get studyImportPublicationUncertain =>
      'The study save could not be confirmed. Review the destination before retrying.';

  @override
  String get studyImportNameCollisions =>
      'No free study name was found after 100 attempts. Choose another destination for the downloaded games.';

  @override
  String studyImportProgress(int done, int total) {
    return 'Importing $done/$total';
  }

  @override
  String get studyImportStop => 'Stop the download (keeps what has arrived)';

  @override
  String get studyImportReview => 'Review downloaded study';

  @override
  String studyImportBackground(int count, int minutes) {
    return 'Downloading $count games (~$minutes min). chessgames.com is slow on purpose — keep working, it runs in the background.';
  }

  @override
  String studyImportComplete(int count, int failed, String name) {
    return 'Imported $count games into “$name” ($failed unavailable).';
  }

  @override
  String studyImportStopped(int count, String name) {
    return 'Stopped the download. Saved $count chapters into “$name”.';
  }

  @override
  String studyImportNoContent(int failed) {
    return 'No study was saved ($failed games unavailable).';
  }

  @override
  String get studyImportOpen => 'Open';

  @override
  String get studyImportLichessOffline =>
      'Lichess did not respond (rate-limited or offline). Try again shortly.';

  @override
  String get studyImportLichessLogin =>
      'Study not found. If it is private or unlisted, log into Lichess first (Settings → Accounts), then try again.';

  @override
  String get studyImportLichessScope =>
      'Study not found. If it is private, log out and back in to grant study access.';

  @override
  String get studyImportLichessRejected =>
      'Lichess rejected the request. Log out and back in under Settings → Accounts, then try again.';

  @override
  String studyImportLichessUserMissing(String name) {
    return 'No public studies found for “$name”.';
  }

  @override
  String studyImportLichessHttp(int status) {
    return 'Lichess returned HTTP $status.';
  }

  @override
  String get studyImportLichessEmpty =>
      'That study is empty — nothing to import.';

  @override
  String get studyImportUnresolved =>
      'Review the previous downloaded study before starting another import.';

  @override
  String get studyOpenFailed =>
      'Could not open that study. Your current study is unchanged.';

  @override
  String get studyImportReviewAction => 'Review';

  @override
  String get studyImportPgnFailed =>
      'Could not import that PGN. Your study is unchanged.';

  @override
  String get studyListRetry => 'Could not load studies. Retry';

  @override
  String studyImportAdded(int count) {
    return 'Added $count chapters.';
  }

  @override
  String get studyImportApplyFailed =>
      'Could not finish the import. Your existing work is preserved.';

  @override
  String get studyImportNotAccepted =>
      'The import was not accepted. Resolve the active import or study change, then retry. Your download is kept in this dialog.';

  @override
  String builderCopyNeedsVerification(String destination) {
    return 'Copy needs verification: $destination. The draft is retained; this append will not be repeated.';
  }

  @override
  String get builderInspectCopy => 'Inspect copy';

  @override
  String get builderLineSaveFailed => 'Line edits are retained. Saving failed.';

  @override
  String get builderSourceChanged =>
      'The source changed or is missing. Restored edits are a scratch line; save them to an explicit destination.';

  @override
  String get builderSaveDraftCopy => 'Save draft as a new line…';

  @override
  String get builderRetainedDraftsTooltip => 'Retained Builder drafts';

  @override
  String get builderScratch => 'Scratch';

  @override
  String get builderDraftRetained =>
      'The draft is retained. Choose a destination and try saving it again.';

  @override
  String builderRetainedDraftCount(int count) {
    return 'Retained drafts ($count)';
  }

  @override
  String get builderCopyInspectionFailed =>
      'Destination could not be inspected. The copy intent and draft are retained.';

  @override
  String get builderVerifyCopy => 'Verify the saved copy';

  @override
  String get builderVerifyCopyExplanation =>
      'Confirm only if the intended line is present in this observed file. Keeping the draft does not repeat the append.';

  @override
  String get builderKeepDraft => 'Keep draft';

  @override
  String get builderCopyPresent => 'Copy is present';

  @override
  String get builderCopyRetained =>
      'The copy and draft are retained. Inspect the destination before trying again.';

  @override
  String createdChapterPaths(String paths) {
    return 'Saved chapters:\n$paths';
  }

  @override
  String chapterPathsToInspect(String paths) {
    return 'Paths to inspect (writes may be unconfirmed):\n$paths';
  }

  @override
  String get chapterDeleteConfirm =>
      'The chapter will be removed from this folder and kept in recovery storage.';

  @override
  String get chapterDeleteUnsupported =>
      'Verified chapter deletion is unavailable on this device.';

  @override
  String get chapterDeleteReadFailed =>
      'Could not verify this chapter for deletion. Only files in managed app folders can be removed.';

  @override
  String get chapterDeleteMissing =>
      'This chapter is no longer available. Nothing was removed.';

  @override
  String get chapterDeleteConflict =>
      'The chapter changed since deletion was requested. Nothing was removed. Reload it before trying again.';

  @override
  String get chapterDeleteFailed =>
      'The chapter could not be moved to recovery.';

  @override
  String chapterDeleteSaved(String path) {
    return 'Chapter moved to recovery:\n$path';
  }

  @override
  String chapterDeleteUncertain(String paths) {
    return 'Deletion could not be confirmed. Check these locations before taking another action; do not retry automatically:\n$paths';
  }

  @override
  String get chapterDeleteReview => 'Review chapter deletion';

  @override
  String chapterDeleteTitle(String name) {
    return 'Delete chapter \"$name\"?';
  }

  @override
  String chapterDeleteContext(String path, String message) {
    return '$path\n$message';
  }

  @override
  String studyChapterListTitle(int count) {
    return 'Chapters ($count)';
  }

  @override
  String get studyNewChapter => 'New chapter';

  @override
  String get studySearchChapters => 'Search chapters';

  @override
  String get studyFilteredReorder => 'Reordering is off while searching';

  @override
  String get studyDragReorder => 'Drag to reorder';

  @override
  String get studyNoMatchingChapters => 'No matching chapters';

  @override
  String get studyChapterOpenNow => 'Open now';

  @override
  String get studyEditChapter => 'Edit chapter';

  @override
  String get studyDeleteChapter => 'Delete chapter';

  @override
  String get studyKeepOneChapter => 'A study needs at least one chapter';

  @override
  String get studyChapterActions => 'Chapter actions';

  @override
  String get studyChaptersDone => 'Done';

  @override
  String get studyUsePosition => 'Use this position';

  @override
  String get studyInvalidFen => 'That is not a valid FEN.';

  @override
  String get studyPasteGameRequired => 'Paste at least one game.';

  @override
  String get studyName => 'Name';

  @override
  String get studyChapterNameFromPgn => 'From the PGN when left blank';

  @override
  String get studyChapterStartFrom => 'Start from';

  @override
  String get studyInitialPosition => 'Initial position';

  @override
  String get studyPosition => 'Position';

  @override
  String get studyPgn => 'PGN';

  @override
  String get studyFen => 'FEN';

  @override
  String get studySetupBoard => 'Set up board…';

  @override
  String get studyPasteChaptersHint =>
      'Paste PGN. Each game becomes a chapter.';

  @override
  String get studyOrientation => 'Orientation';

  @override
  String get studyAutomaticOrientation => 'Automatic';

  @override
  String get studyCreate => 'Create';

  @override
  String get studyChapterNameRequired => 'A chapter needs a name.';

  @override
  String get studyPgnTags => 'PGN tags';

  @override
  String get studyTag => 'Tag';

  @override
  String get studyTagValue => 'Value';

  @override
  String get studyRemoveTag => 'Remove tag';

  @override
  String get studyAddTag => 'Add tag';

  @override
  String studyInvalidTagName(String tag) {
    return 'Tag names are letters and digits: \"$tag\".';
  }

  @override
  String studyOwnedTag(String tag) {
    return '$tag is written by the study; edit it above.';
  }

  @override
  String studyImportGamesFound(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count games found.',
      one: '1 game found.',
    );
    return '$_temp0';
  }

  @override
  String studyDownloadCount(int count) {
    return 'Download $count';
  }

  @override
  String get studyImportFromUrl => 'Import from URL';

  @override
  String get studyUrl => 'URL';

  @override
  String get studyImportSupportedUrls =>
      'lichess.org/study/<id>  —  one study, all chapters\nlichess.org/study/by/<user>  —  every public study of theirs\nchessgames.com/perl/chesscollection?cid=<id>  —  a collection';

  @override
  String get studyImportAppend =>
      'Add to the current study instead of creating a new one';

  @override
  String get studyImportCollectionSeparate =>
      'A chessgames.com collection downloads in the background and always gets its own study.';

  @override
  String get studyImportNoOpenStudy => 'No study is open.';

  @override
  String get studyImportDelay => 'Seconds between requests (chessgames.com)';

  @override
  String get studyImportDelayHelp =>
      'chessgames.com bans fast downloads: 2–3 s apart gets blocked after ~20 games, 22 s apart sustains 60. At 22 s a 60-game collection takes about 25 minutes, running in the background.';

  @override
  String get studyImportContacting => 'Contacting the server…';

  @override
  String get studyImportLinkHint =>
      'Paste a link to see what will be imported.';

  @override
  String get studyImportUnsupportedUrl =>
      'Not a Lichess study or chessgames.com collection link.';

  @override
  String get studyImportCollectionBlocked => 'Collection page blocked';

  @override
  String get studyImportPasteIdsHelp =>
      'chessgames.com served a bot check instead of the collection. Downloading the games still works — it just needs the list.\n\nOpen the collection in a browser, select all (Ctrl+A) and copy, or save the page source, then paste it below.';

  @override
  String get studyImportOpenCollection => 'Open the collection page';

  @override
  String get studyImportPasteIdsHint =>
      'Paste the page, game links, or game ids…';

  @override
  String get studyImportNoIds => 'No game ids found yet.';

  @override
  String get studyDownload => 'Download';

  @override
  String studyNumberedNew(int count) {
    return 'New study ($count)';
  }

  @override
  String studyChapterCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chapters',
      one: '1 chapter',
    );
    return '$_temp0';
  }

  @override
  String studyPreferredChapterCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chapters',
      one: '1 chapter',
    );
    return 'Prep file · $_temp0';
  }

  @override
  String get studyAddLine => 'Add line to study';

  @override
  String get studyNewStudy => 'New study';

  @override
  String get studyAddNewStudy => 'Add new study';

  @override
  String get studyStudyName => 'Study name';

  @override
  String get studyCreateAndAdd => 'Create and add';

  @override
  String get studyNameRequired => 'Please enter a study name.';

  @override
  String get studyNameExists => 'A study with this name already exists.';

  @override
  String get studyChapterName => 'Chapter name';

  @override
  String get studySearchExisting => 'Search existing studies';

  @override
  String get studyNoStudiesToAdd =>
      'No studies yet. Use Add new study to create one.';

  @override
  String get studyNoStudiesMatch => 'No studies match your search.';

  @override
  String get studyEditChapterMenu => 'Edit chapter…';

  @override
  String get studySetStartMenu => 'Set starting position…';

  @override
  String get studyCopyChapter => 'Copy chapter PGN';

  @override
  String get studyClearAnnotationsMenu => 'Clear comments, glyphs and shapes…';

  @override
  String get studyClearVariationsMenu => 'Clear variations…';

  @override
  String get studyDeleteChapterMenu => 'Delete chapter…';

  @override
  String get studyNoChapters => 'No chapters';

  @override
  String get studyManageChapters => 'Manage & reorder chapters…';

  @override
  String get studyChapter => 'Chapter';

  @override
  String get studyRename => 'Rename study';

  @override
  String get studySwitch => 'Switch study';

  @override
  String get studyNameConfirm => 'OK';

  @override
  String get studyNameUnusable => 'That name has no characters a file can use.';

  @override
  String get studyAddFailed => 'Failed to add to study.';

  @override
  String studyHistoryTitle(String name) {
    return 'Study: $name';
  }

  @override
  String get pgnDeleteOneComment => 'Delete 1 comment?';

  @override
  String get pgnSaveComment => 'Save comment';

  @override
  String get pgnComment => 'Comment';

  @override
  String get pgnCollapseComment => 'Collapse comment';

  @override
  String get pgnEditComment => 'Edit comment';

  @override
  String get pgnCommentKept => 'Comment kept until deleted';

  @override
  String get pgnCommentLabel => 'Comment:';

  @override
  String get pgnDeleteComment => 'Delete comment';

  @override
  String get pgnSelectMoveNotes => 'Select a move to add notes';

  @override
  String pgnRemoveCommentOn(String move) {
    return 'Remove the comment on $move';
  }

  @override
  String get pgnLineCopied => 'Line copied to clipboard';

  @override
  String get pgnMove => 'Move';

  @override
  String get pgnEditCommentMenu => 'Edit Comment';

  @override
  String get pgnAddCommentMenu => 'Add Comment';

  @override
  String get pgnUnmarkQuizStart => 'Unmark Quiz Start';

  @override
  String get pgnMarkQuizStart => 'Start Quiz From This Move';

  @override
  String get pgnUnmarkQuizEnd => 'Unmark Quiz End';

  @override
  String get pgnMarkQuizEnd => 'End Quiz After This Move';

  @override
  String get pgnPromoteVariation => 'Promote Variation';

  @override
  String get pgnMakeMainLine => 'Make Main Line';

  @override
  String get pgnCopyWholeLine => 'Copy Whole Line';

  @override
  String get pgnCopyFromHere => 'Copy PGN from Here';

  @override
  String get pgnViewInLines => 'View in Lines';

  @override
  String get pgnDeleteFromHere => 'Delete from Here';

  @override
  String get pgnLineTitle => 'Line title';

  @override
  String get pgnStartPosition => 'the start position';

  @override
  String get pgnEmptyEditor => 'Play a move or select a saved line.';

  @override
  String get pgnQuizEndHelp => 'Quiz ends here: training stops after this move';

  @override
  String get pgnDeleteContinuations =>
      'This removes the move and all continuations from here, including their annotations.';

  @override
  String get pgnQuizStartHelp =>
      'Quiz starts here: training auto-plays the moves before this one and asks for this one';

  @override
  String get studyBackMove => 'Back one move';

  @override
  String get studyForwardMove => 'Forward one move';

  @override
  String get studyGoStart => 'Go to start';

  @override
  String get studyGoEnd => 'Go to end';

  @override
  String get studyToggleEngine => 'Toggle engine';

  @override
  String get studyFlipBoard => 'Flip board';

  @override
  String get studyBrowsePgn => 'Browse in PGN viewer';

  @override
  String get studyNextChapter => 'Next chapter';

  @override
  String get studyPreviousChapter => 'Previous chapter';

  @override
  String get studyFocusInput => 'Focus move input';

  @override
  String get studyCommentCurrent => 'Comment current move';

  @override
  String get studyImportPgnChapters => 'Import PGN as chapters';

  @override
  String get studyNoPgnGames => 'No games found in that PGN.';

  @override
  String get studyPgnCopied => 'Study PGN copied to clipboard.';

  @override
  String get studyReplacePosition => 'Replace starting position?';

  @override
  String get studyReplace => 'Replace';

  @override
  String get studySetPosition => 'Set chapter position';

  @override
  String get studySaveFirst => 'Save the study first (create it by name).';

  @override
  String get studyNoTrainingChapters => 'No chapters with moves to train yet.';

  @override
  String get studyNoTrainingMoves => 'This chapter has no moves to train yet.';

  @override
  String get studyChapterPgnCopied => 'Chapter PGN copied to clipboard.';

  @override
  String get studyClearAnnotations => 'Clear all comments, glyphs and shapes?';

  @override
  String get clear => 'Clear';

  @override
  String get studyClearVariations => 'Clear variations?';

  @override
  String get studyNeedsChapter => 'A study needs at least one chapter.';

  @override
  String get studyFromUrl => 'From URL…';

  @override
  String get studyPgnFileChapters => 'PGN file as chapters…';

  @override
  String get studyExportHeading => 'Export';

  @override
  String get studyCopyPgn => 'Copy study PGN';

  @override
  String get studySavePgnAs => 'Save study PGN as…';

  @override
  String get studyTrainHeading => 'Train';

  @override
  String get studyTrainChapter => 'Train this chapter';

  @override
  String get studyTrainAll => 'Train whole study';

  @override
  String get studyBoardHeading => 'Board';

  @override
  String get studyExploreHeading => 'Explore';

  @override
  String get studyManageHeading => 'Manage';

  @override
  String get studyDeleteMenu => 'Delete study…';

  @override
  String get studySearch => 'Search studies';

  @override
  String get studyNoStudies => 'No studies yet — import or create one.';

  @override
  String get studyGoChapter => 'Go to chapter';

  @override
  String get studyNoChaptersYet => 'This study has no chapters yet.';

  @override
  String studyAddedChapters(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Added $count chapters.',
      one: 'Added 1 chapter.',
    );
    return '$_temp0';
  }

  @override
  String studyDeleteNamed(String name) {
    return 'Delete study \"$name\"?';
  }

  @override
  String studyDeleteChapterNamed(String name) {
    return 'Delete chapter \"$name\"?';
  }

  @override
  String studyChapterNumber(int number) {
    return 'Chapter $number';
  }

  @override
  String studyPgnHistory(String name) {
    return 'PGN: $name';
  }

  @override
  String get boardInvalidFen => 'Could not parse FEN. Check all fields.';

  @override
  String get boardWhiteToMove => 'White to move';

  @override
  String get boardBlackToMove => 'Black to move';

  @override
  String get boardStartPosition => 'Start position';

  @override
  String get boardClear => 'Clear board';

  @override
  String get boardAdvanced => 'Advanced position settings';

  @override
  String get boardCastlingEnPassant => 'Castling and en passant';

  @override
  String get boardCastling => 'Castling';

  @override
  String get boardEnPassant => 'En passant';

  @override
  String get boardNoEnPassant => 'none';

  @override
  String get boardFenPending =>
      'Apply or discard the FEN text before using this position.';

  @override
  String get boardCopyFen => 'Copy FEN';

  @override
  String get boardFenCopied => 'FEN copied.';

  @override
  String get boardPasteFen => 'Paste FEN';

  @override
  String get boardApplyFen => 'Apply FEN';

  @override
  String get boardDiscardFen => 'Discard FEN changes';

  @override
  String get boardSetupHelp =>
      'Drag pieces where you want them, or click a spare piece and paint it onto squares. Right-click clears a square; with a piece in hand it switches the colour.';

  @override
  String boardCastleSide(String side, String castle) {
    return '$side $castle';
  }

  @override
  String get boardMovePieces => 'Move pieces';

  @override
  String get boardErasePieces => 'Erase pieces';

  @override
  String get boardPiecePawn => 'pawn';

  @override
  String get boardPieceKnight => 'knight';

  @override
  String get boardPieceBishop => 'bishop';

  @override
  String get boardPieceRook => 'rook';

  @override
  String get boardPieceQueen => 'queen';

  @override
  String get boardPieceKing => 'king';

  @override
  String boardPieceName(String side, String piece) {
    return '$side $piece';
  }

  @override
  String boardSpareHelp(String piece) {
    return '$piece: drag onto the board, or click to paint with it';
  }

  @override
  String get copyDone => 'Copied';

  @override
  String get copyAction => 'Copy';

  @override
  String get choiceCloseList => 'Close list';

  @override
  String get choiceShowAll => 'Show all';

  @override
  String get choiceNothing => 'Nothing to choose from';

  @override
  String get choiceNoMatches => 'No matches';

  @override
  String get pgnNotSavedFile => 'Not saved to a file';

  @override
  String get pgnChooseSaveFile => 'Use Save as… to choose a PGN file.';

  @override
  String get pgnAutoSaved => 'Autosave on · Saved';

  @override
  String get pgnManualSaved => 'Autosave off · Saved';

  @override
  String pgnSavingPath(String path) {
    return 'Saving changes to $path';
  }

  @override
  String pgnManualSavePath(String path) {
    return 'Autosave is off. Use Save to write changes to $path';
  }

  @override
  String pgnAutoSavePath(String path) {
    return 'Changes save automatically to $path';
  }

  @override
  String pgnNeedsManualSavePath(String path) {
    return 'Changes need a manual save to $path';
  }

  @override
  String pgnDeleteCounts(int moves, int comments) {
    String _temp0 = intl.Intl.pluralLogic(
      moves,
      locale: localeName,
      other: '$moves moves',
      one: '1 move',
    );
    String _temp1 = intl.Intl.pluralLogic(
      comments,
      locale: localeName,
      other: '$comments comments',
      one: '1 comment',
    );
    return 'Delete $_temp0 and $_temp1?';
  }

  @override
  String studyDeleteContents(int chapters, int moves, int comments) {
    String _temp0 = intl.Intl.pluralLogic(
      chapters,
      locale: localeName,
      other: '$chapters chapters',
      one: '1 chapter',
    );
    String _temp1 = intl.Intl.pluralLogic(
      moves,
      locale: localeName,
      other: '$moves moves',
      one: '1 move',
    );
    String _temp2 = intl.Intl.pluralLogic(
      comments,
      locale: localeName,
      other: '$comments comments',
      one: '1 comment',
    );
    return '$_temp0 with $_temp1 and $_temp2. The PGN file will be moved to Chess Auto Prep recovery trash.';
  }

  @override
  String studyReplacePositionContents(String name) {
    return 'Chapter \"$name\" already has moves; setting a new starting position will clear them.';
  }

  @override
  String studyClearAnnotationContents(int comments, String name) {
    String _temp0 = intl.Intl.pluralLogic(
      comments,
      locale: localeName,
      other: '$comments comments',
      one: '1 comment',
    );
    return 'Remove $_temp0 and all glyphs and shapes from \"$name\". The moves stay.';
  }

  @override
  String studyClearVariationContents(int moves, int comments, String name) {
    String _temp0 = intl.Intl.pluralLogic(
      moves,
      locale: localeName,
      other: '$moves moves',
      one: '1 move',
    );
    String _temp1 = intl.Intl.pluralLogic(
      comments,
      locale: localeName,
      other: '$comments comments',
      one: '1 comment',
    );
    return 'Remove $_temp0 and $_temp1 from \"$name\", including sideline annotations. The main line and its notes stay.';
  }

  @override
  String studyRemoveCounts(int moves, int comments) {
    String _temp0 = intl.Intl.pluralLogic(
      moves,
      locale: localeName,
      other: '$moves moves',
      one: '1 move',
    );
    String _temp1 = intl.Intl.pluralLogic(
      comments,
      locale: localeName,
      other: '$comments comments',
      one: '1 comment',
    );
    return 'Remove $_temp0 and $_temp1, including all annotations.';
  }

  @override
  String studyLichessSource(String id) {
    return 'Lichess study · $id';
  }

  @override
  String studyLichessChapterSource(String study, String chapter) {
    return 'Lichess study chapter · $study/$chapter';
  }

  @override
  String studyLichessUserSource(String user) {
    return 'Lichess · all of $user\'s studies';
  }

  @override
  String studyCollectionSource(String id) {
    return 'chessgames.com collection · cid $id';
  }

  @override
  String get engineAppearanceToggle => 'Toggle engine';

  @override
  String get engineAppearanceEngine => 'Engine';

  @override
  String get engineAppearanceBusy => 'Engine busy';

  @override
  String get engineAppearanceHideThreat => 'Hide threat';

  @override
  String get engineAppearanceShowThreat => 'Show threat';

  @override
  String get engineAppearanceStopAnalysis => 'Stop analysis';

  @override
  String get engineAppearanceStartAnalysis => 'Start analysis';

  @override
  String get engineAppearanceStop => 'Stop';

  @override
  String get engineAppearanceLocalEngine => 'Local engine';

  @override
  String get engineAppearanceOptions => 'Analysis options';

  @override
  String get engineAppearanceNoLegalMoves => 'No legal moves.';

  @override
  String get engineAppearanceAnalyzing => 'Analyzing...';

  @override
  String get engineAppearanceFailure => 'Engine failed. Toggle it to retry.';

  @override
  String get engineAppearanceSettings => 'Engine settings';

  @override
  String get engineAppearanceCollapseLine => 'Collapse line';

  @override
  String get engineAppearanceShowFullLine => 'Show full line';

  @override
  String get engineNoticeLocked =>
      'Stockfish is busy building your repertoire. Pause the build or wait for it to finish before using engine analysis.';

  @override
  String get engineNoticeBusyCompact =>
      'Engine busy — building your repertoire.';

  @override
  String get engineNoticeBusyTitle => 'Engine Busy';

  @override
  String get engineNoticeBusyBody =>
      'Stockfish is building your repertoire.\nPause the build or let it finish to analyze again.';

  @override
  String engineAppearanceSearchStatus(String mode, int depth, String nodes) {
    String _temp0 = intl.Intl.selectLogic(mode, {
      'threat': 'Threat · ',
      'other': '',
    });
    return '${_temp0}Depth $depth • $nodes nodes';
  }

  @override
  String engineAppearanceLinesStatus(String mode, int count, int depth) {
    String _temp0 = intl.Intl.selectLogic(mode, {
      'threat': 'Threat · ',
      'other': '',
    });
    String _temp1 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return '$_temp0$_temp1 • depth $depth';
  }

  @override
  String engineAppearanceDepthStatus(int depth, String nodes) {
    return 'Depth $depth · $nodes nodes';
  }

  @override
  String get boardSetupTitle => 'Set up position';

  @override
  String get boardUsePosition => 'Use position';

  @override
  String get generationSourceChanged =>
      'The chapter changed. Close this configuration and open it again.';

  @override
  String get generationConfigurationRefreshRequired =>
      'Reload the chapter and reopen this configuration before making further changes.';

  @override
  String get generationCutUnconfirmed =>
      'The cut could not be confirmed. Reload the chapter before making further changes.';

  @override
  String generationCutRefreshRequired(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Removed $count lines, but this configuration could not be refreshed. Reload the chapter before making further changes.',
      one:
          'Removed 1 line, but this configuration could not be refreshed. Reload the chapter before making further changes.',
      zero:
          'The chapter could not be refreshed. Reload it and reopen this configuration before making further changes.',
    );
    return '$_temp0';
  }
}
