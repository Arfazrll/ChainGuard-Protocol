const usdFmt = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });
const intFmt = new Intl.NumberFormat('en-US');

export const usd = (v: number) => usdFmt.format(v);
export const int = (v: number) => intFmt.format(Math.round(v));

/** $8.9M, $412K, $1.2B: for tight spaces and counters. */
export function usdCompact(v: number): string {
	const a = Math.abs(v);
	if (a >= 1e9) return `$${(v / 1e9).toFixed(a >= 1e10 ? 0 : 1)}B`;
	if (a >= 1e6) return `$${(v / 1e6).toFixed(a >= 1e7 ? 0 : 1)}M`;
	if (a >= 1e3) return `$${Math.round(v / 1e3)}K`;
	return usdFmt.format(v);
}

/** 0x2718…25d3 */
export const short = (hex: string, head = 6, tail = 4) =>
	hex && hex.length > head + tail + 1 ? `${hex.slice(0, head)}…${hex.slice(-tail)}` : hex;

export const etherscanTx = (tx: string) => `https://etherscan.io/tx/${tx}`;
