//// Shared async pipeline for fetching and processing DCO status.
////
//// Both the action and CLI use this to fetch the commit comparison, decode it, and run
//// the DCO check. Frontends handle the result (summary rendering, exit codes, job
//// summaries) themselves.

import dco_check
import dco_check/config.{type Config}
import dco_check/error.{type DcoCheckError}
import dco_check/internal/github/client
import dco_check/internal/github/decode
import dco_check/internal/github/response_types
import dco_check/internal/github/types as github_types
import dco_check/types.{type DcoRecord, type DcoSummary}
import gleam/fetch as gleam_fetch
import gleam/http/request as http_request
import gleam/http/response.{type Response}
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oaspec/fetch as oaspec_fetch
import oaspec/transport
import pontil

/// Add a bearer token to an AsyncSend.
pub fn with_auth(
  send send: transport.AsyncSend,
  token token: String,
) -> transport.AsyncSend {
  fn(req: transport.Request) {
    let authed =
      transport.Request(..req, headers: [
        #("authorization", "Bearer " <> token),
        ..req.headers
      ])
    send(authed)
  }
}

/// Fetch the commit comparison from the GitHub API.
///
/// Returns a Promise of the raw response (for wrapping in pontil.group_async).
pub fn fetch_comparison(
  send send: transport.AsyncSend,
  owner owner: String,
  repo repo: String,
  basehead basehead: String,
) -> Promise(Result(response_types.ReposCompareCommitsResponse, DcoCheckError)) {
  client.repos_compare_commits_async(
    async_send: send,
    owner:,
    repo:,
    basehead:,
    page: None,
    per_page: None,
  )
  |> oaspec_fetch.to_promise
  |> promise.map(fn(r) { result.map_error(r, error.TransportError) })
}

/// Decode the API response and run the DCO check.
/// Synchronous — wrap in promise.resolve at the call site.
pub fn process_response(
  response response: response_types.ReposCompareCommitsResponse,
  config cfg: Config,
) -> Result(#(DcoSummary, List(DcoRecord)), DcoCheckError) {
  case response {
    response_types.ReposCompareCommitsResponseOk(json_body) -> {
      pontil.debug(
        "process_response: decoding commit comparison ("
        <> int.to_string(string.length(json_body))
        <> " bytes)",
      )
      case decode.decode_commit_comparison(json_body) {
        Ok(comparison) -> {
          pontil.debug(
            "process_response: decode complete, calling get_dco_status",
          )
          Ok(dco_check.get_dco_status(
            commits: comparison.commits,
            url: comparison.html_url,
            config: cfg,
            total: comparison.total_commits,
          ))
        }
        Error(err) -> Error(error.ResponseDecodeError(err))
      }
    }
    response_types.ReposCompareCommitsResponseNotFound(err) ->
      Error(error.ApiNotFound(option.unwrap(err.message, "not found")))
    response_types.ReposCompareCommitsResponseInternalServerError(err) ->
      Error(
        error.ApiServerError(option.unwrap(err.message, "internal server error")),
      )
    response_types.ReposCompareCommitsResponseServiceUnavailable(err) ->
      Error(
        error.ApiUnavailable(option.unwrap(err.message, "service unavailable")),
      )
  }
}

