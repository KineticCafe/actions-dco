//// GitHub Action entrypoint for DCO check.
////
//// Pipeline: read inputs -> load config -> call GitHub API -> get_dco_status ->
//// render summary -> write job summary -> optionally comment on PR -> set pass/fail.

import dco_check
import dco_check/config
import dco_check/error
import dco_check/format
import dco_check/pipeline
import dco_check/types.{
  type DcoRecord, type DcoSummary, AiCoAuthorRejected, AiSignoffRejected,
  AiTraceRejected, InvalidCommit, NoMatch, NoSignoffs,
}
import gleam/bool
import gleam/dict
import gleam/function
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import houdini
import oaspec/fetch
import oaspec/transport
import pontil
import pontil/context
import pontil/core as pontil_core
import pontil/summary.{type SummaryElement}

pub fn main() -> Nil {
  pontil.info(dco_check.package_name <> " " <> dco_check.package_version)
  pontil.register_default_process_handlers()

  promise.map(run_pipeline(), fn(result) {
    case result {
      Ok(#(dco_summary, records)) -> {
        case write_summary(dco_summary:, records:) {
          Ok(_) -> Nil
          Error(err) ->
            pontil.warning(
              "Failed to write job summary: " <> pontil_core.describe_error(err),
            )
        }
        case dco_summary.failed > 0 || dco_summary.invalid > 0 {
          True -> pontil.set_failed(build_failure_message(dco_summary))
          False -> pontil.info("DCO check passed.")
        }
      }
      Error(err) -> {
        write_error_summary(err)
        pontil.set_failed(describe_error(err))
      }
    }
  })

  Nil
}

type DcoCheckActionError {
  DcoCheckError(error.DcoCheckError)
  ContextError(context.PontilContextError)
  SummaryError(pontil_core.PontilCoreError)
  /// A `config` input was given but a default branch config file exists.
  ConfigConflict(path: String)
  /// Inputs removed in v4 are still set.
  RemovedInputsSet(List(RemovedInput))
}

/// An action input removed in v4, with migration advice.
pub type RemovedInput {
  RemovedInput(name: String, advice: String)
}

/// Inputs removed in v4. In 4.0, setting one fails the run so the policy change is not
/// silent. In 4.1 this check is dropped and GitHub's own "Unexpected input" warning is all
/// that remains.
const removed_inputs = [
  RemovedInput(
    name: "exempt-authors",
    advice: "Move the exemptions to `exempt-authors = [...]` in the TOML configuration (the `config` input or a default branch config file).",
  ),
]

/// Fail if any input removed in v4 is set. GitHub passes undeclared inputs through as
/// `INPUT_*` environment variables, so they are still visible here.
pub fn check_removed_inputs() -> Result(Nil, List(RemovedInput)) {
  case
    list.filter(removed_inputs, fn(input) { pontil.get_input(input.name) != "" })
  {
    [] -> Ok(Nil)
    set -> Error(set)
  }
}

pub fn describe_removed_input(input: RemovedInput) -> String {
  "The '" <> input.name <> "' input was removed in v4. " <> input.advice
}

/// Setup result includes PR number for comment support.
type ActionContext {
  ActionContext(
    send: transport.AsyncSend,
    owner: String,
    repo: String,
    basehead: String,
    pr_number: Int,
    api_url: String,
    token: String,
    /// Raw (trimmed) `config` input. Resolved after the default branch lookup.
    config_input: String,
    /// The effective config. Only valid after `load_config`.
    cfg: config.Config,
  )
}

