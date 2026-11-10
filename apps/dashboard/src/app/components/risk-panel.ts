import { ChangeDetectionStrategy, Component, computed, input } from '@angular/core';
import { AuditStatus, RiskBand, RiskScore } from '../core/models';
import { short } from '../core/format';

/** Band → label and glyph. Colour is never the only carrier (dataviz rule). */
const BAND: Record<RiskBand, { label: string; glyph: string }> = {
  critical: { label: 'Critical', glyph: '◆' },
  high: { label: 'High', glyph: '▲' },
  elevated: { label: 'Elevated', glyph: '●' },
  low: { label: 'Low', glyph: '✓' },
};

/**
 * Protocol health scores (0–100) from the risk-score API, worst first, and
 * the state of the tamper-evident audit chain behind them.
 */
@Component({
  selector: 'cg-risk-panel',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <header class="head">
      <h2>Protocol risk</h2>
      <span class="model mono">{{ model() }}</span>
    </header>

    @if (rows().length === 0) {
      <p class="empty">No scores yet.</p>
    } @else {
      <ul class="list">
        @for (s of rows(); track s.protocol) {
          <li class="row band--{{ s.band }}">
            <span class="name">{{ s.protocol }}</span>
            <span class="score mono" [attr.aria-label]="s.protocol + ' score ' + s.score + ' of 100'">{{ s.score }}</span>
            <span class="band"><i aria-hidden="true">{{ bands[s.band].glyph }}</i>{{ bands[s.band].label }}</span>
            <span class="meter" aria-hidden="true"><span class="fill" [style.width.%]="s.score"></span></span>
            <span class="why">{{ why(s) }}</span>
          </li>
        }
      </ul>
    }

    <p class="audit audit--{{ auditState() }}" role="status">
      @switch (auditState()) {
        @case ('valid') {
          <span aria-hidden="true">✓</span> Audit chain verified: {{ audit()!.entries }} entries, head
          <span class="mono">{{ short(audit()!.head, 8, 6) }}</span>
        }
        @case ('broken') {
          <span aria-hidden="true">◆</span> Audit chain broken at entry {{ audit()!.broken_at }}: {{ audit()!.reason }}
        }
        @default { Audit chain status unavailable }
      }
    </p>
  `,
  styles: `
    :host { display: block; }
    .head { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 8px; }
    .head h2 { font: 600 16px/1.2 var(--font-display); letter-spacing: -0.01em; margin: 0; }
    .model { color: var(--ink-3); font-size: 11.5px; }
    .list { list-style: none; margin: 0; padding: 0; }
    .row { display: grid; grid-template-columns: 1fr 40px 96px; grid-template-areas: 'name score band' 'meter meter meter' 'why why why'; gap: 3px 10px; align-items: baseline; padding: 7px 0; border-bottom: 1px solid var(--hairline); font-size: 13px; }
    .name { grid-area: name; text-transform: capitalize; color: var(--ink-1); }
    .score { grid-area: score; text-align: right; font-size: 14px; color: var(--ink-1); }
    .band { grid-area: band; color: var(--ink-2); font-size: 12px; white-space: nowrap; }
    .band i { font-style: normal; margin-right: 5px; }
    .meter { grid-area: meter; height: 4px; border-radius: 4px; background: var(--surface-3); overflow: hidden; }
    .fill { display: block; height: 100%; border-radius: 4px; background: var(--live); }
    .why { grid-area: why; color: var(--ink-3); font-size: 11.5px; }
    .band--elevated .fill { background: var(--sev-medium); }
    .band--elevated .band { color: var(--sev-medium); }
    .band--high .fill { background: var(--sev-high); }
    .band--high .band { color: var(--sev-high); }
    .band--critical .fill { background: var(--sev-critical); }
    .band--critical .band { color: var(--sev-critical); font-weight: 600; }
    .band--low .band { color: var(--live); }
    .empty { color: var(--ink-3); margin: 0; font-size: 13px; }
    .audit { margin: 12px 0 0; font-size: 12px; color: var(--ink-3); overflow-wrap: anywhere; }
    .audit--valid { color: var(--live); }
    .audit--broken { color: var(--sev-critical); font-weight: 600; }
  `,
})
export class RiskPanel {
  readonly scores = input.required<RiskScore[]>();
  readonly audit = input<AuditStatus | null>(null);

  protected readonly bands = BAND;
  protected readonly short = short;

  protected readonly rows = computed(() => [...this.scores()].sort((a, b) => a.score - b.score || a.protocol.localeCompare(b.protocol)));
  protected readonly model = computed(() => this.scores()[0]?.model ?? '');
  protected readonly auditState = computed(() => {
    const a = this.audit();
    return a == null ? 'unknown' : a.valid ? 'valid' : 'broken';
  });

  protected why(s: RiskScore): string {
    const [alerts, invariants] = s.components;
    const parts = [];
    if (alerts?.items.length) parts.push(`${alerts.items.length} alert${alerts.items.length === 1 ? '' : 's'} −${Math.round(alerts.deduction)}`);
    const broken = invariants?.items.filter((i) => i.state === 'breached').length ?? 0;
    if (broken) parts.push(`${broken} invariant${broken === 1 ? '' : 's'} broken −${invariants.deduction}`);
    parts.push(`confidence ${s.confidence}`);
    return parts.join(' · ');
  }
}
