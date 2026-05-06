# Sign-off Validation Design

## Sign-off Format (per DCO spec)

The canonical sign-off format is:

```
Signed-off-by: Name <email>
```

Both name and email are required. The DCO spec explicitly states "using a known
identity (sorry, no anonymous contributions.)"

Invalid sign-off forms (should be logged as warnings):

- `Signed-off-by: <email>` — missing name
- `Signed-off-by: Name` — missing email
- `Signed-off-by: @username` — not a real identity
- `Signed-off-by: https://...` — not a real identity
- `Signed-off-by: Name <not-an-email>` — invalid email

## Commit Identity Validation

Author and committer are independent identities. Each is valid only if it has
both a name and an email. Never mix fields across author and committer to
synthesize a composite identity.

### Building the identity set

1. If author has both name and email → add to valid identities
2. If committer has both name and email → add to valid identities
3. If the set is empty → fail ("no valid commit identity found")

### Matching

A commit passes if at least one valid `Signed-off-by` trailer matches at least
one valid commit identity (case-insensitive comparison on both name and email).

## Configuration

### External config file

Policy configuration lives in `.github/dco.yml` (YAML 1.2). The action's
workflow inputs are minimal:

- `repo-token`: GitHub token (default: `${{ github.token }}`)
- `config-path`: Path to config file (default: `.github/dco.yml`)

Everything else is in the config file.

### Config schema

```yaml
# Exempt authors — implied DCO sign-off (e.g., company employees).
# Exact emails or domain patterns (@example.com).
# Applied to commit author only.
exempt-authors:
  - joe@example.net
  - "@example.com"

# Bot policy
bots:
  # Named bot accounts that are unconditionally exempt from DCO.
  # These are structural/mechanical bots (dependency updaters, etc.)
  # Use the full [bot] account name as it appears in the GitHub API.
  exempt:
    - "dependabot[bot]"
    - "renovate[bot]"
    - "github-actions[bot]"

  # AI attribution trailers that revoke bot exemption.
  # If a commit from an exempt bot contains any of these trailers,
  # it is NOT exempt and requires a human Signed-off-by.
  ai-trailers:
    - "Assisted-by"
    - "Co-authored-by"
    # Match is prefix-based on the trailer name; the value is checked
    # against known AI patterns (see below).

  # Patterns in trailer values that indicate AI involvement.
  # If a trailer listed in ai-trailers has a value matching any of these,
  # the bot exemption is revoked for that commit.
  ai-patterns:
    - "Claude"
    - "Copilot"
    - "GPT"
    - "Gemini"
    - "Kiro"
```

### Defaults (no config file present)

When no config file exists, behaviour matches v2 for backwards compat:

- No exempt authors
- All `type: "Bot"` commits are skipped (blanket exemption)
- No AI trailer detection

When a config file exists but `bots.exempt` is empty, NO bots are exempt (opt-in
model).

## Processing Pipeline

For each commit in the PR:

1. Check if merge commit (multiple parents) → store as skipped because of merge
2. Check bot status: a. If `type: "Bot"` and account is in `bots.exempt` list:
   - Check for AI attribution trailers (per `bots.ai-trailers` +
     `bots.ai-patterns`)
   - If AI trailer found → do NOT skip, continue to sign-off check
   - If no AI trailer → store as skipped because of allowed bot b. If
     `type: "Bot"` and account is NOT in `bots.exempt` → continue to sign-off
     check (unknown bot, treat with suspicion) c. If not a bot → continue
