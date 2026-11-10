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
      <p class="value">{{ head() ? '#' + int(head()!.number) : '-' }}</p>
      <p class="source">{{ headDetail() }}</p>
    </section>

    <section class="tile">
      <h3>Records analysed</h3>
      <p class="value">{{ int(stats()?.counters?.records) }}</p>
      <p class="source">{{ blocksLine() }}</p>
    </section>

    <section class="tile">
      <h3>Open alerts</h3>
      <p class="value">{{ int(openTotal()) }}</p>
      <p class="source sevs">
        @for (s of shown; track s) {
          <span class="sev-count sev--{{ s }}" [title]="meta[s].label"><i aria-hidden="true">{{ meta[s].glyph }}</i> {{ meta[s].label }} {{ open()[s] }}</span>
        }
      </p>
    </section>

    <section class="tile">
      <h3>Pipeline latency</h3>
      @if (stats()?.latency_ms?.pipeline?.samples) {
        <p class="value">{{ ms(stats()!.latency_ms.pipeline.p50) }}</p>
        <p class="source">p50 · p95 {{ ms(stats()!.latency_ms.pipeline.p95) }} · ingestd → rules evaluated</p>
      } @else {
        <p class="value withheld">n/a</p>
        <p class="source">No live blocks yet; replayed history is not counted as latency.</p>
      }
    </section>

    <section class="tile">
      <h3>Block → detection</h3>
      @if (stats()?.clock_skew_suspected) {
        <p class="value withheld">n/a</p>
        <p class="source warn">Host clock is behind block time, so this figure would be wrong. Check NTP.</p>
      } @else if (stats()?.latency_ms?.detect?.samples) {
        <p class="value">{{ ms(stats()!.latency_ms.detect.p50) }}</p>
        <p class="source">p50 · from block timestamp (±1 s resolution)</p>
      } @else {
        <p class="value withheld">n/a</p>
        <p class="source">Measured on live blocks only.</p>
      }
    </section>

    <section class="tile">
      <h3>Reorgs handled</h3>
      <p class="value">{{ int(stats()?.counters?.reorgs) }}</p>
      <p class="source">{{ int(stats()?.alerts?.retracted) }} alerts retracted · {{ int(stats()?.alerts?.suppressed) }} rate-limited</p>
    </section>
  `,
  styles: `
    :host { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 10px; }
    .tile {
      padding: 14px 16px;
      border-radius: var(--radius);
      background: var(--glass);
      backdrop-filter: blur(14px) saturate(140%);
      border: 1px solid var(--hairline-strong);
      min-width: 0;
      transition: border-color 0.2s, box-shadow 0.2s;
    }
    .tile:hover { border-color: color-mix(in srgb, var(--brand) 40%, var(--hairline-strong)); box-shadow: 0 0 24px -8px var(--brand-wash); }
    h3 { margin: 0; font-size: 12px; font-weight: 500; color: var(--ink-3); letter-spacing: 0.01em; }
    .value { margin: 6px 0 4px; font: 600 26px/1.1 var(--font-display); letter-spacing: -0.03em; color: var(--ink-1); }
    .withheld { color: var(--ink-3); }
    .source { margin: 0; font-size: 11.5px; color: var(--ink-3); line-height: 1.4; }
    .warn { color: var(--ink-2); }
    .sevs { display: flex; flex-wrap: wrap; gap: 2px 10px; }
    .sev-count i { font-style: normal; }
    .sev-count.sev--critical i { color: var(--sev-critical); }
    .sev-count.sev--high i { color: var(--sev-high); }
    .sev-count.sev--medium i { color: var(--sev-medium); }
    .sev-count.sev--low i { color: var(--sev-low); }
  `,
})
export class StatTiles {
  readonly stats = input<Stats | null>(null);
  readonly head = input<BlockSummary | null>(null);
  readonly open = input.required<Record<Severity, number>>();
  readonly now = input.required<number>();

  protected readonly shown: Severity[] = ['critical', 'high', 'medium', 'low'];
  protected readonly meta = SEVERITY_META;
  protected int = int;
  protected ms = ms;

  protected readonly openTotal = computed(() => Object.values(this.open()).reduce((a, b) => a + b, 0));

  protected readonly headDetail = computed(() => {
    const h = this.head();
    if (!h) return 'waiting for the first block';
    const nodes = `${h.attested_by.length} node${h.attested_by.length === 1 ? '' : 's'} agreed`;
    const t = h.timestamp * 1000;
    const when = this.now() - t > 86_400_000 ? `${blockDate(t)} (replay)` : ago(t, Math.max(this.now(), t));
    return `${when} · ${nodes}`;
  });

  protected readonly blocksLine = computed(() => {
    const c = this.stats()?.counters;
    if (!c) return 'decoded & enriched';
    const live = c.blocks - (c.replayed_blocks ?? 0);
    const replay = c.replayed_blocks ? ` + ${int(c.replayed_blocks)} replayed` : '';
    return `${int(live)} live block${live === 1 ? '' : 's'}${replay} · decoded & enriched`;
  });
}
