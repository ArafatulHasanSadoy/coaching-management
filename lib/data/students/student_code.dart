/// Builds student IDs from the centre's own pattern.
///
/// Centres already have a numbering habit — printed on ID cards, written in
/// ledgers, quoted over the phone — so the pattern is configurable rather than
/// imposed. Supported placeholders:
///
///   `{YY}`    two-digit year        `{YYYY}`  four-digit year
///   `{#####}` zero-padded sequence, width set by the number of hashes
///
/// `AEC-{YY}-{#####}` produces `AEC-26-00427`.
abstract final class StudentCode {
  static final _sequence = RegExp(r'\{(#+)\}');

  /// The fixed part of a pattern for a given year — everything before the
  /// sequence. Used to find which existing codes belong to the same series.
  static String prefixFor(String pattern, DateTime when) {
    final resolved = _resolveYear(pattern, when);
    final match = _sequence.firstMatch(resolved);
    return match == null ? resolved : resolved.substring(0, match.start);
  }

  /// Renders [pattern] for [when] with [sequence] filled in.
  static String render({
    required String pattern,
    required DateTime when,
    required int sequence,
  }) {
    final resolved = _resolveYear(pattern, when);
    final match = _sequence.firstMatch(resolved);
    if (match == null) return '$resolved$sequence';

    final width = match.group(1)!.length;
    return resolved.replaceRange(
      match.start,
      match.end,
      sequence.toString().padLeft(width, '0'),
    );
  }

  /// Reads the sequence number back out of an existing code.
  ///
  /// Returns null when the code does not belong to this series or has no
  /// numeric tail — a centre that renumbered mid-year, or a code typed by hand.
  static int? sequenceOf(String code, String prefix) {
    if (!code.startsWith(prefix)) return null;
    final tail = code.substring(prefix.length);
    final digits = RegExp(r'^\d+').firstMatch(tail)?.group(0);
    return digits == null ? null : int.tryParse(digits);
  }

  /// The next code in the series, given every code already issued.
  ///
  /// Takes the highest sequence rather than the count, so deleting or skipping
  /// a student can never hand out a number that is already on an ID card.
  static String next({
    required String pattern,
    required DateTime when,
    required Iterable<String> existingCodes,
  }) {
    final prefix = prefixFor(pattern, when);
    var highest = 0;
    for (final code in existingCodes) {
      final n = sequenceOf(code, prefix);
      if (n != null && n > highest) highest = n;
    }
    return render(pattern: pattern, when: when, sequence: highest + 1);
  }

  static String _resolveYear(String pattern, DateTime when) => pattern
      .replaceAll('{YYYY}', when.year.toString())
      .replaceAll('{YY}', (when.year % 100).toString().padLeft(2, '0'));
}