3. Build valid commit identities (author, committer — independently)
4. If no valid commit identities → fail ("need both name and email on author or
   committer")
5. Parse all `Signed-off-by` trailers from the commit message
6. Validate each trailer as a `(name, email)` pair:
   - If unparseable or missing name/email → log warning, exclude from matching
   - If email fails validation → log warning, exclude from matching
7. If no sign-off trailers exist → check author exemptions, fail if not exempt
8. Match valid sign-offs against valid identities
9. If match found → pass (record in results)
10. If no match → fail with expected identity info (record in results)

## Result Types

Single ordered list preserving commit order. Each `DcoRecord` carries a
`DcoDisposition` indicating the outcome:

- `Passed` — valid sign-off matched a commit identity
- `NoSignoffs` — no Signed-off-by trailers and not exempt
- `NoMatch(expected, found)` — sign-offs present but none match a commit identity
- `InvalidCommit` — commit metadata broken (no valid identity derivable)
- `Exempted(identity, match)` — author matched an exemption pattern (exact email or domain)
- `MergeCommit` — skipped, multiple parents
- `BotCommit(login, name, email)` — skipped, allowed bot (structured identity)
- `Skipped(String)` — skipped for other reasons

`Unprocessed` is the initial state before evaluation; no record should remain in
this state after processing.

## Data Model

```gleam
/// A complete git identity (both name and email present).
pub type Identity {
  Identity(email: String, name: String)
}

/// How an author was matched for exemption.
pub type ExemptionMatch {
  ExactEmail
  DomainPattern(String)
}

/// The outcome of DCO evaluation for a single commit.
pub type DcoDisposition {
  Unprocessed
  Exempted(identity: Identity, match: ExemptionMatch)
  NoSignoffs
  NoMatch(expected: List(Identity), found: List(Identity))
  InvalidCommit
  Passed
  MergeCommit
  BotCommit(login: String, name: Option(String), email: Option(String))
  Skipped(String)
}

/// A commit record with DCO evaluation result.
pub type DcoRecord {
  DcoRecord(
    sha: String,
    url: String,
    author: Option(types.GitUser),       // git commit author (name, email, date)
    committer: Option(types.GitUser),    // git commit committer
    identities: List(Identity),         // validated complete identities
    disposition: DcoDisposition,
  )
}

/// Author exemption patterns.
pub type Exemptions {
  Exemptions(exact: List(String), ends_with: List(String))
}
```

Note: `types.GitUser` is the git-level author/committer from the commit object
(`name: Option(String)`, `email: Option(String)`, `date: Option(String)`). The
GitHub API-level user (`SimpleUser`) carries `type_`, `login`, `id`, etc. and
lives on the outer `Commit` record as `commit.author` / `commit.committer` (the
linked GitHub account, not the git identity). Bot detection uses
`SimpleUser.type_ == "Bot"` + `SimpleUser.login` for allowlist matching.

## Summary Output

### Return type

`get_dco_status` returns `#(DcoSummary, List(DcoRecord))`.

```gleam
pub type DcoSummary {
  DcoSummary(
    total_commits: Int,    // from CommitComparison.total_commits
    evaluated: Int,        // commits actually processed
    passed: Int,
    failed: Int,
    exempted: Int,
    skipped_merge: Int,
    skipped_bot: Int,
    truncated: Bool,       // total_commits > evaluated
  )
}
```

### Truncation

The GitHub commit comparison API returns at most 250 commits without pagination.
We do not paginate. If `CommitComparison.total_commits > list.length(commits)`,
set `truncated: True` and report it in the summary banner.

### Display limits

The summary counts always reflect the full evaluated set. Detail tables are
capped to avoid walls of noise:

| Category | Max rows | Overflow message |
|----------|----------|------------------|
| Failed | 20 | "and N more commits failed. Consider `git rebase --signoff`." |
| Exempted | 20 | "and N more commits exempted." |
| Bot/merge skipped | 10 | "and N more commits skipped." |
| Passed | 0 (count only) | — |

Bot commits are reported as distinct bots (grouped by `login`), not individual
commits. E.g., "dependabot[bot]: 12 commits, renovate[bot]: 3 commits" rather
than 15 rows.

### Rendering order

1. If truncated → banner: "Evaluated {evaluated} of {total_commits} commits
   (GitHub API limit; not paginated)."
2. One-line summary: "{passed} passed, {failed} failed, {exempted} exempted,
   {skipped_merge + skipped_bot} skipped."
3. Failed table (if any) — capped, most actionable info first.
4. Exempted table (if any) — capped.
5. Skipped table (if any) — capped, bots and merges together.

Passed commits are never listed individually.

## Logging

Log as warnings (visible in action output but not causing failure on their own):

- Sign-off trailers that can't be parsed into `(name, email)`
- Sign-off trailers with invalid email addresses
- Incomplete commit identities (author or committer missing name or email)
- Unknown bot accounts (not in exempt list) that lack sign-offs
- AI trailer detected on an otherwise-exempt bot commit

These help contributors diagnose why their sign-off didn't match without the
action silently swallowing malformed data.

## Notes on Alternative Identities

GitHub usernames (`@handle`), URLs, and email-only identities are not valid per
the DCO spec. The action should not attempt to match against these forms.

## AI/LLM Contribution Attribution (reference)

Per kernel guidelines (potentially adoptable for project contributing rules):

- AI agents must not add `Signed-off-by` — only humans certify the DCO
- AI-assisted contributions should include an `Assisted-by:` trailer
- The human submitter takes full responsibility for the contribution

---

## Pinned Notes

- **Possible feature: comment on pull request?** The action enforces a social
  contract that's hard to see in normal review. A PR comment (not just a job
  summary) would surface failures/warnings where contributors actually look.
