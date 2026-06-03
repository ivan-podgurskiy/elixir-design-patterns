defmodule ElixirDesignPatterns.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_design_patterns,
      version: "1.0.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Documentation
      name: "Elixir Design Patterns",
      description: "Practical, runnable examples of OTP and functional design patterns in Elixir",
      source_url: "https://github.com/ivan-podgurskiy/elixir-design-patterns",
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"] ++ Path.wildcard("guides/*.md")
      ],

      # Package
      package: [
        maintainers: ["Ivan Podgurskiy"],
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/ivan-podgurskiy/elixir-design-patterns"}
      ],

      # Testing and analysis
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        flags: [:error_handling, :underspecs, :unknown]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.cobertura": :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ElixirDesignPatterns.Application, []}
    ]
  end

  defp deps do
    [
      # Development and testing
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