/// Full pipeline: fetch + process. Convenience for frontends that don't need
/// to wrap individual steps in groups.
pub fn run(
  send send: transport.AsyncSend,
  owner owner: String,
  repo repo: String,
  basehead basehead: String,
  config cfg: Config,
) -> Promise(Result(#(DcoSummary, List(DcoRecord)), DcoCheckError)) {
  fetch_comparison(send:, owner:, repo:, basehead:)
  |> promise.try_await(fn(response) {
    process_response(response:, config: cfg) |> promise.resolve
  })
}

const comment_marker = "<!-- dco-check -->"

/// Find an existing DCO check comment on the PR, if any.
pub fn find_existing_comment(
  send send: transport.AsyncSend,
  owner owner: String,
  repo repo: String,
  issue_number issue_number: Int,
) -> Promise(Result(Option(Int), DcoCheckError)) {
  client.issues_list_comments_async(
    async_send: send,
    owner:,
    repo:,
    issue_number:,
    since: None,
    per_page: Some(100),
    page: None,
  )
  |> oaspec_fetch.to_promise
  |> promise.map(fn(r) {
    case r {
      Ok(response_types.IssuesListCommentsResponseOk(comments, _headers)) ->
        Ok(find_comment_with_marker(comments))
      Ok(response_types.IssuesListCommentsResponseNotFound(_)) -> Ok(None)
      Ok(response_types.IssuesListCommentsResponseGone(_)) -> Ok(None)
      Error(err) -> Error(error.TransportError(err))
    }
  })
}

/// Create or update the DCO check comment on a PR.
pub fn upsert_comment(
  send send: transport.AsyncSend,
  owner owner: String,
  repo repo: String,
  issue_number issue_number: Int,
  existing_comment_id existing: Option(Int),
  body body: String,
) -> Promise(Result(Nil, DcoCheckError)) {
  let full_body = comment_marker <> "\n" <> body

  case existing {
    Some(comment_id) ->
      client.issues_update_comment_async(
        async_send: send,
        owner:,
        repo:,
        comment_id:,
        body: github_types.IssuesUpdateCommentRequest(body: full_body),
      )
      |> oaspec_fetch.to_promise
      |> promise.map(fn(r) {
        case r {
          Ok(response_types.IssuesUpdateCommentResponseOk(_)) -> Ok(Nil)
          Ok(response_types.IssuesUpdateCommentResponseUnprocessableEntity(_)) ->
            Error(error.ApiServerError(
              "Failed to update comment: validation error",
            ))
          Error(err) -> Error(error.TransportError(err))
        }
      })
    None ->
      client.issues_create_comment_async(
        async_send: send,
        owner:,
        repo:,
        issue_number:,
        body: github_types.IssuesCreateCommentRequest(body: full_body),
      )
      |> oaspec_fetch.to_promise
      |> promise.map(fn(r) {
        case r {
          Ok(response_types.IssuesCreateCommentResponseCreated(_, _)) -> Ok(Nil)
          Ok(response_types.IssuesCreateCommentResponseForbidden(_)) ->
            Error(error.ApiServerError(
              "Failed to create comment: forbidden (check pull-requests: write permission)",
            ))
          Ok(response_types.IssuesCreateCommentResponseNotFound(_)) ->
            Error(error.ApiServerError("Failed to create comment: PR not found"))
          Ok(response_types.IssuesCreateCommentResponseGone(_)) ->
            Error(error.ApiServerError("Failed to create comment: PR gone"))
          Ok(response_types.IssuesCreateCommentResponseUnprocessableEntity(_)) ->
            Error(error.ApiServerError(
              "Failed to create comment: validation error",
            ))
          Error(err) -> Error(error.TransportError(err))
        }
      })
  }
}

fn find_comment_with_marker(
  comments: List(github_types.IssueComment),
) -> Option(Int) {
  case
    list.find(comments, fn(c) {
      option.unwrap(c.body, "")
      |> string.contains(comment_marker)
    })
  {
    Ok(comment) -> Some(comment.id)
    Error(Nil) -> None
  }
}

/// Fetch the default branch config file, trying .github/dco-check.toml then .dco-check.toml.
/// Returns None if neither file exists (404 on both). Returns Error if the file exists
/// but cannot be decoded or parsed.
pub fn fetch_default_branch_config(
  api_url api_url: String,
  token token: String,
  owner owner: String,
  repo repo: String,
) -> Promise(Result(Option(config.DefaultBranchConfig), DcoCheckError)) {
  fetch_config_file(
    api_url:,
    token:,
    owner:,
    repo:,
    path: ".github/dco-check.toml",
  )
  |> promise.try_await(fn(result) {
    case result {
      Some(cfg) -> promise.resolve(Ok(Some(cfg)))
      None ->
        fetch_config_file(
          api_url:,
          token:,
          owner:,
          repo:,
          path: ".dco-check.toml",
        )
    }
  })
}

/// Fetch a single config file path from the default branch using the raw content media
/// type. Returns Ok(None) on 404, Ok(Some(config)) on success, Error on other failures.
fn fetch_config_file(
  api_url api_url: String,
  token token: String,
  owner owner: String,
  repo repo: String,
  path path: String,
) -> Promise(Result(Option(config.DefaultBranchConfig), DcoCheckError)) {
  let url = api_url <> "/repos/" <> owner <> "/" <> repo <> "/contents/" <> path

  use req <- pontil.try_sync(
    http_request.to(url)
    |> result.replace_error(error.ConfigRefError(
      "Invalid URL for config file: " <> url,
    )),
  )

  let req =
    req
    |> http_request.set_header("accept", "application/vnd.github.raw+json")
    |> http_request.set_header("authorization", "Bearer " <> token)

  gleam_fetch.send(req)
  |> promise.try_await(fn(resp) { gleam_fetch.read_text_body(resp) })
  |> promise.map(fn(r) {
    r
    |> result.replace_error(error.ConfigRefError(
      "Network error fetching " <> path <> " from default branch",
    ))
    |> result.try(fn(resp) {
      case resp.status {
        200 ->
          case config.parse_default_branch_config(resp.body) {
            Ok(cfg) -> Ok(Some(cfg))
            Error(err) -> Error(err)
          }
        404 -> Ok(None)
        403 ->
          Error(error.ConfigRefError(
            "Forbidden reading " <> path <> " from default branch",
          ))
        status ->
          Error(error.ConfigRefError(
            path <> ": unexpected HTTP " <> int.to_string(status),
          ))
      }
    })
  })
}

/// Fetch a remote config via a ref URL. Sends the auth token only if the URL matches the
/// API base URL. For non-API URLs, uses gleam/fetch directly without any authentication.
pub fn fetch_ref_config(
  api_url api_url: String,
  token token: String,
  url url: String,
) -> Promise(Result(Config, DcoCheckError)) {
  use req <- pontil.try_sync(
    http_request.to(url)
    |> result.replace_error(error.ConfigRefError("Invalid ref URL: " <> url)),
  )

  let req = case string.starts_with(url, api_url) {
    True -> http_request.set_header(req, "authorization", "Bearer " <> token)
    False -> req
  }

  gleam_fetch.send(req)
  |> promise.try_await(fn(resp) { gleam_fetch.read_text_body(resp) })
  |> promise.map(fn(r) {
    r
    |> result.replace_error(error.ConfigRefError(
      "Network error fetching ref: " <> url,
    ))
    |> result.try(fn(resp) { parse_ref_text_response(resp, url) })
  })
}

fn parse_ref_text_response(
  resp: Response(String),
  url: String,
) -> Result(Config, DcoCheckError) {
  case resp.status {
    200 -> config.parse(resp.body)
    404 -> Error(error.ConfigRefError("ref URL not found (404): " <> url))
    _ ->
      Error(error.ConfigRefError(
        "ref URL returned HTTP " <> int.to_string(resp.status) <> ": " <> url,
      ))
  }
}
