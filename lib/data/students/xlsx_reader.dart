import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Reads the first sheet of an `.xlsx` file into rows of strings.
///
/// Written rather than taken from a package because every `excel` release pins
/// `archive ^3`, and the backup system — which matters far more than an import
/// convenience — is built on `archive ^4`. An xlsx is a zip of XML, and reading
/// one is a bounded problem; downgrading the thing that protects a centre's
/// records to avoid writing it would have been the wrong trade.
///
/// Everything comes back as text on purpose: a mobile number read as a number
/// loses its leading zero, and a student ID of `007` becomes `7`.
abstract final class XlsxReader {
  static Future<List<List<String>>> read(File file) async {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());

    final shared = _sharedStrings(archive);
    final sheet = _firstSheet(archive);
    if (sheet == null) return const [];

    final rows = <int, Map<int, String>>{};
    var widest = 0;

    for (final row in sheet.findAllElements('row')) {
      final rowIndex = int.tryParse(row.getAttribute('r') ?? '') ?? 0;
      if (rowIndex == 0) continue;

      final cells = <int, String>{};
      for (final cell in row.findElements('c')) {
        final ref = cell.getAttribute('r') ?? '';
        final column = _columnOf(ref);
        if (column < 0) continue;

        final text = _cellText(cell, shared);
        if (text.isNotEmpty) {
          cells[column] = text;
          if (column + 1 > widest) widest = column + 1;
        }
      }
      if (cells.isNotEmpty) rows[rowIndex] = cells;
    }

    if (rows.isEmpty) return const [];

    final ordered = rows.keys.toList()..sort();
    return [
      for (final index in ordered)
        [
          // Filled to a uniform width so a blank cell mid-row does not shift
          // every column after it onto the wrong field.
          for (var c = 0; c < widest; c++) rows[index]![c] ?? '',
        ],
    ];
  }

  static List<String> _sharedStrings(Archive archive) {
    final entry = archive.files
        .where((f) => f.name == 'xl/sharedStrings.xml')
        .firstOrNull;
    if (entry == null) return const [];

    final document =
        XmlDocument.parse(utf8.decode(entry.content as List<int>));
    return [
      for (final si in document.findAllElements('si'))
        si.findAllElements('t').map((t) => t.innerText).join(),
    ];
  }

  static XmlDocument? _firstSheet(Archive archive) {
    final sheets = archive.files
        .where((f) =>
            f.name.startsWith('xl/worksheets/sheet') && f.name.endsWith('.xml'))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (sheets.isEmpty) return null;

    return XmlDocument.parse(
      utf8.decode(sheets.first.content as List<int>),
    );
  }

  /// `"BC12"` → 54. Spreadsheet columns are base-26 with no zero.
  static int _columnOf(String reference) {
    var column = 0;
    var seen = false;
    for (final unit in reference.codeUnits) {
      if (unit >= 65 && unit <= 90) {
        column = column * 26 + (unit - 64);
        seen = true;
      } else if (seen) {
        break;
      }
    }
    return seen ? column - 1 : -1;
  }

  static String _cellText(XmlElement cell, List<String> shared) {
    final type = cell.getAttribute('t');

    // Inline strings carry their text directly rather than via the shared table.
    if (type == 'inlineStr') {
      return cell.findAllElements('t').map((t) => t.innerText).join();
    }

    final raw = cell.findElements('v').firstOrNull?.innerText ?? '';
    if (raw.isEmpty) return '';

    if (type == 's') {
      final index = int.tryParse(raw);
      return index != null && index < shared.length ? shared[index] : '';
    }

    // Trim the trailing zeros Excel leaves on whole numbers, so a roll number
    // reads as 7 rather than 7.0.
    final number = double.tryParse(raw);
    if (number != null && number == number.roundToDouble()) {
      return number.toInt().toString();
    }
    return raw;
  }
}
