defmodule OpenPlaatoKeg.MixProject do
  use Mix.Project

  def project do
    [
      app: :open_plaato_keg,
      elixir: "~> 1.16",
      version: application_version(),
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp releases do
    [
      open_plaato_keg: [
        version: application_version(),
        cookie: "ReleaseC00kie",
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        include_erts: true,
        overlays: ["etc"]
      ]
    ]
  end

  defp aliases do
    [
      test: "test --no-start"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {OpenPlaatoKeg, []}
    ]
  end

  defp deps do
    [
      {:thousand_island, "~> 1.3"},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.16"},
      {:websock_adapter, "~> 0.5"},
      {:poison, "~> 6.0"},
      {:credo, "~> 1.7", only: [:dev, :ci], runtime: false},
      {:assert_value, "~> 0.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp application_version do
    File.stream!("./.release/version")
    |> Stream.map(&String.trim/1)
    |> Stream.take(1)
    |> Enum.join()
  rescue
    _ -> "0.0.0+master"
  end
end
