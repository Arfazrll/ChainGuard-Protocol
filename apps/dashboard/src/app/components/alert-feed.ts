import { ChangeDetectionStrategy, Component, computed, input, signal } from '@angular/core';
import { Alert, Severity } from '../core/models';
import { SEVERITY_ORDER, filterAlerts, openBySeverity } from '../core/state';
import { SEVERITY_META, ago, explorerTx, kindLabel, short, usdCompact } from '../core/format';
import { reportUrl } from '../core/live.service';

const STATUS_META = {
  provisional: { label: 'Provisional', glyph: '◌', hint: 'Evidence is in a block that could still be reorged' },
  final: { label: 'Final', glyph: '✓', hint: 'Every evidence block is finalized' },
  retracted: { label: 'Retracted', glyph: '↺', hint: 'A reorg orphaned the evidence; this alert no longer stands' },
} as const;

const LANE_META = {
  rule: { label: 'Rule', hint: 'A YAML rule matched a known attack shape' },
  invariant: { label: 'Invariant', hint: 'A per-protocol property that must always hold was broken' },
  ml: { label: 'ML', hint: 'Statistical anomaly; capped at medium, corroborate before acting' },
  system: { label: 'System', hint: 'About the monitor itself' },
} as const;

@Component({
  selector: 'cg-alert-feed',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <header class="head">
      <div>
        <h2>Alerts</h2>
        <p class="sub">Three lanes (rules, invariants, ML). Every alert carries its weakness class and the exact on-chain evidence.</p>
      </div>
    </header>

    <div class="filters" role="group" aria-label="Filter alerts by severity">
      @for (s of severities; track s) {
        <button
          type="button"
          class="sev sev--{{ s }} toggle"
          [class.off]="!active().has(s)"
          [attr.aria-pressed]="active().has(s)"
          (click)="toggle(s)"
        >
          <i aria-hidden="true">{{ meta[s].glyph }}</i>{{ meta[s].label }}
          <span class="count">{{ counts()[s] }}</span>
        </button>
      }
      <label class="retracted">
        <input type="checkbox" [checked]="showRetracted()" (change)="showRetracted.set(!showRetracted())" />
        Show retracted
      </label>
    </div>

    @if (visible().length === 0) {
      <div class="empty">
        <span class="pulse" aria-hidden="true"></span>
        @if (alerts().length === 0) {
          <p><strong>No alerts.</strong> Rules are evaluating every block as it lands.</p>
        } @else {
          <p>No alerts match the current filter.</p>
        }
      </div>
    } @else {
      <ol class="list">
        @for (a of visible(); track a.id) {
          <li class="alert" [class.retracted]="a.status === 'retracted'" [class.fresh]="fresh().has(a.id)">
            <div class="row">
              <span class="sev sev--{{ a.severity }}"><i aria-hidden="true">{{ meta[a.severity].glyph }}</i>{{ meta[a.severity].label }}</span>
              <h3 class="title">{{ a.title }}</h3>
              <span class="status status--{{ a.status }}" [title]="status[a.status].hint">
                <span aria-hidden="true">{{ status[a.status].glyph }}</span> {{ status[a.status].label }}
              </span>
            </div>

            <div class="meta">
              <span class="lane" [title]="lanes[a.lane ?? 'rule'].hint">{{ lanes[a.lane ?? 'rule'].label }}</span>
              <span class="mono">{{ a.rule_id }}</span>
              <span>{{ a.weakness.class }}</span>
              @if (a.block_number) { <span class="mono">block #{{ a.block_number }}</span> }
              @if (!a.system) {
                <span [class.verified]="a.min_attestations >= 2" title="Independent RPC nodes that returned identical evidence">
                  {{ a.min_attestations >= 2 ? '✓' : '!' }} {{ a.sources.length }} node{{ a.sources.length === 1 ? '' : 's' }}
                </span>
              }
              @if (a.occurrences > 1) { <span>×{{ a.occurrences }}</span> }
              <span>{{ since(a.first_seen_ms) }}</span>
              @if (!a.system) {
                <a class="report" [href]="report + '/reports/alerts/' + a.id + '.pdf'" target="_blank" rel="noopener"
                  title="Compliance report with evidence and the audit-chain check">PDF report</a>
              }
            </div>

            @for (n of a.notes; track $index) {
              <p class="note">{{ n }}</p>
            }

            @if (a.evidence.length) {
              <button type="button" class="expand" [attr.aria-expanded]="open().has(a.id)" (click)="toggleOpen(a.id)">
                {{ open().has(a.id) ? 'Hide' : 'Show' }} evidence ({{ a.evidence.length }})
              </button>
              @if (open().has(a.id)) {
                <div class="evidence-wrap">
                  <table class="evidence">
                    <thead>
                      <tr><th>Event</th><th>Contract</th><th class="num">Value</th><th>Tx · log</th><th>Attested</th></tr>
                    </thead>
                    <tbody>
                      @for (e of a.evidence; track e.record_id) {
                        <tr>
                          <td>{{ kind(e.kind) }}</td>
                          <td>{{ contractLabel(e) }}</td>
                          <td class="num mono">{{ money(e.value_usd) }}</td>
                          <td class="mono">
                            @if (tx(a.chain_id, e.tx_hash); as href) {
                              <a [href]="href" target="_blank" rel="noopener">{{ short(e.tx_hash, 8, 4) }}</a>
                            } @else {
                              {{ short(e.tx_hash, 8, 4) }}
                            }
                            · {{ e.log_index }}
                          </td>
                          <td class="mono">{{ e.attested_by.length }}</td>
                        </tr>
                      }
                    </tbody>
                  </table>
                </div>
              }
            }
          </li>
        }
      </ol>
    }
  `,
  styles: `
    :host { display: block; }
    .head h2 { font: 600 20px/1.2 var(--font-display); letter-spacing: -0.02em; margin: 0; }
    .sub { margin: 4px 0 0; color: var(--ink-3); font-size: 13px; }
    .filters { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 16px 0 12px; }
    .toggle { cursor: pointer; transition: opacity 0.15s, background 0.15s; }
    .toggle:hover { background: var(--surface-2); }
    .toggle.off { opacity: 0.42; }
    .count { font-family: var(--font-mono); font-weight: 500; color: var(--ink-2); }
    .retracted { margin-left: auto; display: inline-flex; gap: 6px; align-items: center; color: var(--ink-3); font-size: 12.5px; cursor: pointer; }
    .retracted input { accent-color: var(--brand); }
    .list { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
    .alert {
      padding: 14px 16px;
      border-radius: var(--radius-sm);
      background: var(--surface-1);
      border: 1px solid var(--hairline);
      transition: border-color 0.2s;
    }
    .alert:hover { border-color: var(--hairline-strong); }
    .alert.retracted { opacity: 0.6; }
    .alert.retracted .title { text-decoration: line-through; text-decoration-color: var(--ink-3); }
    .row { display: flex; gap: 10px; align-items: baseline; flex-wrap: wrap; }
    .title { flex: 1 1 260px; margin: 0; font-size: 14.5px; font-weight: 600; line-height: 1.35; overflow-wrap: anywhere; }
    .status { font-size: 12px; color: var(--ink-2); white-space: nowrap; }
    .status--final { color: var(--live); }
    .meta { display: flex; flex-wrap: wrap; gap: 4px 14px; margin-top: 6px; color: var(--ink-3); font-size: 12.5px; }
    .meta .mono { font-size: 12px; }
    .verified { color: var(--live); }
    .report { color: var(--brand-ink); text-decoration: none; }
    .report:hover { text-decoration: underline; }
    .lane { color: var(--ink-2); border: 1px solid var(--hairline-strong); border-radius: 999px; padding: 0 7px; font-size: 11.5px; line-height: 17px; }
    .note { margin: 8px 0 0; padding: 6px 10px; border-left: 2px solid var(--sev-medium); color: var(--ink-2); font-size: 12.5px; background: var(--surface-2); border-radius: 0 6px 6px 0; }
    .expand { margin-top: 10px; background: none; border: 0; padding: 0; color: var(--brand-ink); cursor: pointer; font-size: 12.5px; }
    .evidence-wrap { overflow-x: auto; margin-top: 8px; }
    .evidence { width: 100%; border-collapse: collapse; font-size: 12.5px; }
    .evidence th { text-align: left; font-weight: 500; color: var(--ink-3); padding: 6px 8px; border-bottom: 1px solid var(--hairline); white-space: nowrap; }
    .evidence td { padding: 6px 8px; border-bottom: 1px solid var(--hairline); color: var(--ink-2); white-space: nowrap; }
    .evidence .num { text-align: right; font-variant-numeric: tabular-nums; }
    .empty { display: flex; gap: 12px; align-items: center; padding: 28px 18px; border: 1px dashed var(--hairline-strong); border-radius: var(--radius-sm); color: var(--ink-2); }
    .empty p { margin: 0; }
    .pulse { width: 8px; height: 8px; border-radius: 50%; background: var(--live); box-shadow: 0 0 0 0 var(--live-wash); }
    @media (prefers-reduced-motion: no-preference) {
      .pulse { animation: pulse 2.4s var(--ease) infinite; }
      .alert.fresh { animation: enter 0.5s var(--ease) both; }
      @keyframes pulse { 0% { box-shadow: 0 0 0 0 var(--live-wash); } 70% { box-shadow: 0 0 0 10px transparent; } 100% { box-shadow: 0 0 0 0 transparent; } }
      @keyframes enter { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }
    }
  `,
})
export class AlertFeed {
  readonly alerts = input.required<Alert[]>();
  readonly fresh = input<ReadonlySet<string>>(new Set());
  readonly now = input.required<number>();

  protected readonly severities = SEVERITY_ORDER;
  protected readonly meta = SEVERITY_META;
  protected readonly status = STATUS_META;
  protected readonly lanes = LANE_META;
  protected readonly report = reportUrl();
  protected readonly active = signal<ReadonlySet<Severity>>(new Set(SEVERITY_ORDER));
  protected readonly showRetracted = signal(true);
  protected readonly open = signal<ReadonlySet<string>>(new Set());

  protected readonly counts = computed(() => openBySeverity(this.alerts()));
  protected readonly visible = computed(() =>
    filterAlerts(this.alerts(), { severities: this.active(), showRetracted: this.showRetracted() }),
  );

  protected toggle(s: Severity): void {
    this.active.update((cur) => {
      const next = new Set(cur);
      next.has(s) ? next.delete(s) : next.add(s);
      return next;
    });
  }

  protected toggleOpen(id: string): void {
    this.open.update((cur) => {
      const next = new Set(cur);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  }

  protected since(ms: number): string {
    return ago(ms, this.now());
  }
  protected kind = kindLabel;
  protected short = short;
  protected money = usdCompact;
  protected tx = explorerTx;

  protected contractLabel(e: Alert['evidence'][number]): string {
    return e.labels.find((l) => l.role === 'contract')?.name ?? short(e.contract);
  }
}
