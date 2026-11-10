defmodule ChainGuard.Rules.PredicateTest do
  use ExUnit.Case, async: true

  alias ChainGuard.Rules.Predicate
  import ChainGuard.Fixtures

  defp compile!(spec) do
    {:ok, p} = Predicate.compile(spec)
    p
  end

  setup do
    b = block(1)

    approval =
      record(
        b,
        0,
        %{
          "kind" => "approval",
          "owner" => "0xAA",
          "spender" => "0xBb",
          "amount" => Integer.to_string(Integer.pow(2, 256) - 1)
        },
        labels: [label("owner", "0xaa", "Some wallet", "exchange")],
        value_usd: nil
      )

    {:ok, approval: approval}
  end

  test "equality, membership and comparison", %{approval: r} do
    assert Predicate.matches?(compile!(%{"kind" => "approval"}), r)
    assert Predicate.matches?(compile!(%{"kind" => ["swap", "approval"]}), r)
    refute Predicate.matches?(compile!(%{"kind" => %{"ne" => "approval"}}), r)

    assert Predicate.matches?(compile!(%{"event.amount" => %{"gte" => "2^255"}}), r),
           "256-bit decimal strings compare numerically"

    refute Predicate.matches?(compile!(%{"event.amount" => %{"lt" => "1_000"}}), r)
  end

  test "addresses compare case-insensitively", %{approval: r} do
    assert Predicate.matches?(compile!(%{"event.spender" => "0xbB"}), r)
    assert Predicate.matches?(compile!(%{"event.owner" => ["0xaa"]}), r)
  end

  test "labels by role and presence", %{approval: r} do
    assert Predicate.matches?(compile!(%{"label.owner.category" => "exchange"}), r)
    assert Predicate.matches?(compile!(%{"label.spender" => %{"exists" => false}}), r)
    refute Predicate.matches?(compile!(%{"label.owner" => %{"exists" => false}}), r)
  end

  test "missing values never satisfy comparisons", %{approval: r} do
    refute Predicate.matches?(compile!(%{"value_usd" => %{"gte" => 0}}), r)
    assert Predicate.matches?(compile!(%{"value_usd" => %{"ne" => 5}}), r)
  end

  test "combinators", %{approval: r} do
    assert Predicate.matches?(
             compile!(%{"any" => [%{"kind" => "swap"}, %{"kind" => "approval"}]}),
             r
           )

    refute Predicate.matches?(compile!(%{"not" => %{"kind" => "approval"}}), r)

    assert Predicate.matches?(
             compile!(%{"all" => [%{"kind" => "approval"}, %{"attestations" => %{"gte" => 2}}]}),
             r
           )
  end

  test "typos fail at load time with a message" do
    assert {:error, msg} = Predicate.compile(%{"knd" => "approval"})
    assert msg =~ "unknown field \"knd\""
    assert {:error, msg} = Predicate.compile(%{"value_usd" => %{"greater" => 1}})
    assert msg =~ "unknown operator"
    assert {:error, msg} = Predicate.compile(%{"value_usd" => %{"gte" => "lots"}})
    assert msg =~ "needs a number"
    assert {:error, _} = Predicate.compile(%{"value_usd" => %{"gte" => 1, "lte" => 2}})
    assert {:error, _} = Predicate.compile(%{})
  end
end
