//// Developer Certificate of Origin Check for GitHub Actions
////
//// Enforce the presence of commit sign-offs on pull requests, indicating that the
//// contributor to a project certifies that they are permitted to contribute to the
//// project. The sign-off line represents certification of the
//// [Developer Certificate of Origin][dco].
////
//// [dco]: https://developercertificate.org

import dco_check/config.{type Config, type Exemptions, AiSignoffRequireHuman}
import dco_check/format
import dco_check/internal/ai_agents
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
import gleam/result
import gleam/string
import pontil

pub const package_name = "KineticCafe/dco-check"

pub const package_version = "4.0.1"

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

  // Build the AI agent registries once for the whole run. The full registry decides
  // Signed-off-by handling and bot exclusion; the relaxed one, omitting
  // `ai.ignore-agents`, is used by the Co-authored-by and trace checks.
  let registries =
    Registries(
      full: config.ai_registry(config),
      relaxed: config.ai_relaxed_registry(config),
    )

  pontil.debug("get_dco_status: starting evaluate_commit map")

  let records =
    list.map(commits, fn(commit) {
      evaluate_commit(commit:, url:, config:, registries:)
    })

  pontil.debug("get_dco_status: evaluate_commit map complete, building summary")

  let summary = build_summary(records:, total:, count:)

  pontil.debug("get_dco_status: done")

  #(summary, records)
}

/// The AI agent registries for a run.
type Registries {
  Registries(full: ai_agents.Registry, relaxed: ai_agents.Registry)
}

/// Process a single commit through the DCO pipeline.
///
/// Stage order matters: the AI checks run first so that no exemption (merge, bot, author
/// email) can rescue a commit they reject.
fn evaluate_commit(
  commit commit: github_types.Commit,
  url url: String,
  config config: Config,
  registries registries: Registries,
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
      subject: format.subject(git_commit.message),
      author:,
      committer:,
      identities: resolve_identities([author, committer]),
      ignored_ai_signoffs: [],
      disposition: t.Unprocessed,
    )

  // Parse trailers once for the entire pipeline.
  let parsed_trailers =
    trailers.parse(git_commit.message, trailer_mode(config.trailer_parsing))

  pontil.debug("evaluate_commit: entering pipeline")

  use record <- check_ai_signoff(
    record,
    parsed_trailers,
    config,
    registries.full,
  )
  use record <- check_ai_co_author(
    record,
    parsed_trailers,
    config,
    registries.relaxed,
  )
  use record <- check_ai_trace(
    record,
    parsed_trailers,
    config,
    registries.relaxed,
  )
  use record <- check_merge(commit, record, parsed_trailers)
  use record <- check_bot(commit, record, config, registries.full)
  use record <- check_identities(record)

  check_signoffs(
    record:,
    trailers: parsed_trailers,
    exemptions: config.exempt_authors,
    aliases: config.aliases,
    registry: registries.full,
  )
}

