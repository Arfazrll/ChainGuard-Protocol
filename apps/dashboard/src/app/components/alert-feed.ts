import { ChangeDetectionStrategy, Component, computed, input, signal } from '@angular/core';
import { Alert, Severity } from '../core/models';
import { SEVERITY_ORDER, filterAlerts, openBySeverity } from '../core/state';
import { SEVERITY_META, ago, explorerTx, kindLabel, short, usdCompact } from '../core/format';
import { reportUrl } from '../core/live.service';

const STATUS_META = {
  provisional: { label: 'Provisional', hint: 'Evidence is in a block that could still be reorganized' },
  final: { label: 'Final', hint: 'Every evidence block is finalized' },
  retracted: { label: 'Retracted', hint: 'A reorg orphaned the evidence; this alert no longer stands' },
} as const;

const LANE_META = {
  rule: { label: 'Rule lane', hint: 'A YAML rule matched a known attack shape' },
  invariant: { label: 'Invariant lane', hint: 'A per-protocol property that must always hold was broken' },
  ml: { label: 'Model', hint: 'Statistical anomaly; capped at medium, corroborate before acting' },
  system: { label: 'System', hint: 'About the monitor itself' },
} as const;

@Component({
  selector: 'cg-alert-feed',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <header class="panel-head">
      <div>
        <h2>Alerts</h2>
        <p class="panel-sub">Each alert names its detection lane, its weakness class and the on-chain evidence behind it.</p>
      </div>
    </header>

    <div class="filters">
      <div class="seg" role="group" aria-label="Filter alerts by severity">
        @for (s of severities; track s) {
          <button type="button" [class.off]="!active().has(s)" [attr.aria-pressed]="active().has(s)" (click)="toggle(s)">
            <span class="swatch swatch--{{ s }}" aria-hidden="true"></span>{{ meta[s].label }}
            <span class="n num">{{ counts()[s] }}</span>
          </button>
        }
      </div>
      <label class="retracted">
        <input type="checkbox" [checked]="showRetracted()" (change)="showRetracted.set(!showRetracted())" />
        Show retracted
      </label>
    </div>

    @if (visible().length === 0) {
      <div class="empty">
        @if (alerts().length === 0) {
          <p><strong>No alerts.</strong> Every block is checked as it lands; alerts appear here the moment one fires.</p>
        } @else {
          <p>No alerts match this filter.</p>
        }
      </div>
    } @else {
      <ol class="list">
        @for (a of visible(); track a.id) {
          <li class="alert alert--{{ a.severity }}" [class.retracted]="a.status === 'retracted'" [class.fresh]="fresh().has(a.id)">
            <div class="row">
              <span class="sev sev--{{ a.severity }}">{{ meta[a.severity].label }}</span>
              <h3 class="title">{{ a.title }}</h3>
              <span class="status status--{{ a.status }}" [title]="status[a.status].hint">{{ status[a.status].label }}</span>
            </div>

            <div class="meta">
              <span class="lane" [title]="lanes[a.lane ?? 'rule'].hint">{{ lanes[a.lane ?? 'rule'].label }}</span>
              <span class="mono">{{ a.rule_id }}</span>
              <span>{{ a.weakness.class }}</span>
              @if (a.block_number) { <span class="num">Block {{ int(a.block_number) }}</span> }
              @if (!a.system) {
                <span [class.verified]="a.min_attestations >= 2" title="Independent RPC nodes that returned identical evidence">
                  {{ a.min_attestations >= 2 ? 'Verified by' : 'Only' }} {{ a.sources.length }} node{{ a.sources.length === 1 ? '' : 's' }}
                </span>
              }
              @if (a.occurrences > 1) { <span>Seen {{ a.occurrences }} times</span> }
              <span>{{ since(a.first_seen_ms) }}</span>
            </div>

            @for (n of a.notes; track $index) {
              <p class="note">{{ n }}</p>
            }

            <div class="actions">
              @if (a.evidence.length) {
                <button type="button" class="link" [attr.aria-expanded]="open().has(a.id)" (click)="toggleOpen(a.id)">
                  {{ open().has(a.id) ? 'Hide evidence' : 'Show evidence' }} ({{ a.evidence.length }})
                </button>
              }
              @if (!a.system) {
                <a [href]="report + '/reports/alerts/' + a.id + '.pdf'" target="_blank" rel="noopener"
                  title="Compliance report with the evidence and the audit-chain check">PDF report</a>
              }
            </div>

            @if (open().has(a.id)) {
              <div class="evidence-wrap">
                <table class="data-table">
                  <thead>
                    <tr><th>Event</th><th>Contract</th><th class="num">Value</th><th>Transaction</th><th class="num">Log</th><th class="num">Nodes</th></tr>
                  </thead>
                  <tbody>
                    @for (e of a.evidence; track e.record_id) {
                      <tr>
                        <td>{{ kind(e.kind) }}</td>
                        <td>{{ contractLabel(e) }}</td>
                        <td class="num">{{ money(e.value_usd) }}</td>
                        <td class="mono">
                          @if (tx(a.chain_id, e.tx_hash); as href) {
                            <a [href]="href" target="_blank" rel="noopener">{{ short(e.tx_hash, 8, 4) }}</a>
                          } @else {
                            {{ short(e.tx_hash, 8, 4) }}
                          }
                        </td>
                        <td class="num">{{ e.log_index }}</td>
                        <td class="num">{{ e.attested_by.length }}</td>
                      </tr>
                    }
                  </tbody>
                </table>
              </div>
            }
          </li>
        }
      </ol>
    }
  `,
  styles: `
    :host { display: block; }
    .filters { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 14px; }
    .seg { display: inline-flex; flex-wrap: wrap; gap: 2px; padding: 3px; border-radius: 10px; background: var(--surface-2); border: 1px solid var(--rule); }
    .seg button {
      display: inline-flex; align-items: center; gap: 7px;
      padding: 5px 10px; border: 0; border-radius: 7px;
      background: var(--surface); color: var(--ink-2);
      font-size: 12.5px; font-weight: 500; cursor: pointer;
      box-shadow: 0 1px 2px rgba(13, 17, 23, 0.06);
      transition: background 0.15s var(--ease), color 0.15s var(--ease);
    }
    .seg button.off { background: transparent; color: var(--muted); box-shadow: none; }
    .seg button.off .swatch { opacity: 0.4; }
    .swatch { width: 8px; height: 8px; border-radius: 2px; background: var(--sev-low); }
    .swatch--critical { background: var(--sev-critical); }
    .swatch--high { background: var(--sev-high); }
    .swatch--medium { background: var(--sev-medium); }
    .n { color: var(--muted); font-weight: 500; }
    .retracted { margin-left: auto; display: inline-flex; gap: 7px; align-items: center; color: var(--graphite); font-size: 13px; cursor: pointer; }
    .retracted input { accent-color: var(--cobalt); margin: 0; }

    .list { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
    .alert {
      position: relative;
      padding: 14px 16px 14px 18px;
      border-radius: var(--r-sm);
      background: var(--surface);
      border: 1px solid var(--rule);
      transition: border-color 0.15s var(--ease);
    }
    .alert::before { content: ''; position: absolute; left: -1px; top: 12px; bottom: 12px; width: 3px; border-radius: 0 3px 3px 0; background: var(--sev-low); }
    .alert--critical::before { background: var(--sev-critical); }
    .alert--high::before { background: var(--sev-high); }
    .alert--medium::before { background: var(--sev-medium); }
    .alert:hover { border-color: var(--rule-strong); }
    .alert.retracted { opacity: 0.62; }
    .alert.retracted .title { text-decoration: line-through; text-decoration-color: var(--muted); }

    .row { display: flex; gap: 10px; align-items: baseline; flex-wrap: wrap; }
    .title { flex: 1 1 260px; font-size: 14.5px; font-weight: 600; line-height: 1.4; overflow-wrap: anywhere; letter-spacing: 0; }
    .status { font-size: 12.5px; font-weight: 500; color: var(--graphite); white-space: nowrap; }
    .status--final { color: var(--ok); }
    .status--retracted { color: var(--sev-medium); }

    .meta { display: flex; flex-wrap: wrap; gap: 4px 16px; margin-top: 8px; color: var(--graphite); font-size: 12.5px; }
    .meta .mono { color: var(--ink-2); }
    .lane { color: var(--ink-2); font-weight: 500; }
    .verified { color: var(--ok); }
    .note { margin: 10px 0 0; padding: 8px 12px; border-radius: 8px; background: var(--sev-medium-wash); color: var(--ink-2); font-size: 13px; }
    .actions { display: flex; gap: 18px; margin-top: 10px; font-size: 13px; font-weight: 500; }
    .link { background: none; border: 0; padding: 0; color: var(--cobalt); cursor: pointer; font-weight: 500; }
    .link:hover { text-decoration: underline; text-underline-offset: 3px; }
    .evidence-wrap { overflow-x: auto; margin-top: 10px; border: 1px solid var(--rule-soft); border-radius: 8px; }

    .empty { padding: 28px 20px; border: 1px dashed var(--rule-strong); border-radius: var(--r-sm); color: var(--graphite); }
    .empty p { margin: 0; }
    .empty strong { color: var(--ink); }
    @media (prefers-reduced-motion: no-preference) {
      .alert.fresh { animation: enter 0.45s var(--ease) both; }
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
  protected int = (n: number) => n.toLocaleString('en-US');
  protected kind = kindLabel;
  protected short = short;
  protected money = usdCompact;
  protected tx = explorerTx;

  protected contractLabel(e: Alert['evidence'][number]): string {
    return e.labels.find((l) => l.role === 'contract')?.name ?? short(e.contract);
  }
}
