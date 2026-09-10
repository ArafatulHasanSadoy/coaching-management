import 'package:coaching_ops/data/questions/ocr_service.dart';
import 'package:flutter_test/flutter_test.dart';

ScanResult page(String text) => ScanResult(
      fullText: text,
      blocks: [
        for (var i = 0; i < text.split('\n\n').length; i++)
          ScannedBlock(text: text.split('\n\n')[i].trim(), top: i * 100),
      ],
    );

void main() {
  group('splitting a scanned page into questions', () {
    test('a numbered paper splits on the numbers', () {
      final result = page('''
1. What is the unit of velocity?
(a) metre (b) m/s
2. Define acceleration.
3. A body starts from rest and reaches 20 m/s in 5 s.
Find its acceleration.''');

      final questions = OcrService.splitQuestions(result);
      expect(questions, hasLength(3));
      expect(questions[0], contains('unit of velocity'));
      expect(questions[0], contains('(a) metre'),
          reason: 'the options belong to the question above them');
      expect(questions[2], contains('Find its acceleration'),
          reason: 'an unnumbered continuation stays with its question');
    });

    test('handles the shapes a paper actually uses', () {
      for (final marker in ['1.', '1)', '(1)', 'Q1.', '1:', '1-']) {
        final questions = OcrService.splitQuestions(
          page('$marker First question\n2. Second question'),
        );
        expect(questions, hasLength(2), reason: 'marker: $marker');
      }
    });

    test('falls back to blocks when nothing is numbered', () {
      final result = page('First paragraph here.\n\nSecond paragraph here.');
      final questions = OcrService.splitQuestions(result);
      expect(questions, hasLength(2));
    });

    test('an empty scan yields nothing rather than one blank question', () {
      expect(OcrService.splitQuestions(page('')), isEmpty);
    });

    test('the leading number is dropped, since the paper renumbers', () {
      expect(
        OcrService.withoutLeadingNumber('7। ত্বরণ কাকে বলে?'),
        'ত্বরণ কাকে বলে?',
      );
      expect(
        OcrService.withoutLeadingNumber('Q12) Define force'),
        'Define force',
      );
      expect(
        OcrService.withoutLeadingNumber('No number here'),
        'No number here',
      );
    });
  });

  group('warning about unsupported script', () {
    test('flags Bangla, which the on-device model does not read', () {
      expect(OcrService.looksUnsupported('বেগের একক কোনটি?'), isTrue);
    });

    test('does not flag English or maths', () {
      expect(OcrService.looksUnsupported('What is v = u + at?'), isFalse);
      expect(OcrService.looksUnsupported(''), isFalse);
    });
  });
}
