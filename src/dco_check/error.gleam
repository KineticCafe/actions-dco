//// Unified error type for the dco_check library.

import dco_check/internal/github/client
import gleam/int
import gleam/string
import oaspec/transport
import simplifile
import tom

pub type DcoCheckError {
  // Config errors
  ConfigParseError(tom.ParseError)
  ConfigFileError(path: String, reason: simplifile.FileError)
  // Pipeline errors
  TransportError(client.ClientError)
  ApiNotFound(String)
  ApiServerError(String)
  ApiUnavailable(String)
  ResponseDecodeError(String)
}

pub fn describe_error(err: DcoCheckError) -> String {
  case err {
    ConfigParseError(tom.Unexpected(got:, expected:)) ->
      "Invalid TOML: unexpected '" <> got <> "', expected " <> expected
    ConfigParseError(tom.KeyAlreadyInUse(key:)) ->
      "Invalid TOML: duplicate key " <> string.join(key, ".")
    ConfigFileError(path:, reason:) ->
      "Cannot read config file: "
      <> path
      <> " ("
      <> simplifile.describe_error(reason)
      <> ")"
    TransportError(client_err) -> describe_client_error(client_err)
    ApiNotFound(msg) -> "not found: " <> msg
    ApiServerError(msg) -> "server error: " <> msg
    ApiUnavailable(msg) -> "service unavailable: " <> msg
    ResponseDecodeError(msg) -> msg
  }
}

fn describe_client_error(err: client.ClientError) -> String {
  case err {
    client.TransportError(error:) ->
      case error {
        transport.ConnectionFailed(detail:) -> "connection failed: " <> detail
        transport.Timeout -> "timeout"
        transport.InvalidBaseUrl(detail:) -> "invalid base url: " <> detail
        transport.TlsFailure(detail:) -> "tls failure: " <> detail
        transport.Unsupported(detail:) -> "unsupported: " <> detail
      }
    client.DecodeFailure(detail:) -> "decode failure: " <> detail
    client.InvalidResponse(detail:) -> "invalid response: " <> detail
    client.UnexpectedStatus(status:, ..) ->
      "unexpected status: " <> int.to_string(status)
  }
}
