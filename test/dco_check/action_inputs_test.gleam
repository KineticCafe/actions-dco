import dco_check_action
import envoy
import gleam/string

// GitHub exposes `with:` inputs as INPUT_<NAME> (uppercased, spaces -> underscores), even
// for inputs the action no longer declares.
const exempt_authors_var = "INPUT_EXEMPT-AUTHORS"

fn with_env(name: String, value: String, run: fn() -> a) -> a {
  envoy.set(name, value)
  let result = run()
  envoy.unset(name)
  result
}

pub fn removed_input_unset_passes_test() {
  envoy.unset(exempt_authors_var)
  assert dco_check_action.check_removed_inputs() == Ok(Nil)
}

pub fn removed_input_set_fails_test() {
  let assert Error([input]) =
    with_env(exempt_authors_var, "joe@example.com @example.com", fn() {
      dco_check_action.check_removed_inputs()
    })

  assert input.name == "exempt-authors"

  let message = dco_check_action.describe_removed_input(input)
  assert string.contains(message, "'exempt-authors' input was removed in v4")
  assert string.contains(message, "TOML configuration")
}

pub fn removed_input_whitespace_only_passes_test() {
  // pontil trims inputs, so a blank value is the same as not set.
  assert with_env(exempt_authors_var, "   ", fn() {
      dco_check_action.check_removed_inputs()
    })
    == Ok(Nil)
}
