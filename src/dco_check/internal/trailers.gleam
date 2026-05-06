//// Git trailer parsing using `git interpret-trailers` semantics.
////
//// Trailers are the final block(s) of lines in a commit message separated from the body
//// by blank lines. Each trailer is a line of the form "Token: value" where Token has no
//// internal whitespace. Values may be folded across continuation lines (leading
//// whitespace per RFC 822).
////
//// Keys are normalized to lowercase in output.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Parsing mode for trailer extraction.
pub type Mode {
  /// Only the final paragraph is considered as trailers.
  Strict
  /// Walk backwards through blank-line-separated sub-blocks, accumulating trailers as
  /// long as each sub-block parses entirely as trailers.
  Lenient
}

/// Parse trailers from a commit message.
///
/// Returns an ordered list of (lowercase-key, trimmed-value) pairs. RFC 822 folding
/// (continuation lines starting with whitespace) is supported.
pub fn parse(
  message message: String,
  mode mode: Mode,
) -> List(#(String, String)) {
  let trimmed =
    message
    |> string.replace("\r\n", "\n")
    |> string.trim_end

  let paragraphs = string.split(trimmed, "\n\n")

  case mode {
    Strict ->
      list.last(paragraphs)
      |> result.unwrap("")
      |> parse_block
      |> result.unwrap([])

    Lenient ->
      paragraphs
      |> list.reverse
      |> collect_lenient([])
  }
}

/// Group parsed trailers into a dict keyed by token with collected values.
///
/// The order of trailer values is preserved.
pub fn group(trailers: List(#(String, String))) -> Dict(String, List(String)) {
  list.fold(trailers, dict.new(), fn(acc, pair) {
    let #(key, value) = pair
    let existing = dict.get(acc, key) |> result.unwrap(or: [])
    dict.insert(acc, key, [value, ..existing])
  })
  |> dict.map_values(fn(_, values) { list.reverse(values) })
}

/// Parse a "Name <email>" identity string from a trailer value.
///
/// Useful for Signed-off-by, Co-authored-by, Reviewed-by, etc. Returns Ok(#(Option(name),
/// Option(email))) if the value has valid angle-bracket structure. Returns Error(Nil) if
/// the structure is malformed (no `<`, extra `<`, or missing `>`).
pub fn parse_identity(
  value: String,
) -> Result(#(Option(String), Option(String)), Nil) {
  let trimmed = string.trim(value)

  use #(name_part, rest) <- result.try(string.split_once(trimmed, "<"))
  use <- bool.guard(string.contains(rest, "<"), return: Error(Nil))
  use <- bool.guard(
    string.contains(rest, ">") |> bool.negate,
    return: Error(Nil),
  )

  let name = case string.trim(name_part) {
    "" -> None
    n -> Some(n)
  }
  let email = case string.drop_end(rest, 1) {
    "" -> None
    e -> Some(e)
  }
  Ok(#(name, email))
}

/// Try to parse a paragraph as a trailer block. Returns Ok(list) if every logical line
/// (after folding) is a valid trailer, Error(Nil) otherwise.
fn parse_block(block: String) -> Result(List(#(String, String)), Nil) {
  let lines = string.split(block, "\n")
  let folded = fold_continuation_lines(lines, [])

  let results = list.map(folded, parse_trailer_line)

  case list.all(results, fn(r) { option.is_some(r) }) {
    True ->
      Ok(
        list.filter_map(results, fn(r) {
          case r {
            Some(t) -> Ok(t)
            None -> Error(Nil)
          }
        }),
      )
    False -> Error(Nil)
  }
}

/// Walk reversed paragraphs, accumulating trailers from the end as long as each paragraph
/// parses entirely as trailers.
fn collect_lenient(
  paragraphs: List(String),
  acc: List(List(#(String, String))),
) -> List(#(String, String)) {
  case paragraphs {
    [] -> list.flatten(acc)
    [block, ..rest] -> {
      case parse_block(block) {
        Ok(trailers) -> collect_lenient(rest, [trailers, ..acc])
        Error(Nil) -> list.flatten(acc)
      }
    }
  }
}

/// Fold RFC 822 continuation lines: lines starting with whitespace are appended to the
/// previous line's value.
fn fold_continuation_lines(
  lines: List(String),
  acc: List(String),
) -> List(String) {
  case lines {
    [] -> list.reverse(acc)
    [line, ..rest] -> {
      use <- bool.guard(
        is_continuation(line) |> bool.negate,
        return: fold_continuation_lines(rest, [line, ..acc]),
      )

      case acc {
        [prev, ..prev_rest] ->
          fold_continuation_lines(rest, [
            prev <> " " <> string.trim(line),
            ..prev_rest
          ])
        [] ->
          // Continuation with nothing to continue — skip
          fold_continuation_lines(rest, acc)
      }
    }
  }
}

fn is_continuation(line: String) -> Bool {
  case string.first(line) {
    Ok(" ") | Ok("\t") -> True
    _ -> False
  }
}

/// Parse a single (already-folded) trailer line into (lowercase-key, trimmed-value).
fn parse_trailer_line(line: String) -> Option(#(String, String)) {
  case scan_key(line, 0) {
    Ok(#(key, rest)) -> {
      case string.first(rest) {
        Ok(":") -> {
          let value =
            rest
            |> string.drop_start(1)
            |> string.trim
          Some(#(string.lowercase(key), value))
        }
        _ -> None
      }
    }
    Error(Nil) -> None
  }
}

/// Scan a trailer key: first char must be alpha, rest alphanumeric or hyphen, no
/// whitespace allowed.
fn scan_key(input: String, len: Int) -> Result(#(String, String), Nil) {
  case string.first(input |> string.drop_start(len)) {
    Error(Nil) if len == 0 -> Error(Nil)
    // End of string
    Error(Nil) ->
      Ok(#(string.slice(input, 0, len), string.drop_start(input, len)))

    Ok(ch) if len == 0 ->
      // First char must be alpha
      case is_alpha(ch) {
        True -> scan_key(input, 1)
        False -> Error(Nil)
      }

    Ok(ch) -> {
      case is_key_char(ch) {
        True -> scan_key(input, len + 1)
        False if len == 0 -> Error(Nil)
        False ->
          Ok(#(string.slice(input, 0, len), string.drop_start(input, len)))
      }
    }
  }
}

fn is_alpha(ch: String) -> Bool {
  case ch {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "A"
    | "B"
    | "C"
    | "D"
    | "E"
    | "F"
    | "G"
    | "H"
    | "I"
    | "J"
    | "K"
    | "L"
    | "M"
    | "N"
    | "O"
    | "P"
    | "Q"
    | "R"
    | "S"
    | "T"
    | "U"
    | "V"
    | "W"
    | "X"
    | "Y"
    | "Z" -> True
    _ -> False
  }
}

fn is_key_char(ch: String) -> Bool {
  case ch {
    "-" -> True
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> is_alpha(ch)
  }
}
