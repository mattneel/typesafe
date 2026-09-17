defmodule TypeSafe.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mattneel/typesafe"
  @api_docs_url "https://docs.typesafe.ai"

  def project do
    [
      app: :typesafe,
      version: @version,
      elixir: "~> 1.18",
      name: "TypeSafe",
      source_url: @source_url,
      homepage_url: @source_url,
      description:
        "Elixir client for the TypeSafe System One API (Jev): typed Choice, Noul and Score judgments for your code.",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      test_coverage: [summary: [threshold: 90], ignore_modules: [~r/^TypeSafe\..*Helpers$/]],
      dialyzer: [
        plt_add_apps: [:ex_unit, :plug, :mix],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        flags: [:error_handling, :unknown, :extra_return, :missing_return]
      ]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test, "test.live": :test, ci: :test]]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1", only: [:dev, :test], runtime: false},
      # CI-only override for running the suite against a Req pre-release, e.g.
      # TYPESAFE_CI_REQ_VERSION=0.8.0-rc.0. The long name avoids picking up an unrelated variable
      # in a consuming project; never set it when running `mix hex.build`.
      {:req, System.get_env("TYPESAFE_CI_REQ_VERSION", "~> 0.7.4 or ~> 0.8")},
      {:zoi, "~> 0.18"},
      {:telemetry, "~> 1.4"},
      {:plug, "~> 1.20", optional: true},
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.12", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "TypeSafe API docs" => @api_docs_url,
        "Changelog" => "https://hexdocs.pm/typesafe/changelog.html"
      },
      files: ~w(lib priv/json_schema guides cheatsheets mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      formatters: ["html", "markdown"],
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/questions.md",
        "guides/confidence.md",
        "guides/batching.md",
        "guides/testing.md",
        "guides/telemetry.md",
        {"cheatsheets/typesafe.cheatmd", filename: "cheatsheet"},
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\//,
        Cheatsheets: ~r/cheatsheets\//
      ],
      groups_for_modules: [
        Questions: ~r/TypeSafe\.Question/,
        Answers: [~r/TypeSafe\.Answer/, TypeSafe.Response, TypeSafe.Usage, TypeSafe.Model],
        Transport: [TypeSafe.Client, TypeSafe.Retry, TypeSafe.Req, TypeSafe.Error],
        Observability: [TypeSafe.Telemetry],
        Testing: [TypeSafe.Test]
      ]
    ]
  end

  # Mix runs a task only once per invocation, so the second reach.check must be a rerun.
  defp reach_smells(_args), do: Mix.Task.rerun("reach.check", ["--smells"])

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "test --warnings-as-errors"
      ],
      "test.live": ["test --only live"],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch",
        &reach_smells/1
      ]
    ]
  end
end
