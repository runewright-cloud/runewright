// SPDX-License-Identifier: GPL-3.0-or-later
//
// lan_discovery.dart — mDNS/NSD peer discovery, the second half of the
// design doc's "AOSP-universal" Adapter 1 (sockets for the wire,
// established in lan_socket_transport.dart; this file is discovery).
//
// Uses `nsd` (native NSD/Bonjour bindings: Android NsdManager, iOS/macOS
// Bonjour, Windows) rather than a pure-Dart mDNS client, because it
// supports *registering* (advertising) a service, not just resolving one --
// `multicast_dns` is query-only and would need a hand-rolled mDNS responder
// to advertise, which `nsd` gives for free via the platform stack.
//
// Real-network caveat (M4 plan, "characterize, don't assume a code bug"):
// AP/client isolation (common on guest Wi-Fi) blocks multicast entirely;
// some networks deprioritize multicast traffic; discovery timing varies.
// This file has no automated test for actual discovery -- there is no
// substitute for testing on a controlled network with two real devices,
// which is the two-device validation gate, not something this dev
// environment can simulate.
//
// M4 findings (docs/M4_findings.md M4.6): the first real hardware run
// showed a peer's resolved `addresses` (and this device's own interface
// list) can include a Wi-Fi Direct interface alongside the real Wi-Fi one.
// Wi-Fi Direct addresses are reliably in 192.168.49.0/24 (Android) and are
// never reachable from a peer on the same real Wi-Fi AP. Naively taking
// the first resolved address risks dialing an address that looks valid but
// isn't on the shared network. [selectBestAddress]/[preferredLocalAddress]
// below filter for this. **This logic is unit-tested against representative
// interface lists (test/protocol/lan_discovery_test.dart) but not yet
// confirmed end-to-end with real mDNS discovery between two devices** --
// the M4 hardware run used manual IP entry, not automatic discovery. That
// confirmation is a two-device follow-up, not something this dev machine
// can perform (no second device, and `nsd` has no Linux desktop backend at
// all -- see M4.4).

import 'dart:io';

import 'package:nsd/nsd.dart';

import 'lan_socket_transport.dart';

/// Service type per RFC 6763 (`_<name>._tcp`); validated by `nsd` itself
/// (see `disableServiceTypeValidation` in the nsd package if this ever
/// needs to change).
const kRunewrightServiceType = '_runewright._tcp';

/// Distinct service type for Commune/Trade pairing (docs/COMMUNE_TRADE_PLAN.md
/// §5.4) -- kept separate from [kRunewrightServiceType] so a device browsing
/// for a duel never lists a trade-only peer and vice versa.
///
/// Uses the `rw-` short prefix rather than `runewright-` because `nsd`
/// enforces RFC 6763's 15-character cap on the service label (the part
/// between the leading `_` and `._tcp`); `runewright-trade` is 16 characters
/// and fails `nsd`'s validation with an `illegalArgument` NsdError at
/// register/discover time (`"Service type must be in format _<Service>._<Proto>"`).
const kRunewrightTradeServiceType = '_rw-trade._tcp';

/// Distinct service type for Commune/Sync Art pairing
/// (lib/trade/sync_art_session.dart) -- kept separate from
/// [kRunewrightServiceType] and [kRunewrightTradeServiceType] so a device
/// browsing for a duel or a trade never lists a sync-art-only peer, and
/// vice versa.
///
/// Uses the `rw-` short prefix for the same 15-character-label reason as
/// [kRunewrightTradeServiceType] above -- `runewright-syncart` is 18
/// characters and would fail the same validation.
const kRunewrightSyncArtServiceType = '_rw-syncart._tcp';

/// Distinct service type for Master/Apprentice pairing
/// (docs/MASTER_APPRENTICE_PLAN.md §5.3) — kept separate from the three
/// above so a device browsing for a duel, trade, or sync-art peer never
/// lists an apprenticeship-only peer, and vice versa.
///
/// `rw-appr` is 7 characters, well inside the same 15-character label cap
/// that made `runewright-trade` fail validation.
const kRunewrightApprenticeServiceType = '_rw-appr._tcp';

/// Advertises this device as a duel host at [port] (the port a prior
/// `LanSocketTransport.bind()` returned). Returns the active
/// `Registration` -- pass it to [stopAdvertisingDuelHost] when the host
/// stops listening (e.g. after a peer connects, or the player cancels).
///
/// [displayName] is shown to discovering peers; the platform may suffix it
/// ("Name (2)") on a local name collision -- harmless, just cosmetic.
///
/// [serviceType] defaults to the duel service type; pass
/// [kRunewrightTradeServiceType] to advertise a trade session instead.
Future<Registration> advertiseDuelHost({
  required int port,
  String displayName = 'Runewright Duel',
  String serviceType = kRunewrightServiceType,
}) {
  return register(Service(name: displayName, type: serviceType, port: port));
}

Future<void> stopAdvertisingDuelHost(Registration registration) => unregister(registration);

/// Starts discovering nearby duel hosts. The returned `Discovery` exposes
/// `.services` (the current list, kept live) and `.addServiceListener` (a
/// found/lost callback) -- see the `nsd` package docs. Call
/// [stopDiscoveringDuelHosts] when done; per `nsd`'s own docs, discovery is
/// an expensive platform operation and must be explicitly stopped.
///
/// [serviceType] defaults to the duel service type; pass
/// [kRunewrightTradeServiceType] to discover trade sessions instead.
Future<Discovery> discoverDuelHosts({String serviceType = kRunewrightServiceType}) =>
    startDiscovery(serviceType, autoResolve: true);

