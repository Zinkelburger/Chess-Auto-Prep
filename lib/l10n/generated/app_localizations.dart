import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// Recovery action after a possibly partial training progress write.
  ///
  /// In en, this message translates to:
  /// **'Reload saved progress'**
  String get trainingReloadProgress;

  /// Explains partial progress persistence without promising replay or rollback.
  ///
  /// In en, this message translates to:
  /// **'Training progress may be partly saved. Reload saved progress before training again. History and PGN updates may be incomplete. Reloading does not retry the changes.'**
  String get trainingProgressPartial;

  /// Study and PGN control: cancel
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// Repertoire catalog: retry
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// Repertoire catalog: refresh
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// Repertoire catalog: restore
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restore;

  /// Study and PGN control: delete
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// Repertoire catalog: rename
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// Repertoire catalog: importPgn
  ///
  /// In en, this message translates to:
  /// **'Import PGN'**
  String get importPgn;

  /// Study and PGN control: importAction
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get importAction;

  /// Repertoire catalog: importing
  ///
  /// In en, this message translates to:
  /// **'Importing…'**
  String get importing;

  /// Repertoire catalog: working
  ///
  /// In en, this message translates to:
  /// **'Working…'**
  String get working;

  /// Visible label for the White side; stored PGN values remain canonical.
  ///
  /// In en, this message translates to:
  /// **'White'**
  String get white;

  /// Visible label for the Black side; stored PGN values remain canonical.
  ///
  /// In en, this message translates to:
  /// **'Black'**
  String get black;

  /// Repertoire catalog: openPgnFile
  ///
  /// In en, this message translates to:
  /// **'Open PGN file…'**
  String get openPgnFile;

  /// Repertoire catalog: pastePgn
  ///
  /// In en, this message translates to:
  /// **'Paste PGN'**
  String get pastePgn;

  /// Repertoire catalog: clearSearch
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get clearSearch;

  /// Repertoire catalog: createRepertoire
  ///
  /// In en, this message translates to:
  /// **'Create repertoire'**
  String get createRepertoire;

  /// Repertoire catalog: createNewRepertoire
  ///
  /// In en, this message translates to:
  /// **'Create new repertoire'**
  String get createNewRepertoire;

  /// Repertoire catalog: creationHeading
  ///
  /// In en, this message translates to:
  /// **'Bring your lines. Start training.'**
  String get creationHeading;

  /// Repertoire catalog: repertoireName
  ///
  /// In en, this message translates to:
  /// **'Repertoire name'**
  String get repertoireName;

  /// Repertoire catalog: repertoireNameHint
  ///
  /// In en, this message translates to:
  /// **'My Sicilian'**
  String get repertoireNameHint;

  /// Repertoire catalog: playingSide
  ///
  /// In en, this message translates to:
  /// **'Playing side'**
  String get playingSide;

  /// Repertoire catalog: emptyRepertoire
  ///
  /// In en, this message translates to:
  /// **'Empty repertoire'**
  String get emptyRepertoire;

  /// Repertoire catalog: emptyRepertoireHelp
  ///
  /// In en, this message translates to:
  /// **'Create a place for chapters and lines. Add moves before training.'**
  String get emptyRepertoireHelp;

  /// Repertoire catalog: pgnMoves
  ///
  /// In en, this message translates to:
  /// **'PGN moves'**
  String get pgnMoves;

  /// Repertoire catalog: pgnPasteHint
  ///
  /// In en, this message translates to:
  /// **'Paste your PGN here'**
  String get pgnPasteHint;

  /// PGN example; preserve canonical SAN notation and moves.
  ///
  /// In en, this message translates to:
  /// **'1. e4 e5 2. Nf3 Nc6…'**
  String get pgnExample;

  /// Repertoire catalog: pasteHelp
  ///
  /// In en, this message translates to:
  /// **'Add your moves now. You can rename the repertoire later.'**
  String get pasteHelp;

  /// Repertoire catalog: fileReadFailed
  ///
  /// In en, this message translates to:
  /// **'Could not read that file.'**
  String get fileReadFailed;

  /// Repertoire catalog: fileOpenFailed
  ///
  /// In en, this message translates to:
  /// **'Could not open that file. Try again.'**
  String get fileOpenFailed;

  /// Repertoire catalog: creationNeedsMoves
  ///
  /// In en, this message translates to:
  /// **'Open or paste a PGN with moves to train.'**
  String get creationNeedsMoves;

  /// Repertoire catalog: importNeedsMoves
  ///
  /// In en, this message translates to:
  /// **'That PGN has no moves to train.'**
  String get importNeedsMoves;

  /// Repertoire catalog: pasteNeedsMoves
  ///
  /// In en, this message translates to:
  /// **'Paste PGN with moves to train.'**
  String get pasteNeedsMoves;

  /// Repertoire catalog: creationFailed
  ///
  /// In en, this message translates to:
  /// **'Could not create the repertoire. Your input is still here; try again.'**
  String get creationFailed;

  /// Repertoire catalog: importFailed
  ///
  /// In en, this message translates to:
  /// **'Could not import the repertoire. Please try again.'**
  String get importFailed;

  /// Repertoire catalog: pasteFailed
  ///
  /// In en, this message translates to:
  /// **'Could not import. Your PGN is still here; try again.'**
  String get pasteFailed;

  /// Repertoire catalog: repertoireExists
  ///
  /// In en, this message translates to:
  /// **'A repertoire named \"{name}\" already exists.'**
  String repertoireExists(String name);

  /// Repertoire catalog: creationUncertain
  ///
  /// In en, this message translates to:
  /// **'The file may already be saved. Keep this draft and reload the library before retrying.'**
  String get creationUncertain;

  /// Repertoire catalog: preparationFailed
  ///
  /// In en, this message translates to:
  /// **'Import preparation failed. No repertoire was published. Keep this draft and retry.'**
  String get preparationFailed;

  /// Repertoire catalog: recoveryRequired
  ///
  /// In en, this message translates to:
  /// **'The folder may have moved, but its references could not be confirmed. Reload the library to recover this operation before making another change.'**
  String get recoveryRequired;

  /// Repertoire catalog: catalogLoadFailed
  ///
  /// In en, this message translates to:
  /// **'Could not load repertoires. Please try again.'**
  String get catalogLoadFailed;

  /// Repertoire catalog: recoverLibrary
  ///
  /// In en, this message translates to:
  /// **'Recover library'**
  String get recoverLibrary;

  /// Repertoire catalog: restoreFailed
  ///
  /// In en, this message translates to:
  /// **'Restore failed. Your recovery files are retained. Refresh the list or choose another name.'**
  String get restoreFailed;

  /// Repertoire catalog: recoveryEmpty
  ///
  /// In en, this message translates to:
  /// **'Recovery is empty'**
  String get recoveryEmpty;

  /// Repertoire catalog: recoveryEmptyHelp
  ///
  /// In en, this message translates to:
  /// **'Deleted repertoires will appear here.'**
  String get recoveryEmptyHelp;

  /// Repertoire catalog: recoveryFilesChanged
  ///
  /// In en, this message translates to:
  /// **'Recovery files are missing or changed'**
  String get recoveryFilesChanged;

  /// Repertoire catalog: deletedAt
  ///
  /// In en, this message translates to:
  /// **'Deleted {time}'**
  String deletedAt(String time);

  /// Repertoire catalog: catalogEmpty
  ///
  /// In en, this message translates to:
  /// **'No repertoires yet'**
  String get catalogEmpty;

  /// Repertoire catalog: catalogEmptyHelp
  ///
  /// In en, this message translates to:
  /// **'Open a PGN file or create a repertoire to get started.'**
  String get catalogEmptyHelp;

  /// Repertoire catalog: nothingMatches
  ///
  /// In en, this message translates to:
  /// **'Nothing matches \"{query}\".'**
  String nothingMatches(String query);

  /// Repertoire catalog: repertoires
  ///
  /// In en, this message translates to:
  /// **'Repertoires'**
  String get repertoires;

  /// Repertoire catalog: studiesTactics
  ///
  /// In en, this message translates to:
  /// **'Studies — custom tactics'**
  String get studiesTactics;

  /// Repertoire catalog: repertoireRecovery
  ///
  /// In en, this message translates to:
  /// **'Repertoire recovery'**
  String get repertoireRecovery;

  /// Repertoire catalog: yourRepertoires
  ///
  /// In en, this message translates to:
  /// **'Your repertoires'**
  String get yourRepertoires;

  /// Repertoire catalog: backToLibrary
  ///
  /// In en, this message translates to:
  /// **'Back to library'**
  String get backToLibrary;

  /// Repertoire catalog: recovery
  ///
  /// In en, this message translates to:
  /// **'Recovery'**
  String get recovery;

  /// Repertoire catalog: searchRepertoires
  ///
  /// In en, this message translates to:
  /// **'Search repertoires'**
  String get searchRepertoires;

  /// Repertoire catalog: chapterCount
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 chapter} other{{count} chapters}}'**
  String chapterCount(int count);

  /// Repertoire catalog: repertoireDetails
  ///
  /// In en, this message translates to:
  /// **'{chapters} · Modified {time}'**
  String repertoireDetails(String chapters, String time);

  /// Repertoire catalog: browseChapters
  ///
  /// In en, this message translates to:
  /// **'Browse chapters'**
  String get browseChapters;

  /// Repertoire catalog: renameRepertoire
  ///
  /// In en, this message translates to:
  /// **'Rename repertoire'**
  String get renameRepertoire;

  /// Repertoire catalog: deleteRepertoire
  ///
  /// In en, this message translates to:
  /// **'Delete repertoire'**
  String get deleteRepertoire;

  /// Repertoire catalog: createdRepertoire
  ///
  /// In en, this message translates to:
  /// **'Created “{name}”. Add moves before training.'**
  String createdRepertoire(String name);

  /// Repertoire catalog: importedRepertoire
  ///
  /// In en, this message translates to:
  /// **'Imported “{name}”. Rename it from your repertoire list.'**
  String importedRepertoire(String name);

  /// Repertoire catalog: restoreRepertoire
  ///
  /// In en, this message translates to:
  /// **'Restore repertoire'**
  String get restoreRepertoire;

  /// Repertoire catalog: restoreNamePrompt
  ///
  /// In en, this message translates to:
  /// **'Choose a name for the restored repertoire:'**
  String get restoreNamePrompt;

  /// Repertoire catalog: duplicateRepertoireName
  ///
  /// In en, this message translates to:
  /// **'A repertoire with this name already exists.'**
  String get duplicateRepertoireName;

  /// Repertoire catalog: deleteRepertoirePrompt
  ///
  /// In en, this message translates to:
  /// **'Delete repertoire \"{name}\"?'**
  String deleteRepertoirePrompt(String name);

  /// Repertoire catalog: deleteRepertoireHelp
  ///
  /// In en, this message translates to:
  /// **'Its files and training history will be kept. Restore it from Recovery in the library.'**
  String get deleteRepertoireHelp;

  /// Repertoire catalog: deleteLegacyRepertoireHelp
  ///
  /// In en, this message translates to:
  /// **'Its files will be moved to Chess Auto Prep recovery trash.'**
  String get deleteLegacyRepertoireHelp;

  /// Repertoire catalog: deleteRepertoireFailed
  ///
  /// In en, this message translates to:
  /// **'Could not delete repertoire.'**
  String get deleteRepertoireFailed;

  /// Repertoire catalog: renameRepertoirePrompt
  ///
  /// In en, this message translates to:
  /// **'Enter new name for the repertoire:'**
  String get renameRepertoirePrompt;

  /// Repertoire catalog: renameRepertoireFailed
  ///
  /// In en, this message translates to:
  /// **'Could not rename repertoire.'**
  String get renameRepertoireFailed;

  /// Repertoire catalog: nameRequired
  ///
  /// In en, this message translates to:
  /// **'Please enter a name.'**
  String get nameRequired;

  /// Repertoire catalog: nameTrailingDotOrSpace
  ///
  /// In en, this message translates to:
  /// **'Names cannot end with a dot or space.'**
  String get nameTrailingDotOrSpace;

  /// Repertoire catalog: nameReserved
  ///
  /// In en, this message translates to:
  /// **'That name is reserved.'**
  String get nameReserved;

  /// Repertoire catalog: nameIllegalCharacters
  ///
  /// In en, this message translates to:
  /// **'Names cannot contain < > : \" / \\ | ? * or control characters.'**
  String get nameIllegalCharacters;

  /// Repertoire catalog: nameSystemReserved
  ///
  /// In en, this message translates to:
  /// **'That name is reserved by the operating system.'**
  String get nameSystemReserved;

  /// Repertoire catalog: nameTooLong
  ///
  /// In en, this message translates to:
  /// **'Names must be {maxLength} characters or fewer.'**
  String nameTooLong(int maxLength);

  /// Repertoire catalog: justNow
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get justNow;

  /// Repertoire catalog: minutesAgo
  ///
  /// In en, this message translates to:
  /// **'{count}m ago'**
  String minutesAgo(int count);

  /// Repertoire catalog: hoursAgo
  ///
  /// In en, this message translates to:
  /// **'{count}h ago'**
  String hoursAgo(int count);

  /// Repertoire catalog: daysAgo
  ///
  /// In en, this message translates to:
  /// **'{count}d ago'**
  String daysAgo(int count);

  /// Shared document save interaction: saveChanges
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get saveChanges;

  /// Shared document save interaction: saveCopy
  ///
  /// In en, this message translates to:
  /// **'Save a copy…'**
  String get saveCopy;

  /// Shared document save interaction: keepEditing
  ///
  /// In en, this message translates to:
  /// **'Keep editing'**
  String get keepEditing;

  /// Shared document save interaction: inspectCurrentDocument
  ///
  /// In en, this message translates to:
  /// **'Inspect current file'**
  String get inspectCurrentDocument;

  /// Shared document save interaction: reloadPreservingDraft
  ///
  /// In en, this message translates to:
  /// **'Reload and keep draft'**
  String get reloadPreservingDraft;

  /// Shared document save interaction: restoreRetainedDraft
  ///
  /// In en, this message translates to:
  /// **'Restore retained draft'**
  String get restoreRetainedDraft;

  /// Shared document save interaction: documentClean
  ///
  /// In en, this message translates to:
  /// **'No unsaved changes'**
  String get documentClean;

  /// Study and PGN control: documentDirty
  ///
  /// In en, this message translates to:
  /// **'Unsaved changes'**
  String get documentDirty;

  /// Study and PGN control: documentSaving
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get documentSaving;

  /// Shared document save interaction: documentSaved
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get documentSaved;

  /// Shared document save interaction: documentReloading
  ///
  /// In en, this message translates to:
  /// **'Reading current file…'**
  String get documentReloading;

  /// Shared document save interaction: documentConflict
  ///
  /// In en, this message translates to:
  /// **'The file changed or was removed. Your draft is unchanged. Inspect the current file or save a copy.'**
  String get documentConflict;

  /// Shared document save interaction: documentCollision
  ///
  /// In en, this message translates to:
  /// **'That destination already exists. Nothing was replaced. Choose another name for your copy.'**
  String get documentCollision;

  /// Shared document save interaction: documentSaveFailed
  ///
  /// In en, this message translates to:
  /// **'Could not save. Your draft is unchanged. You can retry or save a copy.'**
  String get documentSaveFailed;

  /// Shared document save interaction: documentSaveUncertain
  ///
  /// In en, this message translates to:
  /// **'The file may have been saved. Your draft is retained. Inspect and reload before saving again, or save a copy.'**
  String get documentSaveUncertain;

  /// Shared document save interaction: documentReadFailed
  ///
  /// In en, this message translates to:
  /// **'Could not read the current file. Your draft and loaded revision are unchanged.'**
  String get documentReadFailed;

  /// Shared document save interaction: documentMissing
  ///
  /// In en, this message translates to:
  /// **'The file no longer exists. Your draft is unchanged.'**
  String get documentMissing;

  /// Shared document save interaction: documentDraftRetained
  ///
  /// In en, this message translates to:
  /// **'Your previous draft is kept in this session. Restore it or save it before closing the document.'**
  String get documentDraftRetained;

  /// Shared document save interaction: chooseAnotherName
  ///
  /// In en, this message translates to:
  /// **'Choose another name'**
  String get chooseAnotherName;

  /// Shared document save interaction: closeDocumentInspection
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get closeDocumentInspection;

  /// Shared document save interaction: copyDestination
  ///
  /// In en, this message translates to:
  /// **'Copy destination'**
  String get copyDestination;

  /// Restore one of the drafts retained by this document session
  ///
  /// In en, this message translates to:
  /// **'Restore draft {number}'**
  String restoreRetainedDraftNumber(int number);

  /// Workspace navigation: backToPreviousView
  ///
  /// In en, this message translates to:
  /// **'Back to previous view'**
  String get backToPreviousView;

  /// Workspace navigation: selectRepertoire
  ///
  /// In en, this message translates to:
  /// **'Select repertoire'**
  String get selectRepertoire;

  /// Workspace navigation: back
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// Appearance settings: appearance
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// Appearance settings: appearanceDark
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get appearanceDark;

  /// Appearance settings: appearanceLight
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get appearanceLight;

  /// Appearance settings: appearanceSystem
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get appearanceSystem;

  /// Appearance settings: appearanceLoading
  ///
  /// In en, this message translates to:
  /// **'Loading appearance…'**
  String get appearanceLoading;

  /// Appearance settings: appearanceSaving
  ///
  /// In en, this message translates to:
  /// **'Saving appearance…'**
  String get appearanceSaving;

  /// Appearance settings: appearanceFailed
  ///
  /// In en, this message translates to:
  /// **'Could not confirm the appearance setting. Your last confirmed appearance is still applied.'**
  String get appearanceFailed;

  /// Appearance settings: appearanceReload
  ///
  /// In en, this message translates to:
  /// **'Reload saved choice'**
  String get appearanceReload;

  /// Appearance settings: appearanceSystemHelp
  ///
  /// In en, this message translates to:
  /// **'System follows your desktop’s light or dark appearance.'**
  String get appearanceSystemHelp;

  /// Study save and recovery interaction: studySaveRecovery
  ///
  /// In en, this message translates to:
  /// **'Save and recovery…'**
  String get studySaveRecovery;

  /// Study save and recovery interaction: studyCopyName
  ///
  /// In en, this message translates to:
  /// **'Copy name'**
  String get studyCopyName;

  /// Study save and recovery interaction: studyCopyPrompt
  ///
  /// In en, this message translates to:
  /// **'The copy will open as your current study. The original file is kept.'**
  String get studyCopyPrompt;

  /// No description provided for @studyCopyInitial.
  ///
  /// In en, this message translates to:
  /// **'{name} copy'**
  String studyCopyInitial(String name);

  /// No description provided for @studySaveDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Save {name}'**
  String studySaveDialogTitle(String name);

  /// Study save and recovery interaction: studyExportTitle
  ///
  /// In en, this message translates to:
  /// **'Export study PGN'**
  String get studyExportTitle;

  /// Study save and recovery interaction: studyExportDirectory
  ///
  /// In en, this message translates to:
  /// **'Choose export folder'**
  String get studyExportDirectory;

  /// Study save and recovery interaction: studyExportName
  ///
  /// In en, this message translates to:
  /// **'File name'**
  String get studyExportName;

  /// Study save and recovery interaction: studyInvalidName
  ///
  /// In en, this message translates to:
  /// **'Enter a file name without path separators or reserved characters.'**
  String get studyInvalidName;

  /// Application document close interaction: closeApplicationTitle
  ///
  /// In en, this message translates to:
  /// **'Close application?'**
  String get closeApplicationTitle;

  /// Application document close interaction: keepApplicationOpen
  ///
  /// In en, this message translates to:
  /// **'Keep app open'**
  String get keepApplicationOpen;

  /// Application document close interaction: documentChangedWhileClosing
  ///
  /// In en, this message translates to:
  /// **'A document changed while closing. The app has stayed open so you can review the latest changes.'**
  String get documentChangedWhileClosing;

  /// Application document close interaction: documentCloseFailed
  ///
  /// In en, this message translates to:
  /// **'The close request could not finish. The app has stayed open. Review any save or recovery errors, then try again.'**
  String get documentCloseFailed;

  /// Native close interception failed to initialize
  ///
  /// In en, this message translates to:
  /// **'Close protection could not start. Save your changes before closing the window.'**
  String get windowCloseUnavailable;

  /// Application document close interaction: studyCloseUnsaved
  ///
  /// In en, this message translates to:
  /// **'This study has unsaved changes or retained drafts. Save the work you want to keep before closing.'**
  String get studyCloseUnsaved;

  /// Study close confirmation after all changes and drafts are resolved
  ///
  /// In en, this message translates to:
  /// **'Your study is saved. You can close the app.'**
  String get studyCloseReady;

  /// Application document close interaction: closeWithoutSaving
  ///
  /// In en, this message translates to:
  /// **'Close without saving'**
  String get closeWithoutSaving;

  /// Application document close interaction: closeApplication
  ///
  /// In en, this message translates to:
  /// **'Close application'**
  String get closeApplication;

  /// PGN document save and recovery control.
  ///
  /// In en, this message translates to:
  /// **'Choose a new PGN filename. Existing files are kept.'**
  String get documentCopyPrompt;

  /// PGN document save and recovery control.
  ///
  /// In en, this message translates to:
  /// **'File name'**
  String get documentCopyName;

  /// PGN document save and recovery control.
  ///
  /// In en, this message translates to:
  /// **'Folder'**
  String get documentCopyFolder;

  /// PGN document save and recovery control.
  ///
  /// In en, this message translates to:
  /// **'Browse folders'**
  String get documentBrowseFolder;

  /// PGN document save and recovery control.
  ///
  /// In en, this message translates to:
  /// **'Enter a file name without folders.'**
  String get documentCopyInvalidName;

  /// PGN document save and recovery control.
  ///
  /// In en, this message translates to:
  /// **'Enter an absolute folder path.'**
  String get documentCopyInvalidFolder;

  /// PGN document save and recovery control.
  ///
  /// In en, this message translates to:
  /// **'The folder picker could not open. You can enter the folder path.'**
  String get documentFolderPickerFailed;

  /// PGN document save and recovery control.
  ///
  /// In en, this message translates to:
  /// **'Save and recovery…'**
  String get documentSaveRecovery;

  /// PGN document save and recovery control.
  ///
  /// In en, this message translates to:
  /// **'Save PGN collection'**
  String get documentCollectionSaveTitle;

  /// PGN document save and recovery control.
  ///
  /// In en, this message translates to:
  /// **'Export PGN collection'**
  String get documentExportTitle;

  /// Open a newly exported PGN collection.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get documentOpenExport;

  /// PGN export confirmation.
  ///
  /// In en, this message translates to:
  /// **'Exported {name}'**
  String documentExported(String name);

  /// Recovery status for the named workspace
  ///
  /// In en, this message translates to:
  /// **'Recover {workspace} work'**
  String workspaceRecoveryTitle(String workspace);

  /// Study workspace restart recovery: studyRecoveryExplanation
  ///
  /// In en, this message translates to:
  /// **'These checkpoints contain work from previous sessions. Restoring opens the captured draft without writing to its original file. Save or make a copy after reviewing it.'**
  String get workspaceRecoveryExplanation;

  /// Study workspace restart recovery: studyRecoveryActionFailed
  ///
  /// In en, this message translates to:
  /// **'Recovery could not finish. Your checkpoint is still preserved. Retry or save the current draft as a copy.'**
  String get workspaceRecoveryActionFailed;

  /// Study workspace restart recovery: restoreStudyRecovery
  ///
  /// In en, this message translates to:
  /// **'Restore draft'**
  String get restoreWorkspaceRecovery;

  /// Study workspace restart recovery: dismissStudyRecovery
  ///
  /// In en, this message translates to:
  /// **'Dismiss recovery'**
  String get dismissWorkspaceRecovery;

  /// Study workspace restart recovery: dismissStudyRecoveryQuestion
  ///
  /// In en, this message translates to:
  /// **'Remove this checkpoint from the recovery list? Its archived bytes remain on disk, but the app will no longer offer to restore it.'**
  String get dismissWorkspaceRecoveryQuestion;

  /// Recovery status for the named workspace
  ///
  /// In en, this message translates to:
  /// **'{workspace} recovery is unavailable. Save your work explicitly; recent edits may not survive a restart.'**
  String workspaceRecoveryUnavailable(String workspace);

  /// Recovery status for the named workspace
  ///
  /// In en, this message translates to:
  /// **'Some {workspace} recovery files could not be read. Their files have been preserved.'**
  String workspaceRecoveryUnreadable(String workspace);

  /// Recovery status for the named workspace
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{workspace} work from a previous session is available.} other{{workspace} work from {count} previous sessions is available.}}'**
  String workspaceRecoveryAvailable(String workspace, int count);

  /// Study workspace restart recovery: reviewStudyRecovery
  ///
  /// In en, this message translates to:
  /// **'Review recovery'**
  String get reviewWorkspaceRecovery;

  /// Study workspace restart recovery: retryStudyRecovery
  ///
  /// In en, this message translates to:
  /// **'Retry recovery'**
  String get retryWorkspaceRecovery;

  /// Local date and time of the saved Study checkpoint
  ///
  /// In en, this message translates to:
  /// **'{date} · {time}'**
  String workspaceRecoveryTimestamp(String date, String time);

  /// Study and PGN control: studyWorkspaceName
  ///
  /// In en, this message translates to:
  /// **'Study'**
  String get studyWorkspaceName;

  /// Workspace recovery display name
  ///
  /// In en, this message translates to:
  /// **'PGN Viewer'**
  String get pgnWorkspaceName;

  /// Workspace recovery display name
  ///
  /// In en, this message translates to:
  /// **'Untitled PGN'**
  String get untitledPgnWorkspace;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'Recover generated outputs'**
  String get generationRecoveryTitle;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'Recover generated outputs…'**
  String get generationRecoveryAction;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'These older files have no recorded source revision. Inspect or export them here; they do not replace the current chapter or its verified analysis. Original files stay unchanged.'**
  String get generationRecoveryProvenance;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Saved tree'**
  String get generationRecoveryTree;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Saved probes'**
  String get generationRecoveryProbes;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Saved traps'**
  String get generationRecoveryTraps;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Unfinished build'**
  String get generationRecoveryPartial;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Export original file…'**
  String get generationRecoveryExport;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Choose a folder for the recovered file'**
  String get generationRecoveryExportDirectory;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'No saved files were found in this output. Choose another retained output or refresh.'**
  String get generationRecoveryEmpty;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Select a saved artifact to inspect its contents.'**
  String get generationRecoverySelect;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'No saved entries'**
  String get generationRecoveryNoEntries;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Could not read this entry'**
  String get generationRecoveryUnreadable;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Automatic resume is unavailable: this unfinished build has no verifiable source revision. You can inspect its explored positions, export the original file, or start a fresh build from the chapter.'**
  String get generationRecoveryResumeUnavailable;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Saved configuration'**
  String get generationRecoveryConfig;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Previous position'**
  String get generationRecoveryParent;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Original file exported to {path}'**
  String generationRecoveryExported(String path);

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Entry {number}'**
  String generationRecoveryEntry(int number);

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'{nodes} saved nodes · depth {depth}'**
  String generationRecoveryNodes(int nodes, int depth);

  /// Legacy analysis recovery failure
  ///
  /// In en, this message translates to:
  /// **'Technical details'**
  String get generationRecoveryDiagnostics;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'Saved outputs could not be loaded. Try refreshing.'**
  String get generationRecoveryLoadFailed;

  /// Legacy analysis recovery failure
  ///
  /// In en, this message translates to:
  /// **'This file could not be read safely. Other saved files remain available.'**
  String get generationRecoveryReadFailed;

  /// Legacy analysis recovery failure
  ///
  /// In en, this message translates to:
  /// **'This entry could not be decoded. You can still export its original file.'**
  String get generationRecoveryDecodeFailed;

  /// Legacy analysis recovery failure
  ///
  /// In en, this message translates to:
  /// **'A file already exists at that destination. Choose a different location; nothing was replaced.'**
  String get generationRecoveryCollision;

  /// Legacy analysis recovery failure
  ///
  /// In en, this message translates to:
  /// **'The original file could not be exported. Choose another location or try again.'**
  String get generationRecoveryExportFailed;

  /// Legacy analysis recovery failure
  ///
  /// In en, this message translates to:
  /// **'The export may have been saved, but completion could not be confirmed. Inspect the destination below before trying again.'**
  String get generationRecoveryExportUncertain;

  /// Legacy analysis inspection
  ///
  /// In en, this message translates to:
  /// **'Destination: {path}'**
  String generationRecoveryDestination(String path);

  /// Legacy analysis inspection
  ///
  /// In en, this message translates to:
  /// **'Popular reply'**
  String get generationRecoveryPopularMove;

  /// Legacy analysis inspection
  ///
  /// In en, this message translates to:
  /// **'Best reply'**
  String get generationRecoveryBestMove;

  /// Legacy analysis inspection
  ///
  /// In en, this message translates to:
  /// **'Move probability'**
  String get generationRecoveryProbability;

  /// Legacy analysis inspection
  ///
  /// In en, this message translates to:
  /// **'Evaluation gain'**
  String get generationRecoveryGain;

  /// Legacy analysis inspection
  ///
  /// In en, this message translates to:
  /// **'Evaluation (side to move)'**
  String get generationRecoveryEvaluation;

  /// Legacy analysis inspection
  ///
  /// In en, this message translates to:
  /// **'Expected score'**
  String get generationRecoveryExpectedScore;

  /// Legacy analysis inspection
  ///
  /// In en, this message translates to:
  /// **'Engine principal variation (UCI)'**
  String get generationRecoveryPv;

  /// Study and PGN control: generationRecoveryNotSaved
  ///
  /// In en, this message translates to:
  /// **'Not saved'**
  String get generationRecoveryNotSaved;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'Inspect or export saved outputs. Recovery does not change the chapter, select analysis or resume a build. Original files stay unchanged.'**
  String get generationRecoveryReadOnly;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'Choose saved output'**
  String get generationRecoveryChooseOutput;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'Older files beside this chapter'**
  String get generationRecoveryLegacyFiles;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'Generated PGN proposal'**
  String get generationRecoveryCourse;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'Model games'**
  String get generationRecoveryModelGames;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'Run record'**
  String get generationRecoveryManifest;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'Publication receipt'**
  String get generationRecoveryReceipt;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'Recorded run'**
  String get generationRecoveryRun;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'Recorded source'**
  String get generationRecoverySource;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'The source revision was not recorded or could not be decoded.'**
  String get generationRecoverySourceUnknown;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'The recorded source revision matches the chapter observed now. This alone does not verify the saved analysis.'**
  String get generationRecoverySourceMatches;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'The recorded source differs from the chapter observed now.'**
  String get generationRecoverySourceChanged;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'The current chapter could not be read, so its source revision could not be compared.'**
  String get generationRecoverySourceUnavailable;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'The current selection record names this output. Recovery does not certify it as current analysis.'**
  String get generationRecoverySelectionNames;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'No current selection evidence was found for this output. It may have been selected previously.'**
  String get generationRecoverySelectionUnknown;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'No publication receipt was found. The PGN write may still have succeeded; inspect the chapter before generating again.'**
  String get generationRecoveryReceiptAbsent;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'A publication receipt was recorded. It does not prove that this output is the current chapter.'**
  String get generationRecoveryReceiptPresent;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'A publication receipt exists but could not be verified. The PGN write may have succeeded.'**
  String get generationRecoveryReceiptUnreadable;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'Recovery does not resume retained builds. Use the normal generation flow only when its current source and saved configuration are validated.'**
  String get generationRecoveryResumeRetained;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'This file differs from its recorded checksum. Inspect or export it as edited data.'**
  String get generationRecoveryIntegrityChanged;

  /// Read-only generation output recovery.
  ///
  /// In en, this message translates to:
  /// **'This file matches the checksum in its run record; that record is not proof of publication.'**
  String get generationRecoveryIntegrityMatches;

  /// Recovery namespace enumeration failed; explicit refresh remains available.
  ///
  /// In en, this message translates to:
  /// **'This folder could not be inspected. Available outputs remain accessible. Try refreshing.'**
  String get generationRecoveryListFailed;

  /// Generation recovery source selection.
  ///
  /// In en, this message translates to:
  /// **'All retained chapter outputs'**
  String get generationRecoveryAllSources;

  /// Generation recovery source selection.
  ///
  /// In en, this message translates to:
  /// **'No retained chapter namespaces were found in the repertoire library.'**
  String get generationRecoveryNoSources;

  /// Generation recovery source selection.
  ///
  /// In en, this message translates to:
  /// **'Deleted chapter files can be recovered here. If the entire repertoire was deleted, restore its folder from library recovery first.'**
  String get generationRecoveryDeletedRepertoire;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Import: {name}'**
  String studyImportJob(String name);

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Starting…'**
  String get studyImportStarting;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Cancelling…'**
  String get studyImportCancelling;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Fetching game {game}/{total}'**
  String studyImportFetching(int game, int total);

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Game {game}/{total} · next in {seconds}s'**
  String studyImportWaiting(int game, int seconds, int total);

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Rate-limited — retrying game {game}/{total} in {seconds}s'**
  String studyImportRetrying(int game, int seconds, int total);

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Downloaded {count}'**
  String studyImportDownloaded(int count);

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Skipped game {id}'**
  String studyImportSkipped(String id);

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 chapter} other{{count} chapters}}'**
  String studyImportChapters(int count);

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'The study importer is closed.'**
  String get studyImportClosed;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'A collection download is already running.'**
  String get studyImportAlreadyRunning;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'No games found in that collection.'**
  String get studyImportEmpty;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Collection game IDs must be numeric.'**
  String get studyImportInvalidIds;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Could not start the collection download. Try again.'**
  String get studyImportStartupFailed;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Collection download stopped. Downloaded games remain cached.'**
  String get studyImportDownloadFailed;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'chessgames.com is refusing requests. Downloaded games are cached — start the same collection again later to resume.'**
  String get studyImportThrottled;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Downloaded games could not be saved. Review the downloaded content or try again later.'**
  String get studyImportPublicationFailed;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'The study save could not be confirmed. Review the destination before retrying.'**
  String get studyImportPublicationUncertain;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'No free study name was found after 100 attempts. Choose another destination for the downloaded games.'**
  String get studyImportNameCollisions;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Importing {done}/{total}'**
  String studyImportProgress(int done, int total);

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Stop the download (keeps what has arrived)'**
  String get studyImportStop;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Review downloaded study'**
  String get studyImportReview;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Downloading {count} games (~{minutes} min). chessgames.com is slow on purpose — keep working, it runs in the background.'**
  String studyImportBackground(int count, int minutes);

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Imported {count} games into “{name}” ({failed} unavailable).'**
  String studyImportComplete(int count, int failed, String name);

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Stopped the download. Saved {count} chapters into “{name}”.'**
  String studyImportStopped(int count, String name);

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'No study was saved ({failed} games unavailable).'**
  String studyImportNoContent(int failed);

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get studyImportOpen;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Lichess did not respond (rate-limited or offline). Try again shortly.'**
  String get studyImportLichessOffline;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Study not found. If it is private or unlisted, log into Lichess first (Settings → Accounts), then try again.'**
  String get studyImportLichessLogin;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Study not found. If it is private, log out and back in to grant study access.'**
  String get studyImportLichessScope;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Lichess rejected the request. Log out and back in under Settings → Accounts, then try again.'**
  String get studyImportLichessRejected;

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'No public studies found for “{name}”.'**
  String studyImportLichessUserMissing(String name);

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'Lichess returned HTTP {status}.'**
  String studyImportLichessHttp(int status);

  /// Study import progress, results and recovery
  ///
  /// In en, this message translates to:
  /// **'That study is empty — nothing to import.'**
  String get studyImportLichessEmpty;

  /// Pending failed publication must be resolved before another collection starts
  ///
  /// In en, this message translates to:
  /// **'Review the previous downloaded study before starting another import.'**
  String get studyImportUnresolved;

  /// Study handoff read failed
  ///
  /// In en, this message translates to:
  /// **'Could not open that study. Your current study is unchanged.'**
  String get studyOpenFailed;

  /// Compact snackbar action that opens imported document recovery
  ///
  /// In en, this message translates to:
  /// **'Review'**
  String get studyImportReviewAction;

  /// Study source PGN read failure
  ///
  /// In en, this message translates to:
  /// **'Could not import that PGN. Your study is unchanged.'**
  String get studyImportPgnFailed;

  /// Retry a failed study library read
  ///
  /// In en, this message translates to:
  /// **'Could not load studies. Retry'**
  String get studyListRetry;

  /// No description provided for @studyImportAdded.
  ///
  /// In en, this message translates to:
  /// **'Added {count} chapters.'**
  String studyImportAdded(int count);

  /// Study import or adoption failure; existing edits remain available.
  ///
  /// In en, this message translates to:
  /// **'Could not finish the import. Your existing work is preserved.'**
  String get studyImportApplyFailed;

  /// An admission rejection keeps downloaded input in its dialog for retry.
  ///
  /// In en, this message translates to:
  /// **'The import was not accepted. Resolve the active import or study change, then retry. Your download is kept in this dialog.'**
  String get studyImportNotAccepted;

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'Copy needs verification: {destination}. The draft is retained; this append will not be repeated.'**
  String builderCopyNeedsVerification(String destination);

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'Inspect copy'**
  String get builderInspectCopy;

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'Line edits are retained. Saving failed.'**
  String get builderLineSaveFailed;

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'The source changed or is missing. Restored edits are a scratch line; save them to an explicit destination.'**
  String get builderSourceChanged;

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'Save draft as a new line…'**
  String get builderSaveDraftCopy;

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'Retained Builder drafts'**
  String get builderRetainedDraftsTooltip;

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'Scratch'**
  String get builderScratch;

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'The draft is retained. Choose a destination and try saving it again.'**
  String get builderDraftRetained;

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'Retained drafts ({count})'**
  String builderRetainedDraftCount(int count);

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'Destination could not be inspected. The copy intent and draft are retained.'**
  String get builderCopyInspectionFailed;

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'Verify the saved copy'**
  String get builderVerifyCopy;

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'Confirm only if the intended line is present in this observed file. Keeping the draft does not repeat the append.'**
  String get builderVerifyCopyExplanation;

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'Keep draft'**
  String get builderKeepDraft;

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'Copy is present'**
  String get builderCopyPresent;

  /// Builder durable workspace recovery
  ///
  /// In en, this message translates to:
  /// **'The copy and draft are retained. Inspect the destination before trying again.'**
  String get builderCopyRetained;

  /// Confirmed chapter files retained after a partial import
  ///
  /// In en, this message translates to:
  /// **'Saved chapters:\n{paths}'**
  String createdChapterPaths(String paths);

  /// Candidate and recovery paths after an interrupted chapter operation
  ///
  /// In en, this message translates to:
  /// **'Paths to inspect (writes may be unconfirmed):\n{paths}'**
  String chapterPathsToInspect(String paths);

  /// Manual chapter deletion recovery confirmation
  ///
  /// In en, this message translates to:
  /// **'The chapter will be removed from this folder and kept in recovery storage.'**
  String get chapterDeleteConfirm;

  /// Verified manual chapter deletion: chapterDeleteUnsupported
  ///
  /// In en, this message translates to:
  /// **'Verified chapter deletion is unavailable on this device.'**
  String get chapterDeleteUnsupported;

  /// Verified manual chapter deletion: chapterDeleteReadFailed
  ///
  /// In en, this message translates to:
  /// **'Could not verify this chapter for deletion. Only files in managed app folders can be removed.'**
  String get chapterDeleteReadFailed;

  /// Verified manual chapter deletion: chapterDeleteMissing
  ///
  /// In en, this message translates to:
  /// **'This chapter is no longer available. Nothing was removed.'**
  String get chapterDeleteMissing;

  /// Verified manual chapter deletion: chapterDeleteConflict
  ///
  /// In en, this message translates to:
  /// **'The chapter changed since deletion was requested. Nothing was removed. Reload it before trying again.'**
  String get chapterDeleteConflict;

  /// Verified manual chapter deletion: chapterDeleteFailed
  ///
  /// In en, this message translates to:
  /// **'The chapter could not be moved to recovery.'**
  String get chapterDeleteFailed;

  /// Verified manual chapter deletion: chapterDeleteSaved
  ///
  /// In en, this message translates to:
  /// **'Chapter moved to recovery:\n{path}'**
  String chapterDeleteSaved(String path);

  /// Verified manual chapter deletion: chapterDeleteUncertain
  ///
  /// In en, this message translates to:
  /// **'Deletion could not be confirmed. Check these locations before taking another action; do not retry automatically:\n{paths}'**
  String chapterDeleteUncertain(String paths);

  /// Title for uncertain manual chapter deletion inspection
  ///
  /// In en, this message translates to:
  /// **'Review chapter deletion'**
  String get chapterDeleteReview;

  /// Confirmation title for removing a chapter
  ///
  /// In en, this message translates to:
  /// **'Delete chapter \"{name}\"?'**
  String chapterDeleteTitle(String name);

  /// Deletion result identifies the originally requested chapter even after navigation
  ///
  /// In en, this message translates to:
  /// **'{path}\n{message}'**
  String chapterDeleteContext(String path, String message);

  /// Study chapter list control: studyChapterListTitle
  ///
  /// In en, this message translates to:
  /// **'Chapters ({count})'**
  String studyChapterListTitle(int count);

  /// Study workflow control: studyNewChapter
  ///
  /// In en, this message translates to:
  /// **'New chapter'**
  String get studyNewChapter;

  /// Study and PGN control: studySearchChapters
  ///
  /// In en, this message translates to:
  /// **'Search chapters'**
  String get studySearchChapters;

  /// Study chapter list control: studyFilteredReorder
  ///
  /// In en, this message translates to:
  /// **'Reordering is off while searching'**
  String get studyFilteredReorder;

  /// Study chapter list control: studyDragReorder
  ///
  /// In en, this message translates to:
  /// **'Drag to reorder'**
  String get studyDragReorder;

  /// Study chapter list control: studyNoMatchingChapters
  ///
  /// In en, this message translates to:
  /// **'No matching chapters'**
  String get studyNoMatchingChapters;

  /// Study chapter list control: studyChapterOpenNow
  ///
  /// In en, this message translates to:
  /// **'Open now'**
  String get studyChapterOpenNow;

  /// Study chapter list control: studyEditChapter
  ///
  /// In en, this message translates to:
  /// **'Edit chapter'**
  String get studyEditChapter;

  /// Study chapter list control: studyDeleteChapter
  ///
  /// In en, this message translates to:
  /// **'Delete chapter'**
  String get studyDeleteChapter;

  /// Study chapter list control: studyKeepOneChapter
  ///
  /// In en, this message translates to:
  /// **'A study needs at least one chapter'**
  String get studyKeepOneChapter;

  /// Study workflow control: studyChapterActions
  ///
  /// In en, this message translates to:
  /// **'Chapter actions'**
  String get studyChapterActions;

  /// Study chapter list control: studyChaptersDone
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get studyChaptersDone;

  /// Study chapter dialog label: Use this position
  ///
  /// In en, this message translates to:
  /// **'Use this position'**
  String get studyUsePosition;

  /// Study chapter dialog label: That is not a valid FEN.
  ///
  /// In en, this message translates to:
  /// **'That is not a valid FEN.'**
  String get studyInvalidFen;

  /// Study chapter dialog label: Paste at least one game.
  ///
  /// In en, this message translates to:
  /// **'Paste at least one game.'**
  String get studyPasteGameRequired;

  /// Study and PGN control: studyName
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get studyName;

  /// Study chapter dialog label: From the PGN when left blank
  ///
  /// In en, this message translates to:
  /// **'From the PGN when left blank'**
  String get studyChapterNameFromPgn;

  /// Study chapter dialog label: Start from
  ///
  /// In en, this message translates to:
  /// **'Start from'**
  String get studyChapterStartFrom;

  /// Study chapter dialog label: Initial position
  ///
  /// In en, this message translates to:
  /// **'Initial position'**
  String get studyInitialPosition;

  /// Study chapter dialog label: Position
  ///
  /// In en, this message translates to:
  /// **'Position'**
  String get studyPosition;

  /// Study chapter dialog label: PGN
  ///
  /// In en, this message translates to:
  /// **'PGN'**
  String get studyPgn;

  /// Study chapter dialog label: FEN
  ///
  /// In en, this message translates to:
  /// **'FEN'**
  String get studyFen;

  /// Study chapter dialog label: Set up board…
  ///
  /// In en, this message translates to:
  /// **'Set up board…'**
  String get studySetupBoard;

  /// Study chapter dialog label: Paste PGN. Each game becomes a chapter.
  ///
  /// In en, this message translates to:
  /// **'Paste PGN. Each game becomes a chapter.'**
  String get studyPasteChaptersHint;

  /// Study chapter dialog label: Orientation
  ///
  /// In en, this message translates to:
  /// **'Orientation'**
  String get studyOrientation;

  /// Study chapter dialog label: Automatic
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get studyAutomaticOrientation;

  /// Study chapter dialog label: Create
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get studyCreate;

  /// Study chapter dialog label: A chapter needs a name.
  ///
  /// In en, this message translates to:
  /// **'A chapter needs a name.'**
  String get studyChapterNameRequired;

  /// Study chapter dialog label: PGN tags
  ///
  /// In en, this message translates to:
  /// **'PGN tags'**
  String get studyPgnTags;

  /// Study chapter dialog label: Tag
  ///
  /// In en, this message translates to:
  /// **'Tag'**
  String get studyTag;

  /// Study chapter dialog label: Value
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get studyTagValue;

  /// Study chapter dialog label: Remove tag
  ///
  /// In en, this message translates to:
  /// **'Remove tag'**
  String get studyRemoveTag;

  /// Study chapter dialog label: Add tag
  ///
  /// In en, this message translates to:
  /// **'Add tag'**
  String get studyAddTag;

  /// No description provided for @studyInvalidTagName.
  ///
  /// In en, this message translates to:
  /// **'Tag names are letters and digits: \"{tag}\".'**
  String studyInvalidTagName(String tag);

  /// No description provided for @studyOwnedTag.
  ///
  /// In en, this message translates to:
  /// **'{tag} is written by the study; edit it above.'**
  String studyOwnedTag(String tag);

  /// Study workflow control: studyImportGamesFound
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 game found.} other{{count} games found.}}'**
  String studyImportGamesFound(int count);

  /// Study workflow control: studyDownloadCount
  ///
  /// In en, this message translates to:
  /// **'Download {count}'**
  String studyDownloadCount(int count);

  /// Study workflow control: studyImportFromUrl
  ///
  /// In en, this message translates to:
  /// **'Import from URL'**
  String get studyImportFromUrl;

  /// Study workflow control: studyUrl
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get studyUrl;

  /// Study workflow control: studyImportSupportedUrls
  ///
  /// In en, this message translates to:
  /// **'lichess.org/study/<id>  —  one study, all chapters\nlichess.org/study/by/<user>  —  every public study of theirs\nchessgames.com/perl/chesscollection?cid=<id>  —  a collection'**
  String get studyImportSupportedUrls;

  /// Study workflow control: studyImportAppend
  ///
  /// In en, this message translates to:
  /// **'Add to the current study instead of creating a new one'**
  String get studyImportAppend;

  /// Study workflow control: studyImportCollectionSeparate
  ///
  /// In en, this message translates to:
  /// **'A chessgames.com collection downloads in the background and always gets its own study.'**
  String get studyImportCollectionSeparate;

  /// Study workflow control: studyImportNoOpenStudy
  ///
  /// In en, this message translates to:
  /// **'No study is open.'**
  String get studyImportNoOpenStudy;

  /// Study workflow control: studyImportDelay
  ///
  /// In en, this message translates to:
  /// **'Seconds between requests (chessgames.com)'**
  String get studyImportDelay;

  /// Study workflow control: studyImportDelayHelp
  ///
  /// In en, this message translates to:
  /// **'chessgames.com bans fast downloads: 2–3 s apart gets blocked after ~20 games, 22 s apart sustains 60. At 22 s a 60-game collection takes about 25 minutes, running in the background.'**
  String get studyImportDelayHelp;

  /// Study workflow control: studyImportContacting
  ///
  /// In en, this message translates to:
  /// **'Contacting the server…'**
  String get studyImportContacting;

  /// Study workflow control: studyImportLinkHint
  ///
  /// In en, this message translates to:
  /// **'Paste a link to see what will be imported.'**
  String get studyImportLinkHint;

  /// Study workflow control: studyImportUnsupportedUrl
  ///
  /// In en, this message translates to:
  /// **'Not a Lichess study or chessgames.com collection link.'**
  String get studyImportUnsupportedUrl;

  /// Study workflow control: studyImportCollectionBlocked
  ///
  /// In en, this message translates to:
  /// **'Collection page blocked'**
  String get studyImportCollectionBlocked;

  /// Study workflow control: studyImportPasteIdsHelp
  ///
  /// In en, this message translates to:
  /// **'chessgames.com served a bot check instead of the collection. Downloading the games still works — it just needs the list.\n\nOpen the collection in a browser, select all (Ctrl+A) and copy, or save the page source, then paste it below.'**
  String get studyImportPasteIdsHelp;

  /// Study workflow control: studyImportOpenCollection
  ///
  /// In en, this message translates to:
  /// **'Open the collection page'**
  String get studyImportOpenCollection;

  /// Study workflow control: studyImportPasteIdsHint
  ///
  /// In en, this message translates to:
  /// **'Paste the page, game links, or game ids…'**
  String get studyImportPasteIdsHint;

  /// Study workflow control: studyImportNoIds
  ///
  /// In en, this message translates to:
  /// **'No game ids found yet.'**
  String get studyImportNoIds;

  /// Study workflow control: studyDownload
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get studyDownload;

  /// Study workflow control: studyNumberedNew
  ///
  /// In en, this message translates to:
  /// **'New study ({count})'**
  String studyNumberedNew(int count);

  /// Study workflow control: studyChapterCount
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 chapter} other{{count} chapters}}'**
  String studyChapterCount(int count);

  /// Study workflow control: studyPreferredChapterCount
  ///
  /// In en, this message translates to:
  /// **'Prep file · {count, plural, =1{1 chapter} other{{count} chapters}}'**
  String studyPreferredChapterCount(int count);

  /// Study workflow control: studyAddLine
  ///
  /// In en, this message translates to:
  /// **'Add line to study'**
  String get studyAddLine;

  /// Study and PGN control: studyNewStudy
  ///
  /// In en, this message translates to:
  /// **'New study'**
  String get studyNewStudy;

  /// Study and PGN control: studyAddNewStudy
  ///
  /// In en, this message translates to:
  /// **'Add new study'**
  String get studyAddNewStudy;

  /// Study and PGN control: studyStudyName
  ///
  /// In en, this message translates to:
  /// **'Study name'**
  String get studyStudyName;

  /// Study and PGN control: studyCreateAndAdd
  ///
  /// In en, this message translates to:
  /// **'Create and add'**
  String get studyCreateAndAdd;

  /// Study and PGN control: studyNameRequired
  ///
  /// In en, this message translates to:
  /// **'Please enter a study name.'**
  String get studyNameRequired;

  /// Study and PGN control: studyNameExists
  ///
  /// In en, this message translates to:
  /// **'A study with this name already exists.'**
  String get studyNameExists;

  /// Study and PGN control: studyChapterName
  ///
  /// In en, this message translates to:
  /// **'Chapter name'**
  String get studyChapterName;

  /// Study and PGN control: studySearchExisting
  ///
  /// In en, this message translates to:
  /// **'Search existing studies'**
  String get studySearchExisting;

  /// Study and PGN control: studyNoStudiesToAdd
  ///
  /// In en, this message translates to:
  /// **'No studies yet. Use Add new study to create one.'**
  String get studyNoStudiesToAdd;

  /// Study and PGN control: studyNoStudiesMatch
  ///
  /// In en, this message translates to:
  /// **'No studies match your search.'**
  String get studyNoStudiesMatch;

  /// Study workflow control: studyEditChapterMenu
  ///
  /// In en, this message translates to:
  /// **'Edit chapter…'**
  String get studyEditChapterMenu;

  /// Study workflow control: studySetStartMenu
  ///
  /// In en, this message translates to:
  /// **'Set starting position…'**
  String get studySetStartMenu;

  /// Study workflow control: studyCopyChapter
  ///
  /// In en, this message translates to:
  /// **'Copy chapter PGN'**
  String get studyCopyChapter;

  /// Study workflow control: studyClearAnnotationsMenu
  ///
  /// In en, this message translates to:
  /// **'Clear comments, glyphs and shapes…'**
  String get studyClearAnnotationsMenu;

  /// Study workflow control: studyClearVariationsMenu
  ///
  /// In en, this message translates to:
  /// **'Clear variations…'**
  String get studyClearVariationsMenu;

  /// Study workflow control: studyDeleteChapterMenu
  ///
  /// In en, this message translates to:
  /// **'Delete chapter…'**
  String get studyDeleteChapterMenu;

  /// Study workflow control: studyNoChapters
  ///
  /// In en, this message translates to:
  /// **'No chapters'**
  String get studyNoChapters;

  /// Study workflow control: studyManageChapters
  ///
  /// In en, this message translates to:
  /// **'Manage & reorder chapters…'**
  String get studyManageChapters;

  /// Study workflow control: studyChapter
  ///
  /// In en, this message translates to:
  /// **'Chapter'**
  String get studyChapter;

  /// Study workflow control: studyRename
  ///
  /// In en, this message translates to:
  /// **'Rename study'**
  String get studyRename;

  /// Study and PGN control: studySwitch
  ///
  /// In en, this message translates to:
  /// **'Switch study'**
  String get studySwitch;

  /// Study and PGN control: studyNameConfirm
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get studyNameConfirm;

  /// Study and PGN control: studyNameUnusable
  ///
  /// In en, this message translates to:
  /// **'That name has no characters a file can use.'**
  String get studyNameUnusable;

  /// Study and PGN control: studyAddFailed
  ///
  /// In en, this message translates to:
  /// **'Failed to add to study.'**
  String get studyAddFailed;

  /// Study and PGN control: studyHistoryTitle
  ///
  /// In en, this message translates to:
  /// **'Study: {name}'**
  String studyHistoryTitle(String name);

  /// Study and PGN control: pgnDeleteOneComment
  ///
  /// In en, this message translates to:
  /// **'Delete 1 comment?'**
  String get pgnDeleteOneComment;

  /// Study and PGN control: pgnSaveComment
  ///
  /// In en, this message translates to:
  /// **'Save comment'**
  String get pgnSaveComment;

  /// Study and PGN control: pgnComment
  ///
  /// In en, this message translates to:
  /// **'Comment'**
  String get pgnComment;

  /// Study and PGN control: pgnCollapseComment
  ///
  /// In en, this message translates to:
  /// **'Collapse comment'**
  String get pgnCollapseComment;

  /// Study and PGN control: pgnEditComment
  ///
  /// In en, this message translates to:
  /// **'Edit comment'**
  String get pgnEditComment;

  /// Study and PGN control: pgnCommentKept
  ///
  /// In en, this message translates to:
  /// **'Comment kept until deleted'**
  String get pgnCommentKept;

  /// Study and PGN control: pgnCommentLabel
  ///
  /// In en, this message translates to:
  /// **'Comment:'**
  String get pgnCommentLabel;

  /// Study and PGN control: pgnDeleteComment
  ///
  /// In en, this message translates to:
  /// **'Delete comment'**
  String get pgnDeleteComment;

  /// Study and PGN control: pgnSelectMoveNotes
  ///
  /// In en, this message translates to:
  /// **'Select a move to add notes'**
  String get pgnSelectMoveNotes;

  /// Study and PGN control: pgnRemoveCommentOn
  ///
  /// In en, this message translates to:
  /// **'Remove the comment on {move}'**
  String pgnRemoveCommentOn(String move);

  /// Study and PGN control: pgnLineCopied
  ///
  /// In en, this message translates to:
  /// **'Line copied to clipboard'**
  String get pgnLineCopied;

  /// Study and PGN control: pgnMove
  ///
  /// In en, this message translates to:
  /// **'Move'**
  String get pgnMove;

  /// Study and PGN control: pgnEditCommentMenu
  ///
  /// In en, this message translates to:
  /// **'Edit Comment'**
  String get pgnEditCommentMenu;

  /// Study and PGN control: pgnAddCommentMenu
  ///
  /// In en, this message translates to:
  /// **'Add Comment'**
  String get pgnAddCommentMenu;

  /// Study and PGN control: pgnUnmarkQuizStart
  ///
  /// In en, this message translates to:
  /// **'Unmark Quiz Start'**
  String get pgnUnmarkQuizStart;

  /// Study and PGN control: pgnMarkQuizStart
  ///
  /// In en, this message translates to:
  /// **'Start Quiz From This Move'**
  String get pgnMarkQuizStart;

  /// Study and PGN control: pgnUnmarkQuizEnd
  ///
  /// In en, this message translates to:
  /// **'Unmark Quiz End'**
  String get pgnUnmarkQuizEnd;

  /// Study and PGN control: pgnMarkQuizEnd
  ///
  /// In en, this message translates to:
  /// **'End Quiz After This Move'**
  String get pgnMarkQuizEnd;

  /// Study and PGN control: pgnPromoteVariation
  ///
  /// In en, this message translates to:
  /// **'Promote Variation'**
  String get pgnPromoteVariation;

  /// Study and PGN control: pgnMakeMainLine
  ///
  /// In en, this message translates to:
  /// **'Make Main Line'**
  String get pgnMakeMainLine;

  /// Study and PGN control: pgnCopyWholeLine
  ///
  /// In en, this message translates to:
  /// **'Copy Whole Line'**
  String get pgnCopyWholeLine;

  /// Study and PGN control: pgnCopyFromHere
  ///
  /// In en, this message translates to:
  /// **'Copy PGN from Here'**
  String get pgnCopyFromHere;

  /// Study and PGN control: pgnViewInLines
  ///
  /// In en, this message translates to:
  /// **'View in Lines'**
  String get pgnViewInLines;

  /// Study and PGN control: pgnDeleteFromHere
  ///
  /// In en, this message translates to:
  /// **'Delete from Here'**
  String get pgnDeleteFromHere;

  /// Study and PGN control: pgnLineTitle
  ///
  /// In en, this message translates to:
  /// **'Line title'**
  String get pgnLineTitle;

  /// Study and PGN control: pgnStartPosition
  ///
  /// In en, this message translates to:
  /// **'the start position'**
  String get pgnStartPosition;

  /// Study and PGN control: pgnEmptyEditor
  ///
  /// In en, this message translates to:
  /// **'Play a move or select a saved line.'**
  String get pgnEmptyEditor;

  /// Study and PGN control: pgnQuizEndHelp
  ///
  /// In en, this message translates to:
  /// **'Quiz ends here: training stops after this move'**
  String get pgnQuizEndHelp;

  /// Study and PGN control: pgnDeleteContinuations
  ///
  /// In en, this message translates to:
  /// **'This removes the move and all continuations from here, including their annotations.'**
  String get pgnDeleteContinuations;

  /// Study and PGN control: pgnQuizStartHelp
  ///
  /// In en, this message translates to:
  /// **'Quiz starts here: training auto-plays the moves before this one and asks for this one'**
  String get pgnQuizStartHelp;

  /// Study and PGN control: studyBackMove
  ///
  /// In en, this message translates to:
  /// **'Back one move'**
  String get studyBackMove;

  /// Study and PGN control: studyForwardMove
  ///
  /// In en, this message translates to:
  /// **'Forward one move'**
  String get studyForwardMove;

  /// Study and PGN control: studyGoStart
  ///
  /// In en, this message translates to:
  /// **'Go to start'**
  String get studyGoStart;

  /// Study and PGN control: studyGoEnd
  ///
  /// In en, this message translates to:
  /// **'Go to end'**
  String get studyGoEnd;

  /// Study and PGN control: studyToggleEngine
  ///
  /// In en, this message translates to:
  /// **'Toggle engine'**
  String get studyToggleEngine;

  /// Study and PGN control: studyFlipBoard
  ///
  /// In en, this message translates to:
  /// **'Flip board'**
  String get studyFlipBoard;

  /// Study and PGN control: studyBrowsePgn
  ///
  /// In en, this message translates to:
  /// **'Browse in PGN viewer'**
  String get studyBrowsePgn;

  /// Study and PGN control: studyNextChapter
  ///
  /// In en, this message translates to:
  /// **'Next chapter'**
  String get studyNextChapter;

  /// Study and PGN control: studyPreviousChapter
  ///
  /// In en, this message translates to:
  /// **'Previous chapter'**
  String get studyPreviousChapter;

  /// Study and PGN control: studyFocusInput
  ///
  /// In en, this message translates to:
  /// **'Focus move input'**
  String get studyFocusInput;

  /// Study and PGN control: studyCommentCurrent
  ///
  /// In en, this message translates to:
  /// **'Comment current move'**
  String get studyCommentCurrent;

  /// Study and PGN control: studyImportPgnChapters
  ///
  /// In en, this message translates to:
  /// **'Import PGN as chapters'**
  String get studyImportPgnChapters;

  /// Study and PGN control: studyNoPgnGames
  ///
  /// In en, this message translates to:
  /// **'No games found in that PGN.'**
  String get studyNoPgnGames;

  /// Study and PGN control: studyPgnCopied
  ///
  /// In en, this message translates to:
  /// **'Study PGN copied to clipboard.'**
  String get studyPgnCopied;

  /// Study and PGN control: studyReplacePosition
  ///
  /// In en, this message translates to:
  /// **'Replace starting position?'**
  String get studyReplacePosition;

  /// Study and PGN control: studyReplace
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get studyReplace;

  /// Study and PGN control: studySetPosition
  ///
  /// In en, this message translates to:
  /// **'Set chapter position'**
  String get studySetPosition;

  /// Study and PGN control: studySaveFirst
  ///
  /// In en, this message translates to:
  /// **'Save the study first (create it by name).'**
  String get studySaveFirst;

  /// Study and PGN control: studyNoTrainingChapters
  ///
  /// In en, this message translates to:
  /// **'No chapters with moves to train yet.'**
  String get studyNoTrainingChapters;

  /// Study and PGN control: studyNoTrainingMoves
  ///
  /// In en, this message translates to:
  /// **'This chapter has no moves to train yet.'**
  String get studyNoTrainingMoves;

  /// Study and PGN control: studyChapterPgnCopied
  ///
  /// In en, this message translates to:
  /// **'Chapter PGN copied to clipboard.'**
  String get studyChapterPgnCopied;

  /// Study and PGN control: studyClearAnnotations
  ///
  /// In en, this message translates to:
  /// **'Clear all comments, glyphs and shapes?'**
  String get studyClearAnnotations;

  /// Study and PGN control: clear
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// Study and PGN control: studyClearVariations
  ///
  /// In en, this message translates to:
  /// **'Clear variations?'**
  String get studyClearVariations;

  /// Study and PGN control: studyNeedsChapter
  ///
  /// In en, this message translates to:
  /// **'A study needs at least one chapter.'**
  String get studyNeedsChapter;

  /// Study and PGN control: studyFromUrl
  ///
  /// In en, this message translates to:
  /// **'From URL…'**
  String get studyFromUrl;

  /// Study and PGN control: studyPgnFileChapters
  ///
  /// In en, this message translates to:
  /// **'PGN file as chapters…'**
  String get studyPgnFileChapters;

  /// Study and PGN control: studyExportHeading
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get studyExportHeading;

  /// Study and PGN control: studyCopyPgn
  ///
  /// In en, this message translates to:
  /// **'Copy study PGN'**
  String get studyCopyPgn;

  /// Study and PGN control: studySavePgnAs
  ///
  /// In en, this message translates to:
  /// **'Save study PGN as…'**
  String get studySavePgnAs;

  /// Study and PGN control: studyTrainHeading
  ///
  /// In en, this message translates to:
  /// **'Train'**
  String get studyTrainHeading;

  /// Study and PGN control: studyTrainChapter
  ///
  /// In en, this message translates to:
  /// **'Train this chapter'**
  String get studyTrainChapter;

  /// Study and PGN control: studyTrainAll
  ///
  /// In en, this message translates to:
  /// **'Train whole study'**
  String get studyTrainAll;

  /// Study and PGN control: studyBoardHeading
  ///
  /// In en, this message translates to:
  /// **'Board'**
  String get studyBoardHeading;

  /// Study and PGN control: studyExploreHeading
  ///
  /// In en, this message translates to:
  /// **'Explore'**
  String get studyExploreHeading;

  /// Study and PGN control: studyManageHeading
  ///
  /// In en, this message translates to:
  /// **'Manage'**
  String get studyManageHeading;

  /// Study and PGN control: studyDeleteMenu
  ///
  /// In en, this message translates to:
  /// **'Delete study…'**
  String get studyDeleteMenu;

  /// Study and PGN control: studySearch
  ///
  /// In en, this message translates to:
  /// **'Search studies'**
  String get studySearch;

  /// Study and PGN control: studyNoStudies
  ///
  /// In en, this message translates to:
  /// **'No studies yet — import or create one.'**
  String get studyNoStudies;

  /// Study and PGN control: studyGoChapter
  ///
  /// In en, this message translates to:
  /// **'Go to chapter'**
  String get studyGoChapter;

  /// Study and PGN control: studyNoChaptersYet
  ///
  /// In en, this message translates to:
  /// **'This study has no chapters yet.'**
  String get studyNoChaptersYet;

  /// Study and PGN control: studyAddedChapters
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Added 1 chapter.} other{Added {count} chapters.}}'**
  String studyAddedChapters(int count);

  /// Study and PGN control: studyDeleteNamed
  ///
  /// In en, this message translates to:
  /// **'Delete study \"{name}\"?'**
  String studyDeleteNamed(String name);

  /// Study and PGN control: studyDeleteChapterNamed
  ///
  /// In en, this message translates to:
  /// **'Delete chapter \"{name}\"?'**
  String studyDeleteChapterNamed(String name);

  /// Study and PGN control: studyChapterNumber
  ///
  /// In en, this message translates to:
  /// **'Chapter {number}'**
  String studyChapterNumber(int number);

  /// Study and PGN control: studyPgnHistory
  ///
  /// In en, this message translates to:
  /// **'PGN: {name}'**
  String studyPgnHistory(String name);

  /// Study and PGN control: boardInvalidFen
  ///
  /// In en, this message translates to:
  /// **'Could not parse FEN. Check all fields.'**
  String get boardInvalidFen;

  /// Study and PGN control: boardWhiteToMove
  ///
  /// In en, this message translates to:
  /// **'White to move'**
  String get boardWhiteToMove;

  /// Study and PGN control: boardBlackToMove
  ///
  /// In en, this message translates to:
  /// **'Black to move'**
  String get boardBlackToMove;

  /// Study and PGN control: boardStartPosition
  ///
  /// In en, this message translates to:
  /// **'Start position'**
  String get boardStartPosition;

  /// Study and PGN control: boardClear
  ///
  /// In en, this message translates to:
  /// **'Clear board'**
  String get boardClear;

  /// Study and PGN control: boardAdvanced
  ///
  /// In en, this message translates to:
  /// **'Advanced position settings'**
  String get boardAdvanced;

  /// Study and PGN control: boardCastlingEnPassant
  ///
  /// In en, this message translates to:
  /// **'Castling and en passant'**
  String get boardCastlingEnPassant;

  /// Study and PGN control: boardCastling
  ///
  /// In en, this message translates to:
  /// **'Castling'**
  String get boardCastling;

  /// Study and PGN control: boardEnPassant
  ///
  /// In en, this message translates to:
  /// **'En passant'**
  String get boardEnPassant;

  /// Study and PGN control: boardNoEnPassant
  ///
  /// In en, this message translates to:
  /// **'none'**
  String get boardNoEnPassant;

  /// Study and PGN control: boardFenPending
  ///
  /// In en, this message translates to:
  /// **'Apply or discard the FEN text before using this position.'**
  String get boardFenPending;

  /// Study and PGN control: boardCopyFen
  ///
  /// In en, this message translates to:
  /// **'Copy FEN'**
  String get boardCopyFen;

  /// Study and PGN control: boardFenCopied
  ///
  /// In en, this message translates to:
  /// **'FEN copied.'**
  String get boardFenCopied;

  /// Study and PGN control: boardPasteFen
  ///
  /// In en, this message translates to:
  /// **'Paste FEN'**
  String get boardPasteFen;

  /// Study and PGN control: boardApplyFen
  ///
  /// In en, this message translates to:
  /// **'Apply FEN'**
  String get boardApplyFen;

  /// Study and PGN control: boardDiscardFen
  ///
  /// In en, this message translates to:
  /// **'Discard FEN changes'**
  String get boardDiscardFen;

  /// Study and PGN control: boardSetupHelp
  ///
  /// In en, this message translates to:
  /// **'Drag pieces where you want them, or click a spare piece and paint it onto squares. Right-click clears a square; with a piece in hand it switches the colour.'**
  String get boardSetupHelp;

  /// Study and PGN control: boardCastleSide
  ///
  /// In en, this message translates to:
  /// **'{side} {castle}'**
  String boardCastleSide(String side, String castle);

  /// Study and PGN control: boardMovePieces
  ///
  /// In en, this message translates to:
  /// **'Move pieces'**
  String get boardMovePieces;

  /// Study and PGN control: boardErasePieces
  ///
  /// In en, this message translates to:
  /// **'Erase pieces'**
  String get boardErasePieces;

  /// Study and PGN control: boardPiecePawn
  ///
  /// In en, this message translates to:
  /// **'pawn'**
  String get boardPiecePawn;

  /// Study and PGN control: boardPieceKnight
  ///
  /// In en, this message translates to:
  /// **'knight'**
  String get boardPieceKnight;

  /// Study and PGN control: boardPieceBishop
  ///
  /// In en, this message translates to:
  /// **'bishop'**
  String get boardPieceBishop;

  /// Study and PGN control: boardPieceRook
  ///
  /// In en, this message translates to:
  /// **'rook'**
  String get boardPieceRook;

  /// Study and PGN control: boardPieceQueen
  ///
  /// In en, this message translates to:
  /// **'queen'**
  String get boardPieceQueen;

  /// Study and PGN control: boardPieceKing
  ///
  /// In en, this message translates to:
  /// **'king'**
  String get boardPieceKing;

  /// Study and PGN control: boardPieceName
  ///
  /// In en, this message translates to:
  /// **'{side} {piece}'**
  String boardPieceName(String side, String piece);

  /// Study and PGN control: boardSpareHelp
  ///
  /// In en, this message translates to:
  /// **'{piece}: drag onto the board, or click to paint with it'**
  String boardSpareHelp(String piece);

  /// Study and PGN control: copyDone
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copyDone;

  /// Study and PGN control: copyAction
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copyAction;

  /// Study and PGN control: choiceCloseList
  ///
  /// In en, this message translates to:
  /// **'Close list'**
  String get choiceCloseList;

  /// Study and PGN control: choiceShowAll
  ///
  /// In en, this message translates to:
  /// **'Show all'**
  String get choiceShowAll;

  /// Study and PGN control: choiceNothing
  ///
  /// In en, this message translates to:
  /// **'Nothing to choose from'**
  String get choiceNothing;

  /// Study and PGN control: choiceNoMatches
  ///
  /// In en, this message translates to:
  /// **'No matches'**
  String get choiceNoMatches;

  /// Study and PGN control: pgnNotSavedFile
  ///
  /// In en, this message translates to:
  /// **'Not saved to a file'**
  String get pgnNotSavedFile;

  /// Study and PGN control: pgnChooseSaveFile
  ///
  /// In en, this message translates to:
  /// **'Use Save as… to choose a PGN file.'**
  String get pgnChooseSaveFile;

  /// Study and PGN control: pgnAutoSaved
  ///
  /// In en, this message translates to:
  /// **'Autosave on · Saved'**
  String get pgnAutoSaved;

  /// Study and PGN control: pgnManualSaved
  ///
  /// In en, this message translates to:
  /// **'Autosave off · Saved'**
  String get pgnManualSaved;

  /// Study and PGN control: pgnSavingPath
  ///
  /// In en, this message translates to:
  /// **'Saving changes to {path}'**
  String pgnSavingPath(String path);

  /// Study and PGN control: pgnManualSavePath
  ///
  /// In en, this message translates to:
  /// **'Autosave is off. Use Save to write changes to {path}'**
  String pgnManualSavePath(String path);

  /// Study and PGN control: pgnAutoSavePath
  ///
  /// In en, this message translates to:
  /// **'Changes save automatically to {path}'**
  String pgnAutoSavePath(String path);

  /// Study and PGN control: pgnNeedsManualSavePath
  ///
  /// In en, this message translates to:
  /// **'Changes need a manual save to {path}'**
  String pgnNeedsManualSavePath(String path);

  /// Study and PGN control: pgnDeleteCounts
  ///
  /// In en, this message translates to:
  /// **'Delete {moves, plural, =1{1 move} other{{moves} moves}} and {comments, plural, =1{1 comment} other{{comments} comments}}?'**
  String pgnDeleteCounts(int moves, int comments);

  /// Study and PGN control: studyDeleteContents
  ///
  /// In en, this message translates to:
  /// **'{chapters, plural, =1{1 chapter} other{{chapters} chapters}} with {moves, plural, =1{1 move} other{{moves} moves}} and {comments, plural, =1{1 comment} other{{comments} comments}}. The PGN file will be moved to Chess Auto Prep recovery trash.'**
  String studyDeleteContents(int chapters, int moves, int comments);

  /// Study and PGN control: studyReplacePositionContents
  ///
  /// In en, this message translates to:
  /// **'Chapter \"{name}\" already has moves; setting a new starting position will clear them.'**
  String studyReplacePositionContents(String name);

  /// Study and PGN control: studyClearAnnotationContents
  ///
  /// In en, this message translates to:
  /// **'Remove {comments, plural, =1{1 comment} other{{comments} comments}} and all glyphs and shapes from \"{name}\". The moves stay.'**
  String studyClearAnnotationContents(int comments, String name);

  /// Study and PGN control: studyClearVariationContents
  ///
  /// In en, this message translates to:
  /// **'Remove {moves, plural, =1{1 move} other{{moves} moves}} and {comments, plural, =1{1 comment} other{{comments} comments}} from \"{name}\", including sideline annotations. The main line and its notes stay.'**
  String studyClearVariationContents(int moves, int comments, String name);

  /// Study and PGN control: studyRemoveCounts
  ///
  /// In en, this message translates to:
  /// **'Remove {moves, plural, =1{1 move} other{{moves} moves}} and {comments, plural, =1{1 comment} other{{comments} comments}}, including all annotations.'**
  String studyRemoveCounts(int moves, int comments);

  /// Study and PGN control: studyLichessSource
  ///
  /// In en, this message translates to:
  /// **'Lichess study · {id}'**
  String studyLichessSource(String id);

  /// Study and PGN control: studyLichessChapterSource
  ///
  /// In en, this message translates to:
  /// **'Lichess study chapter · {study}/{chapter}'**
  String studyLichessChapterSource(String study, String chapter);

  /// Study and PGN control: studyLichessUserSource
  ///
  /// In en, this message translates to:
  /// **'Lichess · all of {user}\'s studies'**
  String studyLichessUserSource(String user);

  /// Study and PGN control: studyCollectionSource
  ///
  /// In en, this message translates to:
  /// **'chessgames.com collection · cid {id}'**
  String studyCollectionSource(String id);

  /// Engine analysis control or status: engineAppearanceToggle
  ///
  /// In en, this message translates to:
  /// **'Toggle engine'**
  String get engineAppearanceToggle;

  /// Engine analysis control or status: engineAppearanceEngine
  ///
  /// In en, this message translates to:
  /// **'Engine'**
  String get engineAppearanceEngine;

  /// Engine analysis control or status: engineAppearanceBusy
  ///
  /// In en, this message translates to:
  /// **'Engine busy'**
  String get engineAppearanceBusy;

  /// Engine analysis control or status: engineAppearanceHideThreat
  ///
  /// In en, this message translates to:
  /// **'Hide threat'**
  String get engineAppearanceHideThreat;

  /// Engine analysis control or status: engineAppearanceShowThreat
  ///
  /// In en, this message translates to:
  /// **'Show threat'**
  String get engineAppearanceShowThreat;

  /// Engine analysis control or status: engineAppearanceStopAnalysis
  ///
  /// In en, this message translates to:
  /// **'Stop analysis'**
  String get engineAppearanceStopAnalysis;

  /// Engine analysis control or status: engineAppearanceStartAnalysis
  ///
  /// In en, this message translates to:
  /// **'Start analysis'**
  String get engineAppearanceStartAnalysis;

  /// Engine analysis control or status: engineAppearanceStop
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get engineAppearanceStop;

  /// Engine analysis control or status: engineAppearanceLocalEngine
  ///
  /// In en, this message translates to:
  /// **'Local engine'**
  String get engineAppearanceLocalEngine;

  /// Engine analysis control or status: engineAppearanceOptions
  ///
  /// In en, this message translates to:
  /// **'Analysis options'**
  String get engineAppearanceOptions;

  /// Engine analysis control or status: engineAppearanceNoLegalMoves
  ///
  /// In en, this message translates to:
  /// **'No legal moves.'**
  String get engineAppearanceNoLegalMoves;

  /// Engine analysis control or status: engineAppearanceAnalyzing
  ///
  /// In en, this message translates to:
  /// **'Analyzing...'**
  String get engineAppearanceAnalyzing;

  /// Engine analysis control or status: engineAppearanceFailure
  ///
  /// In en, this message translates to:
  /// **'Engine failed. Toggle it to retry.'**
  String get engineAppearanceFailure;

  /// Engine analysis control or status: engineAppearanceSettings
  ///
  /// In en, this message translates to:
  /// **'Engine settings'**
  String get engineAppearanceSettings;

  /// Engine analysis control or status: engineAppearanceCollapseLine
  ///
  /// In en, this message translates to:
  /// **'Collapse line'**
  String get engineAppearanceCollapseLine;

  /// Engine analysis control or status: engineAppearanceShowFullLine
  ///
  /// In en, this message translates to:
  /// **'Show full line'**
  String get engineAppearanceShowFullLine;

  /// Engine analysis control or status: engineNoticeLocked
  ///
  /// In en, this message translates to:
  /// **'Stockfish is busy building your repertoire. Pause the build or wait for it to finish before using engine analysis.'**
  String get engineNoticeLocked;

  /// Engine analysis control or status: engineNoticeBusyCompact
  ///
  /// In en, this message translates to:
  /// **'Engine busy — building your repertoire.'**
  String get engineNoticeBusyCompact;

  /// Engine analysis control or status: engineNoticeBusyTitle
  ///
  /// In en, this message translates to:
  /// **'Engine Busy'**
  String get engineNoticeBusyTitle;

  /// Engine analysis control or status: engineNoticeBusyBody
  ///
  /// In en, this message translates to:
  /// **'Stockfish is building your repertoire.\nPause the build or let it finish to analyze again.'**
  String get engineNoticeBusyBody;

  /// Engine analysis control or status: engineAppearanceSearchStatus
  ///
  /// In en, this message translates to:
  /// **'{mode, select, threat{Threat · } other{}}Depth {depth} • {nodes} nodes'**
  String engineAppearanceSearchStatus(String mode, int depth, String nodes);

  /// Engine analysis control or status: engineAppearanceLinesStatus
  ///
  /// In en, this message translates to:
  /// **'{mode, select, threat{Threat · } other{}}{count, plural, =1{1 line} other{{count} lines}} • depth {depth}'**
  String engineAppearanceLinesStatus(String mode, int count, int depth);

  /// Engine analysis control or status: engineAppearanceDepthStatus
  ///
  /// In en, this message translates to:
  /// **'Depth {depth} · {nodes} nodes'**
  String engineAppearanceDepthStatus(int depth, String nodes);

  /// Study and PGN control: boardSetupTitle
  ///
  /// In en, this message translates to:
  /// **'Set up position'**
  String get boardSetupTitle;

  /// Study and PGN control: boardUsePosition
  ///
  /// In en, this message translates to:
  /// **'Use position'**
  String get boardUsePosition;

  /// Builder generation configuration admission and cut recovery feedback.
  ///
  /// In en, this message translates to:
  /// **'The chapter changed. Close this configuration and open it again.'**
  String get generationSourceChanged;

  /// Builder generation configuration admission and cut recovery feedback.
  ///
  /// In en, this message translates to:
  /// **'Reload the chapter and reopen this configuration before making further changes.'**
  String get generationConfigurationRefreshRequired;

  /// Builder generation configuration admission and cut recovery feedback.
  ///
  /// In en, this message translates to:
  /// **'The cut could not be confirmed. Reload the chapter before making further changes.'**
  String get generationCutUnconfirmed;

  /// Acknowledged cut count when the original chapter view cannot be refreshed.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{The chapter could not be refreshed. Reload it and reopen this configuration before making further changes.} =1{Removed 1 line, but this configuration could not be refreshed. Reload the chapter before making further changes.} other{Removed {count} lines, but this configuration could not be refreshed. Reload the chapter before making further changes.}}'**
  String generationCutRefreshRequired(int count);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
