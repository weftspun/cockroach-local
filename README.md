# cockroach_local

Treat CockroachDB as a local database host from Elixir: provision the single
`cockroach` binary, start/stop an embedded single-node instance, and run work
against it over Postgrex.

## Install

```elixir
def deps do
  [
    {:cockroach_local, github: "weftspun/cockroach-local"}
  ]
end
```
