//! Additional Node command arguments.

//! clap [Args](clap::Args) for optimism rollup configuration

use clap::builder::ArgPredicate;
use op_alloy_consensus::interop::SafetyLevel;
use std::path::PathBuf;
use url::Url;

/// Storage schema version for the proofs-history database.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, clap::ValueEnum)]
pub enum ProofsStorageVersion {
    /// V1 storage schema (original single-table-per-domain layout). Default.
    #[default]
    V1,
    /// V2 storage schema with changeset and history-bitmap tables, enabling
    /// history-aware reads at any block number within the proof window.
    V2,
}

/// Default proofs history window in blocks: 30 days × 24h × 60min × 60s / 2s
/// per block = `1_296_000`.
pub const DEFAULT_PROOFS_HISTORY_WINDOW: u64 = 1_296_000;

/// Subdirectory under reth's chain-specific data dir where the proofs history
/// DB lives when the user didn't pass `--proofs-history.storage-path`.
pub const DEFAULT_PROOFS_HISTORY_SUBDIR: &str = "historical-proofs";

/// Shared proofs-history storage args used by both the node's [`RollupArgs`]
/// and every `op-proofs` CLI subcommand. `storage_path` is `Option<PathBuf>`
/// because we default to `<reth-data-dir>/historical-proofs` when not
/// provided — see [`Self::resolve_storage_path`].
#[derive(Debug, Clone, PartialEq, Eq, clap::Args)]
pub struct ProofsHistoryStorageArgs {
    /// Path to the proofs-history storage DB. Defaults to
    /// `<reth-data-dir>/historical-proofs` (chain-namespaced via reth's
    /// `--datadir`).
    #[arg(long = "proofs-history.storage-path", value_name = "PROOFS_HISTORY_STORAGE_PATH")]
    pub storage_path: Option<PathBuf>,

    /// Storage schema version. Must match the version used when starting the node.
    #[arg(
        long = "proofs-history.storage-version",
        value_name = "PROOFS_HISTORY_STORAGE_VERSION",
        default_value = "v1"
    )]
    pub storage_version: ProofsStorageVersion,
}

impl ProofsHistoryStorageArgs {
    /// Resolve the storage path, defaulting to
    /// `<reth_data_dir>/historical-proofs` when the user didn't pass
    /// `--proofs-history.storage-path`.
    pub fn resolve_storage_path(&self, reth_data_dir: &std::path::Path) -> PathBuf {
        self.storage_path
            .clone()
            .unwrap_or_else(|| reth_data_dir.join(DEFAULT_PROOFS_HISTORY_SUBDIR))
    }
}

/// Shared proofs-history window arg. Used by both [`RollupArgs`] (the node)
/// and the `op-proofs prune` subcommand so the flag name and default stay in
/// sync.
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::Args)]
pub struct ProofsHistoryWindowArg {
    /// The window to span blocks for proofs history. Value is the number of blocks.
    /// Default is 1 month of blocks based on 2 seconds block time
    /// (`30 * 24 * 60 * 60 / 2 = 1_296_000`).
    #[arg(
        long = "proofs-history.window",
        default_value_t = DEFAULT_PROOFS_HISTORY_WINDOW,
        value_name = "PROOFS_HISTORY_WINDOW"
    )]
    pub window: u64,
}

impl Default for ProofsHistoryWindowArg {
    fn default() -> Self {
        Self { window: DEFAULT_PROOFS_HISTORY_WINDOW }
    }
}

/// Parameters for rollup configuration
#[derive(Debug, Clone, PartialEq, Eq, clap::Args)]
#[command(next_help_heading = "Rollup")]
pub struct RollupArgs {
    /// Endpoint for the sequencer mempool (can be both HTTP and WS)
    #[arg(long = "rollup.sequencer", visible_aliases = ["rollup.sequencer-http", "rollup.sequencer-ws"])]
    pub sequencer: Option<String>,

    /// Disable transaction pool gossip
    #[arg(long = "rollup.disable-tx-pool-gossip")]
    pub disable_txpool_gossip: bool,

    /// By default the pending block equals the latest block
    /// to save resources and not leak txs from the tx-pool,
    /// this flag enables computing of the pending block
    /// from the tx-pool instead.
    ///
    /// If `compute_pending_block` is not enabled, the payload builder
    /// will use the payload attributes from the latest block. Note
    /// that this flag is not yet functional.
    #[arg(long = "rollup.compute-pending-block")]
    pub compute_pending_block: bool,

    /// enables discovery v4 if provided
    #[arg(long = "rollup.discovery.v4", default_value = "false")]
    pub discovery_v4: bool,

