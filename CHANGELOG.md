# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version is 0.x,
any wire-level change to answers is at least a minor version bump.

## [Unreleased]

## [0.1.0] - 2026-09-16

First release: an Elixir client for TypeSafe's System One API (the Jev model). This is not an official
TypeSafe SDK.

### Added

- `TypeSafe.new/1` builds an immutable client on top of `Req`. Options resolve in this order:
  explicit option, `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL` or `TYPESAFE_DEFAULT_MODEL`,
  `config :typesafe`, then the default. Blank environment variables are ignored.
  `:req_options` from config and from `new/1` are merged.
- `TypeSafe.ask/4` and `TypeSafe.ask!/4` send one `POST /v1/systemone` request with any number of
  questions. They accept per-call `:model`, `:timeout`, `:retry`, `:headers` and
  `:telemetry_metadata` options.
- `TypeSafe.list_models/2` for `GET /v1/models`.
- The question constructors `TypeSafe.noul/2`, `TypeSafe.choice/3` and `TypeSafe.score/3`, and
  the tuple-returning `new/3` functions on `TypeSafe.Question.Noul`, `TypeSafe.Question.Choice`
  and `TypeSafe.Question.Score`. Instructions, criteria and state accept JSON structure (maps and
  lists), which is sent as JSON, never stringified. Choice criteria keep option order when given
  as a keyword list. The `:extra` option sends additional wire fields.
- Client-side validation with Zoi before any request is sent. Problems return a
  `:invalid_request` error with `path` and `details`.
- Answer structs `TypeSafe.Answer.Noul`, `TypeSafe.Answer.Choice` and `TypeSafe.Answer.Score`,
  with the helpers `yes?/2`, `ranked/1`, `margin/1`, `expected_level/1` and `max_level/1`.
  Question ids and Choice options come back with the caller's key type. Score levels are keyed
  by integer.
- `TypeSafe.Response` with `answers`, `model`, `usage`, `request_id` and `raw`, plus `fetch/2`,
  `fetch!/2`, `nouls/1`, `choices/1` and `scores/1`.
- Forward compatibility: answers of an unknown type are skipped with a warning and stay readable
  in `response.raw`.
- A single `TypeSafe.Error` exception with a `:type` to match on, covering validation, HTTP
  statuses (400, 401, 403, 404, 422, 429, 529, other 5xx), transport failures (including Finch
  pool checkout timeouts), timeouts and invalid responses. Errors for HTTP responses, including
  `:invalid_response`, carry the status, headers, body, endpoint and `x-typesafe-request-id`.
  `TypeSafe.Error.retryable?/2` is included.
- `TypeSafe.Retry`, a retry policy with the same defaults as TypeSafe's official Python and
  JavaScript SDKs: 2 retries, exponential backoff from 500 ms to 5 s with 25% jitter, retries on 408, 429,
  5xx and transport errors, `Retry-After` support, and a 30 s budget per call. A per-call keyword
  list merges over the client's policy.
- Identification headers in the same format as TypeSafe's official SDKs (`User-Agent`, `X-TypeSafe-SDK`,
  `X-TypeSafe-Runtime`, `X-TypeSafe-Retry-Count`), identifying this client as
  `typesafe-elixir/<version>`. These headers and `Authorization` cannot be overridden.
- Telemetry events `[:typesafe, :request, :start | :stop | :exception]`, one span per call, with
  token usage, status, request id, retry count and error. `TypeSafe.Telemetry.span/3` is included.
- `TypeSafe.Test`, which provides `Req.Test` stubs for applications: `stub_answers/2`,
  `stub_error/2`, `stub_transport_error/2`, `stub_models/2` and composable plugs. The stubs check
  that the question ids and types your code sends match the stubbed answers.
- `TypeSafe.Req`, a Req plugin (`attach/2` and `decode/2`) for applications that already own a
  `Req.Request`. The API key, headers and retry policy apply only to requests that set
  `:typesafe_questions`.
- `mix typesafe.schema`, which writes JSON Schemas for the request and response bodies, with
  `--check` for CI.
- Guides (getting started, questions, confidence, batching, testing, telemetry) and a cheatsheet.
- Support for Req `~> 0.7.4 or ~> 0.8` on Elixir 1.18+ and Erlang/OTP 27+.

[Unreleased]: https://github.com/mattneel/typesafe/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mattneel/typesafe/releases/tag/v0.1.0
