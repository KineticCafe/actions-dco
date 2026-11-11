//// Domain types for DCO check.

import dco_check/internal/github/types
import gleam/option.{type Option}

/// A complete Git identity where both email and name are present.
pub type Identity {
  Identity(email: String, name: String)
}

/// How an author was matched for exemption.
pub type ExemptionMatch {
  ExactEmail
  DomainPattern(String)
}

/// A trailer identity or commit identity that matched the AI agent registry.
pub type AiMatch {
  AiMatch(
    /// Registry agent name (e.g. "Claude"), or the configured-agent label for
    /// identities added through `[ai]`.
    agent: String,
    /// The identity as written: a trailer value (`Claude <noreply@anthropic.com>`) or, for
    /// a commit author or committer, `Name <email>`.
    identity: String,
  )
}

/// The DCO Disposition is how the commit processed under the DCO was resolved.
pub type DcoDisposition {
  Unprocessed
  /// The commit was exempted from DCO processing by email matching. `alias` is the
  /// `alias-signoffs.aliases` address of the author that matched, when the author's own
  /// address did not.
  Exempted(identity: Identity, match: ExemptionMatch, alias: Option(String))
  /// The commit has no Signed-off-by trailers and is not exempt.
  NoSignoffs
  /// The commit has sign-offs but none match a valid commit identity.
  NoMatch(expected: List(Identity), found: List(Identity))
  /// The commit cannot be processed because neither author nor committer
  /// has both name and email.
  InvalidCommit
  /// A Signed-off-by names a known AI agent. AI agents cannot certify the DCO, so this
  /// always fails and no exemption (bot, author email, merge) applies.
  AiSignoffRejected(agents: List(AiMatch))
  /// A Co-authored-by names a known AI agent (`ai.co-authored-by = "reject"`). The agent
  /// assisted; it did not co-author. Attribute it with `Assisted-by:` instead.
  AiCoAuthorRejected(agents: List(AiMatch))
  /// The commit's author or committer is a known AI agent and the commit has no
  /// Assisted-by trailer (`ai.trace-detection = "reject"`).
  AiTraceRejected(agents: List(AiMatch))
  /// The commit passed validation. `identity` is the commit identity (author or
  /// committer) whose sign-off matched.
  Passed(identity: Identity)
  /// A merge commit with no Signed-off-by trailer, auto-passed. A merge commit that
  /// carries a Signed-off-by is validated like any other commit instead.
  MergeCommit
  /// Allowed bot commit with structured identity.
  BotCommit(login: String, name: Option(String), email: Option(String))
  /// The commit was skipped for some other reason.
  Skipped(String)
}

/// DCO Records are commit records with information on the signoff status.
pub type DcoRecord {
  DcoRecord(
    sha: String,
    url: String,
    subject: String,
    author: Option(types.GitUser),
    committer: Option(types.GitUser),
    identities: List(Identity),
    /// AI sign-offs that were ignored because a human also signed the commit
    /// (`ai.signed-off-by = "require-human"`). Frontends flag these.
    ignored_ai_signoffs: List(AiMatch),
    disposition: DcoDisposition,
  )
}

/// Summary counts for the overall DCO check result.
pub type DcoSummary {
  DcoSummary(
    total_commits: Int,
    evaluated: Int,
    passed: Int,
    failed: Int,
    invalid: Int,
    exempted: Int,
    skipped_merge: Int,
    skipped_bot: Int,
    truncated: Bool,
  )
}
