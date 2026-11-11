# Human Responsibility

This policy covers the responsibility of humans when contributing to this
project, with or without generative AI and AI-assisted tooling of any kind.

> **Only humans are authors. Everything else is a tool.**

**You** take full responsibility for your contribution the moment you open a
pull request or an issue. Do not blame or elevate tools: they are neither
excuses nor co-authors and cannot be held accountable. Submitting content you
cannot explain, defend, or take responsibility for will result in your
contribution being rejected.

## AI Usage Policy

This project has strict rules for AI usage[^1]:

- **The human author MUST fully understand all contributions.** If you can't
  explain the issue, feature, or code contribution without the aid of AI
  tools[^2], do not contribute to this project.

- **All AI usage in any form MUST be disclosed.** State the agent harness used
  (Claude Code, Cursor, Amp), the model and other AI tools. Describe in text
  the extent of AI-assistance.

- **Issues, discussions, and pull requests MUST be driven by the human, even
  with AI assistance.** Content generated with AI must have been reviewed _and
  edited_ by a human before submission. AI tools produce overly verbose and
  noisy paragraphs distracting from the main point. Humans must trim this
  down.

- **No AI-generated media is allowed (art, images, videos, audio, etc.).**
  Text and code are the only acceptable AI-generated content, per the other
  rules in this policy.

- **Bad AI drivers WILL face consequences.** People who produce bad
  contributions that are clearly AI (slop) will face sanctions: contributions
  closed, denouncement with [vouch][vouch], project bans, or even bans across
  multiple projects for sufficiently bad actors.

### Maintainers

Maintainers are exempt from AI disclosure, but are encouraged to disclose its
use anyway.

### Disclosure

AI tool disclosure is professional practice. It does not make a weak
contribution acceptable or a strong one suspect. It helps calibrate review.
Add AI-assistance notes to the body of your issue, comment, or pull request if
used. Add an `Assisted-by` git trailer for every commit involving the use of
AI tooling.

```gitcommit
Assisted-by: <agent harness> [model] [tool…]
```

Agents **MUST NOT** be present in `Co-authored-by` or `Signed-off-by`
trailers.

### Autonomous Agents and Reverse Centaurs

Autonomous coding agents and [reverse centaurs][centaur] are not permitted.
The human is the director and owner of the work, not a submit button.

## Human-driven AI Contributions are Welcome

The maintainer of this project uses AI-assisted tooling frequently. This is
not an endorsement of these tools: there is no ethical frontier model
provider, and the infrastructure powering these tools carries real
externalized costs that affect communities and ecosystems that never
consented. The tools are useful. The organizations are untrustworthy (but some
are less worthy of trust than others). [Both of these are true.][critics]

Using AI **well** is [rarely faster than writing code by hand][slowly]. AI
produces first drafts faster, but it has no judgement, taste, or coherence to
its design. AI frequently produces code that is _wrong but plausible_. AI
nearly always writes too much: whether three sentences when one would do,
three paragraphs when two would do, or details that not even a maintainer
would care about in a comment. It's up to you, the human in the loop, to make
these choices that AI cannot.

You are welcome to contribute to this project with AI tooling, but make sure
you understand your contribution because **you** are accountable. Make it
count.

> This policy was informed by the [Ghostty AI Policy][ghostty], the
> [AsyncAPI Generator AI Policy][async] and the essays
> ["I Am Not a Reverse Centaur"][centaur] by Miguel Grinberg,
> ["Open Source Was Not Ready for AI-speed Contributions"][ai-speed] by Franck
> Nijhof, ["Using AI to Write Better Code More Slowly"][slowly] by Nolan
> Lawson, and ["The LLM Critics Are Right. I Use LLMs Anyway."][critics] by
> Jeremy Theocharis.

[^1]: Adapted from the [Ghostty AI Policy][ghostty]

[^2]: AI-assisted translations are always permitted; disclosure is still
    mandatory.

[ai-speed]: https://frenck.dev/open-source-was-not-ready-for-ai-speed-contributions/
[async]: https://github.com/asyncapi/generator/blob/master/apps/generator/docs/ai-policy.md
[centaur]: https://blog.miguelgrinberg.com/post/i-am-not-a-reverse-centaur
[critics]: https://www.theocharis.dev/blog/llm-critics-are-right-i-use-llms-anyway/
[ghostty]: https://github.com/ghostty-org/ghostty/blob/main/AI_POLICY.md
[slowly]: https://nolanlawson.com/2026/05/25/using-ai-to-write-better-code-more-slowly/
[vouch]: https://github.com/mitchellh/vouch
