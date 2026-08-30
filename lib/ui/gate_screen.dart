// SPDX-License-Identifier: GPL-3.0-or-later
//
// gate_screen.dart — M4 two-device validation gate: a throwaway diagnostic
// harness, same role as the M2/M3 spike_screen.dart. Exercises, for the
// first time on real hardware: mDNS discovery (lan_discovery.dart), the
// LAN socket transport (lan_socket_transport.dart), and the full match
// protocol (proof exchange -> verify_ultra_honk -> owner_pubkey recompute
// -> ownership challenge -> signature verify) end to end between two
// physical devices.
//
// NOT the real duel UI -- Battlefield is out of scope per CLAUDE.md.
// Minimal and ugly on purpose; do not extend this toward game UI.
//
// This screen is wiring + status display only: connect-path UI (mDNS
// listen/advertise, mDNS discover, manual IP), and rendering GateRunner's
// step callbacks. The actual exchange orchestration lives in
// gate_runner.dart, which has no Flutter dependency and is independently
// tested (test/ui/gate_runner_test.dart) over real localhost sockets with
// real on-device proving -- this file is the one part of M4 that genuinely
// cannot be verified without two physical devices.

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:nsd/nsd.dart' show Discovery, Registration, Service, ServiceStatus;

import '../ffi/srs_cache.dart';
import '../protocol/lan_discovery.dart' as discovery;
import '../protocol/lan_socket_transport.dart';
import '../protocol/match_session.dart';
import '../protocol/transport.dart';
import 'gate_runner.dart';
import 'safe_layout.dart';

class GateScreen extends StatefulWidget {
  const GateScreen({super.key});

  @override
  State<GateScreen> createState() => _GateScreenState();
}

class _GateScreenState extends State<GateScreen> {
  GateRole _role = GateRole.verifierChallenger;
  String _connectPath = 'none';
  bool _busy = false;
  String _connectStatus = 'Not connected.';

  LanListener? _listener;
  Registration? _registration;
  Discovery? _discoveryHandle;
  final List<Service> _discoveredServices = [];

  Transport? _transport;
  MatchSession? _matchSession;

  final _manualIpController = TextEditingController(text: ':');
  final _steps = {for (final key in kGateStepOrder) key: GateStep(key)};

  @override
  void dispose() {
    _manualIpController.dispose();
    _teardown();
    super.dispose();
  }

  void _teardown() {
    _listener?.close();
    _listener = null;
    if (_registration != null) {
      discovery.stopAdvertisingDuelHost(_registration!);
      _registration = null;
    }
    if (_discoveryHandle != null) {
      discovery.stopDiscoveringDuelHosts(_discoveryHandle!);
      _discoveryHandle = null;
    }
    _matchSession?.close();
    _matchSession = null;
    _transport?.disconnect();
    _transport = null;
  }

  // ── Step + log plumbing ──────────────────────────────────────────────────

  void _resetSteps() {
    setState(() {
      for (final step in _steps.values) {
        step.state = GateStepState.pending;
        step.detail = null;
      }
    });
  }

  void _onStep(String key, GateStepState state, String? detail) {
    setState(() {
      _steps[key]!.state = state;
      _steps[key]!.detail = detail;
    });
  }

  void _onLog(String step, Object value, String? detail) {
    final line = 'RUNEWRIGHT_GATE step=$step value=$value role=${_role.name} connect_path=$_connectPath'
        '${detail != null ? ' detail="$detail"' : ''}';
    developer.log(line, name: 'runewright.gate', level: 800);
    if (kDebugMode) debugPrint('[gate] $line');
  }

  Future<Uint8List> _loadVk() async {
    final data = await rootBundle.load(kGateVkAsset);
    return data.buffer.asUint8List();
  }

  // ── Connect: listen + advertise (mDNS host path, also valid for manual IP) ──

