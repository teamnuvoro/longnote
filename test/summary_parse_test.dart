import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/summary/summarizer.dart';
import 'package:longnote/core/summary/summary_models.dart';

void main() {
  group('MeetingSummary.parse', () {
    test('valid JSON', () {
      final s = MeetingSummary.parse(jsonEncode({
        'key_points': ['Revenue grew 12% to Rs 4.2 crore'],
        'decisions': ['Motion to approve the budget passed 5-2 (moved by Meera)'],
        'action_items': [
          {'task': 'Send minutes', 'owner': 'Arjun', 'due': '20 Nov'},
          {'task': 'Book venue', 'owner': null, 'due': null},
        ],
        'numbers_and_dates': ['Next meeting 3 Dec'],
        'open_questions': ['Who audits Q3?'],
      }));
      expect(s.keyPoints.single, contains('12%'));
      expect(s.decisions.single, contains('5-2'));
      expect(s.actionItems[0].owner, 'Arjun');
      expect(s.actionItems[0].due, '20 Nov');
      expect(s.actionItems[1].owner, isNull);
      expect(s.actionItems[1].due, isNull);
      expect(s.numbersAndDates, ['Next meeting 3 Dec']);
      expect(s.openQuestions, ['Who audits Q3?']);
    });

    test('JSON inside a markdown fence with chatter around it', () {
      const raw = 'Sure! Here are the notes:\n```json\n'
          '{"key_points": ["A"], "decisions": [], "action_items": [], '
          '"numbers_and_dates": [], "open_questions": []}\n```\nHope this helps.';
      expect(MeetingSummary.parse(raw).keyPoints, ['A']);
    });

    test('JSON object embedded in text without a fence (braces in strings)', () {
      const raw =
          'Notes: {"key_points": ["Use {curly} braces", "B"], "decisions": ["x"]} end';
      final s = MeetingSummary.parse(raw);
      expect(s.keyPoints, ['Use {curly} braces', 'B']);
      expect(s.decisions, ['x']);
    });

    test('partial: missing fields become empty lists', () {
      final s = MeetingSummary.parse('{"decisions": ["Ship it"]}');
      expect(s.decisions, ['Ship it']);
      expect(s.keyPoints, isEmpty);
      expect(s.actionItems, isEmpty);
      expect(s.isEmpty, isFalse);
    });

    test('loose shapes: string instead of list, objects, numbers, odd keys', () {
      final s = MeetingSummary.parse(jsonEncode({
        'Key Points': 'Only one point',
        'decisions': [
          {'text': 'Go with vendor B'},
          42,
          null,
          '',
          ['nested', 'ignored'],
        ],
        'action-items': [
          'Call the bank',
          {'action': 'Draft contract', 'assignee': 'Unknown', 'deadline': 'TBD'},
          {'task': '', 'owner': 'X'},
        ],
      }));
      expect(s.keyPoints, ['Only one point']);
      expect(s.decisions, ['Go with vendor B', '42']);
      expect(s.actionItems.map((a) => a.task), ['Call the bank', 'Draft contract']);
      // "Unknown"/"TBD" are NOT treated as a real owner/date.
      expect(s.actionItems[1].owner, isNull);
      expect(s.actionItems[1].due, isNull);
    });

    test('garbage throws', () {
      expect(() => MeetingSummary.parse('I could not summarize this.'),
          throwsA(isA<SummaryParseException>()));
      expect(() => MeetingSummary.parse('{"foo": 1}'),
          throwsA(isA<SummaryParseException>()));
      expect(() => MeetingSummary.parse('{"key_points": ["unterminated'),
          throwsA(isA<SummaryParseException>()));
      expect(() => MeetingSummary.parse('[1,2,3]'),
          throwsA(isA<SummaryParseException>()));
      expect(() => MeetingSummary.parse(''),
          throwsA(isA<SummaryParseException>()));
    });

    test('encode -> parse round trip', () {
      const s = MeetingSummary(
        keyPoints: ['a'],
        decisions: ['b'],
        actionItems: [ActionItem(task: 't', owner: 'o')],
        numbersAndDates: ['5'],
        openQuestions: ['q?'],
      );
      final r = MeetingSummary.parse(s.encode());
      expect(r.toJson(), s.toJson());
    });
  });

  group('merge', () {
    test('keeps order, drops duplicates (case/punctuation-insensitive)', () {
      final m = MeetingSummary.merge(const [
        MeetingSummary(keyPoints: ['Budget is tight.', 'Hiring paused']),
        MeetingSummary(keyPoints: ['budget is tight', 'New office in Pune']),
      ]);
      expect(m.keyPoints, ['Budget is tight.', 'Hiring paused', 'New office in Pune']);
    });

    test('same action item from two chunks keeps stated owner/due', () {
      final m = MeetingSummary.merge(const [
        MeetingSummary(actionItems: [ActionItem(task: 'Send deck')]),
        MeetingSummary(actionItems: [
          ActionItem(task: 'Send deck', owner: 'Ravi', due: 'Friday'),
          ActionItem(task: 'Call auditor'),
        ]),
      ]);
      expect(m.actionItems, hasLength(2));
      expect(m.actionItems.first.owner, 'Ravi');
      expect(m.actionItems.first.due, 'Friday');
    });
  });

  group('chunkTranscript', () {
    test('short text is one chunk', () {
      expect(chunkTranscript('a\nb', 100), ['a\nb']);
    });

    test('splits on line boundaries and respects the limit', () {
      final lines = List.generate(50, (i) => '[00:${i.toString().padLeft(2, '0')}] sentence number $i.');
      final chunks = chunkTranscript(lines.join('\n'), 200);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(200));
      }
      // Nothing lost, order kept.
      expect(chunks.join('\n').split('\n'), lines);
    });

    test('a single huge line is split on sentence/word boundaries', () {
      final line = List.generate(100, (i) => 'Word$i is here.').join(' ');
      final chunks = chunkTranscript(line, 120);
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(120));
      }
      expect(chunks.join(' ').replaceAll(RegExp(r'\s+'), ' '),
          line.replaceAll(RegExp(r'\s+'), ' '));
    });

    test('empty transcript gives no chunks', () {
      expect(chunkTranscript('', 100), isEmpty);
      expect(chunkTranscript('\n\n', 100), isEmpty);
    });
  });

  test('toPlainText lists only stated owner/due', () {
    const s = MeetingSummary(
      decisions: ['Approved'],
      actionItems: [
        ActionItem(task: 'Send minutes', owner: 'Asha'),
        ActionItem(task: 'Book room'),
      ],
    );
    final t = s.toPlainText(title: 'Board');
    expect(t, contains('- Send minutes (owner: Asha)'));
    expect(t, contains('- Book room'));
    expect(t, isNot(contains('Book room (')));
    expect(t, isNot(contains('Key points')));
  });

  test('prompt keeps names/numbers/votes and forbids invented owners/dates', () {
    expect(summaryInstructions, contains('names, numbers'));
    expect(summaryInstructions, contains('votes and motions'));
    expect(summaryInstructions, contains('Never invent an owner or a date'));
  });
}
