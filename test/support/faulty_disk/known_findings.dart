// The confirmed findings more than one fault matrix scenario's ledger names,
// each as the title of the fix still owed. A scenario's `known` entry maps a
// violation to one of these; the matrix fails once the violation is gone, so
// an entry is removed with the fix.

const twoNames =
    'A create killed between link and unlink (createFileExclusively in '
    'lib/storage/atomic_write.dart, native cap_install_new) leaves the new '
    'chapter with a second name, which PgnFileStore.open and '
    'ChapterDirectory.list report unreadable (st_nlink != 1) until a later '
    'write in its folder removes the staged name.';

const recordReadFailed =
    'readJournal (lib/storage/journal_records.dart) quarantines a compound '
    'or relocation record whose read failed with a transient I/O error, saw '
    'the file change, or briefly found it missing, as if it were damaged, so '
    'the operation a crash left half done stays half done: a course renamed '
    'and not its book selector, a moved or deleted chapter whose training '
    'rows and book selectors still name its old path.';

const briefMissingSetsAside =
    'When a participant or its folder (a PGN, a training file, Documents, a '
    'repertoire folder, books.json) briefly reads as missing during '
    'recovery, CompoundWrites (lib/storage/compound_write.dart) and '
    'FileRelocations (lib/storage/file_relocation.dart) take it for '
    'another program\'s change and set the record aside although part of it '
    'had landed, orphaning references: a course renamed and not its book '
    'selector, a moved line\'s streak row naming the source chapter, a moved '
    'chapter\'s book selector naming its old path. Recovery cannot tell such '
    'a file from a deleted one; an owner decision on retrying before setting '
    'a record aside is owed.';

const journalMissingSkipped =
    'When Support, a journal folder or a record in it briefly reads as '
    'missing, recovery (CompoundWrites.recover and FileRelocations.recover, '
    'through readJournal in lib/storage/journal_records.dart) finds '
    'nothing to finish and the recovery gate counts itself done, so the '
    'operation a crash left half done stays half done, its references '
    'orphaned, for the rest of the session.';

const booksMissingSkipped =
    'When books.json briefly reads as missing while a relocation\'s recovery '
    'finishes, FileRelocations._finish (lib/storage/file_relocation.dart) '
    'gets null from recoveryText and _publish leaves books.json as it is, '
    'then forgets the record: the move completes with its book selectors '
    'still naming the chapter\'s old path.';

/// What faults planted inside the recovery of an operation journaled under
/// `Support/<journal>/` show, by finding; [books] for a relocation, which
/// repoints books.json without holding it as a participant.
Map<String, String> recoveryLedger(String journal, {bool books = false}) => {
  for (final family in ['recoveryFault', 'recoveryMissing'])
    for (final contract in ['O4', 'O1', 'O6'])
      '$family/*/read:Support/$journal/*/$contract': recordReadFailed,
  for (final stat in ['stat:Support#*', 'stat:Support/$journal*'])
    for (final contract in ['O7', 'O1', 'O6'])
      'recoveryMissing/*/$stat/$contract': journalMissingSkipped,
  for (final read in ['stat:Documents*', 'read:Documents/*'])
    'recoveryMissing/*/$read/O6': briefMissingSetsAside,
  if (books)
    for (final contract in ['O1', 'O6'])
      'recoveryMissing/*/read:Support/books.json#0/$contract':
          booksMissingSkipped,
};
