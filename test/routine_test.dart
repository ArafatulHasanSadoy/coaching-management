import 'package:coaching_ops/data/documents/document_engine.dart';
import 'package:coaching_ops/data/routine/routine_copy.dart';
import 'package:coaching_ops/data/routine/routine_engine.dart';
import 'package:coaching_ops/data/routine/routine_model.dart';
import 'package:coaching_ops/data/routine/routine_solver.dart';
import 'package:coaching_ops/features/routine/routine_document.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a small, realistic centre.
RoutineProblem centre({
  int batches = 2,
  int rooms = 2,
  int slotsPerDay = 5,
  int days = 5,
  int periodsPerSubject = 3,
  int subjectsPerBatch = 3,
  int roomCapacity = 40,
  int batchSize = 30,
  Map<String, Set<String>> staffBusy = const {},
  List<Placement> pinned = const [],
}) {
  final slots = [
    for (var i = 0; i < slotsPerDay; i++)
      SlotRef(id: 'slot$i', label: '${15 + i}:00', order: i),
  ];
  final roomList = [
    for (var i = 0; i < rooms; i++)
      RoomRef(id: 'room$i', name: 'Room ${i + 1}', capacity: roomCapacity),
  ];
  final batchList = [
    for (var i = 0; i < batches; i++)
      BatchRef(id: 'batch$i', name: 'Batch ${i + 1}', size: batchSize),
  ];
  final subjectList = [
    for (var i = 0; i < subjectsPerBatch; i++)
      SubjectRef(id: 'sub$i', name: 'Subject ${i + 1}'),
  ];
  final staffList = [
    for (var i = 0; i < subjectsPerBatch; i++)
      StaffRef(id: 'staff$i', name: 'Teacher ${i + 1}'),
  ];
  final requirements = [
    for (final b in batchList)
      for (var i = 0; i < subjectsPerBatch; i++)
        RequirementRef(
          batchId: b.id,
          subjectId: 'sub$i',
          staffId: 'staff$i',
          periodsPerWeek: periodsPerSubject,
        ),
  ];

  return RoutineProblem(
    days: [for (var d = 1; d <= days; d++) d],
    slots: slots,
    batches: batchList,
    rooms: roomList,
    staff: staffList,
    subjects: subjectList,
    requirements: requirements,
    staffBusy: staffBusy,
    pinned: pinned,
  );
}

