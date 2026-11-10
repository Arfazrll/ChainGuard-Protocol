#!/usr/bin/env bash
# Enforces SvlteChain's non-negotiable invariants in CI. Fails if the code
# that guarantees them is removed, weakened, or bypassed:
#   1. Read-only: no signing/wallet/keystore code or dependencies, and all
#      node traffic goes through the allowlisted RPC client.
#   2. Multi-node verification: quorum guards and their tests exist and pass.
#   3. Reorg safety: the reorg test-suite exists and passes.
#   4. Tamper-evident audit trail: append-only at the database, hash chain verified.
#   5. No false urgency: dedup, rate limits, and the ML lane's severity ceiling.
#   6. Tenant isolation: watchlists, routes and keys never cross organizations.
# Covers the Rust ingestion crates, the detection engine (apps/engine) when
# Elixir is installed, the ML service (services/anomaly) when uv is installed,
# and the two web front ends.
# Usage: scripts/check-invariants.sh   (from anywhere; needs cargo)
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
violation() { echo "INVARIANT VIOLATION: $*" >&2; fail=1; }
ok() { echo "ok: $*"; }

# --- 1a. No signer / wallet / key-management crates in the build graph -----
# Checked against the resolved tree for every target (not Cargo.lock, which
# also lists optional dependencies that are never compiled).
FORBIDDEN_CRATES='^(alloy-signer[a-z0-9-]*|alloy-network|alloy-provider|ethers|ethers-signers|ethers-middleware|eth-keystore|coins-bip32|coins-bip39|bip39|k256|secp256k1|ecdsa|ledger-transport[a-z0-9-]*|trezor-client) v'
found=$(cargo tree --workspace -e normal,build --target all --prefix none 2>/dev/null | grep -E "$FORBIDDEN_CRATES" | sort -u || true)
if [[ -n "$found" ]]; then
  violation "signing/key-management crates in the dependency graph:"$'\n'"$found"
else
  ok "no signer, wallet or keystore crates in the build graph"
fi

