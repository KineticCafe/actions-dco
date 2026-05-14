import dco_check/internal/trailers
import gleam/int
import gleam/io
import gleam/string
import gleamy/bench

pub fn main() {
  // ~500 char message: subject, 3 body paragraphs, trailer
  let message =
    "deps: Bump actions group\n\n"
    <> "Updates `org/pkg-a` from 1.0.0 to 2.0.0\n- [Notes](https://github.com/org/pkg-a/releases)\n- [Commits](https://github.com/org/pkg-a/compare/aaa...bbb)\n\n"
    <> "Updates `org/pkg-b` from 1.0.0 to 2.0.0\n- [Notes](https://github.com/org/pkg-b/releases)\n- [Commits](https://github.com/org/pkg-b/compare/ccc...ddd)\n\n"
    <> "---\nupdated-dependencies:\n- dependency-name: org/pkg-a\n  dependency-type: direct:production\n...\n\n"
    <> "Signed-off-by: dependabot[bot] <support@github.com>"

  io.println("Message length: " <> int.to_string(string.length(message)))
  io.println("")

  bench.run(
    [bench.Input("small dependabot", message)],
    [
      bench.Function("strict", fn(msg) { trailers.parse(msg, trailers.Strict) }),
      bench.Function("lenient", fn(msg) {
        trailers.parse(msg, trailers.Lenient)
      }),
    ],
    [bench.Duration(1000), bench.Warmup(200)],
  )
  |> bench.table([bench.IPS, bench.Min, bench.Mean, bench.P(99)])
  |> io.println
}
