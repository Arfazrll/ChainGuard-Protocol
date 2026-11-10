import {
  ChangeDetectionStrategy,
  Component,
  DestroyRef,
  ElementRef,
  afterNextRender,
  computed,
  effect,
  inject,
  input,
  signal,
  viewChild,
} from '@angular/core';
import type { Core, ElementDefinition, EventObject, LayoutOptions, StylesheetJson } from 'cytoscape';
import { Alert } from '../core/models';
import { FLOW_BLOCKS, FlowBlock, GraphEdge, GraphNode, buildGraph, shortAddr } from '../core/state';
import { usdCompact } from '../core/format';

/** Entity category → node shape. Category is never carried by color (dataviz rule). */
const SHAPES: Record<string, { shape: string; label: string; d: string }> = {
  lending: { shape: 'round-rectangle', label: 'Lending', d: 'M4 3h6a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z' },
  dex: { shape: 'diamond', label: 'DEX', d: 'M7 1.5 12.5 7 7 12.5 1.5 7z' },
  bridge: { shape: 'hexagon', label: 'Bridge', d: 'M4 2h6l3 5-3 5H4L1 7z' },
  mixer: { shape: 'octagon', label: 'Mixer', d: 'M5 1.5h4l3.5 3.5v4L9 12.5H5L1.5 9V5z' },
  exchange: { shape: 'rectangle', label: 'Exchange', d: 'M2 2h10v10H2z' },
  protocol: { shape: 'round-triangle', label: 'Other protocol', d: 'M7 2 12.5 12h-11z' },
  unlabeled: { shape: 'ellipse', label: 'Unlabeled address', d: 'M3 7a4 4 0 1 0 8 0a4 4 0 1 0-8 0' },
};
const shapeFor = (category: string) => SHAPES[category] ?? SHAPES['protocol'];

interface Tip {
  x: number;
  y: number;
  title: string;
  lines: string[];
}

/**
 * Live fund-flow graph: priced token transfers of the last blocks, aggregated
 * per address pair. Node size follows USD throughput, edge width follows USD
 * (log scale). Red is reserved for risk: it marks addresses and transactions
 * that are evidence in an open alert. Orphaned blocks leave the graph when a
 * reorg drops them.
 */
