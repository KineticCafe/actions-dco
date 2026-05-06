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
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import oaspec/fetch
import oaspec/transport
import pontil
import pontil/context
import pontil/core as pontil_core
import pontil/summary

pub fn main() -> Nil {
  pontil.info(dco_check.package_name <> " " <> dco_check.package_version)

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
  use ctx <- pontil.try_promise(setup())

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

fn format_comment_body(summary: DcoSummary, records: List(DcoRecord)) -> String {
  let heading = case summary.failed > 0 || summary.invalid > 0 {
    True -> "## DCO Check Failed"
    False -> "## DCO Check Passed ✓"
  }

  let summary_line =
    int.to_string(summary.passed)
    <> " passed, "
    <> int.to_string(summary.failed)
    <> " failed, "
    <> int.to_string(summary.invalid)
    <> " invalid, "
    <> int.to_string(summary.exempted)
    <> " exempted, "
    <> int.to_string(summary.skipped_merge + summary.skipped_bot)
    <> " skipped."

  let failures =
    list.filter(records, fn(r) {
      case r.disposition {
        NoSignoffs | NoMatch(..) | InvalidCommit -> True
        _ -> False
      }
    })

  let failure_table = case failures {
    [] -> ""
    _ -> {
      let capped = list.take(failures, 20)
      let rows =
        list.map(capped, fn(r) {
          "| `"
          <> dco_check.format_sha(r.sha)
          <> "` | "
          <> format_disposition(r)
          <> " |"
        })
        |> string.join("\n")

      let header = "\n| Commit | Reason |\n|--------|--------|\n"
      let overflow = case list.length(failures) > 20 {
        True ->
          "\n\n_and "
          <> int.to_string(list.length(failures) - 20)
          <> " more commits failed. Consider `git rebase --signoff`._"
        False -> ""
      }

      header <> rows <> overflow
    }
  }

  heading <> "\n\n" <> summary_line <> "\n" <> failure_table
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

fn write_summary(
  summary: DcoSummary,
  records: List(DcoRecord),
) -> Result(Nil, pontil_core.PontilCoreError) {
  let heading = case summary.failed > 0 || summary.invalid > 0 {
    True -> "DCO Check Failed"
    False -> "DCO Check Passed"
  }

  let elements =
    summary.new()
    |> summary.h1(heading)
    |> summary.separator

  let summary_line =
    int.to_string(summary.passed)
    <> " passed, "
    <> int.to_string(summary.failed)
    <> " failed, "
    <> int.to_string(summary.invalid)
    <> " invalid, "
    <> int.to_string(summary.exempted)
    <> " exempted, "
    <> int.to_string(summary.skipped_merge + summary.skipped_bot)
    <> " skipped."

  let elements = case summary.truncated {
    True ->
      elements
      |> summary.raw(
        "⚠ Evaluated "
        <> int.to_string(summary.evaluated)
        <> " of "
        <> int.to_string(summary.total_commits)
        <> " commits (GitHub API limit; not paginated).",
      )
      |> summary.eol
    False -> elements
  }

  let elements =
    elements
    |> summary.raw(summary_line)
    |> summary.eol

  let failures =
    list.filter(records, fn(r) {
      case r.disposition {
        NoSignoffs | NoMatch(..) | InvalidCommit -> True
        _ -> False
      }
    })

  let elements = case failures {
    [] -> elements
    _ -> {
      let capped = list.take(failures, 20)
      let table =
        summary.new_table()
        |> summary.header_row(["Commit", "Reason"])

      let table =
        list.fold(capped, table, fn(t, r) {
          summary.row(t, [dco_check.format_sha(r.sha), format_disposition(r)])
        })

      let elements =
        elements
        |> summary.h2("Failed")
        |> summary.table(table)

      case list.length(failures) > 20 {
        True ->
          elements
          |> summary.raw(
            "and "
            <> int.to_string(list.length(failures) - 20)
            <> " more commits failed. Consider `git rebase --signoff`.",
          )
          |> summary.eol
        False -> elements
      }
    }
  }

  summary.overwrite(elements)
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
      <> list.map(expected, dco_check.format_signoff) |> string.join(" or ")
      <> ", found "
      <> list.map(found, dco_check.format_signoff) |> string.join(", ")
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
