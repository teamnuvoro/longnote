import 'package:flutter/material.dart';

import '../icons.dart';
import '../tokens.dart';

/// Search field (Figma B1/B3): 40 px high, quiet fill, radius 12, search icon
/// 18, Geist 16. With [onTap] and [readOnly] it acts as a button that opens
/// the search screen.
class LnSearchField extends StatelessWidget {
  const LnSearchField({
    super.key,
    this.controller,
    this.hint = 'Search notes and transcripts',
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.readOnly = false,
    this.autofocus = false,
    this.focusNode,
  });

  final TextEditingController? controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;
  final bool readOnly;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
          color: LnColors.fill,
          borderRadius: BorderRadius.circular(LnRadius.search)),
      child: Row(children: [
        const LnIcon(LnIcons.search, size: 18, color: LnColors.ink3),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            readOnly: readOnly,
            autofocus: autofocus,
            onTap: onTap,
            onChanged: onChanged,
            onSubmitted: onSubmitted,
            textInputAction: TextInputAction.search,
            style: LnText.body.copyWith(height: 1.2),
            cursorColor: LnColors.ink,
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              hintText: hint,
              hintStyle: LnText.placeholder,
            ),
          ),
        ),
      ]),
    );
  }
}

/// Plain text field in the same style (F2 "Name", D4 speaker names).
class LnTextField extends StatelessWidget {
  const LnTextField({
    super.key,
    this.controller,
    this.hint,
    this.onChanged,
    this.maxLines = 1,
    this.autofocus = false,
    this.maxLength,
  });

  final TextEditingController? controller;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final int maxLines;
  final bool autofocus;
  final int? maxLength;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: LnColors.card,
        borderRadius: BorderRadius.circular(LnRadius.search),
        border: Border.all(color: LnColors.line),
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        maxLines: maxLines,
        maxLength: maxLength,
        autofocus: autofocus,
        style: LnText.body.copyWith(height: 1.3),
        cursorColor: LnColors.ink,
        decoration: InputDecoration(
          isCollapsed: true,
          border: InputBorder.none,
          counterText: '',
          hintText: hint,
          hintStyle: LnText.placeholder,
        ),
      ),
    );
  }
}
