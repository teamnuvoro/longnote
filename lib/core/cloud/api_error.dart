import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// A `{"error": {"code", "message", "detail"}}` reply from our backend
/// (BACKEND-API 4, "Errors"), or an unexpected HTTP status.
class ApiException implements Exception {
  ApiException(this.code, this.serverMessage,
      {this.httpStatus, this.detail = const {}});

  final String code;
  final String? serverMessage;
  final int? httpStatus;
  final Map<String, Object?> detail;

  /// Plain English for the "needs attention" list / failed state.
  String get userMessage => plainEnglishError(code, detail: detail);

  @override
  String toString() =>
      'ApiException($code, http $httpStatus${serverMessage == null ? '' : ': $serverMessage'})';
}

/// Our own code for "could not reach the server".
const networkErrorCode = 'network';

/// Server error code -> words the user sees (BACKEND-API 4 table).
String plainEnglishError(String code, {Map<String, Object?> detail = const {}}) {
  switch (code) {
    case 'limit_reached':
      return switch (detail['scope']) {
        'user_hour' =>
          'Too much audio in the last hour. We will try again later.',
        'global_day' =>
          'The service is busy today. We will try again tomorrow.',
        _ => 'Daily limit reached. We will try again after it resets (00:00 UTC).',
      };
    case networkErrorCode:
      return 'No internet. Saved on your phone; it uploads when you are online.';
    case 'upload_refused':
      return 'Too many recordings are waiting to upload. We will try again.';
    case 'timeout':
      return 'The server took too long to answer. We will try again.';
    case 'unauthorized':
      return 'Could not sign in to the service. We will try again.';
    case 'not_found':
      return 'We could not find that upload. We will send it again.';
    case 'too_long':
      return "Recordings over 5 hours can't be transcribed in one piece.";
    case 'payload_too_large':
      return 'This is too long to send at once.';
    case 'upstream_failed':
      return 'The transcription service had a problem. Try again.';
    case 'server_error':
      return 'Something went wrong on our side. Try again.';
    case 'bad_request':
      return 'Something in the request was wrong.';
    case 'encode_failed':
      return 'We could not prepare the audio for upload. Your recording is safe.';
    case 'transcription_failed':
      return 'Transcription failed. We will upload the audio again and retry.';
    case 'no_audio':
      return 'No audio was saved for this note.';
    default:
      return 'Something went wrong. Your audio is safe. Try again.';
  }
}

/// True for errors that mean "the network is not there right now":
/// socket errors, TLS handshakes cut off, timeouts, client exceptions.
bool isNetworkError(Object e) =>
    e is SocketException ||
    e is HandshakeException ||
    e is TimeoutException ||
    e is http.ClientException ||
    e is HttpException;
