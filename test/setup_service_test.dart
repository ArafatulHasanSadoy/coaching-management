import 'package:coaching_ops/data/db/database.dart';
import 'package:coaching_ops/data/defaults/curriculum_defaults.dart';
import 'package:coaching_ops/data/setup/setup_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  SetupPlan planWith({
    List<DefaultClass>? classes,
    bool bangla = true,
    bool rooms = true,
    bool slots = true,
    String name = 'Advance Educare',
  }) =>
      SetupPlan(
        centreName: name,
        address: '12/A, Mirpur Road, Dhaka',
        phone: '01712345678',
        sessionName: '2026',
        sessionStart: DateTime(2026, 1, 1),
        sessionEnd: DateTime(2026, 12, 31),
        selectedClasses: classes ?? [defaultClasses.first],
        banglaSubjectNames: bangla,
        includeDefaultRooms: rooms,
        includeDefaultTimeSlots: slots,
      );

  test('creates a usable centre from the wizard selections', () async {
    final chosen = [
      defaultClasses[0], // Class 6
      defaultClasses[3], // Class 9 — Science
    ];

    final result = await const SetupService()
        .apply(db: db, plan: planWith(classes: chosen), deviceId: 'device-a');

    expect(result.classes, 2);
    expect(result.subjects, chosen.fold<int>(0, (n, c) => n + c.subjects.length));
    expect(result.rooms, defaultRooms.length);
    expect(result.timeSlots, defaultTimeSlots.length);

    final institutions = await db.select(db.institutions).get();
    expect(institutions.single.name, 'Advance Educare');

    final sessions = await db.select(db.academicSessions).get();
    expect(sessions.single.isActive, isTrue);

    final classRows = await db.select(db.classes).get();
    expect(classRows.map((c) => c.name), ['Class 6', 'Class 9 — Science']);

    // Subjects must attach to the class they were created under, not to
    // whichever class happened to be written last.
    final class9 = classRows.firstWhere((c) => c.name.startsWith('Class 9'));
    final class9Subjects = await (db.select(db.subjects)
          ..where((s) => s.classId.equals(class9.id)))
        .get();
    expect(class9Subjects.map((s) => s.name), contains('পদার্থবিজ্ঞান'));
    expect(
      class9Subjects.firstWhere((s) => s.name == 'পদার্থবিজ্ঞান').weeklyClasses,
      3,
    );
  });

  test('subject names follow the chosen script', () async {
    await const SetupService().apply(
      db: db,
      plan: planWith(classes: [defaultClasses[3]], bangla: false),
      deviceId: 'device-a',
    );

    final subjects = await db.select(db.subjects).get();
    expect(subjects.map((s) => s.name), contains('Physics'));
    expect(subjects.map((s) => s.name), isNot(contains('পদার্থবিজ্ঞান')));
  });

  test('optional defaults can be declined', () async {
    final result = await const SetupService().apply(
      db: db,
      plan: planWith(rooms: false, slots: false),
      deviceId: 'device-a',
    );

    expect(result.rooms, 0);
    expect(result.timeSlots, 0);
    expect(await db.select(db.rooms).get(), isEmpty);
  });

  test('records that setup happened', () async {
    await const SetupService()
        .apply(db: db, plan: planWith(), deviceId: 'device-a');

    final institution = (await db.select(db.institutions).get()).single;
    final trail = await db.auditTrailFor('institutions', institution.id);
    expect(trail.single.action, 'setup_completed');
  });

  test('isComplete flips only once a centre exists', () async {
    expect(await const SetupService().isComplete(db), isFalse);
    await const SetupService()
        .apply(db: db, plan: planWith(), deviceId: 'device-a');
    expect(await const SetupService().isComplete(db), isTrue);
  });

  test('a failure part-way leaves nothing behind', () async {
    // An empty name violates the length constraint, and it does so after the
    // classes in this plan would already have been written.
    await expectLater(
      const SetupService()
          .apply(db: db, plan: planWith(name: ''), deviceId: 'device-a'),
      throwsA(anything),
    );

    expect(await db.select(db.institutions).get(), isEmpty);
    expect(await db.select(db.classes).get(), isEmpty);
    expect(await db.select(db.subjects).get(), isEmpty);
  });
}
