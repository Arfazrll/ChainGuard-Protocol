import { ChangeDetectionStrategy, Component, input } from '@angular/core';
import { BlockSummary, Evidence, ReorgEvent } from '../core/models';
import { int, kindLabel, ms, short, usdCompact } from '../core/format';

/** "Right now": every block as it is adopted, with its notable flows. */
@Component({
  selector: 'cg-block-stream',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <header class="head">
      <h2>Right now</h2>
      <span class="hint">Ethereum mainnet · each block verified by independent nodes</span>
    </header>

    @if (reorgs().length) {
      <p class="reorg" role="status">
        <span aria-hidden="true">↯</span> Reorg depth {{ reorgs()[0].depth }} at #{{ reorgs()[0].common_ancestor.number + 1 }}: orphaned
        records retracted, canonical ones re-emitted.
      </p>
    }

    <div class="terminal" role="log" aria-live="polite" aria-label="Live blocks">
      @if (blocks().length === 0) {
        <p class="waiting">Waiting for the next block…</p>
      }
      @for (b of blocks(); track b.hash) {
        <div class="block" [class.orphaned]="b.status === 'orphaned'">
          <div class="line">
            <span class="num">#{{ int(b.number) }}</span>
            <span class="hash">{{ short(b.hash, 6, 4) }}</span>
            <span>{{ int(b.records) }} rec</span>
            <span>{{ int(b.txs) }} tx</span>
            <span class="ok" title="Nodes that returned this block's logs byte for byte">✓{{ b.attested_by.length }}</span>
            <span class="dim">eval {{ ms(b.eval_ms) }}</span>
            @if (b.alerts.length) {
              <span class="alerts">{{ b.alerts.length }} alert{{ b.alerts.length === 1 ? '' : 's' }}</span>
            }
            <span class="state state--{{ b.status }}">{{ b.status }}</span>
          </div>
          @for (n of b.notable ?? []; track n.record_id) {
            <div class="flow">
              <span aria-hidden="true">↳</span> {{ flow(n) }}
            </div>
          }
        </div>
      }
    </div>
  `,
  styles: `
    :host { display: block; }
    .head { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; flex-wrap: wrap; margin-bottom: 12px; }
    .head h2 { font: 600 20px/1.2 var(--font-display); letter-spacing: -0.02em; margin: 0; }
    .hint { color: var(--ink-3); font-size: 12.5px; }
    .terminal {
      font-family: var(--font-mono);
      font-size: 12px;
      background: var(--glass);
      backdrop-filter: blur(14px) saturate(140%);
      border: 1px solid var(--hairline-strong);
      border-radius: var(--radius);
      padding: 10px 0;
      max-height: 420px;
      overflow-y: auto;
    }
    .waiting { margin: 8px 16px; color: var(--ink-3); }
    .block { padding: 6px 16px; border-bottom: 1px solid var(--hairline); }
    .block:last-child { border-bottom: 0; }
    .line { display: flex; flex-wrap: wrap; gap: 4px 12px; color: var(--ink-2); }
    .num { color: var(--ink-1); font-weight: 500; }
    .hash, .dim { color: var(--ink-3); }
    .ok { color: var(--live); }
    .alerts { color: var(--sev-high); font-weight: 500; }
    .state { margin-left: auto; color: var(--ink-3); }
    .state--final { color: var(--live); }
    .state--orphaned { color: var(--sev-medium); }
    .orphaned .line > span:not(.state) { text-decoration: line-through; opacity: 0.6; }
    .flow { color: var(--ink-3); padding-left: 2px; margin-top: 2px; overflow-wrap: anywhere; }
    .reorg { margin: 0 0 10px; padding: 8px 12px; border-radius: var(--radius-sm); background: var(--surface-2); border-left: 2px solid var(--sev-medium); color: var(--ink-2); font-size: 12.5px; }
    @media (prefers-reduced-motion: no-preference) {
      .block:first-child { animation: drop 0.45s var(--ease) both; }
      @keyframes drop { from { opacity: 0; transform: translateY(-4px); } to { opacity: 1; transform: none; } }
    }
  `,
})
export class BlockStream {
  readonly blocks = input.required<BlockSummary[]>();
  readonly reorgs = input<ReorgEvent[]>([]);

  protected int = int;
  protected short = short;
  protected ms = ms;

  protected flow(e: Evidence): string {
    const value = e.value_usd != null ? usdCompact(e.value_usd) + ' ' : '';
    const token = e.labels.find((l) => l.role === 'contract')?.name;
    const to = e.labels.find((l) => l.role === 'to' || l.role === 'receiver')?.name;
    const what = e.kind === 'flash_loan' ? `flash loan (${(e.event['provider'] as string) ?? '?'})` : kindLabel(e.kind);
    return `${value}${what}${token ? ' · ' + token : ''}${to ? ' → ' + to : ''} · tx ${short(e.tx_hash, 6, 4)}`;
  }
}