@Component({
  selector: 'cg-fund-flow-graph',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <header class="head">
      <div>
        <h2>Fund flows</h2>
        <p class="sub">
          Priced token transfers, last {{ blocks().length }}/{{ maxBlocks }} blocks · {{ graph().nodes.length }} addresses ·
          {{ graph().edges.length }} flows. <span class="hot-key">Red</span> marks evidence in an open alert.
        </p>
      </div>
      <button type="button" class="view" (click)="table.set(!table())" [attr.aria-pressed]="table()">
        {{ table() ? 'Graph view' : 'Table view' }}
      </button>
    </header>

    <div class="stage" [hidden]="table()">
      <div #canvas class="canvas" role="img" [attr.aria-label]="ariaLabel()"></div>
      @if (graph().edges.length === 0) {
        <p class="empty">Waiting for priced transfers. Prices come from labels and Chainlink feeds; unpriced tokens are not drawn.</p>
      }
      @if (tip(); as t) {
        <div class="tip" role="status" [style.left.px]="t.x" [style.top.px]="t.y">
          <strong>{{ t.title }}</strong>
          @for (l of t.lines; track $index) { <div>{{ l }}</div> }
        </div>
      }
    </div>

    @if (table()) {
      <div class="table-wrap">
        <table>
          <thead><tr><th>From</th><th>To</th><th class="num">USD</th><th class="num">Transfers</th><th>Tokens</th></tr></thead>
          <tbody>
            @for (e of tableRows(); track e.id) {
              <tr [class.hot]="e.alerted">
                <td>{{ name(e.source) }}</td>
                <td>{{ name(e.target) }}</td>
                <td class="num">{{ money(e.usd) }}</td>
                <td class="num">{{ e.transfers }}</td>
                <td>{{ e.tokens.join(', ') }}</td>
              </tr>
            }
          </tbody>
        </table>
      </div>
    }

    <ul class="legend" aria-label="Node shapes">
      @for (s of legend; track s.label) {
        <li>
          <svg viewBox="0 0 14 14" aria-hidden="true"><path [attr.d]="s.d" /></svg>{{ s.label }}
        </li>
      }
      <li><span class="swatch hot" aria-hidden="true"></span>In an open alert</li>
    </ul>
  `,
  styles: `
    :host { display: block; }
    .head { display: flex; justify-content: space-between; gap: 12px; align-items: flex-start; margin-bottom: 10px; }
    .head h2 { font: 600 20px/1.2 var(--font-display); letter-spacing: -0.02em; margin: 0; }
    .sub { margin: 4px 0 0; color: var(--ink-3); font-size: 13px; }
    .hot-key { color: var(--sev-critical); font-weight: 600; }
    .view { flex: none; background: none; border: 1px solid var(--hairline-strong); border-radius: 999px; padding: 3px 10px; font-size: 12px; color: var(--ink-2); cursor: pointer; }
    .view:hover { background: var(--surface-2); }
    .stage { position: relative; }
    .canvas { height: 380px; border-radius: var(--radius-sm); background: var(--surface-1); border: 1px solid var(--hairline); }
    .empty { position: absolute; inset: 0; display: grid; place-items: center; margin: 0; padding: 24px; text-align: center; color: var(--ink-3); font-size: 13px; pointer-events: none; }
    .tip { position: absolute; transform: translate(-50%, calc(-100% - 12px)); background: var(--surface-3); border: 1px solid var(--hairline-strong); border-radius: 8px; padding: 6px 10px; font-size: 12px; color: var(--ink-2); white-space: nowrap; pointer-events: none; z-index: 2; }
    .tip strong { color: var(--ink-1); font-weight: 600; display: block; }
    .legend { list-style: none; display: flex; flex-wrap: wrap; gap: 6px 14px; margin: 10px 0 0; padding: 0; color: var(--ink-3); font-size: 12px; }
    .legend li { display: inline-flex; align-items: center; gap: 5px; }
    .legend svg { width: 14px; height: 14px; fill: var(--surface-3); stroke: var(--ink-2); stroke-width: 1.2; }
    .swatch { width: 12px; height: 3px; border-radius: 2px; display: inline-block; }
    .swatch.hot { background: var(--sev-critical); }
    .table-wrap { max-height: 380px; overflow: auto; }
    table { width: 100%; border-collapse: collapse; font-size: 12.5px; }
    th { text-align: left; color: var(--ink-3); font-weight: 500; padding: 5px 8px; border-bottom: 1px solid var(--hairline); position: sticky; top: 0; background: var(--surface-1); }
    td { padding: 5px 8px; border-bottom: 1px solid var(--hairline); color: var(--ink-2); }
    tr.hot td:first-child { box-shadow: inset 2px 0 var(--sev-critical); }
    .num { text-align: right; font-variant-numeric: tabular-nums; font-family: var(--font-mono); }
  `,
})
export class FundFlowGraph {
  readonly blocks = input.required<FlowBlock[]>();
  readonly alerts = input.required<Alert[]>();

  protected readonly maxBlocks = FLOW_BLOCKS;
  protected readonly table = signal(false);
  protected readonly tip = signal<Tip | null>(null);
  protected readonly legend = Object.values(SHAPES);
  protected readonly money = usdCompact;

  protected readonly graph = computed(() => buildGraph(this.blocks(), this.alerts()));
  protected readonly tableRows = computed(() => this.graph().edges.slice(0, 40));
  private readonly names = computed(() => new Map(this.graph().nodes.map((n) => [n.id, n.name])));
  protected readonly ariaLabel = computed(() => {
    const g = this.graph();
    const top = g.edges[0];
    return top
      ? `Fund-flow graph of ${g.nodes.length} addresses and ${g.edges.length} flows. Largest: ${this.name(top.source)} to ${this.name(top.target)}, ${usdCompact(top.usd)}. Use table view for all values.`
      : 'Fund-flow graph: no priced transfers yet.';
  });

  private readonly canvas = viewChild.required<ElementRef<HTMLDivElement>>('canvas');
  private cy?: Core;
  private laidOut = false;

  constructor() {
    const destroyRef = inject(DestroyRef);
    afterNextRender(async () => {
      // Loaded on demand: the graph library stays out of the initial bundle.
      const { default: cytoscape } = await import('cytoscape');
      this.cy = cytoscape({
        container: this.canvas().nativeElement,
        style: stylesheet(),
        minZoom: 0.2,
        maxZoom: 3,
        boxSelectionEnabled: false,
        autounselectify: true,
      });
      this.cy.on('mouseover', 'node', (e) => this.showTip(e));
      this.cy.on('mouseover', 'edge', (e) => this.showTip(e));
      this.cy.on('mouseout viewport', () => this.tip.set(null));
      const theme = matchMedia('(prefers-color-scheme: light)');
      const restyle = () => this.cy?.style(stylesheet());
      theme.addEventListener('change', restyle);
      destroyRef.onDestroy(() => {
        theme.removeEventListener('change', restyle);
        this.cy?.destroy();
      });
      this.sync(this.graph());
    });
    effect(() => {
      const g = this.graph();
      if (this.cy) this.sync(g);
    });
  }

  protected name(id: string): string {
    return this.names().get(id) ?? shortAddr(id);
  }

  private sync(g: { nodes: GraphNode[]; edges: GraphEdge[] }): void {
    const cy = this.cy!;
    const want = new Set([...g.nodes.map((n) => n.id), ...g.edges.map((e) => e.id)]);
    const newest = Math.max(0, ...g.edges.map((e) => e.latest));
    let added = 0;
    cy.batch(() => {
      cy.elements().filter((el) => !want.has(el.id())).remove();
      const defs: ElementDefinition[] = [];
      for (const n of g.nodes) {
        const data = { ...n, size: Math.log10(1 + n.inUsd + n.outUsd), shape: shapeFor(n.category).shape };
        const el = cy.getElementById(n.id);
        if (el.nonempty()) {
          el.data(data);
        } else {
          // Start a new node next to a neighbor already on screen, so layouts stay calm.
          const peer = g.edges.find((e) => (e.source === n.id || e.target === n.id) && cy.getElementById(e.source === n.id ? e.target : e.source).nonempty());
          const at = peer ? cy.getElementById(peer.source === n.id ? peer.target : peer.source).position() : undefined;
          defs.push({ group: 'nodes', data, position: at ? { x: at.x + (Math.random() - 0.5) * 40, y: at.y + (Math.random() - 0.5) * 40 } : undefined });
          added++;
        }
      }
      for (const e of g.edges) {
        const data = { ...e, weight: Math.log10(1 + e.usd) };
        const el = cy.getElementById(e.id);
        if (el.nonempty()) el.data(data);
        else defs.push({ group: 'edges', data });
      }
      cy.add(defs);
      cy.nodes().forEach((n) => {
        n.toggleClass('labeled', !!n.data('labeled'));
        n.toggleClass('hot', !!n.data('alerted'));
      });
      cy.edges().forEach((e) => {
        e.toggleClass('hot', !!e.data('alerted'));
        e.toggleClass('fresh', e.data('latest') === newest);
      });
    });
    if (added > 0 || !this.laidOut) {
      const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
      cy.layout({
        name: 'cose',
        randomize: !this.laidOut,
        animate: reduced || !this.laidOut ? false : 'end',
        animationDuration: 450,
        fit: true,
        padding: 24,
        nodeRepulsion: () => 9000,
        idealEdgeLength: () => 70,
        numIter: 600,
      } as LayoutOptions).run();
      this.laidOut = cy.nodes().length > 0;
    }
  }

  private showTip(e: EventObject): void {
    const el = e.target;
    const p = el.renderedMidpoint?.() ?? el.renderedPosition();
    if (el.isNode()) {
      const n = el.data() as GraphNode;
      this.tip.set({
        x: p.x,
        y: p.y,
        title: n.name,
        lines: [
          `${shapeFor(n.category).label}${n.labeled ? '' : ` · ${shortAddr(n.id)}`}`,
          `in ${usdCompact(n.inUsd)} · out ${usdCompact(n.outUsd)}`,
          ...(n.alerted ? ['Evidence in an open alert'] : []),
        ],
      });
    } else {
      const d = el.data() as GraphEdge;
      this.tip.set({
        x: p.x,
        y: p.y,
        title: `${this.name(d.source)} → ${this.name(d.target)}`,
        lines: [`${usdCompact(d.usd)} · ${d.transfers} transfer${d.transfers === 1 ? '' : 's'}`, d.tokens.join(', ') || 'priced tokens', `last in block #${d.latest}`],
      });
    }
  }
}

