//// CLI entrypoint for DCO check.
////
//// Two modes:
//// - Fixture: reads a saved commit comparison JSON file (no network)
//// - Live: calls the GitHub API via fetch (requires token)

import argv
import dco_check
import dco_check/config
import dco_check/error
import dco_check/pipeline
import dco_check/types.{type DcoRecord, type DcoSummary}
import dco_check_cli/fixture_transport
import envoy
import gleam/dict
import gleam/int
import gleam/io
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/result
import gleam/string
import oaspec/fetch
import oaspec/transport
import pontil
import pontil/summary

/// CLI-specific error type. Everything propagates up to main.
pub type DcoCheckCliError {
  DcoCheckError(error.DcoCheckError)
  DcoCheckFailed(summary: DcoSummary, records: List(DcoRecord))
  SetupError(String)
}

pub fn main() -> Nil {
  pontil.set_output_mode(pontil.ansi_mode())

  promise.map(setup_and_run(), fn(result) {
    case result {
      Ok(#(summary, records)) -> {
        print_results(summary, records)
        Nil
      }
      Error(DcoCheckFailed(summary:, records:)) -> {
        print_results(summary, records)
        pontil.set_exit_code(pontil.Failure)
      }
      Error(err) -> {
        io.println_error("Error: " <> describe_error(err))
        pontil.set_exit_code(pontil.Failure)
      }
    }
  })

  Nil
}

fn setup_and_run() -> Promise(
  Result(#(DcoSummary, List(DcoRecord)), DcoCheckCliError),
) {
  use #(send, owner, repo, basehead, cfg) <- pontil.try_sync(setup())

  pipeline.run(send:, owner:, repo:, basehead:, config: cfg)
  |> promise.map(fn(result) {
    case result {
      Ok(#(summary, records)) if summary.failed > 0 || summary.invalid > 0 ->
        Error(DcoCheckFailed(summary:, records:))
      Ok(result) -> Ok(result)

      Error(err) -> Error(DcoCheckError(err))
    }
  })
}

/// Synchronous setup: determine mode, build send, validate args, load config.
fn setup() -> Result(
  #(transport.AsyncSend, String, String, String, config.Config),
  DcoCheckCliError,
) {
  let #(config_path, args) = extract_config_flag(argv.load().arguments)

  use cfg <- result.try(case config_path {
    "" -> Ok(config.default())
    path ->
      config.load(path)
      |> result.map_error(DcoCheckError)
  })

  case args {
    ["fixture", path] -> {
      fixture_transport.install(path)
      let send = fetch.send |> transport.with_base_url("https://api.github.com")
      Ok(#(send, "fixture", "fixture", "x...x", cfg))
    }
    ["live", repo_arg, basehead] -> {
      use token <- result.try(
        github_token()
        |> result.replace_error(SetupError(
          "GITHUB_TOKEN or GH_TOKEN environment variable required",
        )),
      )
      case string.split(repo_arg, "/") {
        [owner, repo] -> {
          let send =
            fetch.send
            |> pipeline.with_auth(token:)
            |> transport.with_base_url("https://api.github.com")
          Ok(#(send, owner, repo, basehead, cfg))
        }
        _ ->
          Error(SetupError("repo must be owner/repo format, got: " <> repo_arg))
      }
    }
    _ ->
      Error(SetupError(
        "Usage:\n  dco_check_cli [--config <path>] fixture <path-to-compare.json>\n  dco_check_cli [--config <path>] live <owner/repo> <base...head>",
      ))
  }
}

fn print_results(dco_summary: DcoSummary, records: List(DcoRecord)) -> Nil {
  let has_failures = dco_summary.failed > 0 || dco_summary.invalid > 0

  let heading = case has_failures {
    True -> "❌ DCO Check Failed"
    False -> "✅ DCO Check Passed"
  }

  let elements =
    summary.new()
    |> summary.h2(heading)

  let elements = case dco_summary.truncated {
    True ->
      elements
      |> summary.raw(
        "⚠️  Evaluated "
        <> int.to_string(dco_summary.evaluated)
        <> " of "
        <> int.to_string(dco_summary.total_commits)
        <> " commits (GitHub API limit).",
      )
      |> summary.eol
    False -> elements
  }

  let failures = failure_records(records)

  let elements = case failures {
    [] -> elements
    _ -> {
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
        |> summary.h3("Issues")
        |> summary.table(table)

      case list.length(failures) > 20 {
        True ->
          elements
          |> summary.raw(
            "…and "
            <> int.to_string(list.length(failures) - 20)
            <> " more. Consider `git rebase --signoff`.",
          )
          |> summary.eol
        False -> elements
      }
    }
  }

  let groups = build_success_groups(records, dict.new(), [])

  let elements = case groups {
    [] -> elements
    _ -> {
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
      |> summary.h3("Commits")
      |> summary.table(table)
    }
  }

  elements
  |> summary.to_ansi()
  |> io.print
}

/// A grouped success entry: identity label, count, and note.
type SuccessGroup {
  SuccessGroup(identity: String, count: Int, note: String)
}

fn failure_records(records: List(DcoRecord)) -> List(DcoRecord) {
  list.filter(records, fn(r) {
    case r.disposition {
      types.NoSignoffs | types.NoMatch(..) | types.InvalidCommit -> True
      _ -> False
    }
  })
}

fn build_success_groups(
  records: List(DcoRecord),
  counts: dict.Dict(String, Int),
  order: List(SuccessGroup),
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
        Ok(group) -> {
          let key = group.identity <> "|" <> group.note
          let new_count = { dict.get(counts, key) |> result.unwrap(0) } + 1
          let new_counts = dict.insert(counts, key, new_count)
          let new_order = case dict.has_key(counts, key) {
            True -> order
            False -> [group, ..order]
          }
          build_success_groups(rest, new_counts, new_order)
        }
        Error(Nil) -> build_success_groups(rest, counts, order)
      }
    }
  }
}

fn success_group_for(record: DcoRecord) -> Result(SuccessGroup, Nil) {
  case record.disposition {
    types.Passed -> {
      let identity = case record.identities {
        [id, ..] -> id.name <> " <" <> id.email <> ">"
        [] -> "unknown"
      }
      Ok(SuccessGroup(identity:, count: 1, note: "signed off"))
    }
    types.Exempted(identity:, match:) -> {
      let label = identity.name <> " <" <> identity.email <> ">"
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

fn format_disposition(record: DcoRecord) -> String {
  case record.disposition {
    types.NoSignoffs -> "No Signed-off-by trailer found."
    types.NoMatch(expected:, found:) ->
      "Expected "
      <> list.map(expected, dco_check.format_signoff) |> string.join(" or ")
      <> ", found "
      <> list.map(found, dco_check.format_signoff) |> string.join(", ")
    types.InvalidCommit -> "No valid commit identity."
    _ -> ""
  }
}

fn describe_error(err: DcoCheckCliError) -> String {
  case err {
    DcoCheckError(e) -> error.describe_error(e)
    DcoCheckFailed(..) -> "DCO check failed"
    SetupError(msg) -> msg
  }
}

fn extract_config_flag(args: List(String)) -> #(String, List(String)) {
  case args {
    ["--config", path, ..rest] -> #(path, rest)
    _ -> #("", args)
  }
}

fn github_token() -> Result(String, Nil) {
  envoy.get("GITHUB_TOKEN")
  |> result.lazy_or(fn() { envoy.get("GH_TOKEN") })
}
