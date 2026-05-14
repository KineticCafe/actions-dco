//// Developer Certificate of Origin Check for GitHub Actions
////
//// Enforce the presence of commit sign-offs on pull requests, indicating that the
//// contributor to a project certifies that they are permitted to contribute to the
//// project. The sign-off line represents certification of the
//// [Developer Certificate of Origin][dco].
////
//// [dco]: https://developercertificate.org

import dco_check/config.{type Config, type Exemptions}
import dco_check/internal/bots
import dco_check/internal/email
import dco_check/internal/github/types as github_types
import dco_check/internal/trailers
import dco_check/types.{
  type DcoRecord, type DcoSummary, type ExemptionMatch, type Identity,
} as t
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import houdini
import pontil

pub const package_name = "KineticCafe/dco-check"

pub const package_version = "3.1.0"

/// Evaluate DCO status for a list of commits.
///
/// Returns a summary and the ordered list of records.
pub fn get_dco_status(
  commits commits: List(github_types.Commit),
  url url: String,
  config config: Config,
  total total: Int,
) -> #(DcoSummary, List(DcoRecord)) {
  let exemptions = config.exempt_authors

  pontil.debug(
    "get_dco_status(<"
    <> int.to_string(list.length(commits))
    <> " commits>, "
    <> url
    <> ", <"
    <> int.to_string(list.length(exemptions.exact))
    <> " exact, "
    <> int.to_string(list.length(exemptions.ends_with))
    <> " ends_with exemptions>)",
  )

  let count = list.length(commits)

  pontil.debug("get_dco_status: starting evaluate_commit map")

  let records =
    list.map(commits, fn(commit) { evaluate_commit(commit:, url:, config:) })

  pontil.debug("get_dco_status: evaluate_commit map complete, building summary")

  let summary = build_summary(records:, total:, count:)

  pontil.debug("get_dco_status: done")

  #(summary, records)
}

/// Process a single commit through the DCO pipeline.
fn evaluate_commit(
  commit commit: github_types.Commit,
  url url: String,
  config config: Config,
) -> DcoRecord {
  let git_commit = commit.commit
  let sha = commit.sha

  pontil.debug("evaluate_commit: start " <> sha)

  let author = case git_commit.author {
    Some(github_types.CommitCommitAuthor(user)) -> user
    _ -> None
  }

  let committer = case git_commit.committer {
    Some(github_types.CommitCommitCommitter(user)) -> user
    _ -> None
  }

  let record =
    t.DcoRecord(
      sha:,
      url: url <> "/commits/" <> sha,
      subject: commit_subject(git_commit.message),
      author:,
      committer:,
      identities: resolve_identities([author, committer]),
      disposition: t.Unprocessed,
    )

  // Parse trailers once for the entire pipeline.
  let parsed_trailers =
    trailers.parse(git_commit.message, trailer_mode(config.trailer_parsing))

  pontil.debug("evaluate_commit: entering pipeline")

  use record <- check_merge(commit, record)
  use record <- check_bot(commit, record, config, parsed_trailers)
  use record <- check_identities(record)

  check_signoffs(
    record:,
    trailers: parsed_trailers,
    exemptions: config.exempt_authors,
    aliases: config.aliases,
  )
}

/// If merge commit, resolve immediately.
fn check_merge(
  commit: github_types.Commit,
  record: DcoRecord,
  continue: fn(DcoRecord) -> DcoRecord,
) -> DcoRecord {
  case commit.parents {
    [_, _, ..] -> {
      pontil.debug("commit " <> record.sha <> ": skipping merge commit")
      t.DcoRecord(..record, disposition: t.MergeCommit)
    }
    _ -> continue(record)
  }
}

