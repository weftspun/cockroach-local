# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule CockroachLocal.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/weftspun/cockroach_local"

  def project do
    [
      app: :cockroach_local,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Treat CockroachDB as a local database host: provision the single binary, " <>
          "start/stop an embedded single-node instance, and run work against it over " <>
          "Postgrex. Extracted from holographic-item-memory.",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url}
      ],
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl, :public_key]]
  end

  defp deps do
    [
      {:postgrex, "~> 0.19"}
    ]
  end
end
