import { ChangeDetectionStrategy, Component, computed, input } from '@angular/core';
import { AuditStatus, RiskBand, RiskScore } from '../core/models';
import { short } from '../core/format';

/** Band label. Colour backs it up and is never the only carrier. */
const BAND: Record<RiskBand, string> = {
  critical: 'Critical',
  high: 'High',
  elevated: 'Elevated',
  low: 'Low',
};

/**
 * Protocol health scores (0 to 100) from the risk-score API, worst first, and
 * the state of the tamper-evident audit chain behind them.
 */
@Component({
  selector: 'cg-risk-panel',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <header class="panel-head">
      <h2>Protocol risk</h2>
      @if (model()) { <span class="panel-meta">Model <span class="mono">{{ model() }}</span></span> }
    </header>

    @if (rows().length === 0) {
      <p class="empty">No scores yet. Scores appear once the first block is processed.</p>
    } @else {
      <ul class="list">
        @for (s of rows(); track s.protocol) {
          <li class="row band--{{ s.band }}">
            <span class="name">{{ s.protocol }}</span>
            <span class="score num" [attr.aria-label]="s.protocol + ' score ' + s.score + ' of 100'">{{ s.score }}</span>
            <span class="band">{{ bands[s.band] }}</span>
            <span class="meter" aria-hidden="true"><span class="fill" [style.width.%]="s.score < 2 ? 2 : s.score"></span></span>
            @if (s.band !== 'low') { <span class="why">{{ why(s) }}</span> }
          </li>
        }
      </ul>
      @if (healthy() > 0) {
        <p class="foot">Protocols at Low have no open alerts and no broken invariants.</p>
      }
    }

    <div class="audit audit--{{ auditState() }}" role="status">
      <h3>Audit chain</h3>
      @switch (auditState()) {
        @case ('valid') {
          <p><strong>Verified.</strong> {{ audit()!.entries }} entries, every link intact.</p>
          <p class="head">Latest hash <span class="mono">{{ short(audit()!.head, 10, 8) }}</span></p>
        }
        @case ('broken') {
          <p><strong>Broken at entry {{ audit()!.broken_at }}.</strong> {{ audit()!.reason }}</p>
        }
        @default { <p>Status unavailable. The engine has not reported the audit chain yet.</p> }
      }
    </div>
  `,
  styles: `
    :host { display: block; }
    .list { list-style: none; margin: 0; padding: 0; }
    .row {
      display: grid;
      grid-template-columns: 1fr 44px 76px;
      grid-template-areas: 'name score band' 'meter meter meter' 'why why why';
      gap: 4px 12px;
      align-items: baseline;
      padding: 10px 0;
      border-top: 1px solid var(--rule-soft);
      font-size: 13.5px;
    }
    .row:first-child { border-top: 0; padding-top: 0; }
    .name { grid-area: name; text-transform: capitalize; font-weight: 500; color: var(--ink); }
    .score { grid-area: score; text-align: right; font-size: 16px; font-weight: 600; color: var(--ink); }
    .band { grid-area: band; font-size: 12.5px; font-weight: 500; color: var(--ok); white-space: nowrap; }
    .meter { grid-area: meter; height: 4px; border-radius: 4px; background: var(--surface-3); overflow: hidden; }
    .fill { display: block; height: 100%; border-radius: 4px; background: var(--ok); }
    .why { grid-area: why; color: var(--muted); font-size: 12.5px; }
    .band--elevated .fill { background: var(--sev-medium); }
    .band--elevated .band { color: var(--sev-medium); }
    .band--high .fill { background: var(--sev-high); }
    .band--high .band { color: var(--sev-high); }
    .band--critical .fill { background: var(--sev-critical); }
    .band--critical .band { color: var(--sev-critical); font-weight: 600; }
    .empty { color: var(--graphite); margin: 0; font-size: 13px; }
    .foot { margin: 8px 0 0; color: var(--muted); font-size: 12.5px; }
    .band--low { padding: 7px 0; }
    .audit { margin-top: 16px; padding: 14px 16px; border-radius: var(--r-sm); background: var(--surface-2); border: 1px solid var(--rule-soft); font-size: 13px; color: var(--graphite); }
    .audit h3 { font-size: 13px; color: var(--ink); margin-bottom: 4px; letter-spacing: 0; }
    .audit p { margin: 0; overflow-wrap: anywhere; }
    .audit .head { margin-top: 4px; color: var(--muted); font-size: 12.5px; }
    .audit--valid strong { color: var(--ok); }
    .audit--broken { background: var(--sev-critical-wash); border-color: transparent; }
    .audit--broken strong { color: var(--sev-critical); }
  `,
})
export class RiskPanel {
  readonly scores = input.required<RiskScore[]>();
  readonly audit = input<AuditStatus | null>(null);

  protected readonly bands = BAND;
  protected readonly short = short;

  protected readonly rows = computed(() => [...this.scores()].sort((a, b) => a.score - b.score || a.protocol.localeCompare(b.protocol)));
  protected readonly healthy = computed(() => this.scores().filter((s) => s.band === 'low').length);
  protected readonly model = computed(() => this.scores()[0]?.model ?? '');
  protected readonly auditState = computed(() => {
    const a = this.audit();
    return a == null ? 'unknown' : a.valid ? 'valid' : 'broken';
  });

  protected why(s: RiskScore): string {
    const [alerts, invariants] = s.components;
    const parts = [];
    if (alerts?.items.length) parts.push(`${alerts.items.length} open alert${alerts.items.length === 1 ? '' : 's'} (−${Math.round(alerts.deduction)})`);
    const broken = invariants?.items.filter((i) => i.state === 'breached').length ?? 0;
    if (broken) parts.push(`${broken} invariant${broken === 1 ? '' : 's'} broken (−${invariants.deduction})`);
    if (!parts.length) parts.push('No open alerts');
    return `${parts.join(', ')}. Confidence ${s.confidence}.`;
  }
}
