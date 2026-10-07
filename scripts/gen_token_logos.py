#!/usr/bin/env python3
"""Turn the token logo SVGs in app/assets/token_logos into Dart paths.

Run from the repo root: python3 scripts/gen_token_logos.py

Flutter cannot draw an SVG without a package, and Argus takes no new
dependencies, so each logo is translated once, here, into the Path calls
that draw it. app/lib/ui/token_logo_paths.dart is the result; it is checked
in and is not edited by hand. The SVGs stay beside their NOTICE as the
record of where each mark came from and under what licence.

Only what these files use is understood: <circle> and <path> elements,
fill, fill-opacity and fill-rule, and every path command. A filter (the
drop shadow on one of them) is left out.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / 'app/assets/token_logos'
OUT = ROOT / 'app/lib/ui/token_logo_paths.dart'

# Which file draws which logo. 'disc' False: the mark only; the app sets it
# on a disc of its own colours.
LOGOS = {
    'erg': {'file': 'erg.svg', 'disc': False},
    'btc': {'file': 'btc.svg', 'disc': True},
    'ada': {'file': 'ada.svg', 'disc': True},
    'eth': {'file': 'eth.svg', 'disc': True},
    'bnb': {'file': 'bnb.svg', 'disc': True},
    'doge': {'file': 'doge.svg', 'disc': True},
}

NUMBER = re.compile(r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?')


class Scanner:
    """Reads path data a number, a flag or a command at a time. Arc flags
    are one character each and may run into what follows ("00.796" is 0,
    0, .796), so they are read as flags, not numbers."""

    def __init__(self, d):
        self.d = d
        self.i = 0

    def skip(self):
        while self.i < len(self.d) and self.d[self.i] in ' ,\t\n\r':
            self.i += 1

    def done(self):
        self.skip()
        return self.i >= len(self.d)

    def at_command(self):
        self.skip()
        return self.d[self.i].isalpha()

    def command(self):
        self.skip()
        c = self.d[self.i]
        self.i += 1
        return c

    def num(self):
        self.skip()
        m = NUMBER.match(self.d, self.i)
        if not m:
            raise ValueError(f'bad path data at {self.i}: {self.d[self.i:self.i + 20]!r}')
        self.i = m.end()
        return float(m.group())

    def flag(self):
        self.skip()
        c = self.d[self.i]
        if c not in '01':
            raise ValueError(f'bad arc flag at {self.i}')
        self.i += 1
        return c == '1'


def f(x):
    s = f'{x:.3f}'.rstrip('0').rstrip('.')
    return '0' if s in ('-0', '') else s


def path_calls(d):
    sc = Scanner(d)
    calls = []
    cx = cy = sx = sy = 0.0
    last_ctrl = None  # (x, y, kind) for S and T
    cmd = None
    while not sc.done():
        if sc.at_command():
            cmd = sc.command()
            if cmd in 'Zz':
                calls.append('..close()')
                cx, cy = sx, sy
                last_ctrl = None
                continue
        num = sc.num
        rel = cmd.islower()
        c = cmd.upper()
        ox, oy = (cx, cy) if rel else (0.0, 0.0)
        if c == 'M':
            cx, cy = ox + num(), oy + num()
            sx, sy = cx, cy
            calls.append(f'..moveTo({f(cx)}, {f(cy)})')
            cmd = 'l' if rel else 'L'
            last_ctrl = None
        elif c == 'L':
            cx, cy = ox + num(), oy + num()
            calls.append(f'..lineTo({f(cx)}, {f(cy)})')
            last_ctrl = None
        elif c == 'H':
            cx = (cx if rel else 0.0) + num()
            calls.append(f'..lineTo({f(cx)}, {f(cy)})')
            last_ctrl = None
        elif c == 'V':
            cy = (cy if rel else 0.0) + num()
            calls.append(f'..lineTo({f(cx)}, {f(cy)})')
            last_ctrl = None
        elif c in 'CS':
            if c == 'C':
                x1, y1 = ox + num(), oy + num()
            elif last_ctrl and last_ctrl[2] == 'c':
                x1, y1 = 2 * cx - last_ctrl[0], 2 * cy - last_ctrl[1]
            else:
                x1, y1 = cx, cy
            x2, y2 = ox + num(), oy + num()
            cx, cy = ox + num(), oy + num()
            calls.append(f'..cubicTo({f(x1)}, {f(y1)}, {f(x2)}, {f(y2)}, {f(cx)}, {f(cy)})')
            last_ctrl = (x2, y2, 'c')
        elif c in 'QT':
            if c == 'Q':
                x1, y1 = ox + num(), oy + num()
            elif last_ctrl and last_ctrl[2] == 'q':
                x1, y1 = 2 * cx - last_ctrl[0], 2 * cy - last_ctrl[1]
            else:
                x1, y1 = cx, cy
            cx, cy = ox + num(), oy + num()
            calls.append(f'..quadraticBezierTo({f(x1)}, {f(y1)}, {f(cx)}, {f(cy)})')
            last_ctrl = (x1, y1, 'q')
        elif c == 'A':
            rx, ry, rot = num(), num(), num()
            large, sweep = sc.flag(), sc.flag()
            cx, cy = ox + num(), oy + num()
            calls.append(
                f'..arcToPoint(Offset({f(cx)}, {f(cy)}), radius: Radius.elliptical({f(rx)}, {f(ry)}), '
                f'rotation: {f(rot)}, largeArc: {str(large).lower()}, clockwise: {str(sweep).lower()})'
            )
            last_ctrl = None
        else:
            raise ValueError(f'unknown command {cmd}')
    return calls


def attr(tag, name):
    m = re.search(rf'\s{name}="([^"]*)"', tag)
    return m.group(1) if m else None


def color(value, opacity):
    value = (value or '').lstrip('#')
    if len(value) == 3:
        value = ''.join(ch * 2 for ch in value)
    if value.upper() == 'FFF':
        value = 'FFFFFF'
    alpha = round(255 * opacity)
    return f'Color(0x{alpha:02X}{value.upper()})'


def layers(svg, disc):
    """(dart path expression, colour, evenOdd) for each shape, in order."""
    view = attr(svg, 'viewBox').split()
    size = float(view[2])
    # The group's fill-rule applies to the paths in it.
    group_rule = 'evenodd' in (re.search(r'<g[^>]*>', svg) or [''])[0] if re.search(r'<g[^>]*>', svg) else False
    defs = {attr(m.group(0), 'id'): m.group(0) for m in re.finditer(r'<path[^>]*/>', svg) if attr(m.group(0), 'id')}
    out = []
    disc_color = None
    inherited = None
    for m in re.finditer(r'<(circle|path|use|g)\b[^>]*>', svg):
        tag = m.group(0)
        kind = m.group(1)
        if kind == 'g':
            inherited = attr(tag, 'fill') or inherited
            continue
        if kind == 'circle':
            disc_color = color(attr(tag, 'fill'), 1)
            continue
        if kind == 'use':
            if attr(tag, 'filter'):
                continue  # the drop shadow
            ref = (attr(tag, 'xlink:href') or '').lstrip('#')
            tag, fill = defs[ref], attr(tag, 'fill')
        elif attr(tag, 'id'):
            continue  # a definition, drawn where it is used
        else:
            fill = attr(tag, 'fill') or inherited
        opacity = float(attr(tag, 'fill-opacity') or 1)
        even = group_rule or attr(tag, 'fill-rule') == 'evenodd'
        if attr(tag, 'fill-rule') == 'nonzero':
            even = False
        if fill in (None, 'none') or not re.fullmatch(r'#?[0-9A-Fa-f]{3,6}', fill):
            fill = '000000'
        out.append((path_calls(attr(tag, 'd')), color(fill, opacity), even))
    if disc and disc_color is None:
        raise ValueError('expected a disc')
    return size, disc_color, out


def main():
    lines = [
        '// GENERATED by scripts/gen_token_logos.py from app/assets/token_logos.',
        '// Do not edit by hand; see NOTICE.md there for each mark\'s source.',
        '// ignore_for_file: prefer_const_constructors',
        '',
        "import 'package:flutter/painting.dart';",
        '',
        '/// One filled shape of a logo, in the units of its [TokenLogoArt.size].',
        'class TokenLogoLayer {',
        '  const TokenLogoLayer(this.path, this.color);',
        '  final Path Function() path;',
        '',
        '  /// Null: drawn in the colour the app gives the mark.',
        '  final Color? color;',
        '}',
        '',
        '/// A logo: its square of [size] units, its own disc if it has one, and',
        '/// its shapes.',
        'class TokenLogoArt {',
        '  const TokenLogoArt({required this.size, required this.disc, required this.layers});',
        '  final double size;',
        '  final Color? disc;',
        '  final List<TokenLogoLayer> layers;',
        '}',
        '',
    ]
    entries = []
    for name, spec in LOGOS.items():
        svg = (SRC / spec['file']).read_text()
        size, disc, shapes = layers(svg, spec['disc'])
        layer_exprs = []
        for n, (calls, col, even) in enumerate(shapes):
            fn = f'_{name}{n}'
            lines.append(f'Path {fn}() => Path()')
            if even:
                lines.append('  ..fillType = PathFillType.evenOdd')
            lines.extend(f'  {c}' for c in calls)
            lines[-1] += ';'
            lines.append('')
            colour = col if spec['disc'] else 'null'
            layer_exprs.append(f'TokenLogoLayer({fn}, {colour})')
        disc_expr = disc if spec['disc'] else 'null'
        entries.append(
            f"  '{name}': TokenLogoArt(size: {f(size)}, disc: {disc_expr}, layers: [\n"
            + ''.join(f'    {e},\n' for e in layer_exprs)
            + '  ]),'
        )
    lines.append('/// Every bundled logo, by the name [tokenLogoName] gives a token.')
    lines.append('final tokenLogoArt = <String, TokenLogoArt>{')
    lines.extend(entries)
    lines.append('};')
    OUT.write_text('\n'.join(lines) + '\n')
    print(f'wrote {OUT.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
