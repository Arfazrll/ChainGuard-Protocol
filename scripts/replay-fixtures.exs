# Builds one replay stream from the real incident fixtures, in chronological
# order, with sequence numbers renumbered so the engine reads it as one feed.
#
#   elixir scripts/replay-fixtures.exs [OUT] [FIXTURE_DIR]
#
# Defaults: var/replay.jsonl and apps/engine/test/fixtures/incidents.
# Uses only the standard library (Elixir's built-in JSON), so it also runs in
# the engine's Docker build.
root = Path.expand("..", __DIR__)
[out, dir] =
  case System.argv() do
    [o, d | _] -> [o, d]
    [o] -> [o, Path.join(root, "apps/engine/test/fixtures/incidents")]
    [] -> [Path.join(root, "var/replay.jsonl"), Path.join(root, "apps/engine/test/fixtures/incidents")]
  end

fixtures = ["usdc-depeg-2023-03-11.jsonl", "euler-finance-2023-03-13.jsonl"]

lines =
  fixtures
  |> Enum.flat_map(fn f -> dir |> Path.join(f) |> File.stream!() |> Enum.reject(&(String.trim(&1) == "")) end)
  |> Enum.with_index(1)
  |> Enum.map(fn {line, seq} -> line |> JSON.decode!() |> Map.put("seq", seq) |> JSON.encode!() end)

File.mkdir_p!(Path.dirname(out))
File.write!(out, Enum.join(lines, "\n") <> "\n")
IO.puts("replay stream: #{length(lines)} messages from #{length(fixtures)} incidents -> #{out}")
