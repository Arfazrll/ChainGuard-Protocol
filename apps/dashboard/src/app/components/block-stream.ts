import { ChangeDetectionStrategy, Component, input } from '@angular/core';
import { BlockSummary, Evidence, ReorgEvent } from '../core/models';
import { int, kindLabel, ms, short, usdCompact } from '../core/format';

const STATUS = { provisional: 'Provisional', final: 'Final', orphaned: 'Orphaned' } as const;

/** Every block as it is adopted, with the nodes that attested it and its notable flows. */
@Component({
  selector: 'cg-block-stream',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <header class="panel-head">
      <div>
        <h2>Latest blocks</h2>
        <p class="panel-sub">Each block is accepted only when independent nodes return it identically.</p>
      </div>
    </header>

    @if (reorgs().length) {
      <p class="reorg" role="status">
        <strong>Reorg handled.</strong> Depth {{ reorgs()[0].depth }} at block {{ int(reorgs()[0].common_ancestor.number + 1) }}:
        orphaned records were retracted and the canonical ones processed.
      </p>
    }

    <div class="list" role="log" aria-live="polite" aria-label="Latest blocks">
      @if (blocks().length === 0) {
        <p class="waiting">Waiting for the next block.</p>
      }
      @for (b of blocks(); track b.hash) {
        <div class="block" [class.orphaned]="b.status === 'orphaned'">
          <div class="line">
            <span class="no num">{{ int(b.number) }}</span>
            <span class="details">
            <span class="hash mono">{{ short(b.hash, 6, 4) }}</span>
            <span class="num">{{ int(b.records) }} records</span>
            <span class="num">{{ int(b.txs) }} txs</span>
            <span class="nodes" title="Nodes that returned this block's logs byte for byte">{{ b.attested_by.length }} nodes</span>
            <span class="num dim" title="Time to evaluate every rule and invariant">{{ ms(b.eval_ms) }}</span>
            @if (b.alerts.length) {
              <span class="alerts">{{ b.alerts.length }} alert{{ b.alerts.length === 1 ? '' : 's' }}</span>
            }
            </span>
            <span class="state state--{{ b.status }}">{{ status[b.status] }}</span>
          </div>
          @for (n of b.notable ?? []; track n.record_id) {
            <p class="flow">{{ flow(n) }}</p>
          }
        </div>
      }
    </div>
  `,
  styles: `
    :host { display: block; }
    .list { max-height: 440px; overflow-y: auto; margin: 0 -20px -20px; border-top: 1px solid var(--rule-soft); }
    .waiting { margin: 16px 20px; color: var(--graphite); }
    .block { padding: 10px 20px; border-bottom: 1px solid var(--rule-soft); }
    .block:last-child { border-bottom: 0; }
    .line { display: grid; grid-template-columns: 84px minmax(0, 1fr) auto; align-items: baseline; gap: 12px; font-size: 13px; color: var(--graphite); }
    .details { display: flex; flex-wrap: wrap; gap: 2px 14px; }
    .no { color: var(--ink); font-weight: 600; }
    .hash, .dim { color: var(--muted); }
    .nodes { color: var(--ok); }
    .alerts { color: var(--sev-critical); font-weight: 600; }
    .state { font-size: 12.5px; color: var(--muted); }
    .state--final { color: var(--ok); }
    .state--orphaned { color: var(--sev-medium); }
    .orphaned .line > span:not(.state), .orphaned .details > span { text-decoration: line-through; opacity: 0.6; }
    .flow { margin: 4px 0 0 98px; color: var(--graphite); font-size: 12.5px; overflow-wrap: anywhere; }
    .reorg { margin: 0 0 12px; padding: 10px 12px; border-radius: 8px; background: var(--sev-medium-wash); color: var(--ink-2); font-size: 13px; }
    @media (max-width: 900px) {
      .list { margin: 0 -16px -16px; }
      .block { padding: 10px 16px; }
      .flow { margin-left: 0; }
    }
    @media (prefers-reduced-motion: no-preference) {
      .block:first-child { animation: drop 0.4s var(--ease) both; }
      @keyframes drop { from { opacity: 0; transform: translateY(-4px); } to { opacity: 1; transform: none; } }
    }
  `,
})
export class BlockStream {
  readonly blocks = input.required<BlockSummary[]>();
  readonly reorgs = input<ReorgEvent[]>([]);

  protected readonly status = STATUS;
  protected int = int;
  protected short = short;
  protected ms = ms;

  protected flow(e: Evidence): string {
    const value = e.value_usd != null ? usdCompact(e.value_usd) + ' ' : '';
    const token = e.labels.find((l) => l.role === 'contract')?.name;
    const to = e.labels.find((l) => l.role === 'to' || l.role === 'receiver')?.name;
    const what = e.kind === 'flash_loan' ? `flash loan from ${(e.event['provider'] as string) ?? 'unknown'}` : kindLabel(e.kind);
    return `${value}${what}${token ? ` in ${token}` : ''}${to ? ` to ${to}` : ''}, tx ${short(e.tx_hash, 6, 4)}`;
  }
}
