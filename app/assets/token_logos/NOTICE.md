# Token logos

These marks are drawn into the app from `app/lib/ui/token_logo_paths.dart`,
which `scripts/gen_token_logos.py` generates from the SVGs in this folder.
The app never fetches a logo. A token's icon URL is the issuer's word and a
request to it would tell a server who holds the token.

A mark is bundled only when its licence allows it. Every token without one
gets a monogram: a verified token gets its registry ticker's initial in the
accent, and any other token gets the first character of its id on a disc
coloured from that id.

| File | Mark | Used for | Source | Licence |
| --- | --- | --- | --- | --- |
| `erg.svg` | Ergo | ERG | `src/main/resources/panel/favicon.svg` in [ergoplatform/ergo](https://github.com/ergoplatform/ergo) | CC0-1.0 (the repository's licence) |
| `btc.svg` | Bitcoin | rsBTC | `svg/color/btc.svg` in [spothq/cryptocurrency-icons](https://github.com/spothq/cryptocurrency-icons) | CC0-1.0 |
| `ada.svg` | Cardano | rsADA | `svg/color/ada.svg`, same repository | CC0-1.0 |
| `eth.svg` | Ethereum | rsETH | `svg/color/eth.svg`, same repository | CC0-1.0 |
| `bnb.svg` | BNB | rsBNB | `svg/color/bnb.svg`, same repository | CC0-1.0 |
| `doge.svg` | Dogecoin | rsDOGE | `svg/color/doge.svg`, same repository | CC0-1.0 |

Notes on how the marks are used:

- **ERG:** only the shape of the Ergo mark is used. It is drawn in the
  palette's own colours, on the palette's accent disc, like the rest of
  the app.
- **Rosen-wrapped tokens:** each shows the mark of the chain it wraps.
  This is how Ergo wallets present them, and the row's ticker (rsADA) and
  name still say it is the wrapped token.
- **The Cardano drop shadow** (an SVG filter) is left out.

CC0 waives copyright in these drawings; it does not grant trademark rights.
The marks are used only to identify the asset they name.

The following have no licence that allows bundling, so they get monograms:

- SigUSD, SigRSV, DexyGold, USE, RSN, SPF, COMET, ErgoPad, Paideia and
  the other curated tokens.
- Spectrum's token-logos repository, which carries no licence.
