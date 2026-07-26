//// Unified error type for the dco_check library.

import dco_check/internal/github/client
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
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
  ResponseDecodeError(json.DecodeError)
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
    ResponseDecodeError(decode_err) -> describe_decode_error(decode_err)
  }
}

fn describe_decode_error(err: json.DecodeError) -> String {
  case err {
    json.UnexpectedEndOfInput -> "Failed to decode response: unexpected end of input"
    json.UnexpectedByte(byte) ->
      "Failed to decode response: unexpected byte '" <> byte <> "'"
    json.UnexpectedSequence(seq) ->
      "Failed to decode response: unexpected sequence '" <> seq <> "'"
    json.UnableToDecode(errors) ->
      "Failed to decode commit comparison JSON:\n"
      <> list.map(errors, describe_dynamic_error)
      |> string.join("\n")
  }
}

fn describe_dynamic_error(err: decode.DecodeError) -> String {
  let path = case err.path {
    [] -> ""
    segments -> " at " <> string.join(segments, ".")
  }
  "  expected " <> err.expected <> ", got " <> err.found <> path
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
