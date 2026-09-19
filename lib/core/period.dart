/// Period keys and how they read to a human.
///
/// A period key is `2026-07`: sortable, unambiguous, and the thing the
/// database stores. Nobody outside the database should ever see one — a
/// guardian reads "July 2026", and so does the owner.
library;

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// `2026-07` → `July 2026`.
///
/// Anything that is not a period key is returned untouched, so a one-off
/// charge keeps whatever wording it was given.
String monthLabel(String periodKey) {
  final parts = periodKey.split('-');
  if (parts.length != 2) return periodKey;

  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  if (year == null || month == null || month < 1 || month > 12) {
    return periodKey;
  }
  return '${_monthNames[month - 1]} $year';
}
