# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule CockroachLocalTest do
  use ExUnit.Case, async: true

  describe "default_data_dir/1" do
    test "prefers an explicit :data_dir" do
      assert CockroachLocal.default_data_dir(data_dir: "/tmp/x") == "/tmp/x"
    end

    test "falls back to a home-relative default" do
      dir = CockroachLocal.default_data_dir([])
      assert String.ends_with?(dir, ".cockroach_local")
    end
  end

  describe "bin/1" do
    test "resolves via the :bin_env env var" do
      System.put_env("COCKROACH_BIN_TEST", System.find_executable("sh"))
      assert {:ok, path} = CockroachLocal.bin(bin_env: "COCKROACH_BIN_TEST")
      assert String.ends_with?(path, "sh")
      System.delete_env("COCKROACH_BIN_TEST")
    end

    test "errors clearly when nothing resolves" do
      case System.find_executable("cockroach") do
        nil -> assert {:error, _msg} = CockroachLocal.bin(bin_env: "COCKROACH_BIN_UNSET_XYZ")
        _ -> assert {:ok, _} = CockroachLocal.bin(bin_env: "COCKROACH_BIN_UNSET_XYZ")
      end
    end
  end

  describe "Provision" do
    test "asset_url/1 maps supported targets to release URLs" do
      assert {:ok, url} = CockroachLocal.Provision.asset_url({:linux, :x86_64})
      assert url =~ "V-Sekai/cockroach/releases/download/"
      assert url =~ "linux-amd64.tgz"
    end

    test "asset_url/1 rejects unsupported targets" do
      assert {:error, :unsupported_target} = CockroachLocal.Provision.asset_url({:plan9, :sparc})
    end
  end
end
