import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/http/bounded_client.dart';
import '../domain/model_price.dart';

class PriceNotFoundException implements Exception {
  const PriceNotFoundException(this.model);
  final String model;
  @override
  String toString() => 'No standard catalog price found for $model.';
}

class PriceCatalogException implements Exception {
  const PriceCatalogException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads public standard rates from LiteLLM's model catalog.
class LiteLlmPriceService {
  LiteLlmPriceService({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? BoundedClient(http.Client(), maxBytes: 8 << 20),
       _ownsClient = client == null;

  static final Uri catalogUri = Uri.parse(
    'https://raw.githubusercontent.com/BerriAI/litellm/main/'
    'model_prices_and_context_window.json',
  );

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  static const Map<String, String> _knownAliases = <String, String>{
    'whisper-large-v3': 'groq/whisper-large-v3',
    'whisper-large-v3-turbo': 'groq/whisper-large-v3-turbo',
    'llama-3.3-70b-versatile': 'groq/llama-3.3-70b-versatile',
    'openai/gpt-oss-120b': 'groq/openai/gpt-oss-120b',
    'openai/gpt-oss-20b': 'groq/openai/gpt-oss-20b',
  };

  Future<ModelPrice> fetch(
    String model, {
    required bool isTranscription,
  }) async {
    try {
      final http.Response response = await _client
          .get(catalogUri)
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw PriceCatalogException(
          'LiteLLM catalog request failed (${response.statusCode}).',
        );
      }
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const PriceCatalogException('LiteLLM catalog is malformed.');
      }
      final String catalogKey = _knownAliases[model] ?? model;
      final Object? raw = decoded[catalogKey];
      if (raw is! Map<String, dynamic>) throw PriceNotFoundException(model);
      if (isTranscription) {
        final double seconds = _number(raw['input_cost_per_second']);
        return ModelPrice(perAudioMinute: _converted(seconds * 60));
      }
      return ModelPrice(
        inputPerMTok: _converted(
          _number(raw['input_cost_per_token']) / 0.000001,
        ),
        outputPerMTok: _converted(
          _number(raw['output_cost_per_token']) / 0.000001,
        ),
      );
    } on PriceNotFoundException {
      rethrow;
    } on PriceCatalogException {
      rethrow;
    } on TimeoutException {
      throw const PriceCatalogException('LiteLLM catalog request timed out.');
    } on FormatException {
      throw const PriceCatalogException('LiteLLM catalog is malformed.');
    } catch (exception) {
      throw PriceCatalogException('Could not load LiteLLM catalog: $exception');
    }
  }

  static double _number(Object? value) {
    if (value is! num) {
      throw const PriceCatalogException(
        'Catalog price is missing or malformed.',
      );
    }
    final double result = value.toDouble();
    if (!result.isFinite || result < 0) {
      throw const PriceCatalogException(
        'Catalog price is missing or malformed.',
      );
    }
    return result;
  }

  static double _converted(double value) {
    if (!value.isFinite || value < 0) {
      throw const PriceCatalogException('Catalog price is missing or malformed.');
    }
    return double.parse(value.toStringAsPrecision(12));
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