void main() {
  group('Stage 9 — conflicts', () {
    final problem = centre();

    Placement at(String batch, String subject, String staff, String room,
            int day, String slot) =>
        Placement(
          batchId: batch,
          subjectId: subject,
          staffId: staff,
          roomId: room,
          day: day,
          slotId: slot,
        );

    test('a teacher cannot be in two rooms at once', () {
      final existing = [at('batch0', 'sub0', 'staff0', 'room0', 1, 'slot0')];
      final clash = at('batch1', 'sub0', 'staff0', 'room1', 1, 'slot0');

      final conflicts = RoutineEngine.conflictsFor(
          problem: problem, candidate: clash, existing: existing);

      final teacher =
          conflicts.singleWhere((c) => c.kind == ConflictKind.teacherBusy);
      expect(teacher.hard, isTrue);
      expect(teacher.message, contains('Teacher 1'));
      expect(teacher.message, contains('Batch 1'));
    });

    test('a batch cannot have two classes at once', () {
      final existing = [at('batch0', 'sub0', 'staff0', 'room0', 1, 'slot0')];
      final clash = at('batch0', 'sub1', 'staff1', 'room1', 1, 'slot0');

      expect(
        RoutineEngine.conflictsFor(
                problem: problem, candidate: clash, existing: existing)
            .where((c) => c.kind == ConflictKind.batchBusy && c.hard),
        isNotEmpty,
      );
    });

    test('a room cannot hold two batches at once', () {
      final existing = [at('batch0', 'sub0', 'staff0', 'room0', 1, 'slot0')];
      final clash = at('batch1', 'sub1', 'staff1', 'room0', 1, 'slot0');

      expect(
        RoutineEngine.conflictsFor(
                problem: problem, candidate: clash, existing: existing)
            .where((c) => c.kind == ConflictKind.roomBusy && c.hard),
        isNotEmpty,
      );
    });

    test('a batch that does not fit the room is refused', () {
      final tight = centre(batchSize: 42, roomCapacity: 30);
      final conflicts = RoutineEngine.conflictsFor(
        problem: tight,
        candidate: at('batch0', 'sub0', 'staff0', 'room0', 1, 'slot0'),
        existing: const [],
      );
      final tooSmall =
          conflicts.singleWhere((c) => c.kind == ConflictKind.roomTooSmall);
      expect(tooSmall.hard, isTrue);
      expect(tooSmall.message, contains('42 students'));
      expect(tooSmall.message, contains('seats 30'));
    });

    test('a teacher marked unavailable is refused, and told when', () {
      final busy = centre(staffBusy: {
        'staff0': {'1:slot0'}
      });
      final conflicts = RoutineEngine.conflictsFor(
        problem: busy,
        candidate: at('batch0', 'sub0', 'staff0', 'room0', 1, 'slot0'),
        existing: const [],
      );
      final unavailable = conflicts
          .singleWhere((c) => c.kind == ConflictKind.teacherUnavailable);
      expect(unavailable.hard, isTrue);
      expect(unavailable.message, contains('Saturday'));
    });

    test('the same subject twice a day warns but does not block', () {
      final existing = [at('batch0', 'sub0', 'staff0', 'room0', 1, 'slot0')];
      final second = at('batch0', 'sub0', 'staff0', 'room0', 1, 'slot1');

      final conflicts = RoutineEngine.conflictsFor(
          problem: problem, candidate: second, existing: existing);
      final twice = conflicts
          .singleWhere((c) => c.kind == ConflictKind.subjectTwiceADay);

      expect(
        twice.hard,
        isFalse,
        reason: 'a double period before an exam is a decision, not an error',
      );
      expect(
        RoutineEngine.fits(
            problem: problem, candidate: second, existing: existing),
        isTrue,
      );
    });

    test('"what can go here" offers only what actually fits', () {
      final existing = [at('batch0', 'sub0', 'staff0', 'room0', 1, 'slot0')];
      final options = RoutineEngine.candidatesFor(
        problem: problem,
        day: 1,
        slotId: 'slot0',
        existing: existing,
      );

      // batch0 is busy and staff0 is busy, so neither may appear.
      expect(options.any((c) => c.batchId == 'batch0'), isFalse);
      expect(options.any((c) => c.staffId == 'staff0'), isFalse);
      expect(options, isNotEmpty);
      // Sorted by how much is still owed.
      expect(options.first.remaining, greaterThanOrEqualTo(options.last.remaining));
    });

    test('free periods for a teacher exclude both busy and taught', () {
      final busy = centre(staffBusy: {
        'staff0': {'1:slot0'}
      });
      final free = RoutineEngine.freeCellsFor(
        problem: busy,
        staffId: 'staff0',
        existing: [at('batch0', 'sub0', 'staff0', 'room0', 2, 'slot1')],
      );
      expect(free, isNot(contains('1:slot0')));
      expect(free, isNot(contains('2:slot1')));
      expect(free, contains('1:slot1'));
    });
  });

  group('Stage 10 — generation', () {
    test('a feasible centre is scheduled completely, with no hard conflicts',
        () {
      final problem = centre();
      final result = solveRoutine(SolveRequest(problem: problem));

      expect(result.isComplete, isTrue, reason: result.unplaced.map((u) => u.reason).join('; '));
      expect(result.completeness, 100);
      expect(result.placements, hasLength(problem.requirements.length * 3));

      // Every placement must still be legal against all the others.
      for (final placement in result.placements) {
        final others = [...result.placements]..remove(placement);
        final hard = RoutineEngine.conflictsFor(
          problem: problem,
          candidate: placement,
          existing: others,
        ).where((c) => c.hard);
        expect(hard, isEmpty, reason: hard.map((c) => c.message).join('; '));
      }
    });

    test('the same input produces the same routine', () {
      final problem = centre();
      final a = solveRoutine(SolveRequest(problem: problem));
      final b = solveRoutine(SolveRequest(problem: problem));

      expect(
        a.placements.map((p) => '${p.batchId}/${p.subjectId}/${p.cell}').toList(),
        b.placements.map((p) => '${p.batchId}/${p.subjectId}/${p.cell}').toList(),
        reason: 'pressing Generate twice must not give two different answers',
      );
    });

    test('pinned classes are kept exactly where they were put', () {
      final pinned = [
        const Placement(
          batchId: 'batch0',
          subjectId: 'sub0',
          staffId: 'staff0',
          roomId: 'room0',
          day: 3,
          slotId: 'slot2',
          isPinned: true,
        ),
      ];
      final result = solveRoutine(
        SolveRequest(problem: centre(pinned: pinned)),
      );

      final kept = result.placements.singleWhere((p) => p.isPinned);
      expect(kept.day, 3);
      expect(kept.slotId, 'slot2');
    });

    test('balanced mode is no worse than fast, and usually better', () {
      final problem = centre(batches: 3, subjectsPerBatch: 4, rooms: 3);
      final fast = solveRoutine(
          SolveRequest(problem: problem, mode: SolveMode.fast));
      final balanced = solveRoutine(
          SolveRequest(problem: problem, mode: SolveMode.balanced));

      expect(balanced.softPenalty, lessThanOrEqualTo(fast.softPenalty));
    });

    group('the gate: an impossible routine explains itself', () {
      test('a teacher available only two periods says so, with fixes', () {
        // Teacher 1 needs three periods for two batches — six in total — but is
        // free in only two cells all week.
        final everyCell = <String>{
          for (var d = 1; d <= 5; d++)
            for (var s = 0; s < 5; s++) '$d:slot$s',
        };
        final allowed = {'1:slot0', '2:slot0'};
        final problem = centre(staffBusy: {
          'staff0': everyCell.difference(allowed),
        });

        final result = solveRoutine(SolveRequest(problem: problem));

        expect(result.isComplete, isFalse);
        expect(result.completeness, greaterThan(50),
            reason: 'everything else should still be scheduled');

        final blocked = result.unplaced
            .where((u) => u.requirement.subjectId == 'sub0')
            .toList();
        expect(blocked, isNotEmpty);

        final reason = blocked.first.reason;
        expect(reason, contains('Teacher 1'));
        expect(reason, isNot(contains('failed')));
        expect(blocked.first.suggestions, isNotEmpty);
        expect(
          blocked.first.suggestions.join(' '),
          contains('availability'),
        );
      });

      test('a batch too big for every room says so', () {
        final problem = centre(batchSize: 60, roomCapacity: 30);
        final result = solveRoutine(SolveRequest(problem: problem));

        expect(result.isComplete, isFalse);
        expect(result.unplaced.first.reason, contains('60 students'));
        expect(
          result.unplaced.first.suggestions.join(' '),
          contains('larger room'),
        );
      });

      test('too few rooms names rooms as the problem', () {
        // One room gives 5 days x 5 periods = 25 places. Four batches needing
        // three subjects three times a week want 36, so eleven cannot happen.
        final problem = centre(batches: 4, rooms: 1, subjectsPerBatch: 3);
        final result = solveRoutine(SolveRequest(problem: problem));

        expect(result.isComplete, isFalse);
        expect(
          result.unplaced.map((u) => u.reason).join(' '),
          anyOf(contains('room'), contains('Room')),
        );
      });
    });

    test('a centre-sized problem solves quickly', () {
      final problem = centre(
        batches: 12,
        rooms: 6,
        slotsPerDay: 6,
        days: 6,
        subjectsPerBatch: 5,
        periodsPerSubject: 3,
      );

      final watch = Stopwatch()..start();
      final result = solveRoutine(SolveRequest(problem: problem));
      final ms = watch.elapsedMilliseconds;

      // ignore: avoid_print
      print('12 batches × 5 subjects × 3 periods = '
          '${problem.requirements.length * 3} classes — '
          '${result.placements.length} placed, '
          '${result.completeness.toStringAsFixed(1)}% complete, '
          'penalty ${result.softPenalty}, ${ms}ms');

      expect(result.completeness, greaterThan(95));
      expect(ms, lessThan(30000), reason: 'took ${ms}ms');
    });
  });

  group('class-wise grid', () {
    /// A class with two batches, which is what the merged sheet exists for.
    RoutineProblem twoBatchClass() {
      final base = centre(batches: 2, subjectsPerBatch: 2, periodsPerSubject: 2);
      return RoutineProblem(
        days: base.days,
        slots: base.slots,
        rooms: base.rooms,
        staff: base.staff,
        subjects: base.subjects,
        requirements: base.requirements,
        batches: [
          BatchRef(
            id: 'batch0',
            name: 'Science A',
            size: 30,
            classId: 'class9',
            className: 'Class 9',
          ),
          BatchRef(
            id: 'batch1',
            name: 'Science B',
            size: 30,
            classId: 'class9',
            className: 'Class 9',
          ),
        ],
      );
    }

    test('both batches of a class land on one sheet, each cell labelled', () {
      final problem = twoBatchClass();
      final result = solveRoutine(
        SolveRequest(problem: problem, mode: SolveMode.balanced),
      );

      final html = RoutineDocument(engine: const DocumentEngine()).build(
        problem: problem,
        placements: result.placements,
        versionName: 'Test',
        classId: 'class9',
      );

      // One grid, not two: a class gets a single sheet however many batches
      // it holds.
      expect('<table class="grid"'.allMatches(html).length, 1);
      expect(html, contains('Class 9'));
      expect(html, contains('Science A'));
      expect(html, contains('Science B'));
    });

    test('two batches sharing a period both appear in the same cell', () {
      final problem = twoBatchClass();
      final placements = [
        const Placement(
          batchId: 'batch0',
          subjectId: 'sub0',
          day: 1,
          slotId: 'slot0',
          roomId: 'room0',
        ),
        const Placement(
          batchId: 'batch1',
          subjectId: 'sub1',
          day: 1,
          slotId: 'slot0',
          roomId: 'room1',
        ),
      ];

      final html = RoutineDocument(engine: const DocumentEngine()).build(
        problem: problem,
        placements: placements,
        versionName: 'Test',
        classId: 'class9',
      );

      // The dotted rule is what separates two batches inside one cell; its
      // presence is the proof they were merged rather than one overwriting
      // the other.
      expect(html, contains('class="split"'));
      expect(html, contains('Science A'));
      expect(html, contains('Science B'));
    });

    test('filtering to one class leaves the other class out', () {
      final base = twoBatchClass();
      final problem = RoutineProblem(
        days: base.days,
        slots: base.slots,
        rooms: base.rooms,
        staff: base.staff,
        subjects: base.subjects,
        requirements: base.requirements,
        batches: [
          ...base.batches,
          const BatchRef(
            id: 'batch2',
            name: 'Commerce A',
            size: 20,
            classId: 'class10',
            className: 'Class 10',
          ),
        ],
      );

      final html = RoutineDocument(engine: const DocumentEngine()).build(
        problem: problem,
        placements: const [],
        versionName: 'Test',
        classId: 'class9',
      );

      expect(html, contains('Class 9'));
      expect(html, isNot(contains('Class 10')));
      expect(html, isNot(contains('Commerce A')));
    });

    test('printing every class gives one page-broken grid per class', () {
      final base = twoBatchClass();
      final problem = RoutineProblem(
        days: base.days,
        slots: base.slots,
        rooms: base.rooms,
        staff: base.staff,
        subjects: base.subjects,
        requirements: base.requirements,
        batches: [
          ...base.batches,
          const BatchRef(
            id: 'batch2',
            name: 'Commerce A',
            size: 20,
            classId: 'class10',
            className: 'Class 10',
          ),
        ],
      );

      final html = RoutineDocument(engine: const DocumentEngine()).build(
        problem: problem,
        placements: const [],
        versionName: 'Test',
      );

      expect('<table class="grid"'.allMatches(html).length, 2);
      expect('class="page-break"'.allMatches(html).length, 1);
    });
  });

  group('copying a week from one batch to another', () {
    /// Two batches of different classes that share subject *names* but not
    /// subject rows — the situation the copy has to cope with.
    RoutineProblem twoClasses({String? nabilaTeaches}) {
      const slots = [
        SlotRef(id: 'slot0', label: '15:00', order: 0),
        SlotRef(id: 'slot1', label: '16:00', order: 1),
      ];
      return RoutineProblem(
        days: const [1, 2],
        slots: slots,
        rooms: const [
          RoomRef(id: 'room0', name: 'Room 1', capacity: 40),
          RoomRef(id: 'room1', name: 'Room 2', capacity: 40),
        ],
        staff: const [
          StaffRef(id: 'rahman', name: 'Mr Rahman'),
          StaffRef(id: 'nabila', name: 'Ms Nabila'),
        ],
        subjects: const [
          SubjectRef(id: 'bangla9', name: 'Bangla'),
          SubjectRef(id: 'ict9', name: 'ICT'),
          SubjectRef(id: 'bangla10', name: 'Bangla'),
        ],
        batches: const [
          BatchRef(
            id: 'nine',
            name: 'Class 9 A',
            size: 30,
            classId: 'c9',
            className: 'Class 9',
          ),
          BatchRef(
            id: 'ten',
            name: 'Class 10 A',
            size: 30,
            classId: 'c10',
            className: 'Class 10',
          ),
        ],
        requirements: [
          const RequirementRef(
            batchId: 'nine',
            subjectId: 'bangla9',
            periodsPerWeek: 2,
            staffId: 'rahman',
          ),
          const RequirementRef(
            batchId: 'nine',
            subjectId: 'ict9',
            periodsPerWeek: 1,
            staffId: 'rahman',
          ),
          RequirementRef(
            batchId: 'ten',
            subjectId: 'bangla10',
            periodsPerWeek: 2,
            staffId: nabilaTeaches,
          ),
        ],
      );
    }

    const nineWeek = [
      Placement(
        batchId: 'nine',
        subjectId: 'bangla9',
        day: 1,
        slotId: 'slot0',
        staffId: 'rahman',
        roomId: 'room0',
      ),
      Placement(
        batchId: 'nine',
        subjectId: 'ict9',
        day: 1,
        slotId: 'slot1',
        staffId: 'rahman',
        roomId: 'room0',
      ),
    ];

    test('a subject the target batch does not study is left out, and said so',
        () {
      final outcome = copyBatchRoutine(
        problem: twoClasses(),
        existing: nineWeek,
        fromBatchId: 'nine',
        toBatchId: 'ten',
      );

      // Class 10 has Bangla but no ICT.
      expect(outcome.copied, 1);
      expect(outcome.skipped, 1);
      expect(outcome.placements.single.subjectId, 'bangla10');
      expect(outcome.notes.join(), contains('ICT'));
      expect(outcome.notes.join(), contains('Class 10 A'));
    });

    test("the target batch's own teacher wins over the one being copied", () {
      final outcome = copyBatchRoutine(
        problem: twoClasses(nabilaTeaches: 'nabila'),
        existing: nineWeek,
        fromBatchId: 'nine',
        toBatchId: 'ten',
      );

      // This is the internal connection: Class 10 already said Ms Nabila
      // takes its Bangla, so copying Class 9's week does not hand the period
      // to Mr Rahman.
      expect(outcome.placements.single.staffId, 'nabila');
    });

    test('a teacher already busy at that hour is left blank, not double-booked',
        () {
      const other = Placement(
        batchId: 'other',
        subjectId: 'x',
        day: 1,
        slotId: 'slot0',
        staffId: 'rahman',
        roomId: 'room1',
      );

      final outcome = copyBatchRoutine(
        problem: twoClasses(),
        existing: [...nineWeek, other],
        fromBatchId: 'nine',
        toBatchId: 'ten',
      );

      final copied = outcome.placements.single;
      expect(copied.subjectId, 'bangla10');
      expect(copied.staffId, isNull);
      expect(outcome.teacherBusy, 1);
      expect(outcome.unassigned, 0);
      expect(outcome.notes.join(), contains('already in another class'));
    });


    test('a subject nobody teaches says so, rather than blaming a clash', () {
      final outcome = copyBatchRoutine(
        // Neither batch has named a teacher for Bangla.
        problem: twoClasses(),
        existing: const [
          Placement(
            batchId: 'nine',
            subjectId: 'bangla9',
            day: 1,
            slotId: 'slot0',
            roomId: 'room0',
          ),
        ],
        fromBatchId: 'nine',
        toBatchId: 'ten',
      );

      expect(outcome.unassigned, 1);
      expect(outcome.teacherBusy, 0);
      expect(outcome.notes.join(), contains('nobody is named'));
      expect(outcome.notes.join(), isNot(contains('another class')));
    });

    test('a room already taken at that hour is swapped for a free one', () {
      const other = Placement(
        batchId: 'other',
        subjectId: 'x',
        day: 1,
        slotId: 'slot0',
        staffId: 'someone',
        roomId: 'room0',
      );

      final outcome = copyBatchRoutine(
        problem: twoClasses(),
        existing: [...nineWeek, other],
        fromBatchId: 'nine',
        toBatchId: 'ten',
      );

      expect(outcome.placements.single.roomId, 'room1');
      expect(outcome.withoutRoom, 0);
    });

    test("the target's old week is replaced, not added to", () {
      const stale = Placement(
        batchId: 'ten',
        subjectId: 'bangla10',
        day: 2,
        slotId: 'slot1',
        staffId: 'nabila',
        roomId: 'room1',
      );

      final outcome = copyBatchRoutine(
        problem: twoClasses(),
        existing: [...nineWeek, stale],
        fromBatchId: 'nine',
        toBatchId: 'ten',
      );

      expect(outcome.placements.every((p) => p.batchId == 'ten'), isTrue);
      expect(outcome.placements.any((p) => p.day == 2), isFalse);
    });

    test('copying between two batches of the same class carries everything',
        () {
      final base = twoClasses();
      final problem = RoutineProblem(
        days: base.days,
        slots: base.slots,
        rooms: base.rooms,
        staff: base.staff,
        subjects: base.subjects,
        batches: const [
          BatchRef(
            id: 'nine',
            name: 'Class 9 A',
            size: 30,
            classId: 'c9',
            className: 'Class 9',
          ),
          BatchRef(
            id: 'nineB',
            name: 'Class 9 B',
            size: 30,
            classId: 'c9',
            className: 'Class 9',
          ),
        ],
        requirements: const [
          RequirementRef(
            batchId: 'nine',
            subjectId: 'bangla9',
            periodsPerWeek: 2,
            staffId: 'rahman',
          ),
          RequirementRef(
            batchId: 'nine',
            subjectId: 'ict9',
            periodsPerWeek: 1,
            staffId: 'rahman',
          ),
          RequirementRef(
            batchId: 'nineB',
            subjectId: 'bangla9',
            periodsPerWeek: 2,
            staffId: 'nabila',
          ),
          RequirementRef(
            batchId: 'nineB',
            subjectId: 'ict9',
            periodsPerWeek: 1,
            staffId: 'nabila',
          ),
        ],
      );

      final outcome = copyBatchRoutine(
        problem: problem,
        existing: nineWeek,
        fromBatchId: 'nine',
        toBatchId: 'nineB',
      );

      expect(outcome.copied, 2);
      expect(outcome.skipped, 0);
      // Both periods keep a room, and Ms Nabila takes them since Class 9 B
      // named her.
      expect(outcome.placements.every((p) => p.staffId == 'nabila'), isTrue);
      expect(outcome.placements.every((p) => p.roomId != null), isTrue);
      expect(outcome.isClean, isTrue);
    });
  });
}
