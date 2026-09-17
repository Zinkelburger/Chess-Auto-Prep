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

  /// Repertoire catalog: cancel
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

  /// Repertoire catalog: delete
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

  /// Repertoire catalog: importAction
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

  /// Shared document save interaction: documentDirty
  ///
  /// In en, this message translates to:
  /// **'Unsaved changes'**
  String get documentDirty;

  /// Shared document save interaction: documentSaving
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

  /// Workspace recovery display name
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

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Recover older analysis'**
  String get legacyAnalysisTitle;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Recover older analysis…'**
  String get legacyAnalysisAction;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'These older files have no recorded source revision. Inspect or export them here; they do not replace the current chapter or its verified analysis. Original files stay unchanged.'**
  String get legacyAnalysisProvenance;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Saved tree'**
  String get legacyAnalysisTree;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Saved probes'**
  String get legacyAnalysisProbes;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Saved traps'**
  String get legacyAnalysisTraps;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Unfinished build'**
  String get legacyAnalysisPartial;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Export original file…'**
  String get legacyAnalysisExport;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Choose a folder for the recovered file'**
  String get legacyAnalysisExportDirectory;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'No older analysis files found beside this chapter.'**
  String get legacyAnalysisEmpty;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Select a saved artifact to inspect its contents.'**
  String get legacyAnalysisSelect;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'No saved entries'**
  String get legacyAnalysisNoEntries;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Could not read this entry'**
  String get legacyAnalysisUnreadable;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Automatic resume is unavailable: this unfinished build has no verifiable source revision. You can inspect its explored positions, export the original file, or start a fresh build from the chapter.'**
  String get legacyAnalysisResumeUnavailable;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Saved configuration'**
  String get legacyAnalysisConfig;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Previous position'**
  String get legacyAnalysisParent;

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Recovery issue: {details}'**
  String legacyAnalysisFailure(String details);

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Original file exported to {path}'**
  String legacyAnalysisExported(String path);

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'Entry {number}'**
  String legacyAnalysisEntry(int number);

  /// Legacy generation artifact recovery
  ///
  /// In en, this message translates to:
  /// **'{nodes} saved nodes · depth {depth}'**
  String legacyAnalysisNodes(int nodes, int depth);
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
