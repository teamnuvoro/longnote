import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/summary/local_extractive_summarizer.dart';

void main() {
  final s = LocalExtractiveSummarizer();

  const meeting = '''
[00:00] Good morning everyone, let's start the quarterly budget review.
[00:10] Revenue for the quarter was 4.2 crore, up 12 percent from last year.
[00:25] Marketing spend went over the budget by 8 lakh in October.
[00:40] After discussion we decided to freeze new hiring until March.
[00:55] The motion to approve the revised budget passed with five votes to two.
[01:10] Ravi will send the revised forecast to the board by Friday.
[01:20] Priya, can you check the vendor contracts?
[01:30] Someone should probably look at the travel costs at some point.
[01:45] Do we know when the auditors are coming?
[02:00] The office move is still planned but the date is not fixed.
[02:15] Thanks everyone, see you next week.
''';

  test('finds decisions including the vote', () {
    final r = s.summarizeText(meeting);
    expect(r.decisions.join(' '), contains('freeze new hiring'));
    expect(r.decisions.join(' '), contains('five votes to two'));
  });

  test('action items get an owner/due ONLY when stated', () {
    final r = s.summarizeText(meeting);
    final ravi = r.actionItems.firstWhere((a) => a.task.contains('Ravi'));
    expect(ravi.owner, 'Ravi');
    expect(ravi.due, 'Friday');

    final priya = r.actionItems.firstWhere((a) => a.task.contains('Priya'));
    expect(priya.owner, 'Priya');
    expect(priya.due, isNull);

    final travel = r.actionItems.where((a) => a.task.contains('travel'));
    for (final a in travel) {
      expect(a.owner, isNull, reason: '"Someone" is not an owner');
      expect(a.due, isNull);
    }
  });

  test('numbers and dates are collected', () {
    final r = s.summarizeText(meeting);
    final all = r.numbersAndDates.join(' ');
    expect(all, contains('4.2 crore'));
    expect(all, contains('8 lakh'));
  });

  test('questions go to open questions', () {
    final r = s.summarizeText(meeting);
    expect(r.openQuestions, ['Do we know when the auditors are coming?']);
  });

  test('key points are original sentences, in order, capped', () {
    final r = s.summarizeText(meeting);
    expect(r.keyPoints, isNotEmpty);
    expect(r.keyPoints.length, lessThanOrEqualTo(7));
    var last = -1;
    for (final k in r.keyPoints) {
      final idx = meeting.indexOf(k);
      expect(idx, greaterThan(last), reason: 'extractive and ordered: $k');
      last = idx;
    }
  });

  test('never invents text: every output is a substring of the input', () {
    final r = s.summarizeText(meeting);
    final flat = meeting.replaceAll(RegExp(r'\[\d\d:\d\d\]\s*'), '').replaceAll('\n', ' ');
    for (final t in [
      ...r.keyPoints,
      ...r.decisions,
      ...r.numbersAndDates,
      ...r.openQuestions,
      ...r.actionItems.map((a) => a.task),
    ]) {
      expect(flat, contains(t));
    }
  });

  test('empty or tiny input gives an empty summary, no crash', () {
    expect(s.summarizeText('').isEmpty, isTrue);
    expect(s.summarizeText('[00:01] Hi.').isEmpty, isTrue);
  });

  test('handles a long transcript quickly', () {
    final long = List.generate(20000,
            (i) => '[${i ~/ 60}:${(i % 60).toString().padLeft(2, '0')}] Item $i about the plan and the budget.')
        .join('\n');
    final sw = Stopwatch()..start();
    final r = s.summarizeText(long);
    sw.stop();
    expect(r.keyPoints, isNotEmpty);
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
  });
}
