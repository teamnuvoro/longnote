import 'package:flutter/material.dart';

import '../../ui/widgets.dart';

/// Every design-system component on one screen (developer tool). Reached
/// from Settings > tap the version 7x > Benchmark > "Widget gallery".
class WidgetGalleryScreen extends StatefulWidget {
  const WidgetGalleryScreen({super.key});
  @override
  State<WidgetGalleryScreen> createState() => _WidgetGalleryScreenState();
}

class _WidgetGalleryScreenState extends State<WidgetGalleryScreen> {
  int _tab = 0;
  String _seg = 'summary';
  bool _toggle = true;
  bool _small = false;
  bool _playing = false;

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: LnSpace.section),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LnSectionLabel(title),
          ...children,
        ]),
      );

  Widget _gap([double h = 8]) => SizedBox(height: h);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: LnColors.paper,
      appBar: LnTopBar(
          backLabel: 'Back', onBack: () => Navigator.of(context).maybePop()),
      bottomNavigationBar: LnTabBar(
          currentIndex: _tab, onTap: (i) => setState(() => _tab = i)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
        children: [
          const LnLargeTitle('Gallery', trailing: LnChip('Trial · 2 days left')),
          _section('Colours', [
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in const [
                ('paper', LnColors.paper), ('card', LnColors.card), ('ink', LnColors.ink),
                ('ink2', LnColors.ink2), ('ink3', LnColors.ink3), ('line', LnColors.line),
                ('signal', LnColors.signal), ('saved', LnColors.saved),
                ('attention', LnColors.attention), ('night', LnColors.night),
              ])
                Column(children: [
                  Container(
                      width: 52,
                      height: 36,
                      decoration: BoxDecoration(
                          color: c.$2,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: LnColors.line))),
                  Text(c.$1, style: LnText.chip),
                ]),
            ]),
            _gap(),
            Wrap(spacing: 6, children: [
              for (var i = 0; i < LnSpeakerColors.list.length; i++)
                LnSpeakerAvatar(name: 'S$i', colorIndex: i),
            ]),
          ]),
          _section('Type', [
            Text('Large title', style: LnText.largeTitle),
            Text('Detail title', style: LnText.detailTitle),
            Text('Note title', style: LnText.noteTitle),
            Text('In short: Newsreader 18 / 27 for the summary lead.',
                style: LnText.summaryLead),
            Text('Headline', style: LnText.headline),
            Text('Body: Geist Regular 16 / 24', style: LnText.body),
            Text('Caption', style: LnText.caption),
            const LnOverline('Decisions'),
            Text('00:42:17', style: LnText.mono),
          ]),
          _section('Buttons', [
            const LnPrimaryButton(label: 'Continue', onPressed: _noop),
            _gap(),
            const LnSecondaryButton(label: 'Not now', onPressed: _noop),
            _gap(),
            const LnDestructiveButton(label: 'Delete', onPressed: _noop),
            _gap(),
            const LnPrimaryButton(label: 'Disabled'),
            _gap(),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: const [
              LnSmallButton(label: 'Retry', onPressed: _noop),
              LnPillButton(label: 'Ask', icon: LnIcons.sparkle, style: LnPillStyle.ink, onPressed: _noop),
              LnPillButton(label: 'Edit names', icon: LnIcons.pencil, onPressed: _noop),
              LnPillButton(label: 'Change style', style: LnPillStyle.fill, onPressed: _noop),
              LnIconButton(icon: LnIcons.share, onPressed: _noop),
              LnIconButton(icon: LnIcons.more, onPressed: _noop),
              LnIconButton(icon: LnIcons.trash, shape: LnIconButtonShape.square, iconSize: 17, onPressed: _noop),
            ]),
            _gap(16),
            const Center(child: LnRecordPill(onPressed: _noop)),
          ]),
          _section('Fields and controls', [
            const LnSearchField(),
            _gap(),
            const LnTextField(hint: 'Board meeting — Nov 12'),
            _gap(),
            LnSegmentedControl<String>(
              segments: const {'summary': 'Summary', 'transcript': 'Transcript'},
              selected: _seg,
              onChanged: (v) => setState(() => _seg = v),
            ),
            _gap(),
            Row(children: [
              LnToggle(value: _toggle, onChanged: (v) => setState(() => _toggle = v)),
              const SizedBox(width: 12),
              LnToggle(small: true, value: _small, onChanged: (v) => setState(() => _small = v)),
              const SizedBox(width: 12),
              Text('Speakers', style: LnText.segmentSelected),
            ]),
            _gap(),
            Wrap(spacing: 8, runSpacing: 8, children: const [
              LnChip('Trial · 2 days left'),
              LnChip('Selected', selected: true),
              LnPillChip(label: 'Priya · 14:02', icon: LnIcons.play, onTap: _noop),
              LnPillChip(label: '1×', selected: true),
            ]),
          ]),
          _section('Card group and rows', [
            LnCardGroup(children: [
              LnAttentionRow(
                icon: LnIcons.cloudOff,
                title: 'Client call — Rivera & Co',
                subtitle: 'Saved on phone · uploads when online',
                actions: [LnIconButton(icon: LnIcons.trash, shape: LnIconButtonShape.square, iconSize: 17, onPressed: _noop)],
              ),
              const LnAttentionRow(
                icon: LnIcons.alert,
                title: 'Lecture 7 — Organic chemistry',
                subtitle: 'Transcription failed · audio is safe',
                actions: [LnSmallButton(label: 'Retry', onPressed: _noop)],
              ),
            ]),
            _gap(16),
            const LnCardGroup(children: [
              LnNoteRow(
                  title: 'Weekly product sync',
                  duration: '48:10',
                  status: 'Transcribing · 64%',
                  progress: 0.64),
              LnNoteRow(
                  title: 'Q3 budget review with Priya',
                  duration: '1:12:40',
                  preview: 'Agreed to cut paid ads by 20% and move it to referrals.'),
            ]),
            _gap(16),
            LnCardGroup.settings(children: [
              const LnListRow(icon: LnIcons.globe, label: 'Audio language', value: 'English', onTap: _noop),
              LnListRow.toggle(
                  icon: LnIcons.users,
                  label: 'Speaker labels',
                  value: _toggle,
                  onChanged: (v) => setState(() => _toggle = v)),
              const LnListRow(icon: LnIcons.trash, label: 'Delete note…', destructive: true, large: true, onTap: _noop),
            ]),
          ]),
          _section('Recording (dark)', [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: LnColors.night, borderRadius: BorderRadius.circular(LnRadius.card)),
              child: Column(children: [
                const Wrap(spacing: 8, runSpacing: 8, children: [
                  LnStatusPill(LnStatus.recording),
                  LnStatusPill(LnStatus.paused),
                  LnStatusPill(LnStatus.saved),
                ]),
                const SizedBox(height: 12),
                Text('00:42:17', style: LnText.timer.copyWith(fontSize: 40)),
                const SizedBox(height: 12),
                const Wrap(spacing: 8, children: [
                  LnPillChip(label: 'English', icon: LnIcons.globe, dark: true, onTap: _noop),
                  LnPillChip(label: 'Mark moment', icon: LnIcons.bookmark, dark: true, onTap: _noop),
                ]),
              ]),
            ),
          ]),
          _section('Mini player', [
            LnMiniPlayer(
              playing: _playing,
              position: const Duration(minutes: 14, seconds: 19),
              duration: const Duration(hours: 1, minutes: 12, seconds: 40),
              onPlayPause: () => setState(() => _playing = !_playing),
              onSpeed: _noop,
              onExpand: _noop,
            ),
          ]),
          _section('Sheet', [
            LnSecondaryButton(
              label: 'Open sheet (title header)',
              onPressed: () => showLnSheet<void>(context,
                  builder: (_) => LnSheet(
                        title: 'Q3 budget review with Priya',
                        subtitle: 'Today, 10:24 AM · 1:12:40 · 3 speakers',
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const LnCardGroup(children: [
                            LnListRow(icon: LnIcons.pencil, label: 'Rename', large: true, onTap: _noop),
                            LnListRow(icon: LnIcons.share, label: 'Share or export…', large: true, onTap: _noop),
                            LnListRow(icon: LnIcons.copy, label: 'Copy summary', large: true, onTap: _noop),
                          ]),
                          const SizedBox(height: 12),
                          const LnCardGroup(children: [
                            LnListRow(icon: LnIcons.trash, label: 'Delete note…', large: true, destructive: true, onTap: _noop),
                          ]),
                        ]),
                      )),
            ),
            _gap(),
            LnSecondaryButton(
              label: 'Open sheet (Cancel / Save header)',
              onPressed: () => showLnSheet<void>(context,
                  builder: (ctx) => LnSheet(
                        title: 'Speakers',
                        leadingAction: LnSheetAction('Cancel', onPressed: () => Navigator.pop(ctx)),
                        trailingAction: LnSheetAction('Save', emphasized: true, onPressed: () => Navigator.pop(ctx)),
                        child: const LnTextField(hint: 'Speaker 3'),
                      )),
            ),
          ]),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

void _noop() {}
