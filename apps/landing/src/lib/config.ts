/** Where things live. `?engine=` / `?dashboard=` override at runtime; VITE_* at build. */
function pick(param: string, env: string | undefined, fallback: string): string {
	const q = typeof location === 'undefined' ? null : new URLSearchParams(location.search).get(param);
	return (q || env || fallback).replace(/\/$/, '');
}

export const REPO = 'https://github.com/Arfazrll/ChainGuard-Protocol';
export const DOCS = {
	readme: `${REPO}#readme`,
	run: `${REPO}#run-it-locally`,
	rules: `${REPO}/blob/main/docs/rules.md`,
	invariants: `${REPO}/blob/main/docs/invariants.md`,
	adrs: `${REPO}/tree/main/docs/adr`,
	labels: `${REPO}/blob/main/data/labels/ethereum-mainnet.json`,
	ingest: `${REPO}/blob/main/config/ingestd.example.toml`,
	incidents: `${REPO}/tree/main/apps/engine/test/fixtures/incidents`,
	ml: `${REPO}/tree/main/services/anomaly`,
	issues: `${REPO}/issues`
};

export const engineUrl = () => pick('engine', import.meta.env.VITE_ENGINE_URL, 'http://localhost:4000');
export const dashboardUrl = () => pick('dashboard', import.meta.env.VITE_DASHBOARD_URL, 'http://localhost:4300');
