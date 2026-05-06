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
import gleam/int
import gleam/io
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/result
import gleam/string
import oaspec/fetch
import oaspec/transport
import pontil

/// CLI-specific error type. Everything propagates up to main.
pub type DcoCheckCliError {
  DcoCheckError(error.DcoCheckError)
  DcoCheckFailed(summary: DcoSummary, records: List(DcoRecord))
  SetupError(String)
}

pub fn main() -> Nil {
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
  use #(send, owner, repo, basehead, cfg) <- pontil.try_promise(setup())

  pipeline.run(send:, owner:, repo:, basehead:, config: cfg)
  |> promise.map(fn(result) {
    case result {
      Ok(#(summary, records)) if summary.failed > 0 || summary.invalid == 0 ->
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

fn print_results(summary: DcoSummary, records: List(DcoRecord)) -> Nil {
  case summary.truncated {
    True ->
      io.println(
        "⚠ Evaluated "
        <> int.to_string(summary.evaluated)
        <> " of "
        <> int.to_string(summary.total_commits)
        <> " commits (GitHub API limit; not paginated).",
      )
    False -> Nil
  }

  io.println(
    int.to_string(summary.passed)
    <> " passed, "
    <> int.to_string(summary.failed)
    <> " failed, "
    <> int.to_string(summary.invalid)
    <> " invalid, "
    <> int.to_string(summary.exempted)
    <> " exempted, "
    <> int.to_string(summary.skipped_merge + summary.skipped_bot)
    <> " skipped.",
  )

  records
  |> list.filter(fn(r) {
    case r.disposition {
      types.NoSignoffs | types.NoMatch(..) | types.InvalidCommit -> True
      _ -> False
    }
  })
  |> list.each(fn(r) {
    io.println("  ✗ " <> r.sha <> " — " <> format_disposition(r))
  })
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
