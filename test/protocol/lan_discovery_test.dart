// SPDX-License-Identifier: GPL-3.0-or-later
//
// lan_discovery_test.dart — unit tests for the real-Wi-Fi address
// selection heuristic (lan_discovery.dart), against representative
// interface lists modeled on what the M4 hardware run actually saw: a real
// Wi-Fi interface (wlan0, 192.168.x.x) alongside a Wi-Fi Direct interface
// (p2p0, 192.168.49.x).
//
// What this does NOT cover: whether automatic mDNS discovery actually
// connects two real devices over real Wi-Fi -- that needs two physical
// devices and is a follow-up (see docs/M4_findings.md M4.6/M4.7). This
// file only confirms the selection *logic* picks the right address when
// handed realistic candidate lists.

import 'dart:io';

import 'package:test/test.dart';
import 'package:rune_duel/protocol/lan_discovery.dart';

InternetAddress _addr(String ip) => InternetAddress(ip);

class _FakeInterface implements NetworkInterface {
  _FakeInterface(this.name, this.addresses);

  @override
  final String name;

  @override
  final List<InternetAddress> addresses;

  @override
  int get index => 0;
}

void main() {
  group('filterRealWifiAddresses', () {
    test('keeps a real Wi-Fi interface, excludes a p2p-named one', () {
      final interfaces = [
        _FakeInterface('wlan0', [_addr('192.168.1.160')]),
        _FakeInterface('p2p0', [_addr('192.168.49.4')]),
      ];
      expect(filterRealWifiAddresses(interfaces), [_addr('192.168.1.160')]);
    });

    test('excludes OEM p2p interface name variants (substring match)', () {
      final interfaces = [
        _FakeInterface('wlan0', [_addr('192.168.1.160')]),
        _FakeInterface('p2p-wlan0-0', [_addr('192.168.49.7')]),
      ];
      expect(filterRealWifiAddresses(interfaces), [_addr('192.168.1.160')]);
    });

    test('excludes the Wi-Fi Direct subnet even on a non-p2p-named interface '
        '(defense in depth against unusual OEM naming)', () {
      final interfaces = [
        _FakeInterface('wlan0', [_addr('192.168.1.160')]),
        _FakeInterface('wlan1', [_addr('192.168.49.9')]),
      ];
      expect(filterRealWifiAddresses(interfaces), [_addr('192.168.1.160')]);
    });

    test('excludes loopback addresses', () {
      final interfaces = [
        _FakeInterface('lo', [InternetAddress.loopbackIPv4]),
        _FakeInterface('wlan0', [_addr('192.168.1.160')]),
      ];
      expect(filterRealWifiAddresses(interfaces), [_addr('192.168.1.160')]);
    });

    test('returns empty when only Wi-Fi Direct/loopback interfaces exist', () {
      final interfaces = [
        _FakeInterface('lo', [InternetAddress.loopbackIPv4]),
        _FakeInterface('p2p0', [_addr('192.168.49.4')]),
      ];
      expect(filterRealWifiAddresses(interfaces), isEmpty);
    });
  });

  group('selectBestAddressFrom', () {
    test('prefers the peer address sharing this device\'s real Wi-Fi subnet '
        'over the peer\'s own Wi-Fi Direct address', () {
      final peerAddresses = [_addr('192.168.49.4'), _addr('192.168.1.229')];
      final myAddresses = [_addr('192.168.1.160')]; // same /24 as 192.168.1.229
      expect(selectBestAddressFrom(peerAddresses, myAddresses), _addr('192.168.1.229'));
    });

    test('order of the peer\'s resolved addresses does not matter -- '
        'same-subnet match wins regardless of position', () {
      final peerAddresses = [_addr('192.168.1.229'), _addr('192.168.49.4')];
      final myAddresses = [_addr('192.168.1.160')];
      expect(selectBestAddressFrom(peerAddresses, myAddresses), _addr('192.168.1.229'));
    });

    test('falls back to excluding Wi-Fi Direct addresses when no same-subnet '
        'match exists (e.g. this device\'s own subnet is unknown)', () {
      final peerAddresses = [_addr('192.168.49.4'), _addr('10.0.0.5')];
      final myAddresses = <InternetAddress>[];
      expect(selectBestAddressFrom(peerAddresses, myAddresses), _addr('10.0.0.5'));
    });

    test('falls back to the first address rather than failing when every '
        'candidate looks like Wi-Fi Direct', () {
      final peerAddresses = [_addr('192.168.49.4'), _addr('192.168.49.5')];
      final myAddresses = <InternetAddress>[];
      expect(selectBestAddressFrom(peerAddresses, myAddresses), _addr('192.168.49.4'));
    });

    test('returns null for an empty peer address list', () {
      expect(selectBestAddressFrom([], [_addr('192.168.1.160')]), isNull);
    });
  });
}
