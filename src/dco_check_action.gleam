//// GitHub Action entrypoint for DCO check.
////
//// Pipeline: read inputs -> load config -> call GitHub API -> get_dco_status ->
//// render summary -> write job summary -> optionally comment on PR -> set pass/fail.

import dco_check
import dco_check/config.{Exemptions}
import dco_check/error
import dco_check/pipeline
import dco_check/types.{
  type DcoRecord, type DcoSummary, InvalidCommit, NoMatch, NoSignoffs,
}
import gleam/bool
import gleam/dict
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option
import gleam/result
import gleam/string
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
      Ok(#(summary, records)) -> {
        case write_summary(summary, records) {
          Ok(_) -> Nil
          Error(err) ->
            pontil.warning(
              "Failed to write job summary: " <> pontil_core.describe_error(err),
            )
        }
        case summary.failed > 0 || summary.invalid > 0 {
          True -> pontil.set_failed(build_failure_message(summary))
          False -> pontil.info("DCO check passed.")
        }
      }
      Error(err) -> pontil.set_failed(describe_error(err))
    }
  })

  Nil
}

type DcoCheckActionError {
  DcoCheckError(error.DcoCheckError)
  ContextError(context.PontilContextError)
  SummaryError(pontil_core.PontilCoreError)
}

/// Setup result includes PR number for comment support.
type ActionContext {
  ActionContext(
    send: transport.AsyncSend,
    owner: String,
    repo: String,
    basehead: String,
    pr_number: Int,
    cfg: config.Config,
  )
}

fn run_pipeline() -> Promise(
  Result(#(DcoSummary, List(DcoRecord)), DcoCheckActionError),
) {
  use ctx <- pontil.try_sync(setup())

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
  let body = format_comment_body(summary, records)

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
  summary: DcoSummary,
  records: List(DcoRecord),
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
          <> dco_check.format_sha(r.sha)
          <> "`]("
          <> r.url
          <> ") | "
          <> houdini.escape(r.subject)
          <> " | "
          <> format_disposition(r)
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
          <> g.identity
          <> " | "
          <> int.to_string(g.count)
          <> " ("
          <> g.note
          <> ") |"
        })
        |> string.join("\n")

      "\n\n### Commits\n\n| Identity | Commits |\n|----------|---------|"
      <> "\n"
      <> rows
    }
  }
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
  case record.disposition {
    types.Passed -> {
      let identity = case record.identities {
        [id, ..] -> id.name <> " <" <> dco_check.mask_email(id.email) <> ">"
        [] -> "unknown"
      }
      Ok(SuccessGroup(identity:, count: 1, note: "signed off"))
    }
    types.Exempted(identity:, match:) -> {
      let label =
        identity.name <> " <" <> dco_check.mask_email(identity.email) <> ">"
      let note = case match {
        types.ExactEmail -> "exempt"
        types.DomainPattern(pattern) -> "exempt domain " <> pattern
      }
      Ok(SuccessGroup(identity: label, count: 1, note:))
    }
    types.BotCommit(login:, ..) ->
      Ok(SuccessGroup(identity: login, count: 1, note: "bot, skipped"))
    types.MergeCommit ->
      Ok(SuccessGroup(identity: "merge commits", count: 1, note: "skipped"))
    types.Skipped(reason) ->
      Ok(SuccessGroup(identity: "skipped", count: 1, note: reason))
    _ -> Error(Nil)
  }
}

fn setup() -> Result(ActionContext, DcoCheckActionError) {
  let token = pontil.get_input("repo-token")
  let config_toml = pontil.get_input("config")
  let exempt_authors_input = pontil.get_input("exempt-authors")

  let cfg = case config_toml {
    "" -> load_legacy_inputs(exempt_authors_input)
    toml -> {
      case exempt_authors_input {
        "" -> Nil
        _ ->
          pontil.warning(
            "Both 'config' and 'exempt-authors' inputs provided; 'exempt-authors' is ignored when 'config' is present.",
          )
      }
      case config.parse(toml) {
        Ok(c) -> c
        Error(err) -> {
          pontil.warning("Config parse error: " <> error.describe_error(err))
          config.default()
        }
      }
    }
  }

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
    option.Some(r) -> Ok(r)
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
    cfg:,
  ))
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
  dco_summary: DcoSummary,
  records: List(DcoRecord),
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
      NoSignoffs | NoMatch(..) | InvalidCommit -> True
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
        dco_check.format_sha(r.sha),
        r.subject,
        format_disposition(r),
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
        g.identity,
        int.to_string(g.count) <> " (" <> g.note <> ")",
      ])
    })

  elements
  |> summary.h2("Commits")
  |> summary.table(table)
}

fn build_failure_message(summary: DcoSummary) -> String {
  let total = summary.failed + summary.invalid
  case total {
    1 -> "1 commit has DCO issues."
    n -> int.to_string(n) <> " commits have DCO issues."
  }
}

fn format_disposition(record: DcoRecord) -> String {
  case record.disposition {
    NoSignoffs -> "No Signed-off-by trailer found."
    NoMatch(expected:, found:) ->
      "Expected "
      <> list.map(expected, dco_check.format_signoff_masked)
      |> string.join(" or ")
      <> ", found "
      <> list.map(found, dco_check.format_signoff_masked)
      |> string.join(", ")
    InvalidCommit -> "No valid commit identity."
    _ -> ""
  }
}

fn describe_error(err: DcoCheckActionError) -> String {
  case err {
    DcoCheckError(e) -> error.describe_error(e)
    ContextError(e) -> context.describe_error(e)
    SummaryError(e) -> "Summary write error: " <> pontil_core.describe_error(e)
  }
}

/// Fall back to legacy action inputs (exempt-authors).
fn load_legacy_inputs(exempt_authors_input: String) -> config.Config {
  case exempt_authors_input {
    "" -> {
      pontil.debug("No config or legacy inputs provided, using defaults")
      config.default()
    }
    raw -> {
      pontil.warning(
        "Configuration via the 'exempt-authors' input is deprecated. Use the 'config' input with embedded TOML. See documentation for migration details.",
      )

      let entries =
        string.split(raw, " ")
        |> list.map(string.trim)
        |> list.filter(fn(s) { s != "" })

      let exemptions =
        list.fold(entries, Exemptions(exact: [], ends_with: []), fn(acc, entry) {
          case string.starts_with(entry, "@") {
            True -> Exemptions(..acc, ends_with: [entry, ..acc.ends_with])
            False -> Exemptions(..acc, exact: [entry, ..acc.exact])
          }
        })

      config.Config(..config.default(), exempt_authors: exemptions)
    }
  }
}
