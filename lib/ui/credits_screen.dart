// SPDX-License-Identifier: GPL-3.0-or-later
//
// credits_screen.dart — CreditsScreen: Runewright's own licensing statement
// plus every third-party work bundled into the app (CREDITS.md, kept in
// sync by hand -- see that file's header). Static, offline, no network,
// consistent with the project's no-phone-home stance (CLAUDE.md hard
// invariant 7). Reachable from Settings and from the art pack picker's
// attribution footer (spell_art_pack_screen.dart) -- the latter is the
// "resource that includes the required information" CC BY-SA 4.0 §3(a)(2)
// contemplates for the art pack specifically.

import 'package:flutter/material.dart';

import '../spells/spell_art_pack.dart';
import 'manuscript_theme.dart';

class CreditsScreen extends StatelessWidget {
  const CreditsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kParchmentColor,
      appBar: AppBar(
        backgroundColor: kParchmentColor,
        foregroundColor: kInkColor,
        elevation: 0,
        title: Text('Credits & Licences', style: manuscriptHeaderStyle(fontSize: 20)),
      ),
      // A short, fixed set of children -- SingleChildScrollView+Column (not
      // ListView) so every section lays out eagerly rather than only what's
      // near the viewport, which matters both for widget-test finders and
      // for a licence-attribution screen that must never silently omit
      // content depending on scroll position.
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Runewright', style: manuscriptHeaderStyle(fontSize: 22)),
            const SizedBox(height: 8),
            Text(
              'Code is licensed GPL-3.0-or-later. Creative assets (original art, '
              'sigils, card layouts) are licensed CC BY-SA 4.0. Full texts ship '
              'with the source as LICENSE and LICENSE-ASSETS.',
              style: manuscriptBodyStyle(),
            ),
            const SizedBox(height: 28),
            const _CreditSection(
              title: 'Painterly Spell Icons',
              body: [
                _CreditRow(label: 'Author', value: 'J. W. Bjerk (eleazzaar)'),
                _CreditRow(label: 'Source', value: 'opengameart.org'),
              ],
            ),
            _PackLicenceDetail(licence: kPainterlyLicence),
            const SizedBox(height: 28),
            // CC BY 3.0 *requires* attribution — unlike the CC0 battle-scenery
            // terrain, which is credited nowhere because it needs no credit.
            // If the wizard sprites ship, this section ships with them; see
            // assets/art_pack/avatars/ATTRIBUTION.md.
            const _CreditSection(
              title: 'Wizard Character Sprites',
              body: [
                _CreditRow(
                  label: 'Author',
                  value: 'Svetlana Kushnariova (lana-chan@yandex.ru)',
                ),
                _CreditRow(
                  label: 'Work',
                  value: '24x32 characters with faces (big pack)',
                ),
                _CreditRow(label: 'Source', value: 'opengameart.org'),
                _CreditRow(label: 'Licence', value: 'CC BY 3.0'),
                _CreditRow(
                  label: 'Modifications',
                  value:
                      'Walk frames cropped from the source charsets, the '
                      'colour key replaced with an alpha channel, and edge '
                      'colour bled outward; assembled into a single atlas.',
                ),
              ],
            ),
            const SizedBox(height: 28),
            const _CreditSection(
              title: 'Piper Text-to-Speech',
              body: [
                _CreditRow(label: 'Voice model', value: 'it_IT-paola-medium'),
                _CreditRow(label: 'Author', value: 'paolapersico1'),
                _CreditRow(label: 'Licence', value: 'MIT'),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Used offline, at build time only, to render the Practice Mode '
                'trainer-clip audio. Piper and the voice model are not themselves '
                'bundled into the app -- only their rendered output is.',
                style: manuscriptCaptionStyle(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreditSection extends StatelessWidget {
  const _CreditSection({required this.title, required this.body});

  final String title;
  final List<Widget> body;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: manuscriptHeaderStyle(fontSize: 18)),
        const SizedBox(height: 8),
        ...body,
      ],
    );
  }
}

class _CreditRow extends StatelessWidget {
  const _CreditRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      // Text.rich (not a bare RichText) so widget-test finders like
      // find.textContaining still match this against its plain-text content.
      child: Text.rich(
        TextSpan(
          style: manuscriptBodyStyle(fontSize: 15),
          children: [
            TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}

/// The art pack's licence, attribution, and modification statement, read
/// entirely from [kPainterlyLicence] -- never hardcoded, so a future licence
/// change (docs/SPELL_ART_PACK_PLAN.md D-1) only requires regenerating
/// lib/spells/spell_art_pack.dart, not editing this screen.
class _PackLicenceDetail extends StatelessWidget {
  const _PackLicenceDetail({required this.licence});

  final SpellArtPackLicence licence;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CreditRow(label: 'Licence', value: licence.licence),
          _CreditRow(label: 'Attribution', value: licence.attribution),
          _CreditRow(label: 'Modifications', value: licence.modifications),
          const SizedBox(height: 6),
          Text('Sources:', style: manuscriptCaptionStyle()),
          for (final url in licence.sourceUrls)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Text(url, style: manuscriptCaptionStyle()),
            ),
        ],
      ),
    );
  }
}
