//// Fixture transport: replaces globalThis.fetch with a stub that reads
//// from a local JSON file. Used for CLI testing without network access.

@external(javascript, "./fixture_transport_ffi.mjs", "install")
pub fn install(fixture_path path: String) -> Nil
