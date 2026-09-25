/// Identity of one accepted history append, retained unchanged for exact retry.
/// The native adapter retains its prepared bytes in memory; this is not a
/// durable recovery record and does not survive restarting the application.
final class TrainingHistoryOperation {}
