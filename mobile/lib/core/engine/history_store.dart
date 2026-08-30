/// HistoryStore — persistent logs for EVERY feature that produces history:
///   * journal trades (executed fills)
///   * agent sessions (goal → crew steps → reply → proposals)
///   * copilot decisions (approve/reject with the executed numbers)
/// All stored in SharedPreferences as JSON (survives restarts). No fake data:
/// every record is written from a real engine event.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

class HistoryStore {
  static const _kTrades = 'history_trades';
  static const _kSessions = 'history_agent_sessions';
  static const _kDecisions = 'history_copilot_decisions';

  Future<SharedPreferences> _sp() => SharedPreferences.getInstance();

  // -- journal trades ---------------------------------------------------------

  Future<List<ExecutedTrade>> loadTrades() async {
    final sp = await _sp();
    final raw = sp.getString(_kTrades);
    if (raw == null) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          ExecutedTrade(
            symbol: e['symbol'] as String,
            side: (e['side'] as String? ?? 'buy') == 'sell' ? Side.sell : Side.buy,
            quantity: (e['quantity'] as num).toDouble(),
            filledPrice: (e['filled_price'] as num).toDouble(),
            at:
                DateTime.tryParse(e['at'] as String? ?? '') ??
                    DateTime.now(),
            mode: (e['mode'] as String?) ?? 'paper',
            source: (e['source'] as String?) ?? 'manual',
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> addTrade(ExecutedTrade t) async {
    final sp = await _sp();
    final list = [
      ...[
        for (final e in jsonDecode(sp.getString(_kTrades) ?? '[]') as List) e,
      ],
      {
        'symbol': t.symbol,
        'side': t.side.name,
        'quantity': t.quantity,
        'filled_price': t.filledPrice,
        'at': t.at.toIso8601String(),
        'mode': t.mode,
        'source': t.source,
      },
    ];
    // keep the newest 500 fills
    await sp.setString(
        _kTrades, jsonEncode(list.length > 500 ? list.sublist(list.length - 500) : list));
  }

  // -- agent sessions ---------------------------------------------------------

  Future<List<Map<String, dynamic>>> loadSessions() async {
    final sp = await _sp();
    final raw = sp.getString(_kSessions);
    if (raw == null) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          Map<String, dynamic>.from(e as Map),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> addSession({
    required String goal,
    required String brain,
    required String reply,
    required List<List<String>> steps,
    required List<Map<String, dynamic>> proposals,
    String? chatId,
  }) async {
    final sp = await _sp();
    final list = [
      ...[
        for (final e in jsonDecode(sp.getString(_kSessions) ?? '[]') as List) e,
      ],
      {
        'goal': goal,
        'brain': brain,
        'reply': reply,
        'steps': steps,
        'proposals': proposals,
        'chat_id': chatId,
        'at': DateTime.now().toIso8601String(),
      },
    ];
    // keep the newest 100 sessions
    await sp.setString(_kSessions,
        jsonEncode(list.length > 100 ? list.sublist(list.length - 100) : list));
  }

  // -- copilot decisions ------------------------------------------------------

  Future<List<Map<String, dynamic>>> loadDecisions() async {
    final sp = await _sp();
    final raw = sp.getString(_kDecisions);
    if (raw == null) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          Map<String, dynamic>.from(e as Map),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> addDecision({
    required String symbol,
    required String side,
    required double quantity,
    required double price,
    required String mode,
    required bool approved,
    String? reason,
    String source = 'manual',
  }) async {
    final sp = await _sp();
    final list = [
      ...[
        for (final e in jsonDecode(sp.getString(_kDecisions) ?? '[]') as List) e,
      ],
      {
        'symbol': symbol,
        'side': side,
        'quantity': quantity,
        'price': price,
        'mode': mode,
        'approved': approved,
        'reason': reason,
        'source': source,
        'at': DateTime.now().toIso8601String(),
      },
    ];
    // keep the newest 200 decisions
    await sp.setString(_kDecisions,
        jsonEncode(list.length > 200 ? list.sublist(list.length - 200) : list));
  }
}