fn run_pipeline() -> Promise(
  Result(#(DcoSummary, List(DcoRecord)), DcoCheckActionError),
) {
  use ctx <- pontil.try_sync(setup())

  // A default branch config is authoritative; an inline config alongside it is rejected.
  use ctx <- promise.try_await(
    pontil.group_async("Checking default branch config", fn() {
      load_config(ctx)
    }),
  )

  // Log effective configuration
  pontil.group("Effective configuration", fn() {
    list.each(ctx.cfg.warnings, pontil.warning)
    list.each(config.describe(ctx.cfg), pontil.info)
  })

  use response <- promise.try_await(
    pontil.group_async("Fetching commit comparison", fn() {
      pipeline.fetch_comparison(
        send: ctx.send,
        owner: ctx.owner,
        repo: ctx.repo,
        basehead: ctx.basehead,
      )
    })
    |> promise.map(fn(r) { result.map_error(r, DcoCheckError) }),
  )

  use results <- promise.try_await(
    pontil.group_async("Processing DCO check", fn() {
      pipeline.process_response(response:, config: ctx.cfg)
      |> result.map_error(DcoCheckError)
      |> promise.resolve
    }),
  )

  pontil.debug(
    "run_pipeline: processing complete, comment="
    <> bool.to_string(ctx.cfg.comment),
  )

  use <- bool.guard(
    bool.negate(ctx.cfg.comment),
    return: promise.resolve(Ok(results)),
  )

  let #(summary, records) = results
  pontil.group_async("Updating PR comment", fn() {
    post_comment(ctx:, summary:, records:)
    |> promise.map(fn(r) {
      case r {
        Ok(_) -> Ok(results)
        Error(err) -> {
          pontil.warning(
            "Failed to post PR comment: " <> error.describe_error(err),
          )
          Ok(results)
        }
      }
    })
  })
}

fn post_comment(
  ctx ctx: ActionContext,
  summary summary: DcoSummary,
  records records: List(DcoRecord),
) -> Promise(Result(Nil, error.DcoCheckError)) {
  let body = format_comment_body(summary:, records:)

  pipeline.find_existing_comment(
    send: ctx.send,
    owner: ctx.owner,
    repo: ctx.repo,
    issue_number: ctx.pr_number,
  )
  |> promise.try_await(fn(existing) {
    pipeline.upsert_comment(
      send: ctx.send,
      owner: ctx.owner,
      repo: ctx.repo,
      issue_number: ctx.pr_number,
      existing_comment_id: existing,
      body:,
    )
  })
}

pub fn format_comment_body(
  summary summary: DcoSummary,
  records records: List(DcoRecord),
) -> String {
  let has_failures = summary.failed > 0 || summary.invalid > 0

  let heading = "## " <> summary_heading_h1(has_failures)

  let truncation_note = case summary.truncated {
    True ->
      "\n\n> ⚠️ Evaluated "
      <> int.to_string(summary.evaluated)
      <> " of "
      <> int.to_string(summary.total_commits)
      <> " commits (GitHub API limit)."
    False -> ""
  }

  let failures = failure_records(records)

  let failure_section = case failures {
    [] -> ""
    _ -> {
      let capped = list.take(failures, 20)
      let rows =
        list.map(capped, fn(r) {
          "| [`"
          <> format.sha(r.sha)
          <> "`]("
          <> r.url
          <> ") | "
          <> houdini.escape(format.escape_markdown(r.subject))
          <> " | "
          <> format_disposition(r, escape: format.escape_markdown)
          <> " |"
        })
        |> string.join("\n")

      let overflow = case list.length(failures) > 20 {
        True ->
          "\n\n_…and "
          <> int.to_string(list.length(failures) - 20)
          <> " more. Consider `git rebase --signoff`._"
        False -> ""
      }

      "\n\n### Issues\n\n| Commit | Subject | Problem |\n|--------|---------|---------|"
      <> "\n"
      <> rows
      <> overflow
    }
  }

  let success_section = format_success_section(records)

  heading <> truncation_note <> failure_section <> success_section
}

/// A grouped success entry: identity label, count, and note.
type SuccessGroup {
  SuccessGroup(identity: String, count: Int, note: String)
}

fn format_success_section(records: List(DcoRecord)) -> String {
  let groups = build_success_groups(records:, counts: dict.new(), order: [])

  case groups {
    [] -> ""
    _ -> {
      let rows =
        list.map(groups, fn(g) {
          "| "
          <> houdini.escape(format.escape_markdown(g.identity))
          <> " | "
          <> int.to_string(g.count)
          <> " ("
          <> comment_note(g.note)
          <> ") |"
        })
        |> string.join("\n")

      // GitHub renders Markdown footnotes in comments; the definition is only emitted
      // when a row references it.
      let footnote = case list.any(groups, is_flagged) {
        True -> "\n\n[^ai-signoff]: " <> format.ai_signoff_footnote
        False -> ""
      }

      "\n\n### Commits\n\n| Identity | Commits |\n|----------|---------|"
      <> "\n"
      <> rows
      <> footnote
    }
  }
}

/// Escape a note for the Markdown comment, turning the AI sign-off marker into a footnote
/// reference.
fn comment_note(note: String) -> String {
  houdini.escape(format.escape_markdown(note))
  |> string.replace(
    format.ai_signoff_marker,
    format.ai_signoff_marker <> "[^ai-signoff]",
  )
}

/// Build grouped success entries. Uses a dict keyed by (identity_label, note) to
/// accumulate counts, preserving insertion order via a separate key list.
fn build_success_groups(
  records records: List(DcoRecord),
  counts counts: dict.Dict(String, Int),
  order order: List(SuccessGroup),
) -> List(SuccessGroup) {
  case records {
    [] ->
      list.reverse(order)
      |> list.map(fn(g) {
        let count = case dict.get(counts, g.identity <> "|" <> g.note) {
          Ok(n) -> n
          Error(Nil) -> g.count
        }
        SuccessGroup(..g, count:)
      })
    [record, ..rest] -> {
      case success_group_for(record) {
        Ok(group) -> add_success_group(group:, records: rest, counts:, order:)
        Error(Nil) -> build_success_groups(records: rest, counts:, order:)
      }
    }
  }
}

fn add_success_group(
  group group: SuccessGroup,
  records records: List(DcoRecord),
  counts counts: dict.Dict(String, Int),
  order order: List(SuccessGroup),
) -> List(SuccessGroup) {
  let key = group.identity <> "|" <> group.note

  let order = case dict.has_key(counts, key) {
    True -> order
    False -> [group, ..order]
  }

  let count = { dict.get(counts, key) |> result.unwrap(or: 0) } + 1
  let counts = dict.insert(counts, key, count)

  build_success_groups(records:, counts:, order:)
}

fn success_group_for(record: DcoRecord) -> Result(SuccessGroup, Nil) {
  use group <- result.map(disposition_success_group(record))

  // Flag commits whose AI sign-off was ignored; rows with different flags group apart.
  case format.has_ignored_ai_signoff(record) {
    True ->
      SuccessGroup(..group, note: group.note <> " " <> format.ai_signoff_marker)
    False -> group
  }
}

/// Whether a success row carries the ignored-AI-sign-off marker.
fn is_flagged(group: SuccessGroup) -> Bool {
  string.contains(group.note, format.ai_signoff_marker)
}

fn disposition_success_group(record: DcoRecord) -> Result(SuccessGroup, Nil) {
  case record.disposition {
    types.Passed(identity: id) -> {
      let identity = id.name <> " <" <> format.mask_email(id.email) <> ">"
      Ok(SuccessGroup(identity:, count: 1, note: "signed off"))
    }
    types.Exempted(identity:, match:, alias:) -> {
      let label =
        identity.name <> " <" <> format.mask_email(identity.email) <> ">"
      Ok(SuccessGroup(
        identity: label,
        count: 1,
        note: format.exemption_note(
          match:,
          alias: option.map(alias, format.mask_email),
        ),
      ))
    }
    types.BotCommit(login:, ..) ->
      Ok(SuccessGroup(identity: login, count: 1, note: "bot, skipped"))
    types.MergeCommit ->
      Ok(SuccessGroup(
        identity: "merge commits",
        count: 1,
        note: "no sign-off, skipped",
      ))
    types.Skipped(reason) ->
      Ok(SuccessGroup(identity: "skipped", count: 1, note: reason))
    _ -> Error(Nil)
  }
}

fn setup() -> Result(ActionContext, DcoCheckActionError) {
  use _ <- result.try(
    check_removed_inputs() |> result.map_error(RemovedInputsSet),
  )

  let token = pontil.get_input("repo-token")
  // Inputs are trimmed; an empty value means the input was not set. Config is resolved
  // in `load_config`, after the default branch lookup.
  let config_input = pontil.get_input("config")

  let ctx = context.new()
  use <- guard_pr_context(ctx)

  use event_data <- result.try(
    context.event() |> result.map_error(ContextError),
  )
  use pr_event <- result.try(
    context.event_to_pull_request(event_name: ctx.event_name, event: event_data)
    |> result.map_error(ContextError),
  )

  let pr = pr_event.pull_request
  let basehead = pr.base.sha <> "..." <> pr.head.sha

  use repo <- result.try(case ctx.repo {
    Some(r) -> Ok(r)
    _ ->
      Error(
        ContextError(context.MissingEventField(
          field: "repository",
          event_name: ctx.event_name,
        )),
      )
  })

  pontil.debug("Comparing " <> basehead)

  let send =
    fetch.send
    |> pipeline.with_auth(token:)
    |> transport.with_base_url(ctx.api_url)

  Ok(ActionContext(
    send:,
    owner: repo.owner,
    repo: repo.name,
    basehead:,
    pr_number: pr_event.number,
    api_url: ctx.api_url,
    token:,
    config_input:,
    cfg: config.default(),
  ))
}

/// Resolve the effective config.
///
/// - A default branch config file (`.github/dco-check.toml` or `.dco-check.toml`, possibly
///   a `ref` to a remote config) is authoritative. If the `config` input is also set, the
///   run fails: policy must come from one place, and the workflow file is not it.
/// - Otherwise a non-empty `config` input is parsed strictly; an invalid one fails the run.
/// - Otherwise the defaults are used.
fn load_config(
  ctx: ActionContext,
) -> Promise(Result(ActionContext, DcoCheckActionError)) {
  pipeline.fetch_default_branch_config(
    api_url: ctx.api_url,
    token: ctx.token,
    owner: ctx.owner,
    repo: ctx.repo,
  )
  |> promise.map(fn(r) { result.map_error(r, DcoCheckError) })
  |> promise.try_await(resolve_config(ctx, _))
}

fn resolve_config(
  ctx: ActionContext,
  found: Option(#(String, config.DefaultBranchConfig)),
) -> Promise(Result(ActionContext, DcoCheckActionError)) {
  case found {
    None ->
      inline_or_default_config(ctx)
      |> result.map(fn(cfg) { ActionContext(..ctx, cfg:) })
      |> promise.resolve
    Some(#(path, _)) if ctx.config_input != "" ->
      promise.resolve(Error(ConfigConflict(path:)))
    Some(#(path, config.DirectConfig(cfg))) -> {
      pontil.info("Loaded config from " <> path)
      promise.resolve(Ok(ActionContext(..ctx, cfg:)))
    }
    Some(#(path, config.RefConfig(url:))) -> {
      pontil.info("Loaded config ref from " <> path <> ", fetching: " <> url)

      pipeline.fetch_ref_config(api_url: ctx.api_url, token: ctx.token, url:)
      |> promise.map(fn(resp) {
        resp
        |> result.map_error(DcoCheckError)
        |> result.map(fn(cfg) {
          pontil.info("Loaded remote config from " <> url)
          ActionContext(..ctx, cfg:)
        })
      })
    }
  }
}

/// No default branch config: use the `config` input, else the defaults.
fn inline_or_default_config(
  ctx: ActionContext,
) -> Result(config.Config, DcoCheckActionError) {
  case ctx.config_input {
    "" -> {
      pontil.debug("No config provided, using defaults")
      Ok(config.default())
    }
    toml -> config.parse(toml) |> result.map_error(DcoCheckError)
  }
}

fn guard_pr_context(
  ctx: context.Context,
  continue: fn() -> Result(a, DcoCheckActionError),
) -> Result(a, DcoCheckActionError) {
  use <- bool.guard(
    context.is_pull_request(ctx) || context.is_pull_request_target(ctx),
    return: continue(),
  )

  Error(
    ContextError(context.InvalidEventConversion(
      expected: "pull_request or pull_request_target",
      provided: ctx.event_name,
    )),
  )
}

pub fn write_summary(
  dco_summary dco_summary: DcoSummary,
  records records: List(DcoRecord),
) -> Result(Nil, pontil_core.PontilCoreError) {
  let has_failures = dco_summary.failed > 0 || dco_summary.invalid > 0

  summary.new()
  |> summary.h1(summary_heading_h1(has_failures))
  |> summary_truncated(dco_summary)
  |> summary_failures(records)
  |> summary_success_groups(records)
  |> summary.overwrite()
}

fn summary_heading_h1(has_failures: Bool) -> String {
  use <- bool.guard(has_failures, return: "❌ DCO Check Failed")

  "✅ DCO Check Passed"
}

fn summary_truncated(
  elements: List(SummaryElement),
  dco_summary: DcoSummary,
) -> List(SummaryElement) {
  use <- bool.guard(dco_summary.truncated |> bool.negate, return: elements)

  elements
  |> summary.raw(
    "⚠️  Evaluated "
    <> int.to_string(dco_summary.evaluated)
    <> " of "
    <> int.to_string(dco_summary.total_commits)
    <> " commits (GitHub API limit).",
  )
  |> summary.eol
}

fn failure_records(records: List(DcoRecord)) -> List(DcoRecord) {
  list.filter(records, fn(r) {
    case r.disposition {
      NoSignoffs
      | NoMatch(..)
      | InvalidCommit
      | AiSignoffRejected(..)
      | AiCoAuthorRejected(..)
      | AiTraceRejected(..) -> True
      _ -> False
    }
  })
}

fn summary_failures(
  elements: List(SummaryElement),
  records: List(DcoRecord),
) -> List(SummaryElement) {
  let failures = failure_records(records)

  use <- bool.guard(failures == [], return: elements)

  let table =
    summary.new_table()
    |> summary.header_row(["Commit", "Subject", "Problem"])

  let table =
    list.take(failures, 20)
    |> list.fold(table, fn(t, r) {
      summary.row(t, [
        format.sha(r.sha),
        houdini.escape(r.subject),
        format_disposition(r, escape: function.identity),
      ])
    })

  let elements =
    elements
    |> summary.h2("Issues")
    |> summary.table(table)

  use <- bool.guard(list.length(failures) <= 20, return: elements)

  elements
  |> summary.raw(
    "…and "
    <> int.to_string(list.length(failures) - 20)
    <> " more. Consider `git rebase --signoff`.",
  )
  |> summary.eol
}

fn summary_success_groups(
  elements: List(SummaryElement),
  records: List(DcoRecord),
) -> List(SummaryElement) {
  let groups = build_success_groups(records:, counts: dict.new(), order: [])

  use <- bool.guard(groups == [], return: elements)

  let table =
    summary.new_table()
    |> summary.header_row(["Identity", "Commits"])

  let table =
    list.fold(groups, table, fn(t, g) {
      summary.row(t, [
        houdini.escape(g.identity),
        int.to_string(g.count) <> " (" <> houdini.escape(g.note) <> ")",
      ])
    })

  let elements =
    elements
    |> summary.h2("Commits")
    |> summary.table(table)

  // The job summary table is HTML, where Markdown footnote syntax is not processed, so the
  // marker is the bare emoji and the footnote is a plain line.
  use <- bool.guard(!list.any(groups, is_flagged), return: elements)

  elements
  |> summary.raw(format.ai_signoff_marker <> " " <> format.ai_signoff_footnote)
  |> summary.eol
}

fn build_failure_message(summary: DcoSummary) -> String {
  let total = summary.failed + summary.invalid
  case total {
    1 -> "1 commit has DCO issues."
    n -> int.to_string(n) <> " commits have DCO issues."
  }
}

/// The "Problem" text for a failed commit. `escape` makes the dynamic parts (identities,
/// sign-off values) safe for the surface: `format.escape_markdown` for the Markdown PR
/// comment, `function.identity` for the HTML job summary. The whole message is then
/// HTML-escaped once.
fn format_disposition(
  record: DcoRecord,
  escape escape: fn(String) -> String,
) -> String {
  // Identities render as `Name <email>`; escape so the angle brackets survive
  // in both the HTML job summary and the Markdown PR comment.
  houdini.escape(case record.disposition {
    NoSignoffs -> "No Signed-off-by trailer found."
    NoMatch(expected:, found:) ->
      "Expected "
      <> list.map(expected, fn(id) { escape(format.signoff_masked(id)) })
      |> string.join(" or ")
      <> ", found "
      <> list.map(found, fn(id) { escape(format.signoff_masked(id)) })
      |> string.join(", ")
    InvalidCommit -> "No valid commit identity."
    AiSignoffRejected(agents:) ->
      format.describe_ai_signoff_rejected(
        list.map(agents, fn(match) { escape(format.ai_match_masked(match)) }),
      )
    AiCoAuthorRejected(agents:) ->
      format.describe_ai_co_author_rejected(
        list.map(agents, fn(match) { escape(format.ai_match_masked(match)) }),
      )
    AiTraceRejected(agents:) ->
      format.describe_ai_trace_rejected(
        list.map(agents, fn(match) { escape(format.ai_match_masked(match)) }),
      )
    _ -> ""
  })
}

/// Write a job summary for internal errors (decode failures, etc.) with
/// guidance pointing the user to report the issue.
fn write_error_summary(err: DcoCheckActionError) -> Nil {
  case err {
    DcoCheckError(error.ResponseDecodeError(decode_err)) -> {
      let error_detail =
        error.describe_error(error.ResponseDecodeError(decode_err))
      let search_query = decode_error_search_query(decode_err)
      let search_url =
        "https://github.com/KineticCafe/actions-dco/issues?q=is%3Aissue+"
        <> uri.percent_encode(search_query)
      let new_issue_url =
        "https://github.com/KineticCafe/actions-dco/issues/new?title="
        <> uri.percent_encode("Decode error: " <> search_query)

      let elements =
        summary.new()
        |> summary.h1("❌ Internal Error")
        |> summary.raw(
          "The commit comparison response could not be decoded. This is probably a bug in `actions-dco`, not a problem with your pull request.",
        )
        |> summary.eol
        |> summary.eol
        |> summary.raw("**Error:**")
        |> summary.eol
        |> summary.raw("```")
        |> summary.eol
        |> summary.raw(error_detail)
        |> summary.eol
        |> summary.raw("```")
        |> summary.eol
        |> summary.eol
        |> summary.raw(
          "[Search existing issues]("
          <> search_url
          <> ")"
          <> " · "
          <> "[File a new issue]("
          <> new_issue_url
          <> ")",
        )
        |> summary.eol

      summary.overwrite(elements)
      |> result.map(fn(_) { Nil })
      |> result.unwrap(Nil)
    }
    _ -> Nil
  }
}

/// Extract a short, searchable string from a decode error for issue deduplication.
fn decode_error_search_query(err: json.DecodeError) -> String {
  case err {
    json.UnexpectedEndOfInput -> "unexpected end of input"
    json.UnexpectedByte(byte) -> "unexpected byte " <> byte
    json.UnexpectedSequence(seq) -> "unexpected sequence " <> seq
    json.UnableToDecode(errors) ->
      case errors {
        [first, ..] -> {
          let path = case first.path {
            [] -> ""
            segments -> " at " <> string.join(segments, ".")
          }
          "expected " <> first.expected <> ", got " <> first.found <> path
        }
        [] -> "unable to decode"
      }
  }
}

fn describe_error(err: DcoCheckActionError) -> String {
  case err {
    DcoCheckError(e) -> error.describe_error(e)
    ContextError(e) -> context.describe_error(e)
    SummaryError(e) -> "Summary write error: " <> pontil_core.describe_error(e)
    ConfigConflict(path:) ->
      "The 'config' input is not allowed because a default branch config file exists ("
      <> path
      <> "). DCO policy is read from the default branch; remove the 'config' input from the workflow."
    RemovedInputsSet(inputs) ->
      list.map(inputs, describe_removed_input) |> string.join("\n")
  }
}
