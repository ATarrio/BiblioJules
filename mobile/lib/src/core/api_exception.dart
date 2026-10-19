/// Errors the API layer raises, mapped from HTTP status codes.
library;

/// Base class for anything that went wrong talking to the library server.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  /// A human-readable message, already taken from the server's ``detail``
  /// field when there was one.
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// The token is missing, expired or revoked (HTTP 401).
class ApiAuthException extends ApiException {
  ApiAuthException([super.message = 'Your session has expired.']) : super(statusCode: 401);
}

/// The server refused the request on permission grounds (HTTP 403).
class ApiForbiddenException extends ApiException {
  ApiForbiddenException([super.message = 'You are not allowed to do that.'])
    : super(statusCode: 403);
}

/// A referenced record does not exist (HTTP 404).
class ApiNotFoundException extends ApiException {
  ApiNotFoundException([super.message = 'Not found.']) : super(statusCode: 404);
}

/// The server rejected the data (HTTP 400/422).
class ApiValidationException extends ApiException {
  ApiValidationException(super.message, {super.statusCode});
}

/// The server could not be reached at all (DNS, refused, timeout, no network).
class ApiConnectionException extends ApiException {
  ApiConnectionException(super.message, {super.statusCode});
}
