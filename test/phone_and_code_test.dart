import 'package:coaching_ops/core/phone.dart';
import 'package:coaching_ops/data/students/student_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('phone normalisation', () {
    test('accepts the shapes people actually type', () {
      const canonical = '01712345678';
      for (final input in [
        '01712345678',
        '01712-345678',
        '01712 345678',
        '+8801712345678',
        '8801712345678',
        '00880 1712 345678',
        '1712345678', // leading zero eaten by a spreadsheet
      ]) {
        expect(Phone.normalize(input), canonical, reason: 'input: $input');
      }
    });

    test('rejects what cannot be a mobile number', () {
      for (final input in ['', 'n/a', '0171234', '021234567', '9999999999999']) {
        expect(Phone.normalize(input), isEmpty, reason: 'input: $input');
      }
    });

    test('formats for display without destroying unusable input', () {
      expect(Phone.forDisplay('8801712345678'), '01712-345678');
      expect(Phone.forDisplay('not a number'), 'not a number');
    });
  });

  group('student codes', () {
    final when = DateTime(2026, 3, 1);

    test('renders a centre pattern', () {
      expect(
        StudentCode.render(
            pattern: 'AEC-{YY}-{#####}', when: when, sequence: 427),
        'AEC-26-00427',
      );
      expect(
        StudentCode.render(pattern: '{YYYY}/{###}', when: when, sequence: 7),
        '2026/007',
      );
    });

    test('continues from the highest issued, not the count', () {
      // A deleted student in the middle must not cause a number already
      // printed on an ID card to be handed out again.
      expect(
        StudentCode.next(
          pattern: 'AEC-{YY}-{#####}',
          when: when,
          existingCodes: ['AEC-26-00001', 'AEC-26-00009', 'AEC-26-00004'],
        ),
        'AEC-26-00010',
      );
    });

    test('ignores codes from other years and hand-typed ones', () {
      expect(
        StudentCode.next(
          pattern: 'AEC-{YY}-{#####}',
          when: when,
          existingCodes: ['AEC-25-00999', 'legacy-42', 'AEC-26-00003'],
        ),
        'AEC-26-00004',
      );
    });

    test('starts at one for a fresh series', () {
      expect(
        StudentCode.next(
            pattern: '{YY}-{#####}', when: when, existingCodes: const []),
        '26-00001',
      );
    });
  });
}
