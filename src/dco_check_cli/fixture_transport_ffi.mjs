import { readFileSync } from "node:fs";

export function install(fixture_path) {
  globalThis.fetch = async function (_request) {
    const body = readFileSync(fixture_path, "utf-8");
    return new globalThis.Response(body, {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };
}
