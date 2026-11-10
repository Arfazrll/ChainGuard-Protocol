import { ChangeDetectionStrategy, Component, DestroyRef, OnInit, computed, inject, signal } from '@angular/core';
import { AlertFeed } from './components/alert-feed';
import { BlockStream } from './components/block-stream';
import { FundFlowGraph } from './components/fund-flow-graph';
import { InvariantPanel } from './components/invariant-panel';
import { RiskPanel } from './components/risk-panel';
import { RecordsChart } from './components/records-chart';
import { StatTiles } from './components/stat-tiles';
import { LiveService } from './core/live.service';

const CONNECTION = {
  connecting: { label: 'Connecting', tone: 'idle' },
  live: { label: 'Live', tone: 'live' },
  reconnecting: { label: 'Reconnecting', tone: 'warn' },
  offline: { label: 'Engine offline', tone: 'warn' },
} as const;

@Component({
  selector: 'app-root',
  imports: [AlertFeed, BlockStream, FundFlowGraph, InvariantPanel, RecordsChart, RiskPanel, StatTiles],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './app.html',
  styleUrl: './app.css',
})
export class App implements OnInit {
  protected readonly live = inject(LiveService);
  private readonly destroyRef = inject(DestroyRef);
  protected readonly now = signal(Date.now());
  protected readonly conn = computed(() => CONNECTION[this.live.connection()]);

  ngOnInit(): void {
    this.live.connect();
    const t = setInterval(() => this.now.set(Date.now()), 1000);
    this.destroyRef.onDestroy(() => clearInterval(t));
  }
}