    /// Enable transaction conditional support on sequencer
    #[arg(long = "rollup.enable-tx-conditional", default_value = "false")]
    pub enable_tx_conditional: bool,

    /// HTTP endpoint(s) for the interop filter, used to validate the interop messages referenced
    /// by incoming transactions. Repeat the flag to configure multiple endpoints; each check is
    /// fanned out to all of them and combined by quorum agreement (see
    /// `--rollup.interop-min-responses`). When none are set, interop transaction validation is
    /// disabled: a node that builds blocks will then include transactions carrying invalid
    /// interop messages, producing invalid blocks. It is only safe to leave this unset on nodes
    /// that do not build blocks.
    #[arg(long = "rollup.interop-http", value_name = "INTEROP_HTTP_URL")]
    pub interop_http: Vec<String>,

    /// Minimum number of definitive verdicts required to decide an interop check across the
    /// configured `--rollup.interop-http` endpoints. A transaction is accepted only when this many
    /// endpoints return a definitive verdict and all of them agree it is valid; if they disagree
    /// the transaction is rejected.
    ///
    /// Defaults to the number of endpoints (unanimity, fail-closed). Note this means any single
    /// unreachable or out-of-sync endpoint blocks ALL interop admission until it recovers, so
    /// adding endpoints under the default REDUCES availability. Set a majority quorum (e.g.
    /// N/2+1) to tolerate a degraded endpoint while still only accepting on unanimous
    /// agreement among responders.
    ///
    /// Disagreement detection is best-effort: once the quorum is reached the remaining endpoints
    /// are not awaited, so a slow dissenter beyond the quorum may go unseen.
    #[arg(long = "rollup.interop-min-responses", value_name = "INTEROP_MIN_RESPONSES")]
    pub interop_min_responses: Option<usize>,

    /// Safety level for interop filter validation.
    #[arg(
        long = "rollup.interop-safety-level",
        default_value_t = SafetyLevel::CrossUnsafe,
    )]
    pub interop_safety_level: SafetyLevel,

    /// Optional headers to use when connecting to the sequencer.
    #[arg(long = "rollup.sequencer-headers", requires = "sequencer")]
    pub sequencer_headers: Vec<String>,

    /// RPC endpoint for historical data.
    #[arg(
        long = "rollup.historicalrpc",
        alias = "rollup.historical-rpc",
        value_name = "HISTORICAL_HTTP_URL"
    )]
    pub historical_rpc: Option<String>,

    /// Minimum suggested priority fee (tip) in wei, default `1_000_000`
    #[arg(long, default_value_t = 1_000_000)]
    pub min_suggested_priority_fee: u64,

    /// Maximum cumulative uncompressed (EIP-2718 encoded) block size in bytes.
    ///
    /// When set, the payload builder stops including mempool transactions once the block's total
    /// uncompressed transaction size would exceed this value. This bounds the size of the
    /// `engine_getPayload` response so it stays within the limits assumed by consensus-layer
    /// clients (e.g. the common 10 MiB JSON payload cap). Unset means no limit.
    #[arg(long = "rollup.max-uncompressed-block-size", value_name = "MAX_UNCOMPRESSED_BLOCK_SIZE")]
    pub max_uncompressed_block_size: Option<u64>,

    /// A URL pointing to a secure websocket subscription that streams out flashblocks.
    ///
    /// If given, the flashblocks are received to build pending block. All request with "pending"
    /// block tag will use the pending state based on flashblocks.
    #[arg(long, alias = "websocket-url")]
    pub flashblocks_url: Option<Url>,

    /// Enable flashblock consensus client to drive the chain forward
    ///
    /// When enabled, the flashblock consensus client will process flashblock sequences and submit
    /// them to the engine API to advance the chain.
    /// Requires `flashblocks_url` to be set.
    #[arg(long, default_value_t = false, requires = "flashblocks_url")]
    pub flashblock_consensus: bool,

    /// If true, initialize external-proofs exex to save and serve trie nodes to provide proofs
    /// faster.
    #[arg(
        long = "proofs-history",
        value_name = "PROOFS_HISTORY",
        default_value_ifs([
            ("proofs-history.storage-path", ArgPredicate::IsPresent, "true")
        ])
    )]
    pub proofs_history: bool,

    /// Shared with every `op-proofs` CLI subcommand — see
    /// [`ProofsHistoryStorageArgs`].
    #[command(flatten)]
    pub history: ProofsHistoryStorageArgs,

    /// Shared with the `op-proofs prune` subcommand — see
    /// [`ProofsHistoryWindowArg`].
    #[command(flatten)]
    pub proofs_history_window: ProofsHistoryWindowArg,

    /// Verification interval: perform full block execution every N blocks for data integrity.
    /// - 0: Disabled (Default) (always use fast path with pre-computed data from notifications)
    /// - 1: Always verify (always execute blocks, slowest)
    /// - N: Verify every Nth block (e.g., 100 = every 100 blocks)
    ///
    /// Periodic verification helps catch data corruption or consensus bugs while maintaining
    /// good performance.
    ///
    /// CLI: `--proofs-history.verification-interval 100`
    #[arg(
        long = "proofs-history.verification-interval",
        value_name = "PROOFS_HISTORY_VERIFICATION_INTERVAL",
        default_value_t = 0
    )]
    pub proofs_history_verification_interval: u64,

    /// ralim: cap P2P block download bandwidth, in megabytes per second
    /// (decimal, 1 MB = 1,000,000 bytes).
    ///
    /// Applies a process-global token bucket to the header and body downloads
    /// the staged pipeline performs over devp2p — the path a node uses when it
    /// is far enough behind to backfill. Unset (or 0) leaves the download
    /// unbounded, which is upstream's behaviour.
    ///
    /// The cap is on RLP-encoded response bytes, measured before RLPx's snappy
    /// compression, so actual socket throughput is somewhat lower than the
    /// number given here. Burst is one second of traffic (at least 8 MiB).
    ///
    /// Note this throttles catch-up itself: a node that is behind stays behind
    /// longer. It is a knob for bounding bandwidth cost, not for going faster.
    // Stored in bytes per second rather than MB/s: `RollupArgs` derives `Eq`,
    // which `f64` does not implement, and an exact integer of bytes is the
    // unambiguous unit to hand the limiter anyway.
    #[arg(
        long = "rollup.download-rate-limit-mbps",
        value_name = "MEGABYTES_PER_SEC",
        value_parser = parse_download_rate_limit
    )]
    pub download_rate_limit_bytes_per_sec: Option<u64>,
}

