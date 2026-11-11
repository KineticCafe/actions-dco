//// Registry of known AI agent identities.
////
//// An AI agent cannot certify the Developer Certificate of Origin, so an identity in
//// this registry never satisfies a `Signed-off-by`, may be rejected as a
//// `Co-authored-by` or as a commit author or committer, and its bot account can be
//// excluded from bot exemptions (`bots.exclude-categories = ["ai"]`).
////
//// Matching is by email address (trailers) or GitHub login (bot commit authors), never
//// by display name: "Devin" or "Cursor" may be a person.
////
//// GitHub noreply addresses (`<id>+<login>@users.noreply.github.com`) are produced by
//// `mise run bot_email <login>`. GitHub App owners were checked with `gh api
//// apps/<slug>`. Every entry cites its source.
////
//// DO NOT add dependabot, renovate, or any other mechanical (non-AI) bot to this
//// registry. Their sign-offs are improper but tolerated because bot status exempts them;
//// listing them here would reject every one of their commits. `ai_agents_test` enforces
//// this.

import dco_check/internal/trailers
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string

/// A known AI agent. `key` is a stable lowercase slug used in configuration
/// (`ai.ignore-agents`); `name` is for display and may change. Emails and logins are
/// stored lowercase.
pub type AiAgent {
  AiAgent(key: String, name: String, emails: List(String), logins: List(String))
}

