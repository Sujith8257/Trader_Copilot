/// LLM client — one OpenAI-compatible interface for every brain the app can
/// use. On-device via Termux (llama-server / Ollama at 127.0.0.1), cloud
/// free-tiers (Gemini, Groq), or any local/remote OpenAI-compatible server.
/// The agent loop speaks this and nothing else.
library;

import 'dart:convert';

import 'package:flutter/material.dart' show IconData, Icons;
import 'package:http/http.dart' as http;

enum BrainKind { localServer, openrouter, gemini, claude, groq, rule }

/// Display metadata for the Settings picker.
extension BrainKindX on BrainKind {
  String get label => switch (this) {
    BrainKind.rule => 'Rule brain',
    BrainKind.localServer => 'Local / Wi-Fi',
    BrainKind.openrouter => 'OpenRouter',
    BrainKind.gemini => 'Gemini',
    BrainKind.claude => 'Claude',
    BrainKind.groq => 'Groq',
  };

  String get subtitle => switch (this) {
    BrainKind.rule => 'Offline, no key needed',
    BrainKind.localServer =>
      'llama-server / Ollama / LM Studio — Termux or the same Wi-Fi',
    BrainKind.openrouter => 'One key, 300+ models (incl. free tiers)',
    BrainKind.gemini => 'Google AI Studio free tier',
    BrainKind.claude => 'Anthropic console key',
    BrainKind.groq => 'Fastest free tier',
  };

  IconData get icon => switch (this) {
    BrainKind.rule => Icons.psychology_alt_outlined,
    BrainKind.localServer => Icons.lan_outlined,
    BrainKind.openrouter => Icons.hub_outlined,
    BrainKind.gemini => Icons.auto_awesome,
    BrainKind.claude => Icons.terminal,
    BrainKind.groq => Icons.bolt,
  };

  String get keyHint => switch (this) {
    BrainKind.openrouter => 'sk-or-v1-…',
    BrainKind.gemini => 'AIza…',
    BrainKind.claude => 'sk-ant-…',
    BrainKind.groq => 'gsk_…',
    _ => 'Optional',
  };

  bool get needsKey =>
      this == BrainKind.openrouter ||
      this == BrainKind.gemini ||
      this == BrainKind.claude ||
      this == BrainKind.groq;
}

class BrainConfig {
  const BrainConfig({
    this.kind = BrainKind.rule,
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
  });

  final BrainKind kind;
  final String baseUrl; // e.g. http://127.0.0.1:8080/v1 (Termux llama-server)
  final String apiKey;
  final String
  model; // e.g. qwen3.5-9b (whatever llama-server was started with)

  bool get isLlm => kind != BrainKind.rule;

  /// Preset default URL/model per provider.
  factory BrainConfig.defaults(
    BrainKind kind, {
    String baseUrl = '',
    String apiKey = '',
    String model = '',
  }) {
    switch (kind) {
      case BrainKind.localServer:
        return BrainConfig(
          kind: kind,
          baseUrl: baseUrl.isEmpty ? 'http://127.0.0.1:8080/v1' : baseUrl,
          model: model.isEmpty ? 'qwen' : model,
        );
      case BrainKind.openrouter:
        return BrainConfig(
          kind: kind,
          baseUrl: baseUrl.isEmpty ? 'https://openrouter.ai/api/v1' : baseUrl,
          apiKey: apiKey,
          model: model.isEmpty ? 'anthropic/claude-3.5-haiku' : model,
        );
      case BrainKind.gemini:
        return BrainConfig(
          kind: kind,
          baseUrl: baseUrl.isEmpty
              ? 'https://generativelanguage.googleapis.com/v1beta/openai'
              : baseUrl,
          apiKey: apiKey,
          model: model.isEmpty ? 'gemini-2.0-flash' : model,
        );
      case BrainKind.claude:
        return BrainConfig(
          kind: kind,
          baseUrl: baseUrl.isEmpty ? 'https://api.anthropic.com/v1' : baseUrl,
          apiKey: apiKey,
          model: model.isEmpty ? 'claude-3-5-haiku-latest' : model,
        );
      case BrainKind.groq:
        return BrainConfig(
          kind: kind,
          baseUrl: baseUrl.isEmpty ? 'https://api.groq.com/openai/v1' : baseUrl,
          apiKey: apiKey,
          model: model.isEmpty ? 'llama-3.3-70b-versatile' : model,
        );
      case BrainKind.rule:
        return const BrainConfig(kind: BrainKind.rule);
    }
  }

