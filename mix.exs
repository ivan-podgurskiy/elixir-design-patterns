defmodule ElixirDesignPatterns.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_design_patterns,
      version: "1.0.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Documentation
      name: "Elixir Design Patterns",
      description: "Practical, runnable examples of OTP and functional design patterns in Elixir",
      source_url: "https://github.com/yourusername/elixir-design-patterns",
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"] ++ Path.wildcard("guides/*.md")
      ],

      # Package
      package: [
        maintainers: ["Your Name"],
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/yourusername/elixir-design-patterns"}
      ],

      # Testing and analysis
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        flags: [:error_handling, :underspecs, :unknown]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # Development and testing
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.2", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false},
      {:excoveralls, "~> 0.16", only: :test}
    ]
  end
end
