use anyhow::{Context, Result, bail};
use chainguard_ingest_core::enrich::OracleFeed;
use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub chain_id: u64,
    pub chain_name: String,
    /// Depth at which a block is final. Also the deepest reorg handled automatically.
    #[serde(default = "defaults::confirmations")]
    pub confirmations: u64,
    #[serde(default = "defaults::poll_interval_ms")]
    pub poll_interval_ms: u64,
    #[serde(default = "defaults::request_timeout_ms")]
    pub request_timeout_ms: u64,
    /// First block when there is no checkpoint. Omit to start at the head.
    #[serde(default)]
    pub start_block: Option<u64>,
    #[serde(default = "defaults::max_walkback")]
    pub max_walkback: usize,
    #[serde(default)]
    pub quorum: QuorumSection,
    pub nodes: Vec<NodeConfig>,
    #[serde(default)]
    pub labels: Option<PathBuf>,
    #[serde(default)]
    pub oracle_feeds: Vec<OracleFeed>,
    pub checkpoint: PathBuf,
    pub sink: SinkConfig,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct QuorumSection {
    #[serde(default = "defaults::min_agreement")]
    pub min_agreement: usize,
    #[serde(default)]
    pub allow_single_source: bool,
}

impl Default for QuorumSection {
    fn default() -> Self {
        Self {
            min_agreement: defaults::min_agreement(),
            allow_single_source: false,
        }
    }
}

/// An RPC endpoint. Provider URLs usually embed an API key, so prefer
/// `url_env` (injected from your secret store) over a literal `url`.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NodeConfig {
    pub id: String,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub url_env: Option<String>,
}

impl NodeConfig {
    pub fn resolve_url(&self) -> Result<String> {
        match (&self.url, &self.url_env) {
            (Some(u), None) => Ok(u.clone()),
            (None, Some(var)) => std::env::var(var)
                .with_context(|| format!("node {}: env var {var} is not set", self.id)),
            _ => bail!("node {}: set exactly one of `url` or `url_env`", self.id),
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum SinkConfig {
    /// Newline-delimited JSON to a file, or stdout with `path = "-"`.
    Jsonl { path: String },
    /// Redpanda / Kafka. One single-partition topic per chain keeps a total order.
    Kafka {
        brokers: Vec<String>,
        topic: String,
        #[serde(default = "defaults::yes")]
        create_topic: bool,
        #[serde(default = "defaults::replication")]
        replication_factor: i16,
    },
}

mod defaults {
    pub fn confirmations() -> u64 {
        64
    }
    pub fn poll_interval_ms() -> u64 {
        2_000
    }
    pub fn request_timeout_ms() -> u64 {
        10_000
    }
    pub fn max_walkback() -> usize {
        128
    }
    pub fn min_agreement() -> usize {
        2
    }
    pub fn yes() -> bool {
        true
    }
    pub fn replication() -> i16 {
        1
    }
}

impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let cfg: Config =
            toml::from_str(&text).with_context(|| format!("parsing {}", path.display()))?;
        cfg.validate()?;
        Ok(cfg)
    }

    pub fn validate(&self) -> Result<()> {
        if self.confirmations == 0 {
            bail!("confirmations must be ≥ 1");
        }
        if self.max_walkback as u64 <= self.confirmations {
            bail!(
                "max_walkback ({}) must exceed confirmations ({})",
                self.max_walkback,
                self.confirmations
            );
        }
        if self.nodes.is_empty() {
            bail!("configure at least two independent [[nodes]]");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn example_configs_parse() {
        for f in [
            "../../config/ingestd.example.toml",
            "../../config/ingestd.compose.toml",
        ] {
            let p = Path::new(env!("CARGO_MANIFEST_DIR")).join(f);
            let cfg = Config::load(&p).unwrap_or_else(|e| panic!("{f}: {e:#}"));
            assert!(
                cfg.nodes.len() >= 2,
                "{f}: examples must model multi-node verification"
            );
            assert!(cfg.quorum.min_agreement >= 2, "{f}");
            assert!(!cfg.quorum.allow_single_source, "{f}");
        }
    }

    #[test]
    fn invariant_multi_node_config_defaults_to_two_sources() {
        let cfg: Config = toml::from_str(
            r#"
            chain_id = 1
            chain_name = "x"
            checkpoint = "c.json"
            sink = { kind = "jsonl", path = "-" }
            [[nodes]]
            id = "a"
            url = "http://a"
            "#,
        )
        .unwrap();
        assert_eq!(cfg.quorum.min_agreement, 2);
        assert!(!cfg.quorum.allow_single_source);
    }
}
