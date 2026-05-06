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
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oaspec/fetch
import oaspec/transport

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
  |> fetch.to_promise
  |> promise.map(fn(r) { result.map_error(r, error.TransportError) })
}

/// Decode the API response and run the DCO check.
/// Synchronous — wrap in promise.resolve at the call site.
pub fn process_response(
  response response: response_types.ReposCompareCommitsResponse,
  config cfg: Config,
) -> Result(#(DcoSummary, List(DcoRecord)), DcoCheckError) {
  case response {
    response_types.ReposCompareCommitsResponseOk(json_body) ->
      case decode.decode_commit_comparison(json_body) {
        Ok(comparison) ->
          Ok(dco_check.get_dco_status(
            commits: comparison.commits,
            url: comparison.html_url,
            config: cfg,
            total: comparison.total_commits,
          ))
        Error(_) ->
          Error(error.ResponseDecodeError(
            "Failed to decode commit comparison JSON",
          ))
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
  |> fetch.to_promise
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
      |> fetch.to_promise
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
      |> fetch.to_promise
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
