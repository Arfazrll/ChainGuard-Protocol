import { ChangeDetectionStrategy, Component, computed, input } from '@angular/core';
import { InvariantStatus, MlStatus } from '../core/models';
import { int, usdCompact } from '../core/format';

const STATE = {
  ok: 'Holding',
  breached: 'Broken',
  warming_up: 'Warming up',
} as const;

const ML = {
  ok: 'Scoring every block',
  starting: 'Waiting for the first block',
  degraded: 'Unavailable. Blocks are skipped by the model; rules and invariants are unaffected.',
  disabled: 'Not configured (set CHAINGUARD_ANOMALY_URL)',
} as const;

/**
 * Invariant lane status (one row per monitored property) plus the model
 * lane's health. State is always a label; red only when broken.
 */
@Component({
  selector: 'cg-invariant-panel',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <header class="panel-head">
      <h2>Invariants</h2>
      <span class="panel-meta">{{ summary() }}</span>
    </header>

    @if (items().length === 0) {
      <p class="empty">No invariant status yet.</p>
    } @else {
      <ul class="list">
        @for (i of items(); track i.id) {
          <li class="row state--{{ i.state }}">
            <span class="state" [title]="i.state === 'warming_up' ? 'No data for this feed or protocol yet' : ''">{{ meta[i.state] }}</span>
            <span class="name" [title]="i.name">{{ i.name }}</span>
            <span class="value num">{{ value(i) }}</span>
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
        <strong>Model lane.</strong> {{ mlText[m.state] }}
        @if (m.state === 'ok') { ({{ int(m.blocks_scored) }} blocks so far, alerts capped at {{ m.severity_ceiling }}) }
      </p>
    }
  `,
  styles: `
    :host { display: block; }
    .list { list-style: none; margin: 0; padding: 0; }
    .row {
      display: grid;
      grid-template-columns: 84px minmax(0, 1fr) auto;
      grid-template-areas: 'state name value' 'meter meter meter';
      gap: 4px 12px;
      align-items: baseline;
      padding: 8px 0;
      border-top: 1px solid var(--rule-soft);
      font-size: 13px;
    }
    .row:first-child { border-top: 0; padding-top: 0; }
    .state { grid-area: state; font-size: 12.5px; font-weight: 500; color: var(--muted); white-space: nowrap; }
    .state--ok .state { color: var(--ok); }
    .state--breached .state { color: var(--sev-critical); font-weight: 600; }
    .name { grid-area: name; color: var(--ink-2); min-width: 0; }
    .value { grid-area: value; color: var(--ink); font-size: 12.5px; white-space: nowrap; }
    .meter { grid-area: meter; height: 4px; border-radius: 4px; background: var(--surface-3); overflow: hidden; margin-top: 2px; }
    .fill { display: block; height: 100%; border-radius: 4px; background: var(--series); }
    .state--breached .fill { background: var(--sev-critical); }
    .empty { color: var(--graphite); margin: 0; font-size: 13px; }
    .ml { margin: 14px 0 0; padding-top: 12px; border-top: 1px solid var(--rule); font-size: 13px; color: var(--graphite); }
    .ml strong { color: var(--ink); font-weight: 600; }
    .ml--degraded { color: var(--sev-medium); }
    @media (max-width: 600px) {
      .row { grid-template-columns: 84px minmax(0, 1fr); grid-template-areas: 'state name' 'state value' 'meter meter'; }
      .value { white-space: normal; color: var(--graphite); }
    }
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
    const warming = xs.length - broken - ok;
    return `${broken} broken, ${ok} holding${warming ? `, ${warming} warming up` : ''}`;
  });

  protected value(i: InvariantStatus): string {
    if (i.value == null) return '-';
    switch (i.kind) {
      case 'peg':
        return `$${i.value.toFixed(4)}, ${((i.deviation ?? 0) * 100).toFixed(2)}% off (band ${(i.limit * 100).toFixed(0)}%)`;
      case 'oracle':
        return `$${i.value.toLocaleString('en-US', { maximumFractionDigits: 2 })}, ${i.age_s == null ? '?' : Math.round(i.age_s / 60)} min old`;
      case 'outflow':
        return `${usdCompact(Math.max(0, i.value))} of ${usdCompact(i.limit)} per ${i.within_blocks} blocks`;
    }
  }

  protected fill(i: InvariantStatus): number {
    return Math.max(0, Math.min(100, ((i.value ?? 0) / i.limit) * 100));
  }
}
