import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// One chunk of text the recogniser found, roughly a paragraph.
class ScannedBlock {
  const ScannedBlock({required this.text, required this.top});

  final String text;

  /// Vertical position on the page, used to keep blocks in reading order.
  final double top;
}

class ScanResult {
  const ScanResult({required this.fullText, required this.blocks});

  final String fullText;
  final List<ScannedBlock> blocks;

  bool get isEmpty => fullText.trim().isEmpty;
}

/// Reads text out of a photograph, using Google's on-device model.
///
/// ## What it can and cannot read
///
/// The bundled model covers **Latin script** — English text, numbers, and the
/// symbols that appear in maths. It does **not** include Bangla. A photograph of
/// a Bangla question will come back empty or as nonsense, which is why the
/// capture screen says so before the teacher takes the picture rather than
/// leaving them to work it out from the result.
///
/// Everything runs on the phone. No image leaves the device, which matters for
/// an app that is otherwise entirely offline.
class OcrService {
  OcrService();

  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  /// True for scripts the on-device model does not cover.
  ///
  /// Used to warn honestly rather than to block: a page mixing English and
  /// Bangla still yields useful English, and the teacher edits the rest.
  static bool looksUnsupported(String text) {
    if (text.isEmpty) return false;
    final bengali = RegExp(r'[ঀ-৿]');
    return bengali.hasMatch(text);
  }

  Future<ScanResult> scan(File image) async {
    final input = InputImage.fromFilePath(image.path);
    final recognised = await _recognizer.processImage(input);

    final blocks = <ScannedBlock>[
      for (final block in recognised.blocks)
        if (block.text.trim().isNotEmpty)
          ScannedBlock(
            text: block.text.trim(),
            top: block.boundingBox.top.toDouble(),
          ),
    ]..sort((a, b) => a.top.compareTo(b.top));

    return ScanResult(fullText: recognised.text.trim(), blocks: blocks);
  }

  /// Splits a page into candidate questions.
  ///
  /// Numbered lines are the strongest signal a question paper gives — `1.`,
  /// `৭।`, `Q3)` — so a new number starts a new question and everything under it
  /// belongs to that question until the next one. Where there are no numbers at
  /// all, each block is offered as its own question and the teacher merges what
  /// belongs together.
  static List<String> splitQuestions(ScanResult result) {
    if (result.isEmpty) return const [];

    final numbered = RegExp(r'^\s*(?:Q\s*)?[\(\[]?\d{1,3}[\)\].।:\-]');
    final lines = result.fullText
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.trim().isNotEmpty)
        .toList();

    final questions = <String>[];
    var current = StringBuffer();

    for (final line in lines) {
      if (numbered.hasMatch(line) && current.isNotEmpty) {
        questions.add(current.toString().trim());
        current = StringBuffer();
      }
      if (current.isNotEmpty) current.write('\n');
      current.write(line);
    }
    if (current.isNotEmpty) questions.add(current.toString().trim());

    if (questions.length > 1) return questions;

    // No numbering found — fall back to the recogniser's own blocks.
    return result.blocks.isEmpty
        ? [result.fullText]
        : result.blocks.map((b) => b.text).toList();
  }

  /// Strips the leading number from a split question, since the paper numbers
  /// them again when it is printed.
  static String withoutLeadingNumber(String text) => text.replaceFirst(
        RegExp(r'^\s*(?:Q\s*)?[\(\[]?\d{1,3}[\)\].।:\-]\s*'),
        '',
      );

  void dispose() => _recognizer.close();
}
