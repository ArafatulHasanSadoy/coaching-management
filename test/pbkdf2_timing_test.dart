import 'dart:convert';

import 'package:coaching_ops/data/security/pin_hasher.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// Measures the unlock cost, which Stage 1 flagged as visibly slow and never
/// quantified.
///
/// The trade is real: more iterations make a stolen phone's PIN harder to
/// brute-force, and make every unlock slower on the mid-range hardware a
/// coaching centre actually owns.
void main() {
  test('a PIN check costs a measurable, bounded amount of time', () async {
    const hasher = PinHasher();
    final made = await hasher.hash('1234');

    final watch = Stopwatch()..start();
    final ok = await hasher.verify(
      pin: '1234',
      hash: made.hash,
      salt: made.salt,
    );
    final ms = watch.elapsedMilliseconds;

    expect(ok, isTrue);
    // ignore: avoid_print
    print('PBKDF2 ${PinHasher.iterations} iterations: ${ms}ms on this host '
        '(a mid-range phone is roughly 3-5x slower)');

    // Loose on purpose: this records the cost rather than asserting a target,
    // and a CI machine under load should not fail the suite.
    expect(ms, lessThan(5000));
  });

  test('a wrong PIN is rejected', () async {
    const hasher = PinHasher();
    final made = await hasher.hash('1234');
    expect(
      await hasher.verify(pin: '9999', hash: made.hash, salt: made.salt),
      isFalse,
    );
  });

  test('the stored hash records how it was made', () async {
    final made = await const PinHasher().hash('1234');
    expect(made.hash, startsWith('pbkdf2\$${PinHasher.iterations}\$'));
  });

  test('a PIN hashed before the count was recorded still verifies', () async {
    // The old format was a bare base64 key at 120,000 iterations. Someone who
    // set a PIN then must not be locked out by this change.
    const hasher = PinHasher();
    const legacyPin = '4321';
    final salt = base64Encode(List<int>.generate(16, (i) => i));

    final legacyHash = base64Encode(
      await (await Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: 120000,
        bits: 256,
      ).deriveKey(
        secretKey: SecretKey(utf8.encode(legacyPin)),
        nonce: base64Decode(salt),
      ))
          .extractBytes(),
    );

    expect(
      await hasher.verify(pin: legacyPin, hash: legacyHash, salt: salt),
      isTrue,
      reason: 'an existing PIN must survive the iteration count changing',
    );
    expect(
      await hasher.verify(pin: '0000', hash: legacyHash, salt: salt),
      isFalse,
    );
  });
}
