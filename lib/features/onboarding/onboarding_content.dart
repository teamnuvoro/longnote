import '../../ui/icons.dart';

/// What the user said they will record (onboarding question 1). The first
/// pick decides which sample note the next screens show.
enum RecordUse {
  meetings('meetings', 'Work meetings', 'meetings', LnIcons.users),
  lectures('lectures', 'Lectures and classes', 'lectures', LnIcons.bookmark),
  interviews('interviews', 'Interviews', 'interviews', LnIcons.mic),
  calls('calls', 'Client and sales calls', 'calls', LnIcons.phone),
  talks('talks', 'Sermons and talks', 'talks', LnIcons.star),
  doctor('doctor', 'Doctor visits', 'doctor visits', LnIcons.shield),
  other('other', 'Something else', 'everything else', LnIcons.sparkle);

  const RecordUse(this.id, this.label, this.short, this.icon);
  final String id;
  final String label;

  /// For "Summaries made for lectures and meetings".
  final String short;
  final LnIcons icon;
}

/// How long the recordings usually run (onboarding question 2).
enum RecordLength {
  short('under_30', 'Under 30 minutes'),
  hour('30_60', '30 to 60 minutes'),
  twoHours('1_2h', '1 to 2 hours'),
  longer('over_2h', 'Longer than 2 hours');

  const RecordLength(this.id, this.label);
  final String id;
  final String label;
}

class DemoTurn {
  const DemoTurn(this.speaker, this.color, this.time, this.text);
  final String speaker;
  final int color;
  final String time;
  final String text;
}

class DemoAction {
  const DemoAction(this.text, this.owner);
  final String text;
  final String owner;
}

/// A sample note shown on the pitch screens (made-up content, so nothing
/// claims to be a real customer).
class DemoNote {
  const DemoNote({
    required this.title,
    required this.meta,
    required this.lead,
    required this.points,
    required this.decisionsLabel,
    required this.decisions,
    required this.actionsLabel,
    required this.actions,
    required this.turns,
    required this.question,
    required this.answer,
    required this.answerAt,
    required this.styleWord,
  });
  final String title;
  final String meta;
  final String lead;
  final List<String> points;
  final String decisionsLabel;
  final List<String> decisions;
  final String actionsLabel;
  final List<DemoAction> actions;
  final List<DemoTurn> turns;
  final String question;
  final String answer;
  final String answerAt;

  /// "meetings", "lectures"... for "Summaries made for your ___".
  final String styleWord;

  static DemoNote forUse(RecordUse? use) => switch (use) {
        RecordUse.lectures => _lecture,
        RecordUse.interviews => _interview,
        RecordUse.talks => _talk,
        RecordUse.calls => _call,
        RecordUse.doctor => _doctor,
        _ => _meeting,
      };
}

const _meeting = DemoNote(
  title: 'Q4 planning with the product team',
  meta: '1 h 52 min · 5 speakers',
  lead:
      'The team agreed to ship the new onboarding before the holidays and to move the pricing test to January.',
  points: [
    'Sign-ups are up 18% since the redesign',
    'Support tickets mostly ask about exports',
    'Two engineers free up after the 15th',
  ],
  decisionsLabel: 'Decisions',
  decisions: ['Ship onboarding on Dec 12', 'Pricing test moves to January'],
  actionsLabel: 'Action items',
  actions: [
    DemoAction('Write the release notes', 'Maya'),
    DemoAction('Book the January test', 'Dev'),
    DemoAction('Fix the export bug', 'Sam'),
  ],
  turns: [
    DemoTurn('Maya', 0, '00:41:12',
        'If we ship before the 15th we catch the holiday traffic.'),
    DemoTurn('Dev', 1, '00:41:20',
        'Then pricing has to wait. I don’t want two changes at once.'),
    DemoTurn('Sam', 2, '00:41:31',
        'Agreed. I can have the export fix in by Friday.'),
  ],
  question: 'What did we decide about pricing?',
  answer:
      'The pricing test moves to January, so it doesn’t run at the same time as the new onboarding. Dev will book it.',
  answerAt: '00:41:20',
  styleWord: 'meetings',
);

const _lecture = DemoNote(
  title: 'Biology 201 · Cell respiration',
  meta: '1 h 24 min · Lecture',
  lead:
      'Cells turn glucose into usable energy (ATP) in three stages; most of it comes from the last one.',
  points: [
    'Glycolysis happens in the cytoplasm',
    'The Krebs cycle runs in the mitochondria',
    'The electron transport chain makes ~34 ATP',
  ],
  decisionsLabel: 'Key terms',
  decisions: ['ATP: the cell’s energy currency', 'Aerobic: needs oxygen'],
  actionsLabel: 'To revise',
  actions: [
    DemoAction('Draw the three stages from memory', 'You'),
    DemoAction('Read chapter 9 before Thursday', 'You'),
    DemoAction('Problem set 4 due Monday', 'You'),
  ],
  turns: [
    DemoTurn('Professor', 0, '00:52:03',
        'This is the part that will be on the exam, so slow down here.'),
    DemoTurn('Student', 1, '00:52:15',
        'Is the 34 an exact number or an estimate?'),
    DemoTurn('Professor', 0, '00:52:19',
        'An estimate. Say “about 34” and you get full marks.'),
  ],
  question: 'What did the professor say will be on the exam?',
  answer:
      'The electron transport chain. The professor said to know that it makes about 34 ATP, and that “about 34” gets full marks.',
  answerAt: '00:52:03',
  styleWord: 'lectures',
);

