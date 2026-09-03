/// The app's own version string, for anything that has to report it.
///
/// A constant rather than `package_info_plus`, which is a platform plugin and
/// three method channels for one string that is known at compile time. It is
/// kept honest by `test/app_version_test.dart`, which reads pubspec.yaml and
/// fails if the two ever drift — the failure mode of a hand-written version
/// being that a bug report names the wrong build, which is worse than no
/// version at all.
const String kAppVersion = '1.15.2';