Future<void> stopDiscoveringDuelHosts(Discovery discovery) => stopDiscovery(discovery);

/// Connects to a discovered, resolved [service] (i.e. one with `host`/
/// `addresses` and `port` populated -- guaranteed when discovered via
/// [discoverDuelHosts]'s `autoResolve: true`). Picks the best of possibly
/// several resolved addresses via [selectBestAddress] rather than blindly
/// dialing the first one.
Future<LanSocketTransport> connectToDiscoveredService(Service service) async {
  final port = service.port;
  final addresses = service.addresses;
  if (port == null || addresses == null || addresses.isEmpty) {
    throw ArgumentError('service is not resolved (missing host/port): $service');
  }
  final address = await selectBestAddress(addresses);
  if (address == null) {
    throw ArgumentError('service has no usable address: $service');
  }
  return LanSocketTransport.connectTo(address.address, port);
}

// ── Real-Wi-Fi address selection ────────────────────────────────────────

/// Android's Wi-Fi Direct group subnet -- reliably 192.168.49.0/24,
/// distinct from a real Wi-Fi AP's DHCP-assigned subnet. Addresses in this
/// range are reachable only within a P2P group, never on the shared LAN
/// two duel peers are actually on.
bool _isWifiDirectAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  return bytes.length == 4 && bytes[0] == 192 && bytes[1] == 168 && bytes[2] == 49;
}

/// Wi-Fi Direct / virtual interface name patterns. OEM naming varies
/// (`p2p0`, `p2p-wlan0-0`, etc.), so this is a substring match on `p2p`
/// rather than an exact one.
bool _isWifiDirectInterfaceName(String name) => name.toLowerCase().contains('p2p');

/// The first three octets of an IPv4 address, as a /24-subnet key for
/// "are these two addresses on the same local network" comparisons. Not a
/// real subnet-mask computation (this app has no way to learn the actual
/// mask), but /24 is the overwhelmingly common case for home/venue Wi-Fi
/// and is exactly what distinguishes a real-AP address from a Wi-Fi Direct
/// one in practice.
String? _subnet24(InternetAddress address) {
  final bytes = address.rawAddress;
  if (bytes.length != 4) return null;
  return '${bytes[0]}.${bytes[1]}.${bytes[2]}';
}

/// Filters a raw interface list down to "plausibly real Wi-Fi" candidate
/// addresses: excludes loopback, Wi-Fi-Direct-named interfaces, and
/// addresses in Android's Wi-Fi Direct subnet. Pure and exposed for
/// testing; [_candidateLocalAddresses] is the real
/// (`NetworkInterface.list()`-backed) entry point.
List<InternetAddress> filterRealWifiAddresses(List<NetworkInterface> interfaces) {
  final out = <InternetAddress>[];
  for (final iface in interfaces) {
    if (_isWifiDirectInterfaceName(iface.name)) continue;
    for (final addr in iface.addresses) {
      if (addr.isLoopback || _isWifiDirectAddress(addr)) continue;
      out.add(addr);
    }
  }
  return out;
}

Future<List<InternetAddress>> _candidateLocalAddresses() async {
  final interfaces = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
  return filterRealWifiAddresses(interfaces);
}

/// Best-effort guess at this device's real Wi-Fi address -- for display
/// (the connect screen's "Listening on ..." hint) and as the basis for
/// same-subnet comparison in [selectBestAddress]. Returns null if no
/// non-Wi-Fi-Direct IPv4 address was found (e.g. no Wi-Fi connection).
Future<InternetAddress?> preferredLocalAddress() async {
  final candidates = await _candidateLocalAddresses();
  return candidates.isEmpty ? null : candidates.first;
}

/// Pure selection logic, exposed for testing: given a peer's resolved
/// address list and this device's own candidate local addresses, picks the
/// best address to dial. See [selectBestAddress] for the real entry point.
///
/// Preference order: (1) an address sharing this device's own real-Wi-Fi
/// /24 subnet -- both duel peers on the same Wi-Fi AP share a subnet,
/// their Wi-Fi Direct addresses never do; (2) any address that at least
/// isn't in the known Wi-Fi Direct subnet; (3) whatever's first, rather
/// than failing outright when every candidate looks suspect.
InternetAddress? selectBestAddressFrom(List<InternetAddress> peerAddresses, List<InternetAddress> myAddresses) {
  if (peerAddresses.isEmpty) return null;

  final mySubnets = myAddresses.map(_subnet24).whereType<String>().toSet();
  if (mySubnets.isNotEmpty) {
    for (final addr in peerAddresses) {
      if (mySubnets.contains(_subnet24(addr))) return addr;
    }
  }

  final nonWifiDirect = peerAddresses.where((a) => !_isWifiDirectAddress(a)).toList();
  if (nonWifiDirect.isNotEmpty) return nonWifiDirect.first;

  return peerAddresses.first;
}

/// Picks the best address to dial from a discovered, resolved service's
/// address list, using this device's real local interfaces for the
/// same-subnet comparison. See [selectBestAddressFrom] for the pure logic.
Future<InternetAddress?> selectBestAddress(List<InternetAddress> peerAddresses) async {
  final myAddresses = await _candidateLocalAddresses();
  return selectBestAddressFrom(peerAddresses, myAddresses);
}
