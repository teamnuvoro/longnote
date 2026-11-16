/// Summary templates. Ids are the server's `style` values (BACKEND-API 4.3).
/// Labels/descriptions are for the D6 "Summary style" sheet and G1.
enum SummaryStyle {
  meeting('meeting', 'Meeting notes', 'Key points, decisions, action items with owners.'),
  lecture('lecture', 'Lecture', 'Main ideas, definitions and what to revise.'),
  oneOnOne('one_on_one', '1:1', 'Updates, feedback and agreed next steps.'),
  interview('interview', 'Interview', 'Questions asked, answers and impressions.'),
  clientCall('client_call', 'Client call', 'Needs, objections, promises and follow-ups.'),
  brainstorm('brainstorm', 'Brainstorm', 'Ideas grouped by theme, and what was picked.'),
  sermon('sermon', 'Sermon', 'Message, stories, scripture and take-aways.'),
  doctorVisit('doctor_visit', 'Doctor visit', 'What the doctor said, medicines and next steps.'),
  voiceMemoTodos('voice_memo_todos', 'Voice memo to-dos', 'A clean list of tasks and reminders.');

  const SummaryStyle(this.id, this.label, this.description);

  /// Value sent to the server.
  final String id;
  final String label;
  final String description;

  static SummaryStyle parse(String? id) => SummaryStyle.values
      .firstWhere((e) => e.id == id, orElse: () => SummaryStyle.meeting);
}

/// Max length of the user's own instructions (server cap).
const int maxCustomInstructionsChars = 1000;