/// If bot commit from an allowed bot, resolve immediately.
/// Checks against the configured bot policy and AI trailer detection.
fn check_bot(
  commit: github_types.Commit,
  record: DcoRecord,
  config: Config,
  parsed_trailers: List(#(String, String)),
  continue: fn(DcoRecord) -> DcoRecord,
) -> DcoRecord {
  case commit.author {
    github_types.CommitAuthorSimpleUser(github_types.SimpleUser(
      type_: "Bot",
      login:,
      name:,
      email:,
      ..,
    )) -> {
      case bots.is_bot_exempt(login, config.bots) {
        False -> {
          pontil.debug(
            "commit "
            <> record.sha
            <> ": bot "
            <> login
            <> " not in exempt list, requiring sign-off",
          )
          continue(record)
        }
        True ->
          check_bot_ai(
            record:,
            config:,
            parsed_trailers:,
            login:,
            name:,
            email:,
            continue:,
          )
      }
    }
    _ -> continue(record)
  }
}

fn check_bot_ai(
  record record: DcoRecord,
  config config: Config,
  parsed_trailers parsed_trailers: List(#(String, String)),
  login login: String,
  name name: Option(String),
  email email: Option(String),
  continue continue: fn(DcoRecord) -> DcoRecord,
) -> DcoRecord {
  // Short-circuit: skip AI check entirely when disabled
  use <- bool.guard(bool.negate(config.ai_detection), return: {
    pontil.debug("commit " <> record.sha <> ": skipping exempt bot " <> login)
    t.DcoRecord(..record, disposition: t.BotCommit(login:, name:, email:))
  })

  case bots.has_ai_attribution(parsed_trailers) {
    True -> {
      pontil.warning(
        "commit "
        <> record.sha
        <> ": AI attribution detected on bot commit "
        <> login
        <> ", requiring sign-off",
      )
      continue(record)
    }
    False -> {
      pontil.debug("commit " <> record.sha <> ": skipping exempt bot " <> login)
      t.DcoRecord(..record, disposition: t.BotCommit(login:, name:, email:))
    }
  }
}

/// If no valid identities can be derived, fail immediately.
fn check_identities(
  record: DcoRecord,
  continue: fn(DcoRecord) -> DcoRecord,
) -> DcoRecord {
  case record.identities {
    [] -> {
      pontil.debug(
        "commit "
        <> record.sha
        <> ": no valid commit identity (need both name and email on author or committer)",
      )
      t.DcoRecord(..record, disposition: t.InvalidCommit)
    }
    _ -> continue(record)
  }
}

/// Match signoffs from pre-parsed trailers against identities.
fn check_signoffs(
  record record: DcoRecord,
  trailers parsed_trailers: List(#(String, String)),
  exemptions exemptions: Exemptions,
  aliases aliases: dict.Dict(String, List(String)),
) -> DcoRecord {
  case get_commit_signoffs(sha: record.sha, trailers: parsed_trailers) {
    [] -> check_exemption(record:, exemptions:)
    signoffs -> match_signoffs(record:, signoffs:, aliases:)
  }
}

/// No signoffs found — check if author is exempt, otherwise fail.
fn check_exemption(
  record record: DcoRecord,
  exemptions exemptions: Exemptions,
) -> DcoRecord {
  case find_author_exemption(record:, exemptions:) {
    Some(#(identity, match)) ->
      t.DcoRecord(..record, disposition: t.Exempted(identity:, match:))
    None -> t.DcoRecord(..record, disposition: t.NoSignoffs)
  }
}

/// Match parsed signoffs against the commit's valid identities.
/// Precondition: record.identities is non-empty (checked by check_identities).
fn match_signoffs(
  record record: DcoRecord,
  signoffs signoffs: List(Identity),
  aliases aliases: dict.Dict(String, List(String)),
) -> DcoRecord {
  let sha = record.sha
  let identities = record.identities

  let matched =
    list.any(signoffs, fn(signoff) {
      list.any(identities, fn(id) { identity_matches(signoff:, id:, aliases:) })
    })

  case matched {
    True -> t.DcoRecord(..record, disposition: t.Passed)
    False -> {
      pontil.debug("commit " <> sha <> ": no matching sign-off. Failed.")
      t.DcoRecord(
        ..record,
        disposition: t.NoMatch(expected: identities, found: signoffs),
      )
    }
  }
}

/// Case-insensitive match: name must match, email must match directly or via alias.
/// `signoff` is the parsed sign-off identity, `id` is the commit identity.
fn identity_matches(
  signoff signoff: Identity,
  id id: Identity,
  aliases aliases: dict.Dict(String, List(String)),
) -> Bool {
  let name_match = string.lowercase(signoff.name) == string.lowercase(id.name)
  let signoff_email = string.lowercase(signoff.email)
  let id_email = string.lowercase(id.email)

  let email_match = case signoff_email == id_email {
    True -> True
    False ->
      // Check if the signoff email is an accepted alias for this commit identity
      case dict.get(aliases, id_email) {
        Ok(accepted) -> list.contains(accepted, signoff_email)
        Error(Nil) -> False
      }
  }

  name_match && email_match
}

/// Extract valid Signed-off-by identities from pre-parsed trailers.
fn get_commit_signoffs(
  sha sha: String,
  trailers parsed_trailers: List(#(String, String)),
) -> List(Identity) {
  let signoffs =
    parsed_trailers
    |> list.filter_map(fn(trailer) { validate_signoff(sha:, trailer:) })

  pontil.debug(
    "commit "
    <> sha
    <> ": "
    <> int.to_string(list.length(signoffs))
    <> " valid signoff(s) on commit message",
  )

  signoffs
}

fn validate_signoff(
  sha sha: String,
  trailer trailer: #(String, String),
) -> Result(Identity, Nil) {
  case trailer {
    #("signed-off-by", value) ->
      case trailers.parse_identity(value) {
        Ok(#(Some(name), Some(email_addr))) ->
          case email.is_valid(email_addr) {
            True -> Ok(t.Identity(name:, email: email_addr))
            False -> {
              pontil.warning(
                "commit "
                <> sha
                <> ": sign-off email '"
                <> email_addr
                <> "' is not a valid email address",
              )
              Error(Nil)
            }
          }
        Ok(#(None, _)) -> {
          pontil.warning(
            "commit " <> sha <> ": sign-off missing name in '" <> value <> "'",
          )
          Error(Nil)
        }
        Ok(#(_, None)) -> {
          pontil.warning(
            "commit " <> sha <> ": sign-off missing email in '" <> value <> "'",
          )
          Error(Nil)
        }
        Error(_) -> {
          pontil.warning(
            "commit "
            <> sha
            <> ": cannot parse sign-off identity '"
            <> value
            <> "'",
          )
          Error(Nil)
        }
      }
    _ -> Error(Nil)
  }
}

/// Check if the commit author's email matches an exemption pattern.
pub fn find_author_exemption(
  record record: DcoRecord,
  exemptions exemptions: Exemptions,
) -> Option(#(Identity, ExemptionMatch)) {
  case record.identities, record.author {
    [], _ -> None
    _, Some(github_types.GitUser(email: Some(email_addr), name: Some(name), ..))
    ->
      find_email_exemption(
        sha: record.sha,
        identity: t.Identity(name:, email: email_addr),
        exemptions:,
      )
    _, _ -> None
  }
}

fn find_email_exemption(
  sha sha: String,
  identity identity: Identity,
  exemptions exemptions: Exemptions,
) -> Option(#(Identity, ExemptionMatch)) {
  case list.any(exemptions.exact, fn(v) { v == identity.email }) {
    True -> {
      pontil.debug(
        sha
        <> ": author '"
        <> identity.email
        <> "' exempt from DCO by exact match",
      )
      Some(#(identity, t.ExactEmail))
    }
    False ->
      case
        list.find(exemptions.ends_with, fn(v) {
          string.ends_with(identity.email, v)
        })
      {
        Ok(pattern) -> {
          pontil.debug(
            sha
            <> ": author '"
            <> identity.email
            <> "' exempt from DCO by domain match",
          )
          Some(#(identity, t.DomainPattern(pattern)))
        }
        Error(Nil) -> None
      }
  }
}

/// Build identities from author/committer, keeping only complete pairs.
fn resolve_identities(
  candidates: List(Option(github_types.GitUser)),
) -> List(Identity) {
  list.filter_map(candidates, fn(candidate) {
    case candidate {
      Some(github_types.GitUser(email: Some(email_addr), name: Some(name), ..)) ->
        Ok(t.Identity(email: email_addr, name:))
      _ -> Error(Nil)
    }
  })
}

/// Build summary counts from the processed records.
fn build_summary(
  records records: List(DcoRecord),
  total total_commits: Int,
  count evaluated: Int,
) -> DcoSummary {
  list.fold(
    records,
    t.DcoSummary(
      total_commits:,
      evaluated:,
      passed: 0,
      failed: 0,
      invalid: 0,
      exempted: 0,
      skipped_merge: 0,
      skipped_bot: 0,
      truncated: total_commits > evaluated,
    ),
    fn(summary, record) {
      case record.disposition {
        t.Passed -> t.DcoSummary(..summary, passed: summary.passed + 1)
        t.NoSignoffs -> t.DcoSummary(..summary, failed: summary.failed + 1)
        t.NoMatch(..) -> t.DcoSummary(..summary, failed: summary.failed + 1)
        t.InvalidCommit -> t.DcoSummary(..summary, invalid: summary.invalid + 1)
        t.Exempted(..) ->
          t.DcoSummary(..summary, exempted: summary.exempted + 1)
        t.MergeCommit ->
          t.DcoSummary(..summary, skipped_merge: summary.skipped_merge + 1)
        t.BotCommit(..) ->
          t.DcoSummary(..summary, skipped_bot: summary.skipped_bot + 1)
        t.Skipped(_) ->
          t.DcoSummary(..summary, skipped_merge: summary.skipped_merge + 1)
        t.Unprocessed -> summary
      }
    },
  )
}

pub fn format_signoff(identity: Identity) -> String {
  "\"" <> identity.name <> " <" <> identity.email <> ">\""
}

pub fn format_signoff_html(identity: Identity) -> String {
  identity |> format_signoff |> houdini.escape
}

/// Format a signoff identity with the email local part masked for public display.
pub fn format_signoff_masked(identity: Identity) -> String {
  "\"" <> identity.name <> " <" <> mask_email(identity.email) <> ">\""
}

/// Mask the local part of an email: "alice@example.com" -> "al…@example.com"
pub fn mask_email(email: String) -> String {
  case string.split_once(email, "@") {
    Ok(#(local, domain)) -> {
      let len = string.length(local)
      case len {
        1 | 2 -> local <> "…@" <> domain
        _ -> string.slice(local, 0, 2) <> "…@" <> domain
      }
    }
    Error(Nil) -> "…"
  }
}

pub fn format_sha(sha: String) -> String {
  string.slice(sha, 0, 12)
}

/// Extract the subject (first line) from a commit message, truncated to 50 chars.
fn commit_subject(message: String) -> String {
  let subject = case string.split_once(message, "\n") {
    Ok(#(first, _)) -> first
    Error(Nil) -> message
  }
  case string.length(subject) > 50 {
    True -> string.slice(subject, 0, 50) <> "…"
    False -> subject
  }
}

fn trailer_mode(parsing: config.TrailerParsing) -> trailers.Mode {
  case parsing {
    config.Strict -> trailers.Strict
    config.Lenient -> trailers.Lenient
  }
}
