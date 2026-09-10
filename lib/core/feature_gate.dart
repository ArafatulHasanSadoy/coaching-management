/// Decides whether a paid feature is available.
///
/// The app ships free with monetisation deferred, so every gate is currently
/// open. This exists anyway because the alternative — deciding to charge later
/// and then finding every entry point across the app — is the expensive version
/// of the same work. One place to change, whenever that decision is made.
abstract interface class FeatureGate {
  bool isUnlocked(Feature feature);
}

/// Things that might one day sit behind a paid tier. Listed now only so the call
/// sites read naturally; nothing here is enforced.
enum Feature {
  unlimitedStudents,
  smartRoutine,
  questionPaperBuilder,
  advancedReports,
}

/// The v1 implementation: everything is available to everyone.
class OpenFeatureGate implements FeatureGate {
  const OpenFeatureGate();

  @override
  bool isUnlocked(Feature feature) => true;
}