# --- 1b. No signing or transaction-sending code in production sources -------
# crates/rpc/src/lib.rs is exempt: it *defines* the deny-list.
pattern='eth_send|eth_sign|signTransaction|sign_transaction|personal_|wallet_|PrivateKey|private_key|mnemonic|keystore|SigningKey|LocalSigner'
hits=$( (grep -rnE "$pattern" crates/*/src --include='*.rs'
         grep -rnE "$pattern" apps/engine/lib --include='*.ex' 2>/dev/null
         grep -rnE "$pattern" apps/dashboard/src --include='*.ts' 2>/dev/null
         grep -rnE "$pattern" apps/landing/src --include='*.ts' --include='*.svelte' 2>/dev/null
         grep -rnE "$pattern" services/anomaly/src services/report/src --include='*.py' 2>/dev/null)        | grep -v '^crates/rpc/src/lib.rs:' || true)
if [[ -n "$hits" ]]; then
  violation "signing/sending code in production sources:"$'\n'"$hits"
else
  ok "no signing or sending code in production sources"
fi

# --- 1c. The RPC choke point still enforces the allowlist -------------------
if grep -q 'if !is_allowed(method)' crates/rpc/src/lib.rs; then
  ok "HttpNode::call enforces the read-only allowlist"
else
  violation "crates/rpc/src/lib.rs: HttpNode::call no longer checks is_allowed(method)"
fi

# --- 1d. Only the RPC crate may speak HTTP --------------------------------
direct=$(cargo tree --workspace -e normal -i reqwest --depth 1 --prefix none 2>/dev/null | grep '^chainguard-' | awk '{print $1}' | sort -u || true)
if [[ "$direct" == "chainguard-rpc" ]]; then
  ok "only chainguard-rpc depends on an HTTP client"
else
  violation "crates other than chainguard-rpc depend on reqwest directly: $direct"
fi

# --- 5. The ML lane can never page on its own -------------------------------
if grep -q '@ceiling :medium' apps/engine/lib/chain_guard/anomaly.ex &&
   grep -q 'def lane_gate("ml", severity)' apps/engine/lib/chain_guard/alerts/manager.ex; then
  ok "ML lane severity ceiling (medium) is enforced in the client and the alert manager"
else
  violation "the ML lane severity ceiling was removed (anomaly.ex @ceiling / manager.ex lane_gate)"
fi

# --- 4. The audit log is append-only at the database level -------------------
mig=$(ls apps/engine/priv/repo/migrations/*_create_audit_log.exs 2>/dev/null | head -1)
if [[ -n "$mig" ]] && grep -q "BEFORE UPDATE OR DELETE ON audit_log" "$mig" \
   && grep -q "BEFORE TRUNCATE ON audit_log" "$mig"; then
  ok "audit_log refuses UPDATE, DELETE and TRUNCATE (database trigger)"
else
  violation "the audit_log append-only triggers were removed from the migration"
fi

# --- 2 & 3. Guard tests exist, are not ignored, and pass --------------------
REQUIRED_TESTS=(
  # invariant 1: read-only
  invariant_read_only_allowlist_contains_no_write_methods
  invariant_read_only_client_refuses_write_methods_without_touching_the_network
  # invariant 2: multi-node verification
  invariant_multi_node_single_source_is_rejected_by_default
  invariant_multi_node_quorum_must_be_a_strict_majority
  invariant_multi_node_every_record_is_attested_by_at_least_two_nodes
  invariant_multi_node_forging_node_is_outvoted
  invariant_multi_node_two_disagreeing_nodes_block_progress
  invariant_multi_node_omitted_logs_are_detected
  invariant_multi_node_config_defaults_to_two_sources
  # invariant 3: reorg safety
  reorg_retracts_orphaned_records_and_reemits_canonical_ones
  reorg_below_finality_halts_and_never_rewrites_finalized_history
  fork_head_below_finality_height_halts_instead_of_being_ignored
  at_least_once_redelivery_is_idempotent_downstream
  any_sequence_of_reorgs_converges_or_halts_safely
)
out=$(cargo test --workspace --no-fail-fast 2>&1 || true)
for t in "${REQUIRED_TESTS[@]}"; do
  if grep -qE "^test (.*::)?${t} \.\.\. ok$" <<<"$out"; then
    ok "test $t passed"
  else
    violation "required test $t is missing, ignored, or failing"
  fi
done

# --- Detection engine (Elixir): invariants 2, 3, 5 at the alert layer -------
ENGINE_TESTS=(
  "invariant 2: high/critical evidence from a single node is capped at medium"
  "invariant 3: an orphaned evidence block retracts the alert and tells connectors"
  "invariant 5: duplicates merge instead of paging again"
  "invariant 5: per-rule rate limit suppresses the excess"
  "chain flow (invariant 3 end to end) reorg retracts the alert; the canonical re-inclusion raises a new one; finality settles it"
  "chain flow (invariant 3 end to end) redelivered messages are ignored (idempotent consumer)"
  "historical incident replay through the Broadway pipeline Euler Finance, 2023-03-13 (block 16,817,996): flash-loan drain detected"
  "historical incident replay through the Broadway pipeline baseline: a block of ordinary mainnet traffic raises nothing high or critical"
  "historical incident replay through the Broadway pipeline USDC depeg, 2023-03-11: quiet at \$0.9821 (block 16,802,107), high at \$0.9765 (16,802,135)"
  "monitor processes a reorg rolls the monitor back to before the orphaned block"
  "monitor processes a crashing monitor restarts alone; the others keep running"
  "ML lane never raises above medium, even if a candidate asks for critical"
  "service down: the lane degrades and skips blocks; rules and invariants are unaffected"
  # invariant 4: tamper-evident audit trail
  "hash chain invariant 4: entries form a hash chain that verify/0 re-derives"
  "hash chain invariant 4: the database refuses UPDATE, DELETE and TRUNCATE on the audit log"
  "hash chain invariant 4: an edit that bypasses the database guard is detected at that entry"
  "writer invariant 4: every alert event is written with its inputs and sources"
  # invariant 6: tenant isolation
  "keys and roles invariant 6: roles gate what a key can do"
  "isolation invariant 6: one org can never read or change another org's watchlist, routes or keys"
  "isolation invariant 6: an alert reaches only the orgs that watch its addresses"
  "isolation invariant 6: org channels require that org's key"
)
if command -v mix >/dev/null 2>&1; then
  eout=$(cd apps/engine && mix test --trace 2>&1 || true)
  for t in "${ENGINE_TESTS[@]}"; do
    # Trace mode prints "* test NAME (Xms)" even for failures; a failure
    # also prints "N) test NAME (Module)". Require the first, forbid the second.
    if grep -qF "* test $t (" <<<"$eout" && ! grep -qF ") test $t (" <<<"$eout"; then
      ok "engine test passed: $t"
    else
      violation "required engine test is missing or failing: $t"
    fi
  done
elif [[ "${CI:-}" == "true" ]]; then
  violation "Elixir (mix) is not installed in CI; the engine invariants cannot be checked"
else
  echo "skip: Elixir not installed locally; engine invariants are checked in CI"
fi

# --- ML service (Python): reorg-aware learning, attacks never become normal ---
ML_TESTS=(
  test_reorg_unlearns_the_orphaned_block_and_duplicates_are_ignored
  test_anomalies_are_not_learned_as_normal
  test_a_drain_is_flagged_by_both_flow_and_graph_models_with_evidence
)
if command -v uv >/dev/null 2>&1; then
  mout=$(cd services/anomaly && uv run --locked pytest -o addopts= -v -p no:cacheprovider 2>&1 || true)
  for t in "${ML_TESTS[@]}"; do
    if grep -qE "::${t} PASSED" <<<"$mout"; then
      ok "ML test passed: $t"
    else
      violation "required ML test is missing or failing: $t"
    fi
  done
elif [[ "${CI:-}" == "true" ]]; then
  violation "uv is not installed in CI; the ML lane guards cannot be checked"
else
  echo "skip: uv not installed locally; ML lane guards are checked in CI"
fi

if [[ $fail -ne 0 ]]; then
  echo "invariant check FAILED" >&2
  exit 1
fi
echo "all invariants hold"
