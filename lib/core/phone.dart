/// Bangladeshi phone number handling.
///
/// Numbers arrive in every shape a human can type them: `01712-345678`,
/// `+8801712345678`, `8801712 345678`, `1712345678`. The front desk's most
/// frequent action is finding a student by the number a parent is calling from,
/// and duplicate detection at admission depends on the same comparison, so both
/// need one canonical form rather than string equality on whatever was typed.
abstract final class Phone {
  /// Reduces a number to its canonical local form: eleven digits beginning `01`.
  ///
  /// Returns an empty string when the input cannot be a Bangladeshi mobile
  /// number, so callers can treat "no usable number" as one case rather than
  /// carrying a null through every comparison.
  static String normalize(String raw) {
    var digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';

    // Strip an international prefix first, then apply the local rules to what
    // is left. Doing it the other way round misses `+8801712345678`, where the
    // remainder still needs its leading zero restored.
    if (digits.startsWith('00880') && digits.length > 12) {
      digits = digits.substring(5);
    } else if (digits.startsWith('880') && digits.length > 11) {
      digits = digits.substring(3);
    }

    // A spreadsheet that treated the number as an integer and ate the zero.
    if (digits.length == 10 && digits.startsWith('1')) {
      digits = '0$digits';
    }

    return digits.length == 11 && digits.startsWith('01') ? digits : '';
  }

  /// Whether [raw] looks like a usable Bangladeshi mobile number.
  static bool isValid(String raw) => normalize(raw).isNotEmpty;

  /// Groups a number for display: `01712-345678`.
  static String forDisplay(String raw) {
    final n = normalize(raw);
    if (n.isEmpty) return raw.trim();
    return '${n.substring(0, 5)}-${n.substring(5)}';
  }
}
