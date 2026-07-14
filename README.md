# cockroach_local

Treat **CockroachDB as a local database host** from Elixir: provision the single
`cockroach` binary, start/stop an embedded single-node instance, and run work
against it over [Postgrex](https://hex.pm/packages/postgrex).

This library owns the **host lifecycle only** — it holds no schema. Your
application runs its own DDL/queries inside `with_db/2`, so it can sit behind any
persistence port. Extracted from
[`holographic-item-memory`](https://github.com/weftspun/holographic-item-memory).

## Install

```elixir
def deps do
  [
    {:cockroach_local, github: "weftspun/cockroach_local"}
  ]
end
```

## Use

```elixir
CockroachLocal.with_db([data_dir: "/tmp/db", port: 26257], fn conn ->
  Postgrex.query!(conn, "CREATE TABLE IF NOT EXISTS kv (k STRING PRIMARY KEY, v STRING)", [])
  Postgrex.query!(conn, "UPSERT INTO kv VALUES ($1, $2)", ["a", "1"])
  Postgrex.query!(conn, "SELECT v FROM kv WHERE k = $1", ["a"]).rows
end)
```

If nothing is listening on the SQL port, `with_db/2` spawns
`cockroach start-single-node --insecure`, waits for it to accept connections,
runs your function, and tears the node down. If a node is already up (or you pass
`:db_url`), it is reused and left running.

### Binary resolution

`CockroachLocal.bin/1` resolves, in order: an explicit `:bin`, the `COCKROACH_BIN`
env var (name overridable via `:bin_env`), a bundled `priv/cockroach/` of the OTP
app given as `:priv_app`, then `cockroach` on `$PATH`.

### Provisioning / bundling

`CockroachLocal.Provision` downloads the pinned
[`V-Sekai/cockroach`](https://github.com/V-Sekai/cockroach) 22.1 LTS single
binary for a `{os, cpu}` target and can install it into a `priv/cockroach/`
directory a release bundles:

```elixir
# in a Burrito/release step, for the target being built:
CockroachLocal.Provision.install({:linux, :x86_64}, priv_dir)
```

## License

MIT © 2026 K. S. Ernest (iFire) Lee
