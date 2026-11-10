import {
  ChangeDetectionStrategy,
  Component,
  DestroyRef,
  ElementRef,
  OnInit,
  afterNextRender,
  computed,
  inject,
  signal,
} from '@angular/core';
import { AlertFeed } from './components/alert-feed';
import { BlockStream } from './components/block-stream';
import { FundFlowGraph } from './components/fund-flow-graph';
import { InvariantPanel } from './components/invariant-panel';
import { RiskPanel } from './components/risk-panel';
import { RecordsChart } from './components/records-chart';
import { StatTiles } from './components/stat-tiles';
import { LiveService } from './core/live.service';
import { ThemeService } from './core/theme.service';

const CONNECTION = {
  connecting: { label: 'Connecting', tone: 'idle' },
  live: { label: 'Live', tone: 'live' },
  reconnecting: { label: 'Reconnecting', tone: 'warn' },
  offline: { label: 'Engine offline', tone: 'warn' },
} as const;

/** Sidebar sections; each is a region of the overview page. */
export const SECTIONS = [
  { id: 'overview', label: 'Overview' },
  { id: 'alerts', label: 'Alerts' },
  { id: 'risk', label: 'Risk and audit' },
  { id: 'flows', label: 'Fund flows' },
  { id: 'invariants', label: 'Invariants' },
  { id: 'blocks', label: 'Blocks' },
] as const;

@Component({
  selector: 'app-root',
  imports: [AlertFeed, BlockStream, FundFlowGraph, InvariantPanel, RecordsChart, RiskPanel, StatTiles],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './app.html',
  styleUrl: './app.css',
})
export class App implements OnInit {
  protected readonly live = inject(LiveService);
  protected readonly theme = inject(ThemeService);
  private readonly destroyRef = inject(DestroyRef);
  private readonly host = inject(ElementRef<HTMLElement>).nativeElement as HTMLElement;

  protected readonly sections = SECTIONS;
  protected readonly current = signal<string>('overview');
  protected readonly now = signal(Date.now());
  protected readonly conn = computed(() => CONNECTION[this.live.connection()]);
  protected readonly openTotal = computed(() => Object.values(this.live.openBySeverity()).reduce((a, b) => a + b, 0));

  constructor() {
    afterNextRender(() => {
      // Highlight the last section whose top has passed the upper third of the
      // screen; at the very bottom, the last section.
      let raf = 0;
      const spy = () => {
        raf = 0;
        const line = innerHeight * 0.33;
        const atEnd = innerHeight + scrollY >= document.documentElement.scrollHeight - 4;
        let id: string = SECTIONS[0].id;
        for (const s of SECTIONS) {
          const el = this.host.querySelector(`#${s.id}`);
          if (el && el.getBoundingClientRect().top <= line) id = s.id;
        }
        this.current.set(atEnd ? SECTIONS[SECTIONS.length - 1].id : id);
      };
      const onScroll = () => {
        if (!raf) raf = requestAnimationFrame(spy);
      };
      spy();
      addEventListener('scroll', onScroll, { passive: true });
      addEventListener('resize', onScroll);
      this.destroyRef.onDestroy(() => {
        cancelAnimationFrame(raf);
        removeEventListener('scroll', onScroll);
        removeEventListener('resize', onScroll);
      });
    });
  }

  ngOnInit(): void {
    this.live.connect();
    const t = setInterval(() => this.now.set(Date.now()), 1000);
    this.destroyRef.onDestroy(() => clearInterval(t));
  }
}