const _interview = DemoNote(
  title: 'Interview with a senior designer',
  meta: '58 min · 2 speakers',
  lead:
      'A strong candidate with deep mobile experience; wants to grow into leading a small team.',
  points: [
    'Seven years of iOS and Android design',
    'Led the redesign of a banking app',
    'Prefers small, fast teams',
  ],
  decisionsLabel: 'Impressions',
  decisions: ['Clear, structured answers', 'Strong portfolio, weak on research'],
  actionsLabel: 'Next steps',
  actions: [
    DemoAction('Send the design exercise', 'Priya'),
    DemoAction('Check two references', 'Arjun'),
    DemoAction('Decide by Friday', 'Team'),
  ],
  turns: [
    DemoTurn('Priya', 0, '00:12:40',
        'Tell me about a project that didn’t go to plan.'),
    DemoTurn('Candidate', 1, '00:12:46',
        'The banking redesign. We launched late, but sign-ins went up 30%.'),
    DemoTurn('Priya', 0, '00:13:30', 'What would you do differently?'),
  ],
  question: 'What did they say about the banking app?',
  answer:
      'They led its redesign. It launched late, but sign-ins went up 30% afterwards.',
  answerAt: '00:12:46',
  styleWord: 'interviews',
);

const _talk = DemoNote(
  title: 'Sunday message · Patience',
  meta: '47 min · 1 speaker',
  lead:
      'Patience is not waiting quietly; it is trusting while you keep doing the right thing.',
  points: [
    'The farmer waits for the rain but still ploughs',
    'Impatience usually comes from fear',
    'Small faithful steps add up',
  ],
  decisionsLabel: 'Scripture',
  decisions: ['James 5:7–8', 'Galatians 6:9'],
  actionsLabel: 'Take-aways',
  actions: [
    DemoAction('Name one thing you are rushing', 'This week'),
    DemoAction('Read James 5 each morning', 'Daily'),
    DemoAction('Call someone who is waiting too', 'Sunday'),
  ],
  turns: [
    DemoTurn('Pastor', 0, '00:18:05',
        'The farmer doesn’t sit and wait. He ploughs, and then he waits.'),
    DemoTurn('Pastor', 0, '00:18:21',
        'Patience is work you do while the answer hasn’t come yet.'),
    DemoTurn('Pastor', 0, '00:18:40',
        'So this week, name one thing you are rushing.'),
  ],
  question: 'What was the farmer story about?',
  answer:
      'The farmer ploughs and then waits for the rain. The point: patience means doing the work while you wait.',
  answerAt: '00:18:05',
  styleWord: 'talks',
);

const _call = DemoNote(
  title: 'Discovery call with Northwind',
  meta: '42 min · 3 speakers',
  lead:
      'Northwind wants to replace their current tool by March; price and onboarding time are the main concerns.',
  points: [
    'Team of 40, growing to 60 this year',
    'Unhappy with slow support',
    'Budget is approved for Q1',
  ],
  decisionsLabel: 'Objections',
  decisions: ['Worried about migration time', 'Wants monthly billing'],
  actionsLabel: 'Follow-ups',
  actions: [
    DemoAction('Send pricing for 60 seats', 'Alex'),
    DemoAction('Book a demo with their IT lead', 'Alex'),
    DemoAction('Share the migration guide', 'Jo'),
  ],
  turns: [
    DemoTurn('Alex', 0, '00:22:10', 'What would make this an easy yes?'),
    DemoTurn('Northwind', 1, '00:22:14',
        'If we can move everything over in under two weeks.'),
    DemoTurn('Jo', 2, '00:22:30', 'Most teams your size take about eight days.'),
  ],
  question: 'What would make them say yes?',
  answer:
      'Moving everything over in under two weeks. Jo said teams their size usually take about eight days.',
  answerAt: '00:22:14',
  styleWord: 'calls',
);

const _doctor = DemoNote(
  title: 'Check-up with Dr. Rao',
  meta: '18 min · 2 speakers',
  lead:
      'Blood pressure is a little high; the doctor changed one medicine and wants a follow-up in a month.',
  points: [
    'Blood pressure 142/90',
    'Sleep has improved',
    'Keep walking 30 minutes a day',
  ],
  decisionsLabel: 'Medicines',
  decisions: ['Amlodipine 5 mg, once a day', 'Stop the old evening tablet'],
  actionsLabel: 'Next steps',
  actions: [
    DemoAction('Blood test before the next visit', 'You'),
    DemoAction('Check BP twice a week', 'You'),
    DemoAction('Follow-up on Dec 20', 'Clinic'),
  ],
  turns: [
    DemoTurn('Dr. Rao', 0, '00:06:12',
        'I’d like to switch you to amlodipine, five milligrams.'),
    DemoTurn('You', 1, '00:06:20', 'Do I stop the evening tablet then?'),
    DemoTurn('Dr. Rao', 0, '00:06:24', 'Yes, stop that one from tomorrow.'),
  ],
  question: 'Which tablet do I stop?',
  answer:
      'The old evening tablet, from tomorrow. The doctor started amlodipine 5 mg once a day instead.',
  answerAt: '00:06:24',
  styleWord: 'visits',
);
