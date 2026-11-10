#!/usr/bin/env bash
# Enforces ChainGuard's non-negotiable invariants in CI. Fails if the code
# that guarantees them is removed, weakened, or bypassed:
#   1. Read-only: no signing/wallet/keystore code or dependencies, and all
#      node traffic goes through the allowlisted RPC client.
#   2. Multi-node verification: quorum guards and their tests exist and pass.
#   3. Reorg safety: the reorg test-suite exists and passes.
# Covers the Rust ingestion crates and, when Elixir is installed, the
# detection engine (apps/engine).
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
hits=$( (grep -rnE "$pattern" crates/*/src --include='*.rs';          grep -rnE "$pattern" apps/engine/lib --include='*.ex' 2>/dev/null;          grep -rnE "$pattern" apps/dashboard/src --include='*.ts' 2>/dev/null)        | grep -v '^crates/rpc/src/lib.rs:' || true)
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

if [[ $fail -ne 0 ]]; then
  echo "invariant check FAILED" >&2
  exit 1
fi
echo "all invariants hold"
