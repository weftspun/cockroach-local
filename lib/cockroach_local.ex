# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule CockroachLocal do
  @moduledoc """
  Treat CockroachDB as a **local database host**.

  This library owns the *host lifecycle* only — provisioning the single
  `cockroach` binary, starting/stopping an embedded single-node instance, and
  handing a live `Postgrex` connection to your code. It holds **no schema**: the
  caller runs its own DDL/queries inside `with_db/2`, so any application can
  reuse it behind its own persistence port.

  Extracted from `holographic-item-memory`, whose `Holo.Adapters.CockroachStore`
  keeps its item/transition schema and delegates the host lifecycle here.

  ## Example

      CockroachLocal.with_db([data_dir: "/tmp/db", port: 26257], fn conn ->
        Postgrex.query!(conn, "CREATE TABLE IF NOT EXISTS kv (k STRING PRIMARY KEY, v STRING)", [])
        Postgrex.query!(conn, "UPSERT INTO kv VALUES ($1, $2)", ["a", "1"])
        Postgrex.query!(conn, "SELECT v FROM kv WHERE k = $1", ["a"]).rows
      end)

  ## Binary resolution (`bin/1`)

  In order: an explicit `:bin` path, the `COCKROACH_BIN` env var (name
  overridable via `:bin_env`), a bundled `priv/cockroach/` of the OTP app given
  as `:priv_app`, then `cockroach` on `$PATH`. Provision one for a target with
  `CockroachLocal.Provision`.
  """

  require Logger

  @default_port 26_257
  @ready_timeout_ms 60_000
  @poll_interval_ms 250

  @type opts :: keyword()

  @doc """
  Data directory for the embedded store: `opts[:data_dir]`, else
  `COCKROACH_DATA_DIR`, else `~/.cockroach_local`.
  """
  @spec default_data_dir(opts()) :: String.t()
  def default_data_dir(opts \\ []) do
    opts[:data_dir] || System.get_env("COCKROACH_DATA_DIR") ||
      Path.join(System.user_home!(), ".cockroach_local")
  end

  @doc """
  Run `fun.(conn)` against the store, starting (and stopping) an embedded
  single-node cockroach when nothing is already listening on the SQL port.
  Returns `fun`'s result, or `{:error, reason}`.

  ## Options
    * `:port` — SQL port (default #{@default_port}).
    * `:data_dir` — store path (see `default_data_dir/1`).
    * `:db_url` — connect to an external cluster instead of spawning a node.
    * `:username` / `:database` — connection identity (default `root` / `defaultdb`).
    * `:bin` / `:bin_env` / `:priv_app` — binary resolution (see `bin/1`).
  """
  @spec with_db(opts(), (pid() -> result)) :: result | {:error, term()} when result: var
  def with_db(opts \\ [], fun) do
    conn_opts = conn_opts(opts)
    port = Keyword.fetch!(conn_opts, :port)

    {started_port, os_pid} =
      if is_nil(opts[:db_url]) and not listening?(port) do
        spawn_cockroach(opts, port)
      else
        {nil, nil}
      end

    try do
      case await_conn(conn_opts, @ready_timeout_ms) do
        {:ok, conn} ->
          try do
            fun.(conn)
          after
            GenServer.stop(conn, :normal, 5_000)
          end

        {:error, reason} ->
          {:error, "database did not become ready: #{inspect(reason)}"}
      end
    after
      stop_cockroach(started_port, os_pid)
    end
  end

  @doc """
  Run the embedded cockroach in the foreground, streaming its output. Blocks
  until the node exits. Handy for a long-lived local host other processes reuse.
  """
  @spec run_foreground(opts()) :: {:ok, iodata()} | {:error, iodata(), pos_integer()}
  def run_foreground(opts \\ []) do
    with {:ok, exe} <- bin(opts) do
      args = start_args(opts, opts[:port] || @default_port)
      {_out, status} = System.cmd(exe, args, into: IO.stream(:stdio, :line))

      if status == 0,
        do: {:ok, ""},
        else: {:error, "cockroach exited with status #{status}", status}
    end
  end

  @doc """
  Resolve the cockroach binary: explicit `:bin`, then the `:bin_env` env var
  (default `COCKROACH_BIN`), then `priv/cockroach/` of `:priv_app`, then `$PATH`.
  """
  @spec bin(opts()) :: {:ok, String.t()} | {:error, String.t()}
  def bin(opts \\ []) do
    exe = if match?({:win32, _}, :os.type()), do: "cockroach.exe", else: "cockroach"
    env_name = opts[:bin_env] || "COCKROACH_BIN"

    bundled =
      case opts[:priv_app] do
        nil ->
          nil

        app ->
          case :code.priv_dir(app) do
            {:error, _} -> nil
            priv -> Path.join([to_string(priv), "cockroach", exe])
          end
      end

    cond do
      (b = opts[:bin]) && File.exists?(b) -> {:ok, b}
      b = System.get_env(env_name) -> {:ok, b}
      bundled && File.exists?(bundled) -> {:ok, bundled}
      b = System.find_executable("cockroach") -> {:ok, b}
      true -> {:error, "no cockroach binary: set #{env_name}, bundle priv/cockroach, or add to PATH"}
    end
  end

  # --- connection ------------------------------------------------------------

  defp conn_opts(opts) do
    case opts[:db_url] do
      nil ->
        [
          hostname: "localhost",
          port: opts[:port] || @default_port,
          username: opts[:username] || "root",
          database: opts[:database] || "defaultdb",
          ssl: false
        ]

      url ->
        uri = URI.parse(url)
        [username, password] = String.split(uri.userinfo || "root", ":") |> pad2()

        [
          hostname: uri.host || "localhost",
          port: uri.port || @default_port,
          username: username,
          password: password,
          database: String.trim_leading(uri.path || "/defaultdb", "/"),
          ssl: uri.query != nil and String.contains?(uri.query, "sslmode=require")
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    end
  end

  defp pad2([a]), do: [a, nil]
  defp pad2([a, b | _]), do: [a, b]

  defp listening?(port) do
    case :gen_tcp.connect(~c"localhost", port, [:binary, active: false], 500) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
  end

  defp await_conn(conn_opts, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(conn_opts, deadline)
  end

  defp do_await(conn_opts, deadline) do
    case try_connect(conn_opts) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, reason} ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, reason}
        else
          Process.sleep(@poll_interval_ms)
          do_await(conn_opts, deadline)
        end
    end
  end

  defp try_connect(conn_opts) do
    case Postgrex.start_link(conn_opts ++ [backoff_type: :stop, sync_connect: false]) do
      {:ok, conn} ->
        case safe_query(conn, "SELECT 1") do
          {:ok, _} ->
            {:ok, conn}

          {:error, reason} ->
            GenServer.stop(conn, :normal, 1_000)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_query(conn, sql) do
    Postgrex.query(conn, sql, [])
  catch
    :exit, reason -> {:error, reason}
  end

  # --- process lifecycle -----------------------------------------------------

  defp spawn_cockroach(opts, port) do
    case bin(opts) do
      {:ok, exe} ->
        args = start_args(opts, port)
        Logger.debug("cockroach_local: starting embedded cockroach on port #{port}")

        erl_port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args
          ])

        os_pid =
          case Port.info(erl_port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        {erl_port, os_pid}

      {:error, reason} ->
        raise reason
    end
  end

  defp start_args(opts, port) do
    data_dir = default_data_dir(opts)
    File.mkdir_p!(data_dir)

    [
      "start-single-node",
      "--insecure",
      "--store=path=#{data_dir}",
      "--listen-addr=localhost:#{port}",
      "--http-addr=localhost:0"
    ]
  end

  defp stop_cockroach(nil, _), do: :ok

  defp stop_cockroach(erl_port, os_pid) do
    if os_pid do
      case :os.type() do
        {:win32, _} -> System.cmd("taskkill", ["/PID", to_string(os_pid), "/T", "/F"])
        _ -> System.cmd("kill", [to_string(os_pid)])
      end
    end

    if is_port(erl_port) and Port.info(erl_port) != nil, do: Port.close(erl_port)
    :ok
  catch
    _, _ -> :ok
  end
end