  Future<void> _listenAndAdvertise() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      // Not 'mdns': the listening side cannot tell whether the connecting
      // peer found it via mDNS discovery or typed the address manually --
      // both produce an identical incoming connection. 'mdns' here would
      // overclaim a path that was never actually observed (see
      // docs/M4_findings.md M4.6's connect_path finding).
      _connectPath = 'listening';
      _connectStatus = 'Binding...';
    });
    _resetSteps();
    _onStep('connect', GateStepState.running, 'binding...');
    try {
      final listener = await LanSocketTransport.bind();
      _listener = listener;
      final ip = await _localIpHint();
      setState(() => _connectStatus = 'Listening on ${ip ?? "?"}:${listener.port}');
      _onLog('discovered', 'n/a', 'host: listening on ${ip ?? "?"}:${listener.port}');

      try {
        _registration = await discovery.advertiseDuelHost(port: listener.port);
        _onLog('discovered', true, 'advertised as ${_registration!.service.name}');
      } catch (e) {
        // Soft failure, by design: mDNS advertise failing must not block
        // the manual-IP path, which uses the same listening socket. This
        // is exactly the layer-isolation the gate is for.
        _onLog('discovered', false, 'mdns advertise failed (manual IP still works): $e');
      }

      _onStep('connect', GateStepState.running, 'waiting for peer to connect to ${ip ?? "?"}:${listener.port}...');
      final transport = await listener.acceptOnce();
      _transport = transport;
      _onStep('connect', GateStepState.pass, 'peer connected');
      _onLog('connected', true, 'listening (mdns-advertised + manual-IP-reachable)');

      final session = await MatchSession.accept(transport);
      _matchSession = session;
      _onStep('handshake', GateStepState.pass, 'match_id=${_hexPreview(session.matchId)}');

      await _runExchange(session);
    } catch (e) {
      _onStep('connect', GateStepState.fail, '$e');
      _onLog('connected', false, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Connect: discover (mDNS join path) ───────────────────────────────────

  Future<void> _toggleDiscovery() async {
    if (_discoveryHandle != null) {
      await discovery.stopDiscoveringDuelHosts(_discoveryHandle!);
      setState(() {
        _discoveryHandle = null;
        _discoveredServices.clear();
      });
      return;
    }
    setState(() => _connectPath = 'mdns');
    try {
      final d = await discovery.discoverDuelHosts();
      d.addServiceListener((service, status) {
        if (!mounted) return;
        setState(() {
          if (status == ServiceStatus.found) {
            _discoveredServices.add(service);
          } else {
            _discoveredServices.removeWhere((s) => s.name == service.name);
          }
        });
      });
      setState(() => _discoveryHandle = d);
    } catch (e) {
      _onLog('discovered', false, 'discovery start failed: $e');
      setState(() => _connectStatus = 'Discovery failed to start: $e');
    }
  }

  Future<void> _connectToDiscovered(Service service) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _connectPath = 'mdns';
      _connectStatus = 'Connecting to ${service.name}...';
    });
    _resetSteps();
    _onStep('connect', GateStepState.running, 'connecting to ${service.name}...');
    try {
      final transport = await discovery.connectToDiscoveredService(service);
      _transport = transport;
      final addr = service.addresses?.isNotEmpty == true ? service.addresses!.first.address : '?';
      _onStep('connect', GateStepState.pass, 'connected to $addr:${service.port}');
      _onLog('discovered', true, '${service.name} @ $addr:${service.port}');
      _onLog('connected', true, 'mdns join');

      final session = await MatchSession.initiate(transport);
      _matchSession = session;
      _onStep('handshake', GateStepState.pass, 'match_id=${_hexPreview(session.matchId)}');

      await _runExchange(session);
    } catch (e) {
      _onStep('connect', GateStepState.fail, '$e');
      _onLog('connected', false, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Connect: manual IP (bypasses discovery entirely) ─────────────────────

  Future<void> _connectManual() async {
    if (_busy) return;
    final raw = _manualIpController.text.trim();
    final colonIdx = raw.lastIndexOf(':');
    if (colonIdx <= 0) {
      setState(() => _connectStatus = 'Enter host:port, e.g. 192.168.1.23:54321');
      return;
    }
    final host = raw.substring(0, colonIdx);
    final port = int.tryParse(raw.substring(colonIdx + 1));
    if (port == null) {
      setState(() => _connectStatus = 'Bad port in "$raw"');
      return;
    }

    setState(() {
      _busy = true;
      _connectPath = 'manual_ip';
      _connectStatus = 'Connecting to $host:$port...';
    });
    _resetSteps();
    _onStep('connect', GateStepState.running, 'connecting to $host:$port...');
    try {
      final transport = await LanSocketTransport.connectTo(host, port);
      _transport = transport;
      _onStep('connect', GateStepState.pass, 'connected to $host:$port');
      _onLog('discovered', 'n/a', 'manual entry $host:$port');
      _onLog('connected', true, 'manual_ip');

      final session = await MatchSession.initiate(transport);
      _matchSession = session;
      _onStep('handshake', GateStepState.pass, 'match_id=${_hexPreview(session.matchId)}');

      await _runExchange(session);
    } catch (e) {
      _onStep('connect', GateStepState.fail, '$e');
      _onLog('connected', false, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Exchange ──────────────────────────────────────────────────────────────

  Future<void> _runExchange(MatchSession session) async {
    final runner = GateRunner(onStep: _onStep, onLog: _onLog, loadVk: _loadVk);
    final circuitJson = await rootBundle.loadString(kGateCircuitAsset);
    final cachePath = await srsCachePath();
    if (_role == GateRole.proverSigner) {
      await runner.runProverFlow(session: session, circuitJson: circuitJson, srsCachePath: cachePath);
    } else {
      await runner.runVerifierFlow(session: session, circuitJson: circuitJson, srsCachePath: cachePath);
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('M4 — Two-Device Gate'),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      body: SafeScreenBody(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _roleToggle(),
              const SizedBox(height: 12),
              _connectControls(),
              const SizedBox(height: 12),
              Text(_connectStatus, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 16),
              const Divider(color: Colors.white24),
              const SizedBox(height: 8),
              ..._steps.values.map(_stepTile),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roleToggle() {
    return Row(
      children: [
        Expanded(
          child: _roleButton('Prover / Signer', GateRole.proverSigner),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _roleButton('Verifier / Challenger', GateRole.verifierChallenger),
        ),
      ],
    );
  }

  Widget _roleButton(String label, GateRole role) {
    final selected = _role == role;
    return ElevatedButton(
      onPressed: _busy ? null : () => setState(() => _role = role),
      style: ElevatedButton.styleFrom(
        backgroundColor: selected ? Colors.indigo[700] : Colors.grey[900],
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _connectControls() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey[800]!),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _listenAndAdvertise,
                  child: const Text('Listen + Advertise', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _toggleDiscovery,
                  child: Text(
                    _discoveryHandle == null ? 'Discover' : 'Stop discovery',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
          if (_discoveredServices.isNotEmpty) ...[
            const SizedBox(height: 8),
            ..._discoveredServices.map((s) {
              final addr = s.addresses?.isNotEmpty == true ? s.addresses!.first.address : '?';
              return ListTile(
                dense: true,
                tileColor: Colors.grey[900],
                title: Text(s.name ?? '(unnamed)', style: const TextStyle(color: Colors.white, fontSize: 12)),
                subtitle: Text('$addr:${s.port}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                onTap: _busy ? null : () => _connectToDiscovered(s),
              );
            }),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _manualIpController,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: const InputDecoration(
                    hintText: 'host:port',
                    hintStyle: TextStyle(color: Colors.white38),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _busy ? null : _connectManual,
                child: const Text('Connect', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stepTile(GateStep step) {
    final (color, icon) = switch (step.state) {
      GateStepState.pending => (Colors.white38, Icons.circle_outlined),
      GateStepState.running => (Colors.amber, Icons.sync),
      GateStepState.pass => (Colors.green[400]!, Icons.check_circle),
      GateStepState.fail => (Colors.red[400]!, Icons.cancel),
      GateStepState.skip => (Colors.white24, Icons.remove_circle_outline),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.key, style: TextStyle(color: color, fontSize: 12, fontFamily: 'monospace')),
                if (step.detail != null)
                  Text(
                    step.detail!,
                    style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<String?> _localIpHint() async {
  try {
    final addr = await discovery.preferredLocalAddress();
    return addr?.address;
  } catch (_) {
    // Display-only hint; failure here doesn't block anything.
  }
  return null;
}

String _hexPreview(List<int> bytes) {
  final hex = bytes.take(6).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '0x$hex…';
}
