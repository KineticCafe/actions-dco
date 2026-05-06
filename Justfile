openapi_url := "https://raw.githubusercontent.com/github/rest-api-description/refs/heads/main/descriptions-next/api.github.com/api.github.com.yaml"
openapi_paths := "/repos/{owner}/{repo}/compare/{basehead} /repos/{owner}/{repo}/issues/{issue_number}/comments /repos/{owner}/{repo}/issues/comments/{comment_id} /repos/{owner}/{repo}/issues/{issue_number}/comments"

_default:
    just --list

# @generate:
@generate: simplify_openapi
    gleam run -m oaspec generate
    gleam format

@clean:
    rm -rf build gen

@build:
    gleam build
    gleam run -m pontil_build

@download_openapi:
    curl -sSL {{ openapi_url }} -O

@simplify_openapi:
    scripts/extract-openapi-subset api.github.com.yaml --output api.github.com.min.yaml --strip=all {{ openapi_paths }}
