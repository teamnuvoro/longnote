import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'tokens.dart';

/// Icons exported from the Figma file (Lucide-style, 2 px stroke), stored in
/// assets/icons/. Each SVG has its own stroke colour; [LnIcon] tints it.
enum LnIcons {
  tabNotes('tab_notes'),
  tabAsk('tab_ask'),
  tabImport('tab_import'),
  tabSettings('tab_settings'),
  recordDot('record_dot'),
  search('search'),
  cloud('cloud'),
  cloudOff('cloud_off'),
  trash('trash'),
  alert('alert'),
  globe('globe'),
  chevronRight('chevron_right'),
  chevronLeft('chevron_left'),
  chevronUp('chevron_up'),
  chevronDown('chevron_down'),
  text('text'),
  template('template'),
  users('users'),
  shield('shield'),
  mail('mail'),
  bulb('bulb'),
  star('star'),
  pencil('pencil'),
  share('share'),
  copy('copy'),
  sparkle('sparkle'),
  more('more'),
  phone('phone'),
  play('play'),
  pause('pause'),
  check('check'),
  bookmark('bookmark'),
  lock('lock'),
  x('x');

  const LnIcons(this.file);
  final String file;
  String get asset => 'assets/icons/$file.svg';
}

/// An SVG icon tinted to [color]. [color] null keeps the file's own colours
/// (needed for [LnIcons.recordDot], which is two-coloured).
class LnIcon extends StatelessWidget {
  const LnIcon(this.icon, {super.key, this.size = 20, this.color = LnColors.ink});

  final LnIcons icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      icon.asset,
      width: size,
      height: size,
      colorFilter:
          color == null ? null : ColorFilter.mode(color!, BlendMode.srcIn),
    );
  }
}
