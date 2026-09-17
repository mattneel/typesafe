# Releasing

This is the checklist for publishing a new version of `typesafe` to Hex. Work through it in
order. Every step should pass before you go to the next one.

The package follows [Semantic Versioning](https://semver.org). While the version is 0.x, any
wire-level change to answers is at least a minor bump. Deprecations warn through `IO.warn/2`,
name the version they started in, and stay for at least one minor version.

## 1. Prepare the release branch

- [ ] Start from an up-to-date `master` and create a branch such as `release/vX.Y.Z`.
- [ ] Bump `@version` in `mix.exs`. The user agent (`typesafe-elixir/X.Y.Z`) and the docs
      `source_ref` read it from there.
- [ ] Update the install snippet (`{:typesafe, "~> X.Y.Z"}`) in `README.md`,
      `guides/getting-started.md` and `cheatsheets/typesafe.cheatmd` when the minor or major
      version changes.
- [ ] In `CHANGELOG.md`, move the `[Unreleased]` entries under a new `## [X.Y.Z] - YYYY-MM-DD`
      heading, leave an empty `[Unreleased]` section above it, and update the compare links at
      the bottom.

## 2. Run the local checks

```console
$ mix deps.get
$ mix precommit
```

`mix precommit` runs in the test environment. It compiles with warnings as errors, checks
`mix.lock` for unused dependencies, checks formatting, and runs `credo --strict` and the test
suite with warnings as errors.

Then run the checks that `precommit` does not cover:

```console
$ mix dialyzer
$ mix docs --warnings-as-errors
$ mix hex.audit
$ mix typesafe.schema --check
```

- [ ] `mix typesafe.schema --check` passes. If it fails, a wire schema changed. Regenerate the
      files with `mix typesafe.schema`, review the diff in `priv/json_schema/`, and record the
      change in `CHANGELOG.md`.
- [ ] Optionally, run the live smoke tests against the real API:
      `TYPESAFE_API_KEY=... mix test.live`. Review any diff in `test/fixtures/live/`.

## 3. Inspect the package

```console
$ mix hex.build --unpack
```

- [ ] The unpacked `typesafe-X.Y.Z/` directory contains only `lib/`, `priv/json_schema/`,
      `guides/`, `cheatsheets/`, `mix.exs`, `README.md`, `CHANGELOG.md` and `LICENSE`.
- [ ] No `priv/plts/`, `.env`, `test/` or `_build/` content is included.
- [ ] The metadata printed by `mix hex.build` shows the right version, description, licenses and
      links, and lists `req`, `zoi` and `telemetry` as the runtime dependencies and `plug` as
      optional.

Delete the unpacked directory afterwards.

## 4. Review the docs locally

```console
$ mix docs
$ open doc/index.html   # xdg-open on Linux
```

- [ ] The README is the landing page.
- [ ] The Guides group lists getting started, questions, confidence, batching, testing and
      telemetry, and the Cheatsheets group shows the cheatsheet.
- [ ] Modules are grouped as Questions, Answers, Transport, Observability and Testing.
- [ ] Links to functions and between guides work, and the version in the sidebar is X.Y.Z.

## 5. Get CI green

Open a pull request for the release branch and wait for every job to pass:

- [ ] Test matrix: Elixir 1.18 / OTP 27, 1.19 / OTP 28 and 1.20 / OTP 29.
- [ ] Req compatibility: the suite against Req `~> 0.7.4` and against the latest 0.8 release
      (`TYPESAFE_CI_REQ_VERSION`).
- [ ] Static checks: formatting, Credo, Dialyzer, `mix docs --warnings-as-errors`, `mix hex.audit`
      and `mix deps.unlock --check-unused`.
- [ ] Live: the most recent scheduled run of `mix test --only live` passed, or trigger it
      manually on the release branch.

Merge the pull request once CI is green.

## 6. Tag and publish

From the merged commit on `master`:

```console
$ git tag -a vX.Y.Z -m "vX.Y.Z"
$ git push origin vX.Y.Z
$ mix hex.publish
```

- [ ] `mix hex.publish` shows the same file list and metadata you inspected in step 3. Confirm it.
- [ ] `mix hex.publish` publishes the package and its docs together. If the docs upload fails,
      publish them on their own with `mix hex.publish docs`.
- [ ] Check <https://hex.pm/packages/typesafe> and <https://hexdocs.pm/typesafe> for the new
      version.
- [ ] Create a GitHub release for the tag, and paste the `CHANGELOG.md` section as its notes.

## Package ownership

The package must have at least two people who can publish it, so it is never single-maintainer.

- Add a second owner with `mix hex.owner add typesafe <email-or-username>`.
- If the package later moves to a Hex organisation you control, transfer it once with
  `mix hex.owner transfer typesafe <organisation>`. `transfer` removes the existing individual
  owners, so make sure the organisation has at least two members who can publish.

```console
$ mix hex.owner list typesafe
```

- [ ] The package is owned by the organisation, or by at least two people.

## If something goes wrong

- A new version of an existing package can be replaced (run `mix hex.publish --replace`) or
  reverted (`mix hex.publish --revert X.Y.Z`) within one hour of publishing. A brand new
  package has 24 hours. Reverting the only version removes the package.
- After that window, publish a patch release. To mark a bad version, run
  `mix hex.retire typesafe X.Y.Z invalid --message "..."`.
- Docs can be republished at any time with `mix hex.publish docs`.
