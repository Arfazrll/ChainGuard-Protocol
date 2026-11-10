defmodule ChainGuard.RiskTest do
  use ExUnit.Case, async: false

  alias ChainGuard.{Chain, Invariants, Risk, Stats}
  alias ChainGuard.Alerts.{Alert, Manager}
  alias ChainGuard.Risk.Server
  import ChainGuard.Fixtures

  @now 1_800_000_000_000
  @hour 3_600_000

  defp alert(over) do
    struct!(
      %Alert{
        id: "a#{System.unique_integer([:positive])}",
        rule_id: "privileged-change",
        lane: "rule",
        severity: :high,
        status: :provisional,
        first_seen_ms: @now,
        updated_ms: @now,
        evidence: []
      },
      over
    )
  end

  defp transfer_ev(from_protocol, to_protocol, usd) do
    lab = fn role, p ->
      %{"role" => role, "protocol" => p, "category" => "lending", "name" => p}
    end

    %{
      kind: "erc20_transfer",
      value_usd: usd,
      labels:
        [from_protocol && lab.("from", from_protocol), to_protocol && lab.("to", to_protocol)]
        |> Enum.reject(&is_nil/1)
    }
  end

  describe "model" do
    test "a drained protocol scores critical; a repaid flash-loan lender is not penalized" do
      drain =
        alert(
          rule_id: "flash-loan-drain",
          severity: :critical,
          evidence: [
            transfer_ev("aave", nil, 30_000_000.0),
            transfer_ev(nil, "euler", 30_000_000.0),
            transfer_ev("euler", nil, 38_904_507.0),
            transfer_ev(nil, "aave", 30_027_000.0)
          ]
        )

      inv = alert(lane: "invariant", rule_id: "euler-outflow", severity: :critical)

      invariants = [
        %{id: "euler-outflow", protocol: "euler"},
        %{id: "aave-outflow", protocol: "aave"}
      ]

      statuses = [
        %{id: "euler-outflow", protocol: "euler", state: :breached, value: 8.9e6, limit: 5.0e6},
        %{id: "aave-outflow", protocol: "aave", state: :ok, value: 0.0, limit: 1.5e8}
      ]

      scores = Risk.score_all([drain, inv], invariants, statuses, @now)

      assert %{score: 0, band: "critical", confidence: "high"} = scores["euler"]
      # 45 + 45 capped at 70, plus 30 for the broken invariant.
      assert [%{name: "alerts", deduction: 70.0}, %{name: "invariants", deduction: 30}] =
               scores["euler"].components

      assert Enum.sort(scores["euler"].inputs.alert_ids) == Enum.sort([drain.id, inv.id])
      assert %{score: 100, band: "low", inputs: %{alert_ids: []}} = scores["aave"]
    end

    test "deductions halve every 6 hours; ML alerts count half; retracted alerts not at all" do
      ev = [transfer_ev("vault", nil, 1.0)]
      fresh = alert(severity: :high, evidence: ev)
      old = alert(severity: :high, evidence: ev, updated_ms: @now - 12 * @hour)
      ml = alert(severity: :medium, lane: "ml", evidence: ev)
      gone = alert(severity: :critical, status: :retracted, evidence: ev)

      s = Risk.score_all([fresh, old, ml, gone], [], [], @now)["vault"]
      points = s.components |> hd() |> Map.get(:items) |> Map.new(&{&1.alert_id, &1.points})

      assert points[fresh.id] == 25.0
      assert points[old.id] == 6.25
      assert points[ml.id] == 5.0
      refute Map.has_key?(points, gone.id)
      assert s.score == round(100 - 36.25)
      assert s.band == "elevated"
      assert s.confidence == "low", "no invariant watches this protocol"
    end

    test "privileged changes and pauses count against the emitting protocol" do
      ev = %{
        kind: "proxy_upgraded",
        labels: [%{"role" => "contract", "protocol" => "compound", "category" => "lending"}]
      }

      assert Risk.attribute(alert(evidence: [ev]), %{}) == ["compound"]

      assert Risk.band(80) == "low" and Risk.band(79) == "elevated" and
               Risk.band(39) == "critical"
    end
  end

  describe "server" do
    setup do
      Chain.reset()
      Manager.reset()
      Stats.reset()
      Invariants.reset()
      Server.reset()
      :ok
    end

    test "score changes are broadcast for the audit chain and the live channel" do
      Phoenix.PubSub.subscribe(ChainGuard.PubSub, "risk:scores")
      b = block(10)
      Enum.each(adopt(1, b, euler_like_drain(b)), &(:ok = Chain.handle(&1)))
      :ok = Server.sync()

      assert_receive {:score, "euler", %{score: 0, band: "critical", model: "risk-v1"}}, 2_000
      assert %{score: 0, as_of_ms: _} = Server.get("euler")
      assert %{score: 100} = Server.get("aave")

      # A recompute with nothing new is not a change: nothing is re-recorded.
      :ok = Server.sync()
      refute_receive {:score, "euler", _}, 50
    end
  end
end
