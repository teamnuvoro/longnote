import 'package:flutter/widgets.dart';

import '../icons.dart';
import '../tokens.dart';
import 'pressable.dart';

class LnTab {
  const LnTab(this.label, this.icon);
  final String label;
  final LnIcons icon;
}

/// Bottom tab bar (Figma TabBar 2:165): Notes, Ask, Import, Settings.
/// Record is NOT a tab; it is the floating [LnRecordPill] on Notes.
class LnTabBar extends StatelessWidget {
  const LnTabBar({super.key, required this.currentIndex, required this.onTap});

  static const tabs = [
    LnTab('Notes', LnIcons.tabNotes),
    LnTab('Ask', LnIcons.tabAsk),
    LnTab('Import', LnIcons.tabImport),
    LnTab('Settings', LnIcons.tabSettings),
  ];

  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      decoration: const BoxDecoration(
        color: LnColors.tabBar,
        border: Border(top: BorderSide(color: LnColors.line)),
      ),
      padding: EdgeInsets.only(top: 6, left: 20, right: 20, bottom: bottom),
      child: SizedBox(
        height: 44,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < tabs.length; i++)
              LnPressable(
                onPressed: () => onTap(i),
                semanticLabel: tabs[i].label,
                pressedOpacity: 0.7,
                child: SizedBox(
                  width: 76,
                  child: Column(children: [
                    LnIcon(tabs[i].icon,
                        size: 24,
                        color: i == currentIndex ? LnColors.ink : LnColors.ink3),
                    const SizedBox(height: 3),
                    Text(tabs[i].label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.visible,
                        style: i == currentIndex
                            ? LnText.tabActive
                            : LnText.tabInactive),
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
