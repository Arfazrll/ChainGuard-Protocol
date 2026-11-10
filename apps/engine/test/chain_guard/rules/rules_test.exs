defmodule ChainGuard.RulesTest do
  use ExUnit.Case, async: true

  alias ChainGuard.Rules
  alias ChainGuard.Rules.{Evaluator, Rule}
  import ChainGuard.Fixtures

  @bundled ~w(approval-farming emergency-pause flash-loan-drain mixer-interaction privileged-change)

  defp bundled(id) do
    {rules, []} = Rules.load_dir(Rules.rules_dir())
    Enum.find(rules, &(&1.id == id)) || flunk("rule #{id} not bundled")
  end

  defp run(rule, records, state \\ %{}, b \\ nil) do
    b = b || hd(records)["block"]
    Evaluator.evaluate(rule, state, Evaluator.context(1, b, records))
  end

  describe "bundled rules" do
    test "all five load, validate and declare a weakness class" do
      {rules, errors} = Rules.load_dir(Rules.rules_dir())
      assert errors == []
      assert Enum.map(rules, & &1.id) == @bundled
      for r <- rules, do: assert(r.weakness.class != "", "#{r.id} has no weakness class")
    end

    test "they are running, one supervised process each" do
      assert Enum.map(Rules.list(), & &1.id) == @bundled
    end
  end

  describe "flash-loan-drain" do
    test "fires on net protocol outflow inside a flash-loan tx" do
      rule = bundled("flash-loan-drain")
      {[c], _} = run(rule, euler_like_drain(block(10)))

      assert c.title ==
               "Euler Finance (main proxy) net outflow $8,904,507 in flash-loan tx #{ChainGuard.Rules.Template.short(hash("drain-tx"))}"

      kinds = Enum.map(c.evidence, &get_in(&1, ["event", "kind"]))
      assert "flash_loan" in kinds
      assert c.dedup_key == "flash-loan-drain:" <> hash("drain-tx")
    end

    test "ignores ordinary flash-loan arbitrage: the lender's principal returns" do
      {[], _} = run(bundled("flash-loan-drain"), plain_flash_loan_arbitrage(block(10)))
    end

    test "ignores a large protocol outflow without a flash loan" do
      records = euler_like_drain(block(10)) |> tl()
      {[], _} = run(bundled("flash-loan-drain"), records)
    end
  end

  describe "privileged-change" do
    test "fires on a labeled proxy upgrade, not an unlabeled one" do
      rule = bundled("privileged-change")
      b = block(5)
      pool = addr("pool")
      ev = %{"kind" => "proxy_upgraded", "implementation" => addr("impl")}

      labeled =
        record(b, 0, ev,
          contract: pool,
          labels: [label("contract", pool, "Aave V3 Pool", "lending", "aave")]
        )

      unlabeled = record(b, 1, ev, contract: addr("random"))
      {[c], _} = run(rule, [labeled, unlabeled])
      assert c.title =~ "proxy_upgraded on Aave V3 Pool"
      assert hd(c.evidence)["id"] == labeled["id"]
    end
  end

  describe "emergency-pause" do
    test "fires when a labeled protocol pauses" do
      usdc = addr("usdc")

      r =
        record(block(5), 0, %{"kind" => "paused", "account" => addr("guardian")},
          contract: usdc,
          labels: [label("contract", usdc, "USD Coin", "stablecoin")]
        )

      {[c], _} = run(bundled("emergency-pause"), [r])
      assert c.title =~ "USD Coin was paused"
    end
  end

  describe "mixer-interaction" do
    test "fires on mixer events and on transfers into a mixer" do
      rule = bundled("mixer-interaction")
      b = block(5)
      tc = addr("tornado")

      deposit =
        record(b, 0, %{"kind" => "unknown", "topic0" => hash("Deposit")},
          contract: tc,
          labels: [label("contract", tc, "Tornado Cash 10 ETH", "mixer")]
        )

      into =
        transfer(b, 1, addr("x"), tc, 5_000.0,
          labels: [label("to", tc, "Tornado Cash Router", "mixer")]
        )

      plain = transfer(b, 2, addr("x"), addr("y"), 5_000.0)
      {cands, _} = run(rule, [deposit, into, plain])
      assert length(cands) == 2
    end
  end

  describe "approval-farming" do
    setup do
      rule = bundled("approval-farming")
      # Get past the novelty warm-up with empty blocks.
      state =
        Enum.reduce(1..rule.warmup_blocks, %{}, fn n, st ->
          {_, st} = Evaluator.evaluate(rule, st, Evaluator.context(1, block(n), []))
          st
        end)

      {:ok, rule: rule, state: state, spender: addr("drainer")}
    end

    defp approval(b, i, owner, spender, amount \\ "uint256_max") do
      amt =
        if amount == "uint256_max", do: Integer.to_string(Integer.pow(2, 256) - 1), else: amount

      record(b, i, %{
        "kind" => "approval",
        "owner" => owner,
        "spender" => spender,
        "amount" => amt
      })
    end

    test "fires once 8 distinct owners approve the same new spender", %{
      rule: rule,
      state: st,
      spender: sp
    } do
      b1 = block(400)
      {[], st} = run(rule, for(i <- 1..5, do: approval(b1, i, addr("victim#{i}"), sp)), st, b1)
      b2 = block(401)
      # The same owner twice counts once.
      recs = [
        approval(b2, 0, addr("victim1"), sp)
        | for(i <- 6..8, do: approval(b2, i, addr("victim#{i}"), sp))
      ]

      {[c], st} = run(rule, recs, st, b2)
      assert c.title =~ "8 wallets approved unknown spender"
      assert length(c.evidence) == 8

      # Already fired for this group: more approvals do not re-fire.
      b3 = block(402)
      {[], _} = run(rule, [approval(b3, 0, addr("victim9"), sp)], st, b3)
    end

    test "approvals outside the window do not accumulate", %{rule: rule, state: st, spender: sp} do
      b1 = block(400)
      {[], st} = run(rule, for(i <- 1..5, do: approval(b1, i, addr("v#{i}"), sp)), st, b1)
      b2 = block(400 + rule.within_blocks)
      {[], _} = run(rule, for(i <- 6..8, do: approval(b2, i, addr("v#{i}"), sp)), st, b2)
    end

    test "limited approvals and spenders seen during warm-up are ignored", %{
      rule: rule,
      spender: sp
    } do
      # Spender first seen in block 1, during warm-up, so it is not novel.
      {_, st} = run(rule, [approval(block(1), 0, addr("early"), sp)], %{}, block(1))

      st =
        Enum.reduce(2..(rule.warmup_blocks + 1), st, fn n, st ->
          {_, st} = Evaluator.evaluate(rule, st, Evaluator.context(1, block(n), []))
          st
        end)

      b = block(400)
      {[], _} = run(rule, for(i <- 1..9, do: approval(b, i, addr("v#{i}"), sp)), st, b)

      {[], _} =
        run(rule, for(i <- 1..9, do: approval(b, i, addr("w#{i}"), addr("other"), "1000")), st, b)
    end

    test "a reorg removes the orphaned block's approvals from the window", %{
      rule: rule,
      state: st,
      spender: sp
    } do
      b1 = block(400)
      {[], st} = run(rule, for(i <- 1..5, do: approval(b1, i, addr("v#{i}"), sp)), st, b1)
      st = Evaluator.orphan(rule, st, {1, b1["hash"]})
      b2 = block(400, "fork")
      {[], _} = run(rule, for(i <- 6..8, do: approval(b2, i, addr("v#{i}"), sp)), st, b2)
    end
  end

  describe "rule format" do
    test "rejects bad rules with a pointer to the problem" do
      assert {:error, msg} = Rule.from_yaml("id: x\n", "bad.yaml")
      assert msg =~ "bad.yaml"
      base = "id: my-rule\nname: n\nseverity: high\nweakness: {class: c}\ntitle: t\n"

      assert {:error, msg} =
               Rule.from_yaml(base <> "scope: record\nmatch: {kind: [a], valu_usd: 1}\n")

      assert msg =~ "valu_usd"
      assert {:error, msg} = Rule.from_yaml(base <> "scope: tx\nrequire: []\n")
      assert msg =~ "require"

      assert {:error, msg} =
               Rule.from_yaml(
                 String.replace(base, "high", "urgent") <> "scope: record\nmatch: {kind: a}\n"
               )

      assert msg =~ "severity"

      assert {:error, msg} =
               Rule.from_yaml(
                 "id: my-rule\nname: n\nseverity: low\ntitle: t\nscope: record\nmatch: {kind: a}\n"
               )

      assert msg =~ "weakness"
    end
  end
end
