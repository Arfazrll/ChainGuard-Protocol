import { ChangeDetectionStrategy, Component, DestroyRef, ElementRef, afterNextRender, computed, inject, input, signal } from '@angular/core';
import { BlockSummary } from '../core/models';
import { int, ms } from '../core/format';

const H = 168;
const PAD = { top: 10, right: 8, bottom: 22, left: 40 };
const GAP = 2;
/** Fixed slots: bars keep their width and stream in from the right. */
const SLOTS = 30;

/** A tick step from {1, 2, 5} × 10^k, giving 3–5 gridlines. */
export function niceMax(max: number): { top: number; step: number } {
  if (max <= 0) return { top: 1, step: 1 };
  const raw = max / 4;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 5, 10].map((m) => m * mag).find((s) => s >= raw) ?? 10 * mag;
  return { top: Math.ceil(max / step) * step, step };
}

/**
 * Records per block, oldest → newest. Single series, so no legend: the title
 * names it. Bars are thin with a 4px rounded data-end on a hairline baseline
 * and a 2px gap; hover or focus shows the value, and a table view twins the
 * chart.
 */
@Component({
  selector: 'cg-records-chart',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <header class="head">
      <h2>Records per block</h2>
      <button type="button" class="view" (click)="table.set(!table())" [attr.aria-pressed]="table()">
        {{ table() ? 'Chart view' : 'Table view' }}
      </button>
    </header>

    @if (bars().length === 0) {
      <p class="empty">No blocks yet.</p>
    } @else if (table()) {
      <div class="table-wrap">
        <table>
          <thead><tr><th>Block</th><th class="num">Records</th><th class="num">Txs</th><th class="num">Rule eval</th><th>Status</th></tr></thead>
          <tbody>
            @for (b of tableRows(); track b.hash) {
              <tr>
                <td class="mono">#{{ int(b.number) }}</td>
                <td class="num">{{ int(b.records) }}</td>
                <td class="num">{{ int(b.txs) }}</td>
                <td class="num">{{ ms(b.eval_ms) }}</td>
                <td>{{ b.status }}</td>
              </tr>
            }
          </tbody>
        </table>
      </div>
    } @else {
      <div class="plot">
        <svg [attr.viewBox]="'0 0 ' + w() + ' ' + h" [attr.width]="w()" [attr.height]="h" role="img" [attr.aria-label]="ariaLabel()">
          @for (t of ticks(); track t.v) {
            <line class="grid" [attr.x1]="pad.left" [attr.x2]="w() - pad.right" [attr.y1]="t.y" [attr.y2]="t.y" />
            <text class="tick" [attr.x]="pad.left - 6" [attr.y]="t.y + 3.5" text-anchor="end">{{ int(t.v) }}</text>
          }
          @for (b of bars(); track b.hash; let i = $index) {
            <path class="bar" [class.orphaned]="b.status === 'orphaned'" [class.dim]="hover() !== null && hover() !== i" [attr.d]="b.d" />
            <rect
              class="hit"
              [attr.x]="b.x - gap / 2"
              [attr.y]="pad.top"
              [attr.width]="b.width + gap"
              [attr.height]="h - pad.top - pad.bottom"
              tabindex="0"
              [attr.aria-label]="'Block ' + b.number + ': ' + b.records + ' records'"
              (mouseenter)="hover.set(i)"
              (mouseleave)="hover.set(null)"
              (focus)="hover.set(i)"
              (blur)="hover.set(null)"
            />
          }
          <line class="axis" [attr.x1]="pad.left" [attr.x2]="w() - pad.right" [attr.y1]="h - pad.bottom" [attr.y2]="h - pad.bottom" />
          @if (bars().length > 1) {
            <text class="tick" [attr.x]="bars()[0].x" [attr.y]="h - 6">#{{ int(bars()[0].number) }}</text>
          }
          <text class="tick" [attr.x]="w() - pad.right" [attr.y]="h - 6" text-anchor="end">#{{ int(bars()[bars().length - 1].number) }}</text>
        </svg>
        @if (hovered(); as b) {
          <div class="tip" [style.left.px]="b.x + b.width / 2" role="status">
            <div class="mono">#{{ int(b.number) }}</div>
            <div><strong>{{ int(b.records) }}</strong> records · {{ int(b.txs) }} txs</div>
            <div class="muted">rule eval {{ ms(b.eval_ms) }} · {{ b.status }}</div>
          </div>
        }
      </div>
    }
  `,
  styles: `
    :host { display: block; }
    .head { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 10px; }
    .head h2 { font: 600 16px/1.2 var(--font-display); letter-spacing: -0.01em; margin: 0; }
    .view { background: none; border: 1px solid var(--hairline-strong); border-radius: 999px; padding: 3px 10px; font-size: 12px; color: var(--ink-2); cursor: pointer; }
    .view:hover { background: var(--surface-2); }
    .plot { position: relative; }
    svg { display: block; overflow: visible; }
    .grid { stroke: var(--grid); stroke-width: 1; vector-effect: non-scaling-stroke; }
    .axis { stroke: var(--axis); stroke-width: 1; vector-effect: non-scaling-stroke; }
    .tick { fill: var(--ink-3); font: 10.5px var(--font-ui); font-variant-numeric: tabular-nums; }
    .bar { fill: var(--brand); transition: opacity 0.15s; }
    .bar.orphaned { fill: var(--surface-3); }
    .bar.dim { opacity: 0.45; }
    .hit { fill: transparent; cursor: default; outline: none; }
    .tip {
      position: absolute; top: 0; transform: translate(-50%, -100%);
      background: var(--surface-3); border: 1px solid var(--hairline-strong); border-radius: 8px;
      padding: 6px 10px; font-size: 12px; white-space: nowrap; pointer-events: none; color: var(--ink-1);
    }
    .muted { color: var(--ink-3); }
    .empty { color: var(--ink-3); margin: 0; }
    .table-wrap { max-height: 190px; overflow: auto; }
    table { width: 100%; border-collapse: collapse; font-size: 12.5px; }
    th { text-align: left; color: var(--ink-3); font-weight: 500; padding: 4px 8px; border-bottom: 1px solid var(--hairline); position: sticky; top: 0; background: var(--surface-1); }
    td { padding: 4px 8px; border-bottom: 1px solid var(--hairline); color: var(--ink-2); }
    .num { text-align: right; font-variant-numeric: tabular-nums; }
  `,
})
export class RecordsChart {
  readonly blocks = input.required<BlockSummary[]>();

  /** Real pixel width of the plot, so text and marks never stretch. */
  protected readonly w = signal(600);
  protected readonly h = H;
  protected readonly pad = PAD;
  protected readonly gap = GAP;
  protected readonly table = signal(false);
  protected readonly hover = signal<number | null>(null);
  protected int = int;
  protected ms = ms;

  /** Oldest → newest, at most 30. */
  private readonly series = computed(() => [...this.blocks()].slice(0, SLOTS).reverse());
  private readonly scale = computed(() => niceMax(Math.max(0, ...this.series().map((b) => b.records))));

  protected readonly ticks = computed(() => {
    const { top, step } = this.scale();
    const out: { v: number; y: number }[] = [];
    for (let v = 0; v <= top + 1e-9; v += step) out.push({ v, y: this.y(v) });
    return out;
  });

  protected readonly bars = computed(() => {
    const s = this.series();
    const slot = (this.w() - PAD.left - PAD.right) / SLOTS;
    const width = Math.max(slot - GAP, 1);
    const base = H - PAD.bottom;
    const offset = SLOTS - s.length; // right-align: newest block in the last slot
    return s.map((b, i) => {
      const x = PAD.left + (offset + i) * slot + GAP / 2;
      const y = this.y(b.records);
      const r = Math.min(4, width / 2, base - y);
      // Rounded data-end only; square on the baseline.
      const d =
        base - y < 0.5
          ? ''
          : `M${x},${base} V${y + r} Q${x},${y} ${x + r},${y} H${x + width - r} Q${x + width},${y} ${x + width},${y + r} V${base} Z`;
      return { ...b, x, width, d };
    });
  });

  protected readonly hovered = computed(() => {
    const i = this.hover();
    return i === null ? null : (this.bars()[i] ?? null);
  });

  protected readonly tableRows = computed(() => [...this.series()].reverse());

  protected readonly ariaLabel = computed(() => {
    const s = this.series();
    if (!s.length) return 'No blocks';
    const max = Math.max(...s.map((b) => b.records));
    return `Records per block for the last ${s.length} blocks, up to ${max}. Use table view for exact values.`;
  });

  constructor() {
    const host = inject(ElementRef<HTMLElement>).nativeElement as HTMLElement;
    const destroyRef = inject(DestroyRef);
    afterNextRender(() => {
      const ro = new ResizeObserver(([entry]) => this.w.set(Math.max(240, Math.floor(entry.contentRect.width))));
      ro.observe(host);
      destroyRef.onDestroy(() => ro.disconnect());
    });
  }

  private y(v: number): number {
    const { top } = this.scale();
    return H - PAD.bottom - (v / top) * (H - PAD.top - PAD.bottom);
  }
}
