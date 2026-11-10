import { ChangeDetectionStrategy, Component, computed, input } from '@angular/core';
import { InvariantStatus, MlStatus } from '../core/models';
import { int, usdCompact } from '../core/format';

const STATE = {
  ok: { label: 'Holding', glyph: '✓' },
  breached: { label: 'Broken', glyph: '◆' },
  warming_up: { label: 'Warming up', glyph: '◌' },
} as const;

const ML = {
  ok: 'Scoring every block',
  starting: 'Waiting for first block',
  degraded: 'Unavailable: skipping blocks, other lanes unaffected',
  disabled: 'Not configured (CHAINGUARD_ANOMALY_URL)',
} as const;

/**
 * Invariant lane status (one row per monitored property) plus the ML lane's
 * health. State is always a label and a glyph; red only when broken.
 */
@Component({
  selector: 'cg-invariant-panel',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <header class="head">
      <h2>Invariants</h2>
      <span class="sum">{{ summary() }}</span>
    </header>

    @if (items().length === 0) {
      <p class="empty">No invariant status yet.</p>
    } @else {
      <ul class="list">
        @for (i of items(); track i.id) {
          <li class="row state--{{ i.state }}">
            <span class="state" [title]="i.state === 'warming_up' ? 'No data for this feed or protocol yet' : ''">
              <i aria-hidden="true">{{ meta[i.state].glyph }}</i>{{ meta[i.state].label }}
            </span>
            <span class="name">{{ i.name }}</span>
            <span class="value mono">{{ value(i) }}</span>
            @if (i.kind === 'outflow') {
              <span class="meter" role="meter" [attr.aria-valuenow]="i.value ?? 0" aria-valuemin="0" [attr.aria-valuemax]="i.limit"
                [attr.aria-label]="i.name + ': ' + value(i)">
                <span class="fill" [style.width.%]="fill(i)"></span>
              </span>
            }
          </li>
        }
      </ul>
    }

    @if (ml(); as m) {
      <p class="ml ml--{{ m.state }}">
        <strong>ML lane</strong> {{ mlText[m.state] }}
        @if (m.state === 'ok') { · {{ int(m.blocks_scored) }} blocks · capped at {{ m.severity_ceiling }} }
      </p>
    }
  `,
  styles: `
    :host { display: block; }
    .head { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 8px; }
    .head h2 { font: 600 16px/1.2 var(--font-display); letter-spacing: -0.01em; margin: 0; }
    .sum { color: var(--ink-3); font-size: 12px; }
    .list { list-style: none; margin: 0; padding: 0; display: grid; gap: 2px; }
    .row { display: grid; grid-template-columns: 104px 1fr auto; grid-template-areas: 'state name value' 'meter meter meter'; gap: 2px 10px; align-items: baseline; padding: 6px 0; border-bottom: 1px solid var(--hairline); font-size: 12.5px; }
    .state { grid-area: state; color: var(--ink-3); white-space: nowrap; }
    .state i { font-style: normal; margin-right: 5px; }
    .state--ok .state { color: var(--live); }
    .state--breached .state { color: var(--sev-critical); font-weight: 600; }
    .name { grid-area: name; color: var(--ink-2); min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .value { grid-area: value; color: var(--ink-1); font-size: 12px; white-space: nowrap; }
    .meter { grid-area: meter; height: 4px; border-radius: 4px; background: var(--surface-3); overflow: hidden; margin-top: 2px; }
    .fill { display: block; height: 100%; border-radius: 4px; background: var(--brand); }
    .state--breached .fill { background: var(--sev-critical); }
    .empty { color: var(--ink-3); margin: 0; font-size: 13px; }
    .ml { margin: 12px 0 0; font-size: 12.5px; color: var(--ink-3); }
    .ml strong { color: var(--ink-2); font-weight: 600; margin-right: 4px; }
    .ml--degraded { color: var(--sev-medium); }
  `,
})
export class InvariantPanel {
  readonly statuses = input.required<InvariantStatus[]>();
  readonly ml = input<MlStatus | null>(null);

  protected readonly meta = STATE;
  protected readonly mlText = ML;
  protected readonly int = int;

  /** Broken first, then holding, then warming up. */
  protected readonly items = computed(() => {
    const rank = { breached: 0, ok: 1, warming_up: 2 } as const;
    return [...this.statuses()].sort((a, b) => rank[a.state] - rank[b.state] || a.name.localeCompare(b.name));
  });

  protected readonly summary = computed(() => {
    const xs = this.statuses();
    const broken = xs.filter((x) => x.state === 'breached').length;
    const ok = xs.filter((x) => x.state === 'ok').length;
    return `${broken} broken · ${ok} holding · ${xs.length - broken - ok} warming up`;
  });

  protected value(i: InvariantStatus): string {
    if (i.value == null) return '-';
    switch (i.kind) {
      case 'peg':
        return `$${i.value.toFixed(4)} (${((i.deviation ?? 0) * 100).toFixed(2)}% off; band ${(i.limit * 100).toFixed(0)}%)`;
      case 'oracle':
        return `$${i.value.toLocaleString('en-US', { maximumFractionDigits: 2 })} · ${i.age_s == null ? '?' : Math.round(i.age_s / 60)} min old`;
      case 'outflow':
        return `${usdCompact(Math.max(0, i.value))} / ${usdCompact(i.limit)} per ${i.within_blocks} blocks`;
    }
  }

  protected fill(i: InvariantStatus): number {
    return Math.max(0, Math.min(100, ((i.value ?? 0) / i.limit) * 100));
  }
}
