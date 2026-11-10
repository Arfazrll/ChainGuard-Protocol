import { ChangeDetectionStrategy, Component, computed, input } from '@angular/core';
import { BlockSummary, Severity, Stats } from '../core/models';
import { SEVERITY_META, ago, int, ms } from '../core/format';

const blockDate = (t: number) => new Date(t).toISOString().slice(0, 10);

/**
 * Headline numbers. Every tile names its source; chain-time latency is
 * withheld (not zeroed) when the host clock is behind block time.
 */
@Component({
  selector: 'cg-stat-tiles',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <section class="tile">
      <h3>Head block</h3>
      <p class="value num">{{ head() ? '#' + int(head()!.number) : '-' }}</p>
      <p class="source">{{ headDetail() }}</p>
    </section>

    <section class="tile">
      <h3>Open alerts</h3>
      <p class="value num">{{ int(openTotal()) }}</p>
      <p class="source">{{ openLine() }}</p>
    </section>

    <section class="tile">
      <h3>Records analysed</h3>
      <p class="value num">{{ int(stats()?.counters?.records) }}</p>
      <p class="source">{{ blocksLine() }}</p>
    </section>

    <section class="tile">
      <h3>Pipeline latency, p50</h3>
      @if (stats()?.latency_ms?.pipeline?.samples) {
        <p class="value num">{{ ms(stats()!.latency_ms.pipeline.p50) }}</p>
        <p class="source">p95 {{ ms(stats()!.latency_ms.pipeline.p95) }}, from ingestion to rules evaluated</p>
      } @else {
        <p class="value withheld">Not yet</p>
        <p class="source">Measured on live blocks only; replayed history does not count.</p>
      }
    </section>

    <section class="tile">
      <h3>Block to detection, p50</h3>
      @if (stats()?.clock_skew_suspected) {
        <p class="value withheld">Withheld</p>
        <p class="source warn">This machine's clock is behind block time, so the figure would be wrong. Check NTP.</p>
      } @else if (stats()?.latency_ms?.detect?.samples) {
        <p class="value num">{{ ms(stats()!.latency_ms.detect.p50) }}</p>
        <p class="source">From the block timestamp, which has 1 s resolution</p>
      } @else {
        <p class="value withheld">Not yet</p>
        <p class="source">Measured on live blocks only.</p>
      }
    </section>

    <section class="tile">
      <h3>Reorgs handled</h3>
      <p class="value num">{{ int(stats()?.counters?.reorgs) }}</p>
      <p class="source">{{ int(stats()?.alerts?.retracted) }} alerts retracted, {{ int(stats()?.alerts?.suppressed) }} rate-limited</p>
    </section>
  `,
  styles: `
    :host { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; }
    .tile {
      min-width: 0;
      padding: 16px 18px;
      border-radius: var(--r);
      background: var(--surface);
      border: 1px solid var(--rule);
    }
    h3 { font-size: 13px; font-weight: 500; color: var(--graphite); letter-spacing: 0; }
    .value { margin: 8px 0 4px; font-size: 26px; font-weight: 600; line-height: 1.1; letter-spacing: -0.02em; color: var(--ink); }
    .withheld { color: var(--muted); font-weight: 500; font-size: 22px; }
    .source { margin: 0; font-size: 12.5px; color: var(--muted); line-height: 1.45; }
    .warn { color: var(--sev-medium); }
    @media (max-width: 600px) {
      :host { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
      .tile { padding: 14px; }
      .value { font-size: 20px; }
      .withheld { font-size: 18px; }
    }
  `,
})
export class StatTiles {
  readonly stats = input<Stats | null>(null);
  readonly head = input<BlockSummary | null>(null);
  readonly open = input.required<Record<Severity, number>>();
  readonly now = input.required<number>();

  protected int = int;
  protected ms = ms;

  protected readonly openTotal = computed(() => Object.values(this.open()).reduce((a, b) => a + b, 0));

  /** "2 critical, 1 high", worst first, only severities that are present. */
  protected readonly openLine = computed(() => {
    const o = this.open();
    const parts = (['critical', 'high', 'medium', 'low'] as Severity[])
      .filter((s) => o[s] > 0)
      .map((s) => `${o[s]} ${SEVERITY_META[s].label.toLowerCase()}`);
    return parts.length ? parts.join(', ') : 'Nothing open';
  });

  protected readonly headDetail = computed(() => {
    const h = this.head();
    if (!h) return 'Waiting for the first block';
    const nodes = `${h.attested_by.length} node${h.attested_by.length === 1 ? '' : 's'} agreed`;
    const t = h.timestamp * 1000;
    const when = this.now() - t > 86_400_000 ? `replay of ${blockDate(t)}` : ago(t, Math.max(this.now(), t));
    return `${nodes}, ${when}`;
  });

  protected readonly blocksLine = computed(() => {
    const c = this.stats()?.counters;
    if (!c) return 'Decoded and labeled';
    const live = c.blocks - (c.replayed_blocks ?? 0);
    const replay = c.replayed_blocks ? ` and ${int(c.replayed_blocks)} replayed` : '';
    return `From ${int(live)} live block${live === 1 ? '' : 's'}${replay}`;
  });
}
