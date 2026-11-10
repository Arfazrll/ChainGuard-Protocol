import { Injectable, signal } from '@angular/core';

export type Theme = 'light' | 'dark';

const KEY = 'svltechain-theme';

function systemTheme(): Theme {
  return typeof matchMedia === 'function' && matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

function savedTheme(): Theme | null {
  try {
    const t = localStorage.getItem(KEY);
    return t === 'light' || t === 'dark' ? t : null;
  } catch {
    return null;
  }
}

/**
 * Light or dark. Follows the system until the user picks one; the pick is
 * stored per browser and applied as html[data-theme] (index.html applies it
 * before first paint).
 */
@Injectable({ providedIn: 'root' })
export class ThemeService {
  readonly theme = signal<Theme>(savedTheme() ?? systemTheme());

  constructor() {
    if (typeof matchMedia !== 'function') return;
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
      if (!savedTheme()) this.theme.set(systemTheme());
    });
  }

  toggle(): void {
    const next: Theme = this.theme() === 'dark' ? 'light' : 'dark';
    // The attribute changes before the signal, so anything reacting to the
    // signal (the graph reads CSS variables) already sees the new tokens.
    document.documentElement.dataset['theme'] = next;
    try {
      localStorage.setItem(KEY, next);
    } catch {
      // Storage blocked: the choice lasts for this page only.
    }
    this.theme.set(next);
  }
}
