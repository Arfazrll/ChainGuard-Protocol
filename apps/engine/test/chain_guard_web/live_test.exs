defmodule ChainGuardWeb.LiveTest do
  use ChainGuardWeb.ConnCase, async: false
  import Phoenix.ChannelTest
  import ChainGuard.Fixtures

  @endpoint ChainGuardWeb.Endpoint

  alias ChainGuard.{Chain, Stats}
  alias ChainGuard.Alerts.Manager

  setup do
    Chain.reset()
    Manager.reset()
    Stats.reset()
    :ok
  end

  test "alerts channel: snapshot on join, then live pushes" do
    {:ok, reply, _socket} =
      socket(ChainGuardWeb.UserSocket)
      |> subscribe_and_join(ChainGuardWeb.AlertsChannel, "alerts:global")

    assert reply.alerts == []

    b = block(10)
    Enum.each(adopt(1, b, euler_like_drain(b)), &Chain.handle/1)
    assert_push "alert:raised", %{rule_id: "flash-loan-drain", severity: :critical}

    Chain.handle(orphan(7, b))
    assert_push "alert:retracted", %{status: :retracted}
  end

  test "live channel streams block summaries with notable flows" do
    {:ok, _reply, _socket} =
      socket(ChainGuardWeb.UserSocket) |> subscribe_and_join(ChainGuardWeb.LiveChannel, "live:1")

    b = block(10)
    Enum.each(adopt(1, b, euler_like_drain(b)), &Chain.handle/1)
    assert_push "block", %{number: 10, records: 5, txs: 1, alerts: [_], notable: notable}
    assert Enum.any?(notable, &(&1.kind == "flash_loan"))

    assert {:error, %{reason: "unknown chain"}} =
             socket(ChainGuardWeb.UserSocket)
             |> subscribe_and_join(ChainGuardWeb.LiveChannel, "live:abc")
  end

  test "JSON API", %{conn: conn} do
    # A live block (timestamped now), so it feeds the latency figures.
    b = %{block(10) | "timestamp" => System.system_time(:second)}
    Enum.each(adopt(1, b, euler_like_drain(b)), &Chain.handle/1)

    assert %{"status" => "ok", "read_only" => true, "rules_loaded" => 5, "rule_errors" => []} =
             conn |> get("/api/health") |> json_response(200)

    assert %{"rules" => rules} = conn |> get("/api/rules") |> json_response(200)
    assert Enum.all?(rules, &(&1["weakness"]["class"] != nil))

    assert %{"alerts" => [%{"id" => id, "severity" => "critical", "evidence" => [_ | _]}]} =
             conn |> get("/api/alerts?limit=5") |> json_response(200)

    assert %{"id" => ^id} = conn |> get("/api/alerts/#{id}") |> json_response(200)
    assert conn |> get("/api/alerts/nope") |> json_response(404)

    assert %{
             "counters" => %{"blocks" => 1, "records" => 5, "replayed_blocks" => 0},
             "latency_ms" => %{"detect" => %{"samples" => 1}}
           } =
             conn |> get("/api/stats") |> json_response(200)
  end

  test "CORS allows the configured dashboard origin only", %{conn: conn} do
    ok = conn |> put_req_header("origin", "http://localhost:4300") |> get("/api/health")
    assert get_resp_header(ok, "access-control-allow-origin") == ["http://localhost:4300"]
    other = build_conn() |> put_req_header("origin", "https://evil.example") |> get("/api/health")
    assert get_resp_header(other, "access-control-allow-origin") == []
  end
end
