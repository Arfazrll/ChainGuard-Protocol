//! Durable tracker state. Written after every successful publish, atomically
//! (temp file + fsync + rename), so a crash leaves either the old or the new
//! checkpoint, never a torn one. Replaying from an older checkpoint re-emits
//! messages with the same `seq`, which consumers absorb idempotently.

use anyhow::{Context, Result, bail};
use chainguard_ingest_core::ReorgTracker;
use std::io::Write;
use std::path::{Path, PathBuf};

pub struct Checkpoint {
    path: PathBuf,
}

impl Checkpoint {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&self, chain_id: u64, confirmations: u64) -> Result<Option<ReorgTracker>> {
        let bytes = match std::fs::read(&self.path) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e).with_context(|| format!("reading {}", self.path.display())),
        };
        let t: ReorgTracker = serde_json::from_slice(&bytes)
            .with_context(|| format!("parsing {}", self.path.display()))?;
        if t.chain_id() != chain_id {
            bail!(
                "checkpoint {} is for chain {}, config says {chain_id}",
                self.path.display(),
                t.chain_id()
            );
        }
        if t.confirmations() != confirmations {
            bail!(
                "checkpoint uses confirmations = {} but config says {confirmations}; \
                 changing finality depth on a live checkpoint is not supported",
                t.confirmations()
            );
        }
        Ok(Some(t))
    }

    pub fn save(&self, tracker: &ReorgTracker) -> Result<()> {
        if let Some(dir) = self.path.parent().filter(|d| !d.as_os_str().is_empty()) {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = self.path.with_extension("tmp");
        {
            let mut f = std::fs::File::create(&tmp)
                .with_context(|| format!("creating {}", tmp.display()))?;
            serde_json::to_writer(&mut f, tracker)?;
            f.flush()?;
            f.sync_all()?;
        }
        std::fs::rename(&tmp, &self.path)
            .with_context(|| format!("replacing {}", self.path.display()))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_mismatch_detection() {
        let dir = std::env::temp_dir().join(format!("cg-ckpt-{}", std::process::id()));
        let cp = Checkpoint::new(dir.join("t.json"));
        assert!(cp.load(1, 64).unwrap().is_none());
        let t = ReorgTracker::new(1, 64).unwrap();
        cp.save(&t).unwrap();
        assert_eq!(cp.load(1, 64).unwrap().unwrap(), t);
        assert!(cp.load(10, 64).is_err());
        assert!(cp.load(1, 32).is_err());
        let _ = std::fs::remove_dir_all(dir);
    }
}