/// Parses `--rollup.download-rate-limit-mbps` into bytes per second.
///
/// Fractional megabytes are accepted (`0.5` = 500,000 B/s). `0` is accepted and
/// means unlimited, matching "flag not given", so an operator can disable the
/// limit in a config template without deleting the line. Negative and
/// non-finite values are rejected rather than silently clamped.
fn parse_download_rate_limit(value: &str) -> Result<u64, String> {
    const BYTES_PER_MEGABYTE: f64 = 1_000_000.0;

    let mbps: f64 = value.parse().map_err(|_| format!("not a number: {value}"))?;
    if !mbps.is_finite() || mbps < 0.0 {
        return Err(format!("must be a finite, non-negative number of MB/s: {value}"));
    }
    // Round rather than truncate so a rate below one byte per second still ends
    // up unlimited-by-zero instead of an unexpected 1 B/s crawl.
    Ok((mbps * BYTES_PER_MEGABYTE).round() as u64)
}

impl Default for RollupArgs {
    fn default() -> Self {
        Self {
            sequencer: None,
            disable_txpool_gossip: false,
            compute_pending_block: false,
            discovery_v4: false,
            enable_tx_conditional: false,
            interop_http: Vec::new(),
            interop_min_responses: None,
            interop_safety_level: SafetyLevel::CrossUnsafe,
            sequencer_headers: Vec::new(),
            historical_rpc: None,
            min_suggested_priority_fee: 1_000_000,
            max_uncompressed_block_size: None,
            flashblocks_url: None,
            flashblock_consensus: false,
            proofs_history: false,
            history: ProofsHistoryStorageArgs {
                storage_path: None,
                storage_version: ProofsStorageVersion::V1,
            },
            proofs_history_window: ProofsHistoryWindowArg::default(),
            proofs_history_verification_interval: 0,
            download_rate_limit_bytes_per_sec: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::{Args, Parser};

    /// A helper type to parse Args more easily
    #[derive(Parser)]
    struct CommandParser<T: Args> {
        #[command(flatten)]
        args: T,
    }

    #[test]
    fn parses_download_rate_limit_into_bytes_per_sec() {
        let args = CommandParser::<RollupArgs>::parse_from([
            "reth",
            "--rollup.download-rate-limit-mbps",
            "1.5",
        ])
        .args;
        assert_eq!(args.download_rate_limit_bytes_per_sec, Some(1_500_000));
    }

    #[test]
    fn download_rate_limit_defaults_to_unset() {
        let args = CommandParser::<RollupArgs>::parse_from(["reth"]).args;
        assert_eq!(args.download_rate_limit_bytes_per_sec, None);
    }

    #[test]
    fn download_rate_limit_zero_is_accepted_as_unlimited() {
        // A config template can keep the line and disable the limit with 0;
        // launch treats Some(0) the same as None.
        let args = CommandParser::<RollupArgs>::parse_from([
            "reth",
            "--rollup.download-rate-limit-mbps=0",
        ])
        .args;
        assert_eq!(args.download_rate_limit_bytes_per_sec, Some(0));
    }

    #[test]
    fn download_rate_limit_rejects_negative_and_garbage() {
        for value in ["-1", "nan", "inf", "fast"] {
            let parsed = CommandParser::<RollupArgs>::try_parse_from([
                "reth",
                &format!("--rollup.download-rate-limit-mbps={value}"),
            ]);
            assert!(parsed.is_err(), "{value} should have been rejected");
        }
    }

    #[test]
    fn test_parse_optimism_default_args() {
        let default_args = RollupArgs::default();
        let args = CommandParser::<RollupArgs>::parse_from(["reth"]).args;
        assert_eq!(args, default_args);
    }

    #[test]
    fn test_parse_optimism_compute_pending_block_args() {
        let expected_args = RollupArgs { compute_pending_block: true, ..Default::default() };
        let args =
            CommandParser::<RollupArgs>::parse_from(["reth", "--rollup.compute-pending-block"])
                .args;
        assert_eq!(args, expected_args);
    }

    #[test]
    fn test_parse_optimism_discovery_v4_args() {
        let expected_args = RollupArgs { discovery_v4: true, ..Default::default() };
        let args = CommandParser::<RollupArgs>::parse_from(["reth", "--rollup.discovery.v4"]).args;
        assert_eq!(args, expected_args);
    }

    #[test]
    fn test_parse_optimism_sequencer_http_args() {
        let expected_args =
            RollupArgs { sequencer: Some("http://host:port".into()), ..Default::default() };
        let args = CommandParser::<RollupArgs>::parse_from([
            "reth",
            "--rollup.sequencer-http",
            "http://host:port",
        ])
        .args;
        assert_eq!(args, expected_args);
    }

    #[test]
    fn test_parse_optimism_disable_txpool_args() {
        let expected_args = RollupArgs { disable_txpool_gossip: true, ..Default::default() };
        let args =
            CommandParser::<RollupArgs>::parse_from(["reth", "--rollup.disable-tx-pool-gossip"])
                .args;
        assert_eq!(args, expected_args);
    }

    #[test]
    fn test_parse_optimism_enable_tx_conditional() {
        let expected_args = RollupArgs { enable_tx_conditional: true, ..Default::default() };
        let args =
            CommandParser::<RollupArgs>::parse_from(["reth", "--rollup.enable-tx-conditional"])
                .args;
        assert_eq!(args, expected_args);
    }

    #[test]
    fn test_parse_interop_multiple_endpoints() {
        let expected_args = RollupArgs {
            interop_http: vec!["http://a:1".into(), "http://b:2".into(), "http://c:3".into()],
            interop_min_responses: Some(2),
            ..Default::default()
        };
        let args = CommandParser::<RollupArgs>::parse_from([
            "reth",
            "--rollup.interop-http",
            "http://a:1",
            "--rollup.interop-http",
            "http://b:2",
            "--rollup.interop-http",
            "http://c:3",
            "--rollup.interop-min-responses",
            "2",
        ])
        .args;
        assert_eq!(args, expected_args);
    }

    #[test]
    fn test_parse_max_uncompressed_block_size() {
        let expected_args =
            RollupArgs { max_uncompressed_block_size: Some(7_340_032), ..Default::default() };
        let args = CommandParser::<RollupArgs>::parse_from([
            "reth",
            "--rollup.max-uncompressed-block-size",
            "7340032",
        ])
        .args;
        assert_eq!(args, expected_args);
    }

    #[test]
    fn test_parse_optimism_many_args() {
        let expected_args = RollupArgs {
            disable_txpool_gossip: true,
            compute_pending_block: true,
            enable_tx_conditional: true,
            sequencer: Some("http://host:port".into()),
            ..Default::default()
        };
        let args = CommandParser::<RollupArgs>::parse_from([
            "reth",
            "--rollup.disable-tx-pool-gossip",
            "--rollup.compute-pending-block",
            "--rollup.enable-tx-conditional",
            "--rollup.sequencer-http",
            "http://host:port",
        ])
        .args;
        assert_eq!(args, expected_args);
    }
}
