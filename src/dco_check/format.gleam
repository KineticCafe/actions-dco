//// Format DCO results for display.

import dco_check/internal/ai_agents
import dco_check/internal/trailers
import dco_check/types.{type AiMatch, type DcoRecord, type Identity}
import gleam/bool
import gleam/option.{None, Some}
import gleam/string

const sha_size = 12

const subject_size = 50

/// The abbreviated form of a commit SHA.
pub fn sha(sha: String) -> String {
  string.slice(sha, 0, sha_size)
}

/// A commit's subject: the first line of its message, truncated to 50 characters.
pub fn subject(message: String) -> String {
  let subject = case string.split_once(message, "\n") {
    Ok(#(first, _)) -> first
    Error(Nil) -> message
  }
  case string.length(subject) > subject_size {
    True -> string.slice(subject, 0, subject_size) <> "…"
    False -> subject
  }
}

/// A sign-off identity as `"Name <email>"`.
pub fn signoff(identity: Identity) -> String {
  "\"" <> identity.name <> " <" <> identity.email <> ">\""
}

/// A sign-off identity with the email masked for public display (see `mask_email`).
pub fn signoff_masked(identity: Identity) -> String {
  "\"" <> identity.name <> " <" <> mask_email(identity.email) <> ">\""
}

/// Mask the local part of a personal email for public display in a comment or job run
/// summary: `alice@example.com` -> `al…@example.com`.
///
/// `noreply` addresses and built-in AI agent addresses are not masked.
pub fn mask_email(email: String) -> String {
  use <- bool.guard(
    is_noreply(email) || ai_agents.is_built_in_email(email),
    return: email,
  )

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

/// Returns `true` if the provided email address looks like a no-reply address
/// (`/\bno-?reply\b/i`), which will be used to suppress email masking.
@external(javascript, "./format_ffi.mjs", "is_noreply")
pub fn is_noreply(email: String) -> Bool

/// An AI match as written in the trailer, e.g. `Claude <noreply@anthropic.com>`. For the
/// CLI, which never masks.
pub fn ai_match(match: AiMatch) -> String {
  match.identity
}

/// An AI match for public output. Built-in agent and no-reply addresses are shown in full;
/// an address added with `ai.extra-agent-emails` is masked like a personal one, since
/// a private agent's address may be someone's own.
pub fn ai_match_masked(match: AiMatch) -> String {
  case trailers.parse_identity(match.identity) {
    Ok(#(Some(name), Some(email))) -> name <> " <" <> mask_email(email) <> ">"
    Ok(#(None, Some(email))) -> "<" <> mask_email(email) <> ">"
    _ -> match.identity
  }
}

/// Failure reason for a Signed-off-by naming an AI agent. `agents` are already formatted for
/// the output surface.
pub fn describe_ai_signoff_rejected(agents: List(String)) -> String {
  "Signed-off-by names an AI agent ("
  <> string.join(agents, ", ")
  <> "). AI agents cannot certify the DCO: remove that line and have a human sign off (git rebase --signoff)."
}

/// Failure reason for a Co-authored-by naming an AI agent. `agents` are already formatted for
/// the output surface.
pub fn describe_ai_co_author_rejected(agents: List(String)) -> String {
  "Co-authored-by names an AI agent ("
  <> string.join(agents, ", ")
  <> "). An AI agent assists, it does not co-author: use "
  <> assisted_by_template
  <> " instead."
}

/// Failure reason for a commit whose author or committer is an AI agent and that has no
/// Assisted-by trailer. `agents` are already formatted for the output surface.
pub fn describe_ai_trace_rejected(agents: List(String)) -> String {
  "The commit author or committer is an AI agent ("
  <> string.join(agents, ", ")
  <> ") and the commit has no Assisted-by trailer. Add "
  <> assisted_by_template
  <> "."
}

/// The Assisted-by trailer format recommended in place of an AI Co-authored-by.
pub const assisted_by_template = "Assisted-by: <agent harness> [model] [tool…]"

/// Advice appended to the AI Co-authored-by and trace warnings.
pub const assisted_by_advice =
  "Attribute AI assistance with an Assisted-by trailer: Assisted-by: <agent harness> [model] [tool…]"

/// The success-row note for an exempt author. `alias` is the alias address that matched,
/// already formatted (masked) for the output surface.
pub fn exemption_note(
  match match: types.ExemptionMatch,
  alias alias: option.Option(String),
) -> String {
  let note = case match {
    types.ExactEmail -> "exempt"
    types.DomainPattern(pattern) -> "exempt domain " <> pattern
  }
  case alias {
    Some(address) -> note <> " via alias " <> address
    None -> note
  }
}

/// Marker appended to a commit's row when an AI sign-off on it was ignored. Frontends add
/// `ai_signoff_footnote` once when any row carries it.
pub const ai_signoff_marker = "🤖"

/// Fixed footnote text for `ai_signoff_marker`.
pub const ai_signoff_footnote =
  "This commit also carried a `Signed-off-by` from an AI agent, which was ignored because a human sign-off is also present. AI agents cannot certify the DCO."

/// Whether an AI sign-off on this commit was ignored, so its row carries the marker.
pub fn has_ignored_ai_signoff(record: DcoRecord) -> Bool {
  record.ignored_ai_signoffs != []
}

/// Make untrusted text (a commit subject, a name or email from a trailer) safe to put in a
/// Markdown table cell of a PR comment.
///
/// Characters that would start formatting (`\`, `` ` ``, `*`, `_`, `~`, `[`, `]`, `|`, `$`)
/// get a backslash. A word-initial `@` that would mention a user or team is wrapped in a
/// code span instead: GitHub resolves mentions in the rendered text, so a backslash is
/// reported not to stop one. `foo@bar` and `al…@example.com` are not mentions and are left
/// alone.
///
/// This is not HTML escaping. Apply it first, then `houdini.escape`, so the entities that
/// produces are not themselves escaped. Do not use it for the job summary, an HTML table,
/// where a backslash would show literally.
@external(javascript, "./format_ffi.mjs", "escape_markdown")
pub fn escape_markdown(text: String) -> String
