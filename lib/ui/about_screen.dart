// SPDX-License-Identifier: GPL-3.0-or-later
//
// about_screen.dart — AboutScreen: two tabs, "README" and "Credits", under
// one AppBar+TabBar. The README tab reads README.md straight out of the
// asset bundle (declared in pubspec.yaml) and runs it through a small
// markdown-lite renderer below -- deliberately not a full CommonMark
// implementation (headings, bold/`code`/[links], bullet lists, blockquotes,
// tables, and fenced code blocks only, which is everything the repo's own
// README actually uses). Rendering the real file rather than hand-copying
// its prose means this tab can't silently drift from the README the way a
// transcribed copy could. The Credits tab is credits_screen.dart, formerly
// its own standalone route -- see that file's header for why it moved here.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'credits_screen.dart';
import 'manuscript_theme.dart';
import 'safe_layout.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key, this.initialTab = 0});

  /// 0 = README, 1 = Credits -- entry points that only care about
  /// attribution (Settings, the art pack picker's footer) land straight on
  /// the Credits tab instead of making the player switch to it themselves.
  final int initialTab;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: initialTab,
      child: Scaffold(
        backgroundColor: kParchmentColor,
        appBar: AppBar(
          backgroundColor: kParchmentColor,
          foregroundColor: kInkColor,
          elevation: 0,
          title: Text('About', style: manuscriptHeaderStyle(fontSize: 20)),
          bottom: TabBar(
            labelColor: kInkColor,
            unselectedLabelColor: kInkMutedColor,
            indicatorColor: kIlluminationGold,
            labelStyle: const TextStyle(fontFamily: 'serif', letterSpacing: 1),
            tabs: const [
              Tab(text: 'README'),
              Tab(text: 'Credits'),
            ],
          ),
        ),
        body: SafeScreenBody(
          child: const TabBarView(
            children: [
              _ReadmeTab(),
              CreditsScreen(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadmeTab extends StatefulWidget {
  const _ReadmeTab();

  @override
  State<_ReadmeTab> createState() => _ReadmeTabState();
}

class _ReadmeTabState extends State<_ReadmeTab> {
  // Loaded once and held for the widget's lifetime -- creating this inline
  // in build() instead would hand FutureBuilder a new Future identity on
  // every rebuild (e.g. each frame of the tab-switch animation), which
  // resets it back to the loading state each time and never lets
  // pumpAndSettle observe two consecutive settled frames.
  late final Future<String> _readme = rootBundle.loadString('README.md');

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _readme,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Center(
            child: Text('Could not load README.md', style: manuscriptBodyStyle()),
          );
        }
        return Container(
          color: kParchmentColor,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: parseMarkdownLite(snapshot.data!),
            ),
          ),
        );
      },
    );
  }
}

bool _isBlockStart(String trimmed) {
  return trimmed.startsWith('#') ||
      trimmed.startsWith('- ') ||
      trimmed.startsWith('* ') ||
      trimmed.startsWith('| ') ||
      trimmed.startsWith('|-') ||
      trimmed.startsWith('> ') ||
      trimmed.startsWith('```') ||
      trimmed == '---';
}

