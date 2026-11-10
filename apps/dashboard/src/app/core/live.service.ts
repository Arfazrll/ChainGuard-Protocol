import { DestroyRef, Injectable, computed, inject, signal } from '@angular/core';
import { Channel, Socket } from 'phoenix';
import { Observable, Subject, catchError, from, map, merge, of, switchMap, timer } from 'rxjs';
import { Alert, BlockSummary, ConnectionState, InvariantStatus, MlStatus, ReorgEvent, Stats } from './models';
import { FlowBlock, dropFlowBlock, openBySeverity, pushBlock, pushFlowBlock, setBlockStatus, upsertAlert } from './state';

/** Where the engine lives: `?engine=` wins, then a global, then localhost. */
export function engineUrl(): string {
  const fromQuery = new URLSearchParams(globalThis.location?.search ?? '').get('engine');
  const fromGlobal = (globalThis as { CHAINGUARD_ENGINE?: string }).CHAINGUARD_ENGINE;
  return (fromQuery || fromGlobal || 'http://localhost:4000').replace(/\/$/, '');
}

/** A Phoenix channel event as an Observable (unsubscribing detaches the handler). */
function on<T>(channel: Channel, event: string): Observable<T> {
  return new Observable<T>((sub) => {
    const ref = channel.on(event, (payload) => sub.next(payload as T));
    return () => channel.off(event, ref);
  });
}

/**
 * The dashboard's single connection to the engine. State is exposed as
 * signals for templates; every live update arrives as an RxJS stream.
 */
@Injectable({ providedIn: 'root' })
export class LiveService {
  private readonly destroyRef = inject(DestroyRef);
  private socket?: Socket;

  readonly engine = engineUrl();
  readonly chainId = 1;

  readonly connection = signal<ConnectionState>('connecting');
  readonly alerts = signal<Alert[]>([]);
  readonly blocks = signal<BlockSummary[]>([]);
  readonly stats = signal<Stats | null>(null);
  readonly reorgs = signal<ReorgEvent[]>([]);
  readonly halted = signal<string | null>(null);
  /** Fund-flow edges of the last blocks (orphaned blocks removed). */
  readonly flowBlocks = signal<FlowBlock[]>([]);
  readonly invariants = signal<InvariantStatus[]>([]);
  readonly ml = signal<MlStatus | null>(null);
  /** Ids of alerts that arrived during this session (for the entrance cue). */
  readonly fresh = signal<ReadonlySet<string>>(new Set());

  readonly openBySeverity = computed(() => openBySeverity(this.alerts()));
  readonly head = computed(() => this.blocks()[0] ?? null);

  /** Every lifecycle event, for consumers that want the raw stream. */
  readonly events$ = new Subject<{ event: string; alert: Alert }>();

  connect(): void {
    if (this.socket) return;
    const wsUrl = this.engine.replace(/^http/, 'ws') + '/socket';
    const socket = new Socket(wsUrl, { reconnectAfterMs: (tries) => [500, 1000, 2000, 5000][tries - 1] ?? 10_000 });
    this.socket = socket;

    socket.onOpen(() => this.connection.set('live'));
    socket.onError(() => this.connection.set(this.connection() === 'connecting' ? 'offline' : 'reconnecting'));
    socket.onClose(() => this.connection.set('reconnecting'));
    socket.connect();

    const alerts = socket.channel('alerts:global');
    const live = socket.channel(`live:${this.chainId}`);

    const subs = [
      merge(
        on<Alert>(alerts, 'alert:raised').pipe(map((alert) => ({ event: 'raised', alert }))),
        on<Alert>(alerts, 'alert:updated').pipe(map((alert) => ({ event: 'updated', alert }))),
        on<Alert>(alerts, 'alert:retracted').pipe(map((alert) => ({ event: 'retracted', alert }))),
        on<Alert>(alerts, 'alert:finalized').pipe(map((alert) => ({ event: 'finalized', alert }))),
      ).subscribe(({ event, alert }) => {
        this.alerts.update((xs) => upsertAlert(xs, alert));
        if (event === 'raised') this.fresh.update((s) => new Set([...s, alert.id]));
        this.events$.next({ event, alert });
      }),

      on<BlockSummary>(live, 'block').subscribe(({ flows, ...b }) => {
        this.blocks.update((xs) => pushBlock(xs, b));
        this.flowBlocks.update((w) => pushFlowBlock(w, { hash: b.hash, number: b.number, edges: flows ?? [] }));
      }),
      on<{ block: { hash: string } }>(live, 'block:orphaned').subscribe(({ block }) => {
        this.blocks.update((xs) => setBlockStatus(xs, block.hash, 'orphaned'));
        this.flowBlocks.update((w) => dropFlowBlock(w, block.hash));
      }),
      on<{ statuses: InvariantStatus[] }>(live, 'invariants').subscribe(({ statuses }) => this.invariants.set(statuses)),
      on<Omit<ReorgEvent, 'at_ms'>>(live, 'reorg').subscribe((r) =>
        this.reorgs.update((xs) => [{ ...r, at_ms: Date.now() }, ...xs].slice(0, 20)),
      ),
      on<{ reason: string }>(live, 'integrity_halt').subscribe(({ reason }) => this.halted.set(reason)),

      // Latency percentiles and counters come from the API; push events
      // carry per-block detail.
      timer(0, 5000)
        .pipe(
          switchMap(() =>
            from(fetch(`${this.engine}/api/stats`).then((r) => r.json() as Promise<Stats>)).pipe(catchError(() => of(null))),
          ),
        )
        .subscribe((s) => s && this.stats.set(s)),

      // ML lane health (the lane can be disabled or degraded without
      // affecting the other two).
      timer(0, 10_000)
        .pipe(
          switchMap(() =>
            from(fetch(`${this.engine}/api/lanes`).then((r) => r.json() as Promise<{ ml: MlStatus }>)).pipe(
              catchError(() => of(null)),
            ),
          ),
        )
        .subscribe((l) => l && this.ml.set(l.ml)),
    ];

    alerts.join().receive('ok', (reply: { alerts: Alert[] }) => this.alerts.set(reply.alerts ?? []));
    live.join().receive('ok', (reply: { stats: Stats; blocks: BlockSummary[]; flows?: FlowBlock[]; invariants?: InvariantStatus[]; ml?: MlStatus }) => {
      this.stats.set(reply.stats);
      this.blocks.set(reply.blocks ?? []);
      this.flowBlocks.set(reply.flows ?? []);
      this.invariants.set(reply.invariants ?? []);
      if (reply.ml) this.ml.set(reply.ml);
    });

    this.destroyRef.onDestroy(() => {
      subs.forEach((s) => s.unsubscribe());
      socket.disconnect();
    });
  }
}
