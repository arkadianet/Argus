import 'package:argus_wallet/features.dart';
import 'package:argus_wallet/ui/swap_hub_screen.dart';
import 'package:argus_wallet/ui/widgets/discover_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dexy is paused: the switch is off and the note names the reason', () {
    expect(dexyEnabled, isFalse);
    expect(dexyPausedNote, contains('paused'));
  });

  test('the swap hub offers only the venues that are on', () {
    expect(enabledVenues(dexy: false), [SwapVenue.spectrum, SwapVenue.ageusd]);
    expect(enabledVenues(dexy: true), SwapVenue.values);
    expect(coerceVenue(SwapVenue.dexy, dexy: false), SwapVenue.spectrum);
    expect(coerceVenue(SwapVenue.ageusd, dexy: false), SwapVenue.ageusd);
    expect(coerceVenue(SwapVenue.dexy, dexy: true), SwapVenue.dexy);
  });

  test('discover lists a paused protocol nowhere', () {
    expect(discoverAvailable(DiscoverFeature.dexy, dexy: false), isFalse);
    expect(discoverAvailable(DiscoverFeature.dexy, dexy: true), isTrue);
    expect(discoverAvailable(DiscoverFeature.ageusd, dexy: false), isTrue);
  });
}
