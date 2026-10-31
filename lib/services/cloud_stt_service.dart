import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Cloud speech-to-text through the `stt-proxy` Supabase Edge Function,
/// which forwards the clip to a self-hosted faster-whisper server
/// (STT_SELFHOSTED_URL, configured server-side). Every call degrades
/// silently to null when the backend or network is unavailable — the
/// OS recogniser stays the fallback in those cases.
/// Result of the cloud STT health probe — [ready] means the whole chain
/// works, [down] is transient (whisper unreachable, network), and
/// [misconfigured] means the feature can't work until an admin fixes
/// the backend (no STT_SELFHOSTED_URL, function missing, Supabase off).
enum CloudSttHealth { ready, down, misconfigured }

class CloudSttService {
  CloudSttService({required this.supabase});

  final SupabaseService supabase;

  /// End-to-end health probe: sends a few junk bytes on purpose. An
  /// upstream 400/422 ("invalid file") proves the whole chain —
  /// function deployed, self-hosted server reachable — is alive. A 2xx
  /// (server answered) counts too. A 503 naming the missing secret, or
  /// a 404 missing function, means the feature is not configured —
  /// permanent until an admin deploys/configures it, so callers should
  /// disable cloud STT rather than retry on a cooldown.
  Future<CloudSttHealth> checkHealth() async {
    if (!supabase.enabled) return CloudSttHealth.misconfigured;
    try {
      await Supabase.instance.client.functions
          .invoke('stt-proxy', body: {'audio': 'AAAA', 'format': 'm4a'})
          .timeout(const Duration(seconds: 6));
      return CloudSttHealth.ready;
    } on FunctionException catch (e) {
      if (e.status == 400 || e.status == 422) return CloudSttHealth.ready;
      if (e.status == 404) return CloudSttHealth.misconfigured;
      if (e.status == 503) {
        final details = '${e.details}'.toLowerCase();
        if (details.contains('selfhosted') ||
            details.contains('not configured')) {
          return CloudSttHealth.misconfigured;
        }
      }
      return CloudSttHealth.down;
    } catch (_) {
      return CloudSttHealth.down;
    }
  }

  /// Transcribes the recorded file. Returns the transcript text, or
  /// null on any failure — callers fall back to the on-device result.
  Future<String?> transcribe(String filePath) async {
    if (!supabase.enabled) return null;
    try {
      final file = File(filePath);
      if (!await file.exists() || await file.length() == 0) return null;
      final audio = base64Encode(await file.readAsBytes());
      final format = filePath.split('.').last;
      final res = await Supabase.instance.client.functions
          .invoke('stt-proxy', body: {'audio': audio, 'format': format})
          .timeout(const Duration(seconds: 45));
      final data = res.data;
      if (data is Map) {
        final text = data['text'];
        if (text is String && text.trim().isNotEmpty) {
          return text.trim();
        }
      }
    } catch (_) {}
    return null;
  }
}
