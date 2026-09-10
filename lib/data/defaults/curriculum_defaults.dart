/// Starting points offered by the setup wizard.
///
/// The gate for this stage is that a stranger completes setup unaided. Nobody
/// does that if the first screen is an empty table demanding forty rows, so the
/// wizard offers the Bangladeshi national curriculum pre-filled and asks the
/// owner to tick what they teach. Everything remains editable — these are
/// defaults, not a fixed structure, because centres run streams and batch names
/// no catalogue can anticipate.
library;

/// A subject offered as a default.
///
/// Carries both scripts because the choice is genuinely per-centre: the name is
/// data that prints on question papers and report cards, so a Bangla-medium
/// centre needs পদার্থবিজ্ঞান while an English-medium one needs Physics. The
/// wizard asks once and applies the answer to everything.
class DefaultSubject {
  const DefaultSubject(
    this.bn,
    this.en,
    this.shortBn,
    this.shortEn, {
    this.weeklyClasses = 2,
  });

  final String bn;
  final String en;
  final String shortBn;
  final String shortEn;
  final int weeklyClasses;

  String name({required bool bangla}) => bangla ? bn : en;
  String shortName({required bool bangla}) => bangla ? shortBn : shortEn;
}

/// A class offered as a default, optionally within a stream.
class DefaultClass {
  const DefaultClass({
    required this.name,
    required this.subjects,
    this.group = '',
  });

  final String name;
  final String group;
  final List<DefaultSubject> subjects;

  /// What the wizard shows in its list.
  String get label => group.isEmpty ? name : '$name — $group';
}

// Common subjects, defined once and shared across the classes that use them.
const _bangla = DefaultSubject('বাংলা', 'Bangla', 'বাং', 'Ban', weeklyClasses: 3);
const _english = DefaultSubject('ইংরেজি', 'English', 'ইং', 'Eng', weeklyClasses: 3);
const _math = DefaultSubject('গণিত', 'Mathematics', 'গণিত', 'Math', weeklyClasses: 3);
const _science = DefaultSubject('বিজ্ঞান', 'Science', 'বিজ্ঞান', 'Sci');
const _ict = DefaultSubject('আইসিটি', 'ICT', 'আইসিটি', 'ICT', weeklyClasses: 1);
const _socialScience =
    DefaultSubject('সমাজবিজ্ঞান', 'Social Science', 'সমাজ', 'SocSci');
const _religion = DefaultSubject('ধর্ম', 'Religion', 'ধর্ম', 'Rel', weeklyClasses: 1);
const _physics = DefaultSubject('পদার্থবিজ্ঞান', 'Physics', 'পদার্থ', 'Phy', weeklyClasses: 3);
const _chemistry = DefaultSubject('রসায়ন', 'Chemistry', 'রসায়ন', 'Chem', weeklyClasses: 3);
const _biology = DefaultSubject('জীববিজ্ঞান', 'Biology', 'জীব', 'Bio');
const _higherMath =
    DefaultSubject('উচ্চতর গণিত', 'Higher Mathematics', 'উ.গণিত', 'HMath', weeklyClasses: 3);
const _accounting = DefaultSubject('হিসাববিজ্ঞান', 'Accounting', 'হিসাব', 'Acc', weeklyClasses: 3);
const _business =
    DefaultSubject('ব্যবসায় সংগঠন', 'Business Organisation', 'ব্যবসায়', 'Bus');
const _finance = DefaultSubject('ফিন্যান্স', 'Finance', 'ফিন্যান্স', 'Fin');
const _economics = DefaultSubject('অর্থনীতি', 'Economics', 'অর্থ', 'Econ');
const _civics = DefaultSubject('পৌরনীতি', 'Civics', 'পৌর', 'Civ');
const _geography = DefaultSubject('ভূগোল', 'Geography', 'ভূগোল', 'Geo');
const _history = DefaultSubject('ইতিহাস', 'History', 'ইতিহাস', 'Hist');

const _junior = [_bangla, _english, _math, _science, _ict, _socialScience, _religion];
const _science910 = [_bangla, _english, _math, _physics, _chemistry, _biology, _higherMath, _ict];
const _business910 = [_bangla, _english, _math, _accounting, _business, _finance, _ict];
const _humanities910 = [_bangla, _english, _math, _economics, _civics, _geography, _history, _ict];
const _science1112 = [_bangla, _english, _physics, _chemistry, _biology, _higherMath, _ict];
const _business1112 = [_bangla, _english, _accounting, _business, _finance, _economics, _ict];
const _humanities1112 = [_bangla, _english, _economics, _civics, _geography, _history, _ict];

/// Everything the wizard can offer, in the order it shows them.
const defaultClasses = <DefaultClass>[
  DefaultClass(name: 'Class 6', subjects: _junior),
  DefaultClass(name: 'Class 7', subjects: _junior),
  DefaultClass(name: 'Class 8', subjects: _junior),
  DefaultClass(name: 'Class 9', group: 'Science', subjects: _science910),
  DefaultClass(name: 'Class 9', group: 'Business Studies', subjects: _business910),
  DefaultClass(name: 'Class 9', group: 'Humanities', subjects: _humanities910),
  DefaultClass(name: 'Class 10', group: 'Science', subjects: _science910),
  DefaultClass(name: 'Class 10', group: 'Business Studies', subjects: _business910),
  DefaultClass(name: 'Class 10', group: 'Humanities', subjects: _humanities910),
  DefaultClass(name: 'HSC 1st Year', group: 'Science', subjects: _science1112),
  DefaultClass(name: 'HSC 1st Year', group: 'Business Studies', subjects: _business1112),
  DefaultClass(name: 'HSC 1st Year', group: 'Humanities', subjects: _humanities1112),
  DefaultClass(name: 'HSC 2nd Year', group: 'Science', subjects: _science1112),
  DefaultClass(name: 'HSC 2nd Year', group: 'Business Studies', subjects: _business1112),
  DefaultClass(name: 'HSC 2nd Year', group: 'Humanities', subjects: _humanities1112),
];

/// A default room set. Deliberately small — a centre with more rooms adds them,
/// and a centre with one should not have to delete nine.
const defaultRooms = <({String name, int capacity})>[
  (name: 'Room 1', capacity: 30),
  (name: 'Room 2', capacity: 40),
];

/// Typical coaching hours: late afternoon into evening, after school lets out,
/// with a short break before the last two periods.
const defaultTimeSlots = <({String label, int start, int end})>[
  (label: '3:00 – 4:00 PM', start: 15 * 60, end: 16 * 60),
  (label: '4:00 – 5:00 PM', start: 16 * 60, end: 17 * 60),
  (label: '5:00 – 6:00 PM', start: 17 * 60, end: 18 * 60),
  (label: '6:15 – 7:15 PM', start: 18 * 60 + 15, end: 19 * 60 + 15),
  (label: '7:15 – 8:15 PM', start: 19 * 60 + 15, end: 20 * 60 + 15),
];