/// A Signed-off-by with a known AI agent fails commit validation.
///
/// DCO is about human authorship and responsibility, and AI agents have no legal
/// authorship or responsiblity to claim.
///
/// The _only_ exception is with the configuration option `ai.signed-off-by` set to
/// `"require-human"`. When this setting is enabled, the commit validation failure will be
/// changed to a warning _if_ there is a matching human author or committer sign-off.
fn check_ai_signoff(
  record: DcoRecord,
  parsed_trailers: List(#(String, String)),
  config: Config,
  registry: ai_agents.Registry,
  continue: fn(DcoRecord) -> DcoRecord,
) -> DcoRecord {
  case ai_matches(trailers: parsed_trailers, key: "signed-off-by", registry:) {
    [] -> continue(record)
    agents -> {
      let tolerated =
        config.ai.signed_off_by == AiSignoffRequireHuman
        && has_human_signoff(
          record:,
          trailers: parsed_trailers,
          config:,
          registry:,
        )

      use <- bool.lazy_guard(tolerated, return: fn() {
        pontil.warning(
          "commit "
          <> record.sha
          <> ": ignoring Signed-off-by from AI agent "
          <> agent_names(agents)
          <> " because a human sign-off is present"
          <> " (ai.signed-off-by = \"require-human\")."
          <> " An AI agent cannot certify the DCO.",
        )
        continue(t.DcoRecord(..record, ignored_ai_signoffs: agents))
      })

      pontil.debug(
        "commit " <> record.sha <> ": Signed-off-by names an AI agent. Failed.",
      )
      t.DcoRecord(..record, disposition: t.AiSignoffRejected(agents:))
    }
  }
}

fn agent_names(agents: List(t.AiMatch)) -> String {
  list.map(agents, fn(a) { a.agent }) |> list.unique |> string.join(", ")
}

/// Whether a non-AI Signed-off-by matches the commit's author or committer. Exemptions are
/// deliberately not considered: only a human sign-off counts as a human certifying.
fn has_human_signoff(
  record record: DcoRecord,
  trailers parsed_trailers: List(#(String, String)),
  config config: Config,
  registry registry: ai_agents.Registry,
) -> Bool {
  get_commit_signoffs(sha: record.sha, trailers: parsed_trailers)
  |> list.filter(fn(signoff) {
    result.is_error(ai_agents.match_email(registry:, email: signoff.email))
  })
  |> list.any(fn(signoff) {
    list.any(record.identities, fn(id) {
      identity_matches(signoff:, id:, aliases: config.aliases)
    })
  })
}

/// `ai.co-authored-by`: a Co-authored-by naming a known AI agent (other than one in
/// `ai.ignore-agents`) is ignored, warned about, or fails the commit. Off by default.
///
/// The agent assisted; it should be attributed with Assisted-by.
fn check_ai_co_author(
  record: DcoRecord,
  parsed_trailers: List(#(String, String)),
  config: Config,
  registry: ai_agents.Registry,
  continue: fn(DcoRecord) -> DcoRecord,
) -> DcoRecord {
  use <- bool.guard(
    config.ai.co_authored_by == config.AiIgnore,
    return: continue(record),
  )

  case ai_matches(trailers: parsed_trailers, key: "co-authored-by", registry:) {
    [] -> continue(record)
    agents ->
      case config.ai.co_authored_by {
        config.AiReject -> {
          pontil.debug(
            "commit "
            <> record.sha
            <> ": Co-authored-by names an AI agent. Failed.",
          )
          t.DcoRecord(..record, disposition: t.AiCoAuthorRejected(agents:))
        }
        _ -> {
          pontil.warning(
            "commit "
            <> record.sha
            <> ": Co-authored-by names AI agent "
            <> agent_names(agents)
            <> ". "
            <> format.assisted_by_advice,
          )
          continue(record)
        }
      }
  }
}

/// `ai.trace-detection`: when the commit's author or committer is a known AI agent (other
/// than one in `ai.ignore-agents`) and the commit carries no Assisted-by trailer, the
/// commit is warned about or fails. Off by default.
fn check_ai_trace(
  record: DcoRecord,
  parsed_trailers: List(#(String, String)),
  config: Config,
  registry: ai_agents.Registry,
  continue: fn(DcoRecord) -> DcoRecord,
) -> DcoRecord {
  use <- bool.guard(
    config.ai.trace_detection == config.AiIgnore,
    return: continue(record),
  )
  use <- bool.guard(
    list.any(parsed_trailers, fn(trailer) { trailer.0 == "assisted-by" }),
    return: continue(record),
  )

  let agents =
    [record.author, record.committer]
    |> list.filter_map(fn(user) {
      case user {
        Some(github_types.GitUser(email: Some(email_addr), name:, ..)) ->
          ai_agents.match_email(registry:, email: email_addr)
          |> result.map(fn(agent) {
            t.AiMatch(
              agent:,
              identity: option.unwrap(name, "") <> " <" <> email_addr <> ">",
            )
          })
        _ -> Error(Nil)
      }
    })
    |> list.unique

  case agents, config.ai.trace_detection {
    [], _ -> continue(record)
    _, config.AiReject -> {
      pontil.debug(
        "commit "
        <> record.sha
        <> ": author or committer is an AI agent and there is no Assisted-by. Failed.",
      )
      t.DcoRecord(..record, disposition: t.AiTraceRejected(agents:))
    }
    _, _ -> {
      pontil.warning(
        "commit "
        <> record.sha
        <> ": author or committer is AI agent "
        <> agent_names(agents)
        <> " and the commit has no Assisted-by trailer. "
        <> format.assisted_by_advice,
      )
      continue(record)
    }
  }
}

/// Trailers with the given (lowercase) key whose identity is in the AI agent registry.
fn ai_matches(
  trailers parsed_trailers: List(#(String, String)),
  key key: String,
  registry registry: ai_agents.Registry,
) -> List(t.AiMatch) {
  list.filter_map(parsed_trailers, fn(trailer) {
    let #(trailer_key, value) = trailer
    use <- bool.guard(trailer_key != key, return: Error(Nil))
    ai_agents.match_identity(registry:, value:)
    |> result.map(fn(agent) { t.AiMatch(agent:, identity: value) })
  })
}

/// A merge commit with no Signed-off-by auto-passes. A merge commit that carries a
/// Signed-off-by (`git merge --signoff`) is validated like any other commit. Other
/// trailers (ticket IDs, review tools) do not count.
fn check_merge(
  commit: github_types.Commit,
  record: DcoRecord,
  parsed_trailers: List(#(String, String)),
  continue: fn(DcoRecord) -> DcoRecord,
) -> DcoRecord {
  let has_signoff =
    list.any(parsed_trailers, fn(trailer) { trailer.0 == "signed-off-by" })

  case commit.parents, has_signoff {
    [_, _, ..], False -> {
      pontil.debug(
        "commit " <> record.sha <> ": merge commit without sign-off, passing",
      )
      t.DcoRecord(..record, disposition: t.MergeCommit)
    }
    [_, _, ..], True -> {
      pontil.debug(
        "commit " <> record.sha <> ": merge commit with sign-off, checking",
      )
      continue(record)
    }
    _, _ -> continue(record)
  }
}

/// Decide whether a bot-authored commit needs a sign-off. A bot is exempt when it is in
/// `bots.allow` (always, even an AI bot) or, failing that, when it is not in a
/// `bots.exclude-categories` category and the bot policy allows it. A non-exempt bot
/// commit falls through to normal sign-off matching. The AI checks have already run;
/// `bots.allow` does not affect them.
fn check_bot(
  commit: github_types.Commit,
  record: DcoRecord,
  config: Config,
  registry: ai_agents.Registry,
  continue: fn(DcoRecord) -> DcoRecord,
) -> DcoRecord {
  case commit.author {
    Some(github_types.CommitAuthorSimpleUser(github_types.SimpleUser(
      type_: "Bot",
      login:,
      name:,
      email:,
      ..,
    ))) -> {
      let exempt =
        bots.is_bot_exempt(
          login:,
          policy: config.bots,
          allow: config.bot_allow,
          exclude: config.bot_exclude,
          registry:,
        )

      use <- bool.lazy_guard(bool.negate(exempt), return: fn() {
        pontil.debug(bot_denied_message(
          sha: record.sha,
          login:,
          config:,
          registry:,
        ))
        continue(record)
      })

      pontil.debug("commit " <> record.sha <> ": skipping exempt bot " <> login)
      t.DcoRecord(..record, disposition: t.BotCommit(login:, name:, email:))
    }
    _ -> continue(record)
  }
}

fn bot_denied_message(
  sha sha: String,
  login login: String,
  config config: Config,
  registry registry: ai_agents.Registry,
) -> String {
  let reason = case
    bots.excluded_category(login:, exclude: config.bot_exclude, registry:)
  {
    Ok(category) -> "is in excluded category " <> config.category_name(category)
    Error(Nil) -> "not in exempt list"
  }
  "commit "
  <> sha
  <> ": bot "
  <> login
  <> " "
  <> reason
  <> ", requiring sign-off"
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
  registry registry: ai_agents.Registry,
) -> DcoRecord {
  // Filter out AI agent sign-offs.
  let signoffs =
    get_commit_signoffs(sha: record.sha, trailers: parsed_trailers)
    |> list.filter(fn(signoff) {
      result.is_error(ai_agents.match_email(registry:, email: signoff.email))
    })

  case signoffs {
    [] -> check_exemption(record:, exemptions:, aliases:)
    signoffs -> match_signoffs(record:, signoffs:, aliases:)
  }
}

/// No signoffs found — check if author is exempt, otherwise fail.
fn check_exemption(
  record record: DcoRecord,
  exemptions exemptions: Exemptions,
  aliases aliases: dict.Dict(String, List(String)),
) -> DcoRecord {
  case find_author_exemption(record:, exemptions:, aliases:) {
    Some(#(identity, match, alias)) ->
      t.DcoRecord(..record, disposition: t.Exempted(identity:, match:, alias:))
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
    list.find(identities, fn(id) {
      list.any(signoffs, fn(signoff) {
        identity_matches(signoff:, id:, aliases:)
      })
    })

  case matched {
    Ok(identity) -> t.DcoRecord(..record, disposition: t.Passed(identity:))
    Error(Nil) -> {
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

/// Check if the commit author is exempt. The author's own email is tried first, then each
/// of its `alias-signoffs.aliases` addresses (one hop; aliases do not chain). Only the
/// author's aliases count, never the committer's. Returns the author identity, how it
/// matched, and the alias address when the match came through an alias.
pub fn find_author_exemption(
  record record: DcoRecord,
  exemptions exemptions: Exemptions,
  aliases aliases: dict.Dict(String, List(String)),
) -> Option(#(Identity, ExemptionMatch, Option(String))) {
  case record.identities, record.author {
    [], _ -> None
    _, Some(github_types.GitUser(email: Some(email_addr), name: Some(name), ..))
    ->
      find_identity_exemption(
        sha: record.sha,
        identity: t.Identity(name:, email: email_addr),
        exemptions:,
        aliases:,
      )
    _, _ -> None
  }
}

fn find_identity_exemption(
  sha sha: String,
  identity identity: Identity,
  exemptions exemptions: Exemptions,
  aliases aliases: dict.Dict(String, List(String)),
) -> Option(#(Identity, ExemptionMatch, Option(String))) {
  use <- option.lazy_or(
    find_email_exemption(sha:, email: identity.email, exemptions:)
    |> option.map(fn(match) { #(identity, match, None) }),
  )

  dict.get(aliases, string.lowercase(identity.email))
  |> result.unwrap([])
  |> list.find_map(fn(alias) {
    find_email_exemption(sha:, email: alias, exemptions:)
    |> option.map(fn(match) { #(identity, match, Some(alias)) })
    |> option.to_result(Nil)
  })
  |> option.from_result
}

fn find_email_exemption(
  sha sha: String,
  email email_addr: String,
  exemptions exemptions: Exemptions,
) -> Option(ExemptionMatch) {
  // Email addresses are compared case-insensitively.
  let email = string.lowercase(email_addr)

  case list.any(exemptions.exact, fn(v) { string.lowercase(v) == email }) {
    True -> {
      pontil.debug(
        sha <> ": author '" <> email_addr <> "' exempt from DCO by exact match",
      )
      Some(t.ExactEmail)
    }
    False ->
      case
        list.find(exemptions.ends_with, fn(v) {
          string.ends_with(email, string.lowercase(v))
        })
      {
        Ok(pattern) -> {
          pontil.debug(
            sha
            <> ": author '"
            <> email_addr
            <> "' exempt from DCO by domain match",
          )
          Some(t.DomainPattern(pattern))
        }
        Error(Nil) -> None
      }
  }
}

/// Build identities from author/committer, keeping only complete pairs.
/// Exact duplicates (author == committer) are dropped.
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
  |> list.unique
}

/// Build summary counts from the processed records. AI rejections count as failures.
pub fn build_summary(
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
        t.Passed(..) -> t.DcoSummary(..summary, passed: summary.passed + 1)
        t.NoSignoffs
        | t.NoMatch(..)
        | t.AiSignoffRejected(..)
        | t.AiCoAuthorRejected(..)
        | t.AiTraceRejected(..) ->
          t.DcoSummary(..summary, failed: summary.failed + 1)
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

fn trailer_mode(parsing: config.TrailerParsing) -> trailers.Mode {
  case parsing {
    config.Strict -> trailers.Strict
    config.Lenient -> trailers.Lenient
  }
}
