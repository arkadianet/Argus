import 'package:flutter/material.dart';

import 'argus_theme.dart';

/// Brand moss brightened for text on dark grounds: about 5.5:1 on the
/// Watchful surface, where [moss] manages about 3.4:1 and fails WCAG AA
/// for body-size text. Light palettes keep [moss], which passes there.
const mossBright = Color(0xFF58A074);

/// Palette-aware moss for *text* (incoming amounts, a rise in price), as
/// [rustFor] is for rust. Status dots and borders can keep [moss].
Color mossFor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? mossBright : moss;