/** Canvas cannot read CSS variables, so the stylesheet is built from the live tokens. */
function stylesheet(): StylesheetJson {
  const css = getComputedStyle(document.documentElement);
  const v = (name: string) => css.getPropertyValue(name).trim();
  return [
    {
      selector: 'node',
      style: {
        shape: 'data(shape)' as never,
        width: 'mapData(size, 3, 9, 10, 34)',
        height: 'mapData(size, 3, 9, 10, 34)',
        'background-color': v('--surface-3'),
        'border-width': 1,
        'border-color': v('--hairline-strong') || v('--axis'),
        label: '',
        color: v('--ink-2'),
        'font-family': v('--font-ui'),
        'font-size': 10,
        'text-valign': 'bottom',
        'text-margin-y': 4,
        'text-background-color': v('--surface-1'),
        'text-background-opacity': 0.85,
        'text-background-padding': '2px',
        'text-background-shape': 'roundrectangle',
      },
    },
    { selector: 'node.labeled', style: { label: 'data(name)', 'border-color': v('--brand'), 'border-width': 1.5 } },
    { selector: 'node.hot', style: { 'border-color': v('--sev-critical'), 'border-width': 3, color: v('--ink-1'), label: 'data(name)' } },
    {
      selector: 'edge',
      style: {
        width: 'mapData(weight, 4, 9, 1, 6)',
        'line-color': v('--brand'),
        'target-arrow-color': v('--brand'),
        'target-arrow-shape': 'triangle',
        'arrow-scale': 0.7,
        'curve-style': 'bezier',
        opacity: 0.42,
      },
    },
    { selector: 'edge.fresh', style: { opacity: 0.85 } },
    { selector: 'edge.hot', style: { 'line-color': v('--sev-critical'), 'target-arrow-color': v('--sev-critical'), opacity: 0.95, 'z-index': 10 } },
    { selector: 'node:active, edge:active', style: { 'overlay-opacity': 0 } },
  ] as StylesheetJson;
}