  Map<String, dynamic> toMap() => {
    'kind': kind.name,
    'base_url': baseUrl,
    'api_key': apiKey,
    'model': model,
  };

  static BrainConfig fromMap(Map<String, dynamic> m) => BrainConfig(
    kind: BrainKind.values.firstWhere(
      (k) => k.name == m['kind'],
      orElse: () => BrainKind.rule,
    ),
    baseUrl: (m['base_url'] as String?) ?? '',
    apiKey: (m['api_key'] as String?) ?? '',
    model: (m['model'] as String?) ?? '',
  );
}

class ChatMessage {
  const ChatMessage.system(this.content) : role = 'system';
  const ChatMessage.user(this.content) : role = 'user';
  const ChatMessage.assistant(this.content) : role = 'assistant';

  final String role; // system | user | assistant
  final String content;

  Map<String, String> toMap() => {'role': role, 'content': content};
}

class LlmException implements Exception {
  LlmException(this.message);
  final String message;
  @override
  String toString() => message;
}

class LlmClient {
  LlmClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// One chat completion. Low temperature by default — trading decisions
  /// should be conservative. Returns the assistant content.
  Future<String> chat(
    List<ChatMessage> messages, {
    required BrainConfig brain,
    double temperature = 0.2,
    int maxTokens = 900,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (!brain.isLlm) {
      throw LlmException('No LLM brain configured (rule mode).');
    }
    final base = brain.baseUrl.endsWith('/')
        ? brain.baseUrl.substring(0, brain.baseUrl.length - 1)
        : brain.baseUrl;
    final uri = Uri.parse('$base/chat/completions');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (brain.apiKey.isNotEmpty) 'Authorization': 'Bearer ${brain.apiKey}',
      // Anthropic's OpenAI-compatible endpoint wants a version pin.
      if (brain.kind == BrainKind.claude) 'anthropic-version': '2023-06-01',
    };
    final body = jsonEncode({
      'model': brain.model,
      'messages': [for (final m in messages) m.toMap()],
      'temperature': temperature,
      'max_tokens': maxTokens,
      'stream': false,
    });
    final http.Response r;
    try {
      r = await _client
          .post(uri, headers: headers, body: body)
          .timeout(timeout);
    } catch (e) {
      throw LlmException('LLM unreachable at ${brain.baseUrl}: $e');
    }
    if (r.statusCode >= 400) {
      throw LlmException(
        'LLM ${r.statusCode}: '
        '${r.body.length > 220 ? r.body.substring(0, 220) : r.body}',
      );
    }
    try {
      final decoded = jsonDecode(r.body) as Map<String, dynamic>;
      final choices = decoded['choices'] as List? ?? [];
      if (choices.isEmpty) throw LlmException('LLM returned no choices.');
      return ((((choices.first as Map)['message']) as Map)['content'] ?? '')
          .toString();
    } catch (e) {
      if (e is LlmException) rethrow;
      throw LlmException('Bad LLM response: $e');
    }
  }

  /// Quick reachability probe for the Settings screen.
  Future<String> probe(BrainConfig brain) => chat(
    [const ChatMessage.user('Reply with the single word: OK')],
    brain: brain,
    maxTokens: 8,
    temperature: 0.0,
    timeout: const Duration(seconds: 20),
  );

  /// Extract the first JSON object from an LLM reply (handles ```json
  /// fences and surrounding prose).
  static Map<String, dynamic>? extractJson(String text) {
    var t = text.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(t);
    if (fence != null) t = fence.group(1)!.trim();
    final start = t.indexOf('{');
    if (start == -1) return null;
    var depth = 0, inStr = false, esc = false;
    for (var i = start; i < t.length; i++) {
      final c = t[i];
      if (esc) {
        esc = false;
        continue;
      }
      if (c == r'\') {
        esc = true;
        continue;
      }
      if (c == '"') inStr = !inStr;
      if (inStr) continue;
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) {
          try {
            return jsonDecode(t.substring(start, i + 1))
                as Map<String, dynamic>;
          } catch (_) {
            return null;
          }
        }
      }
    }
    return null;
  }
}