/// Renders the handful of markdown constructs README.md actually uses.
/// Not exposed as a general-purpose markdown widget -- this is scoped to
/// this one file, on purpose (see the file header).
List<Widget> parseMarkdownLite(String source) {
  final widgets = <Widget>[];
  final lines = source.split('\n');
  final tableBuffer = <String>[];
  var i = 0;

  void flushTable() {
    if (tableBuffer.isEmpty) return;
    widgets.add(_MarkdownTable(rows: List.of(tableBuffer)));
    tableBuffer.clear();
  }

  while (i < lines.length) {
    final trimmed = lines[i].trim();

    if (trimmed.startsWith('```')) {
      flushTable();
      final code = <String>[];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        code.add(lines[i]);
        i++;
      }
      i++; // skip the closing fence
      widgets.add(_MarkdownCodeBlock(code.join('\n')));
      continue;
    }

    if (trimmed.startsWith('|')) {
      tableBuffer.add(trimmed);
      i++;
      continue;
    }
    flushTable();

    if (trimmed.isEmpty) {
      widgets.add(const SizedBox(height: 10));
      i++;
      continue;
    }

    if (trimmed == '---') {
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Divider(color: kInkMutedColor.withValues(alpha: 0.4)),
      ));
      i++;
      continue;
    }

    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
    if (heading != null) {
      final level = heading.group(1)!.length;
      final fontSize = switch (level) {
        1 => 24.0,
        2 => 19.0,
        _ => 16.0,
      };
      widgets.add(Padding(
        padding: EdgeInsets.only(top: level == 1 ? 0 : 14, bottom: 8),
        child: Text(heading.group(2)!, style: manuscriptHeaderStyle(fontSize: fontSize)),
      ));
      i++;
      continue;
    }

    if (trimmed.startsWith('> ')) {
      final buffer = StringBuffer(trimmed.substring(2));
      i++;
      while (i < lines.length && lines[i].trim().startsWith('> ')) {
        buffer.write(' ');
        buffer.write(lines[i].trim().substring(2));
        i++;
      }
      widgets.add(Padding(
        padding: const EdgeInsets.only(left: 12, top: 4, bottom: 8),
        child: Text.rich(
          _inlineSpans(buffer.toString(), manuscriptBodyStyle().copyWith(fontStyle: FontStyle.italic)),
        ),
      ));
      continue;
    }

    if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
      final buffer = StringBuffer(trimmed.substring(2));
      i++;
      while (i < lines.length) {
        final next = lines[i].trim();
        if (next.isEmpty || _isBlockStart(next)) break;
        buffer.write(' ');
        buffer.write(next);
        i++;
      }
      widgets.add(Padding(
        padding: const EdgeInsets.only(left: 8, bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('•  ', style: manuscriptBodyStyle()),
            Expanded(child: Text.rich(_inlineSpans(buffer.toString(), manuscriptBodyStyle()))),
          ],
        ),
      ));
      continue;
    }

    // Plain paragraph -- merge wrapped continuation lines into one block.
    final buffer = StringBuffer(trimmed);
    i++;
    while (i < lines.length) {
      final next = lines[i].trim();
      if (next.isEmpty || _isBlockStart(next)) break;
      buffer.write(' ');
      buffer.write(next);
      i++;
    }
    widgets.add(Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(_inlineSpans(buffer.toString(), manuscriptBodyStyle())),
    ));
  }
  flushTable();
  return widgets;
}

/// Inline **bold**, `code`, and [text](url) (rendered as plain underlined
/// text -- the app is offline-only by design, so links are not tappable).
InlineSpan _inlineSpans(String text, TextStyle base) {
  final pattern = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)');
  final spans = <InlineSpan>[];
  var last = 0;
  for (final match in pattern.allMatches(text)) {
    if (match.start > last) {
      spans.add(TextSpan(text: text.substring(last, match.start)));
    }
    if (match.group(1) != null) {
      spans.add(TextSpan(
        text: match.group(1),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ));
    } else if (match.group(2) != null) {
      spans.add(TextSpan(
        text: match.group(2),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ));
    } else if (match.group(3) != null) {
      spans.add(TextSpan(
        text: match.group(3),
        style: const TextStyle(decoration: TextDecoration.underline),
      ));
    }
    last = match.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last)));
  }
  return TextSpan(style: base, children: spans);
}

class _MarkdownCodeBlock extends StatelessWidget {
  const _MarkdownCodeBlock(this.code);

  final String code;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kParchmentPanelColor,
        border: Border.all(color: kInkMutedColor.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        code,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, color: kInkColor, height: 1.4),
      ),
    );
  }
}

/// A markdown pipe-table -- the separator row (`|---|---|`) is dropped and
/// the first remaining row becomes the header.
class _MarkdownTable extends StatelessWidget {
  const _MarkdownTable({required this.rows});

  final List<String> rows;

  static final _separatorCell = RegExp(r'^:?-{2,}:?$');

  List<List<String>> _cells() {
    final out = <List<String>>[];
    for (final row in rows) {
      var inner = row;
      if (inner.startsWith('|')) inner = inner.substring(1);
      if (inner.endsWith('|')) inner = inner.substring(0, inner.length - 1);
      final cells = inner.split('|').map((c) => c.trim()).toList();
      if (cells.every((c) => _separatorCell.hasMatch(c))) continue;
      out.add(cells);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final data = _cells();
    if (data.isEmpty) return const SizedBox.shrink();
    final header = data.first;
    final body = data.skip(1).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: kInkMutedColor.withValues(alpha: 0.5))),
        child: Table(
          border: TableBorder.symmetric(inside: BorderSide(color: kInkMutedColor.withValues(alpha: 0.3))),
          children: [
            TableRow(
              decoration: BoxDecoration(color: kParchmentPanelColor),
              children: [
                for (final cell in header)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Text.rich(
                      _inlineSpans(cell, manuscriptBodyStyle(fontSize: 13).copyWith(fontWeight: FontWeight.bold)),
                    ),
                  ),
              ],
            ),
            for (final row in body)
              TableRow(
                children: [
                  for (final cell in row)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: Text.rich(_inlineSpans(cell, manuscriptBodyStyle(fontSize: 13))),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