/// The effective registry: built-in agents plus any configured extensions. Each identity
/// maps to the key of its agent (`configured_key` for configured extensions) and the
/// agent's display name.
pub opaque type Registry {
  Registry(
    emails: Dict(String, #(String, String)),
    logins: Dict(String, #(String, String)),
  )
}

/// Agent name reported for identities added through configuration.
pub const configured_agent = "AI agent (configured)"

/// Internal key for identities added through configuration. Not a valid slug, so it can
/// never be named in `ai.ignore-agents`.
const configured_key = "(configured)"

/// Built-in AI agents. Changes are made only by pull request to this repository.
pub const agents: List(AiAgent) = [
  // Claude Code writes `Co-Authored-By: Claude <noreply@anthropic.com>`
  // (anthropics/claude-code#53259, #66079). User `claude` (81847) is Anthropic's
  // (profile: @anthropics, anthropic.com/claude-code). `claude[bot]` is the Claude GitHub
  // App, owned by `anthropics`.
  AiAgent(
    key: "claude",
    name: "Claude",
    emails: [
      "noreply@anthropic.com",
      "81847+claude@users.noreply.github.com",
      "claude@users.noreply.github.com",
      "209825114+claude[bot]@users.noreply.github.com",
    ],
    logins: ["claude[bot]"],
  ),
  // VS Code writes `Co-authored-by: Copilot <copilot@github.com>` (microsoft/vscode#314311).
  // `copilot-swe-agent[bot]` (198982749) is the coding agent App, owned by `github`; the API
  // reports its login as `Copilot`. `copilot-pull-request-reviewer[bot]` (175728472) is the
  // code review bot and `copilot[bot]` (167198135) is used by Copilot Chat and CLI; both
  // are type Bot but neither has a public App record.
  AiAgent(
    key: "github-copilot",
    name: "GitHub Copilot",
    emails: [
      "copilot@github.com",
      "198982749+copilot@users.noreply.github.com",
      "175728472+copilot@users.noreply.github.com",
      "167198135+copilot[bot]@users.noreply.github.com",
    ],
    logins: [
      "copilot", "copilot-swe-agent[bot]", "copilot-pull-request-reviewer[bot]",
      "copilot[bot]",
    ],
  ),
  // `chatgpt-codex-connector[bot]` App is owned by `openai`. User `codex` (267193182) is
  // OpenAI's (profile: OpenAI, openai.com/codex). Codex's fallback identity
  // `codex@example.com` is deliberately excluded: it resolves to an unrelated GitHub user
  // (openai/codex#18095).
  AiAgent(
    key: "openai-codex",
    name: "OpenAI Codex",
    emails: [
      "199175422+chatgpt-codex-connector[bot]@users.noreply.github.com",
      "267193182+codex@users.noreply.github.com",
    ],
    logins: ["chatgpt-codex-connector[bot]"],
  ),
  // `gemini-code-assist[bot]` App is owned by `google`; `gemini-cli[bot]` App is owned by
  // `google-gemini`. User `gemini-code-assist` (200291788) is Google's (profile: @google).
  // Gemini CLI writes `Co-Authored-By: Gemini <gemini@google.com>`
  // (google-gemini/gemini-cli#12419).
  AiAgent(
    key: "google-gemini",
    name: "Google Gemini",
    emails: [
      "gemini@google.com",
      "176961590+gemini-code-assist[bot]@users.noreply.github.com",
      "200291788+gemini-code-assist@users.noreply.github.com",
      "218312386+gemini-cli[bot]@users.noreply.github.com",
    ],
    logins: ["gemini-code-assist[bot]", "gemini-cli[bot]"],
  ),
  // `google-labs-jules[bot]` App is owned by `google-labs-code`.
  AiAgent(
    key: "google-jules",
    name: "Google Jules",
    emails: ["161369871+google-labs-jules[bot]@users.noreply.github.com"],
    logins: ["google-labs-jules[bot]"],
  ),
  // Cursor writes `Co-authored-by: Cursor <cursoragent@cursor.com>` (GitHub community
  // discussion #186158; Cursor forum). `cursor[bot]` App is owned by `cursor`.
  AiAgent(
    key: "cursor",
    name: "Cursor",
    emails: [
      "cursoragent@cursor.com", "206951365+cursor[bot]@users.noreply.github.com",
    ],
    logins: ["cursor[bot]"],
  ),
  // `devin-ai-integration[bot]` App is owned by `usacognition` (Cognition).
  AiAgent(
    key: "devin",
    name: "Devin",
    emails: ["158243242+devin-ai-integration[bot]@users.noreply.github.com"],
    logins: ["devin-ai-integration[bot]"],
  ),
  // `amazon-q-developer[bot]` App is owned by `Amazon-Q-Developer`.
  AiAgent(
    key: "amazon-q-developer",
    name: "Amazon Q Developer",
    emails: ["208079219+amazon-q-developer[bot]@users.noreply.github.com"],
    logins: ["amazon-q-developer[bot]"],
  ),
  // `kiro-agent[bot]` App ("Kiro Agent") is owned by `kiro-agent`.
  AiAgent(
    key: "kiro",
    name: "Kiro",
    emails: ["245459735+kiro-agent[bot]@users.noreply.github.com"],
    logins: ["kiro-agent[bot]"],
  ),
  // OpenHands' system prompt sets `openhands <openhands@all-hands.dev>` as the git identity
  // (All-Hands-AI/OpenHands#4776, #5818). User `openhands-agent` (175740463) is All Hands'
  // (profile: @all-hands-ai). Not a bot account, so there is no login entry.
  AiAgent(
    key: "openhands",
    name: "OpenHands",
    emails: [
      "openhands@all-hands.dev",
      "175740463+openhands-agent@users.noreply.github.com",
    ],
    logins: [],
  ),
  // opencode writes `Co-Authored-By: opencode <noreply@opencode.ai>`
  // (anomalyco/opencode#786, #43358). `opencode-agent[bot]` App is owned by `anomalyco`.
  AiAgent(
    key: "opencode",
    name: "opencode",
    emails: [
      "noreply@opencode.ai",
      "219766164+opencode-agent[bot]@users.noreply.github.com",
    ],
    logins: ["opencode-agent[bot]"],
  ),
  // User `warp-agent` (243858445) is Warp's (profile: Warp, warp.dev; @warp-agent in
  // docs.warp.dev GitHub integration). Not a bot account, so there is no login entry.
  AiAgent(
    key: "warp",
    name: "Warp",
    emails: ["243858445+warp-agent@users.noreply.github.com"],
    logins: [],
  ),
  // `jetbrains-ai[bot]` App is owned by `jcp-infra-bot`.
  AiAgent(
    key: "jetbrains-ai",
    name: "JetBrains AI",
    emails: ["220155983+jetbrains-ai[bot]@users.noreply.github.com"],
    logins: ["jetbrains-ai[bot]"],
  ),
  // aider `--attribute-co-authored-by` writes `Co-authored-by: aider (<model>)
  // <noreply@aider.chat>` (Aider-AI/aider#3788, #4226).
  AiAgent(
    key: "aider",
    name: "aider",
    emails: ["noreply@aider.chat"],
    logins: [],
  ),
  // Crush writes `Co-Authored-By: Crush <crush@charm.land>` (Charm Crush attribution docs).
  AiAgent(key: "crush", name: "Crush", emails: ["crush@charm.land"], logins: []),
  // Qwen Code's default co-author is `Qwen-Coder <qwen-coder@alibabacloud.com>`
  // (QwenLM/qwen-code packages/core/src/config/config.ts).
  AiAgent(
    key: "qwen-code",
    name: "Qwen Code",
    emails: ["qwen-coder@alibabacloud.com"],
    logins: [],
  ),
  // Z.ai (GLM)
  AiAgent(key: "z-ai", name: "Z.ai (Glm)", emails: ["noreply@z.ai"], logins: []),
  // GitHub Apps below: login verified with the users API, owner with `gh api apps/<slug>`.
  // Owner: coderabbitai
  AiAgent(
    key: "coderabbit",
    name: "CodeRabbit",
    emails: ["136622811+coderabbitai[bot]@users.noreply.github.com"],
    logins: ["coderabbitai[bot]"],
  ),
  // Owner: GPT-Engineer-App
  AiAgent(
    key: "lovable",
    name: "Lovable",
    emails: ["159125892+lovable-dev[bot]@users.noreply.github.com"],
    logins: ["lovable-dev[bot]"],
  ),
  // Owner: Factory-AI
  AiAgent(
    key: "factory-droid",
    name: "Factory Droid",
    emails: ["138933559+factory-droid[bot]@users.noreply.github.com"],
    logins: ["factory-droid[bot]"],
  ),
  // Owner: codegen-sh
  AiAgent(
    key: "codegen",
    name: "Codegen",
    emails: ["131295404+codegen-sh[bot]@users.noreply.github.com"],
    logins: ["codegen-sh[bot]"],
  ),
  // Owner: sourcery-ai
  AiAgent(
    key: "sourcery",
    name: "Sourcery",
    emails: ["58596630+sourcery-ai[bot]@users.noreply.github.com"],
    logins: ["sourcery-ai[bot]"],
  ),
  // Owner: ellipsis-dev
  AiAgent(
    key: "ellipsis",
    name: "Ellipsis",
    emails: ["65095814+ellipsis-dev[bot]@users.noreply.github.com"],
    logins: ["ellipsis-dev[bot]"],
  ),
  // Owner: greptileai
  AiAgent(
    key: "greptile",
    name: "Greptile",
    emails: ["165735046+greptile-apps[bot]@users.noreply.github.com"],
    logins: ["greptile-apps[bot]"],
  ),
  // Owner: AbanteAI
  AiAgent(
    key: "mentat",
    name: "Mentat",
    emails: ["160964065+mentatbot[bot]@users.noreply.github.com"],
    logins: ["mentatbot[bot]"],
  ),
  // Owner: augmentcode
  AiAgent(
    key: "augment-code",
    name: "Augment Code",
    emails: ["185243770+augmentcode[bot]@users.noreply.github.com"],
    logins: ["augmentcode[bot]"],
  ),
  // Owner: codeflash-ai
  AiAgent(
    key: "codeflash",
    name: "Codeflash",
    emails: ["148906541+codeflash-ai[bot]@users.noreply.github.com"],
    logins: ["codeflash-ai[bot]"],
  ),
  // Owner: korbit-ai
  AiAgent(
    key: "korbit",
    name: "Korbit",
    emails: ["131444098+korbit-ai[bot]@users.noreply.github.com"],
    logins: ["korbit-ai[bot]"],
  ),
  // Owner: gitbito
  AiAgent(
    key: "bito",
    name: "Bito",
    emails: ["188872107+bito-code-review[bot]@users.noreply.github.com"],
    logins: ["bito-code-review[bot]"],
  ),
  // Owner: replit
  AiAgent(
    key: "replit",
    name: "Replit",
    emails: ["312764674+replit[bot]@users.noreply.github.com"],
    logins: ["replit[bot]"],
  ),
  // Owner: continuedev
  AiAgent(
    key: "continue",
    name: "Continue",
    emails: ["230936708+continue[bot]@users.noreply.github.com"],
    logins: ["continue[bot]"],
  ),
  // Owner: mrge-io
  AiAgent(
    key: "cubic",
    name: "cubic",
    emails: ["191113872+cubic-dev-ai[bot]@users.noreply.github.com"],
    logins: ["cubic-dev-ai[bot]"],
  ),
  // Owner: qodo-ai
  AiAgent(
    key: "qodo",
    name: "Qodo",
    emails: ["151058649+qodo-code-review[bot]@users.noreply.github.com"],
    logins: ["qodo-code-review[bot]"],
  ),
]

/// Build the effective registry from the built-in agents plus configured extra agent emails
/// (`ai.extra-agent-emails`). Extras never rename or replace a built-in entry. Bot logins
/// come only from the built-in list.
pub fn effective(
  extra_agent_emails extra_agent_emails: List(String),
) -> Registry {
  let base =
    list.fold(
      agents,
      Registry(emails: dict.new(), logins: dict.new()),
      fn(registry, agent) {
        let entry = #(agent.key, agent.name)
        Registry(
          emails: insert_new(into: registry.emails, keys: agent.emails, entry:),
          logins: insert_new(into: registry.logins, keys: agent.logins, entry:),
        )
      },
    )

  Registry(
    ..base,
    emails: insert_new(into: base.emails, keys: extra_agent_emails, entry: #(
      configured_key,
      configured_agent,
    )),
  )
}

/// The registry without the identities of the given built-in agents (by key). Used for the
/// checks that `ai.ignore-agents` relaxes; the full registry still decides whether a
/// sign-off can certify.
pub fn without(
  registry registry: Registry,
  keys keys: List(String),
) -> Registry {
  let keep = fn(_identity, entry: #(String, String)) {
    !list.contains(keys, entry.0)
  }
  Registry(
    emails: dict.filter(registry.emails, keep),
    logins: dict.filter(registry.logins, keep),
  )
}

/// Resolve a configured agent reference to a built-in agent key. The reference may be the
/// agent's key, one of its emails, or one of its bot logins (case-insensitive).
/// Configured extra agent emails never resolve.
pub fn resolve_key(reference: String) -> Result(String, Nil) {
  let reference = normalize(reference)
  list.find(agents, fn(agent) {
    agent.key == reference
    || list.contains(agent.emails, reference)
    || list.contains(agent.logins, reference)
  })
  |> result.map(fn(agent) { agent.key })
}

/// Whether an address belongs to a built-in agent. Unlike `match_email` this ignores
/// configured extensions, so it needs no `Registry`; it is for display decisions only.
pub fn is_built_in_email(email: String) -> Bool {
  let email = normalize(email)
  list.any(agents, fn(agent) { list.contains(agent.emails, email) })
}

/// Look up an email address. Returns the agent name.
pub fn match_email(
  registry registry: Registry,
  email email: String,
) -> Result(String, Nil) {
  dict.get(registry.emails, normalize(email)) |> result.map(fn(e) { e.1 })
}

/// Look up a GitHub login. Returns the agent name.
pub fn match_login(
  registry registry: Registry,
  login login: String,
) -> Result(String, Nil) {
  dict.get(registry.logins, normalize(login)) |> result.map(fn(e) { e.1 })
}

/// Look up a `Name <email>` trailer value by its email. A value with no email (or a
/// malformed one) never matches, whatever its name.
pub fn match_identity(
  registry registry: Registry,
  value value: String,
) -> Result(String, Nil) {
  case trailers.parse_identity(value) {
    Ok(#(_, Some(email))) -> match_email(registry:, email:)
    _ -> Error(Nil)
  }
}

fn insert_new(
  into into: Dict(String, #(String, String)),
  keys keys: List(String),
  entry entry: #(String, String),
) -> Dict(String, #(String, String)) {
  list.fold(keys, into, fn(acc, key) {
    let key = normalize(key)
    case key == "" || dict.has_key(acc, key) {
      True -> acc
      False -> dict.insert(acc, key, entry)
    }
  })
}

fn normalize(value: String) -> String {
  value |> string.trim |> string.lowercase
}
