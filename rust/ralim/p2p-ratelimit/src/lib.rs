//! Process-global token-bucket rate limiter for op-reth's P2P block downloads.
//!
//! When a node is far behind, reth catches up by downloading headers and bodies
//! over devp2p through the staged pipeline. That download is otherwise
//! unbounded: it goes as fast as the peers will serve it. This crate caps it to
//! a configured number of megabytes per second, process-wide.
//!
//! Two pieces:
//!
//! - [`DownloadRateLimiter`] — the token bucket, charged in bytes.
//! - [`RateLimitedClient`] — a decorator over reth's [`HeadersClient`] and [`BodiesClient`] that
//!   charges the bucket with the RLP size of every response it passes through, and waits out the
//!   resulting deficit.
//!
//! The limiter is installed once at startup from the CLI
//! (`--rollup.download-rate-limit-mbps`) via [`init_global`]. With no limit
//! configured, [`RateLimitedClient`] is a pass-through and costs nothing beyond
//! one extra `Box::pin` per request.
//!
//! # Why global
//!
//! The knob is a cap on what the *host* pulls from the network, so it is
//! process-wide rather than per peer: one bucket shared by the header and body
//! downloaders, and by every peer they fan out to.

use std::{
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, Instant},
};

use alloy_primitives::B256;
use alloy_rlp::Encodable;
use reth_network_p2p::{
    BlockClient,
    bodies::client::BodiesClient,
    download::DownloadClient,
    error::PeerRequestResult,
    headers::client::{HeadersClient, HeadersRequest},
    priority::Priority,
};
use reth_network_peers::PeerId;
use std::ops::RangeInclusive;
use tracing::{debug, warn};

/// Bytes in one megabyte. Decimal, as bandwidth is conventionally quoted:
/// 1 MB/s here means 1,000,000 bytes per second.
const BYTES_PER_MEGABYTE: f64 = 1_000_000.0;

/// A single response is charged in full even when it exceeds the burst
/// capacity, so the bucket needs enough headroom for the largest one reth will
/// ask for. Bodies responses are soft-limited to 2 MB upstream; 8 MB of burst
/// leaves room for that plus concurrency without letting an idle node bank a
/// large credit.
const MIN_CAPACITY_BYTES: f64 = 8.0 * 1_048_576.0;

/// A deficit longer than this means the limit is far below what the sync needs,
/// which is worth saying out loud once per occurrence rather than silently
/// stalling.
const LONG_WAIT_WARN: Duration = Duration::from_secs(10);

static GLOBAL: OnceLock<Arc<DownloadRateLimiter>> = OnceLock::new();

/// Installs the process-global download limiter.
///
/// Call once during startup, before the node builds its pipeline. Later calls
/// leave the installed limiter alone and return it, so a second call cannot
/// silently change the rate.
pub fn init_global(bytes_per_sec: u64) -> &'static Arc<DownloadRateLimiter> {
    let limiter = GLOBAL.get_or_init(|| Arc::new(DownloadRateLimiter::new(bytes_per_sec)));
    if limiter.bytes_per_sec() != bytes_per_sec {
        warn!(
            target: "ralim::ratelimit",
            installed = limiter.bytes_per_sec(),
            requested = bytes_per_sec,
            "P2P download rate limiter was already installed; keeping the installed rate",
        );
    }
    limiter
}

/// The process-global download limiter, or `None` when no limit is configured.
pub fn global() -> Option<&'static Arc<DownloadRateLimiter>> {
    GLOBAL.get()
}

/// A token bucket over bytes, shared by every P2P download in the process.
///
/// Charging is "spend now, pay later": a charge always succeeds immediately and
/// drives the bucket negative, and the caller waits out the deficit. Concurrent
/// callers therefore queue behind each other instead of all being admitted at
/// once, and the long-run average is exactly the configured rate.
#[derive(Debug)]
pub struct DownloadRateLimiter {
    rate_bytes_per_sec: u64,
    capacity_bytes: f64,
    state: Mutex<State>,
}

#[derive(Debug)]
struct State {
    /// Available bytes. Negative while a charge is being paid off.
    tokens: f64,
    last_refill: Instant,
}

impl DownloadRateLimiter {
    /// Creates a limiter capped at `bytes_per_sec`.
    ///
    /// The burst capacity is one second of traffic, floored at
    /// [`MIN_CAPACITY_BYTES`] so a single large response is never bigger than
    /// the bucket itself. A rate of zero would divide by zero when computing a
    /// deficit, so it is clamped to one byte per second; the CLI never passes
    /// zero (there, zero means "no limit" and no limiter is installed).
    pub fn new(bytes_per_sec: u64) -> Self {
        let rate_bytes_per_sec = bytes_per_sec.max(1);
        let capacity_bytes = (rate_bytes_per_sec as f64).max(MIN_CAPACITY_BYTES);
        Self {
            rate_bytes_per_sec,
            capacity_bytes,
            state: Mutex::new(State { tokens: capacity_bytes, last_refill: Instant::now() }),
        }
    }

    /// The configured rate in megabytes per second, for logging.
    pub fn megabytes_per_sec(&self) -> f64 {
        self.rate_bytes_per_sec as f64 / BYTES_PER_MEGABYTE
    }

    /// The configured rate in bytes per second.
    pub const fn bytes_per_sec(&self) -> u64 {
        self.rate_bytes_per_sec
    }

    /// The burst capacity in bytes.
    pub const fn capacity_bytes(&self) -> f64 {
        self.capacity_bytes
    }

    /// Charges `bytes` to the bucket and waits out any resulting deficit.
    pub async fn charge(&self, bytes: usize) {
        let delay = self.charge_at(bytes, Instant::now());
        if delay.is_zero() {
            return;
        }
        if delay >= LONG_WAIT_WARN {
            warn!(
                target: "ralim::ratelimit",
                bytes,
                delay_secs = delay.as_secs_f64(),
                rate_mbps = self.megabytes_per_sec(),
                "P2P download throttled for a long time; the configured rate limit may be too low",
            );
        } else {
            debug!(
                target: "ralim::ratelimit",
                bytes,
                delay_ms = delay.as_millis(),
                "throttling P2P download",
            );
        }
        tokio::time::sleep(delay).await;
    }

    /// The synchronous half of [`charge`](Self::charge): refills the bucket,
    /// subtracts `bytes`, and reports how long the caller must wait. Split out
    /// so the accounting is testable without a clock.
    fn charge_at(&self, bytes: usize, now: Instant) -> Duration {
        // A poisoned lock only means some caller panicked mid-charge; the
        // accounting is still coherent, so recover rather than propagate.
        let mut state = self.state.lock().unwrap_or_else(|err| err.into_inner());

        let elapsed = now.saturating_duration_since(state.last_refill).as_secs_f64();
        state.last_refill = now;
        state.tokens =
            elapsed.mul_add(self.rate_bytes_per_sec as f64, state.tokens).min(self.capacity_bytes);
        state.tokens -= bytes as f64;

        if state.tokens >= 0.0 {
            Duration::ZERO
        } else {
            Duration::from_secs_f64(-state.tokens / self.rate_bytes_per_sec as f64)
        }
    }
}

/// The boxed future the decorated client returns.
///
/// Boxing is what lets the throttling wrapper be an `async` block while still
/// satisfying the client traits' `Future + Send + Sync + Unpin` bound on
/// `Output`: `Pin<Box<dyn Future>>` is `Unpin` however the inner future behaves.
pub type ClientFuture<T> = Pin<Box<dyn Future<Output = PeerRequestResult<T>> + Send + Sync>>;

/// Wraps a reth block client so every header and body response it returns is
/// charged to a [`DownloadRateLimiter`].
///
/// Constructed with [`RateLimitedClient::new`], which picks up the global
/// limiter. Without one it is a pass-through.
#[derive(Debug, Clone)]
pub struct RateLimitedClient<C> {
    inner: C,
    limiter: Option<Arc<DownloadRateLimiter>>,
}

impl<C> RateLimitedClient<C> {
    /// Wraps `inner` with the process-global limiter, if one is installed.
    pub fn new(inner: C) -> Self {
        Self { inner, limiter: global().cloned() }
    }

    /// Wraps `inner` with an explicit limiter. For tests and callers that keep
    /// their own bucket instead of the global one.
    pub const fn with_limiter(inner: C, limiter: Option<Arc<DownloadRateLimiter>>) -> Self {
        Self { inner, limiter }
    }

    /// The wrapped client.
    pub const fn inner(&self) -> &C {
        &self.inner
    }

    /// Whether a limiter is actually installed on this client.
    pub const fn is_limited(&self) -> bool {
        self.limiter.is_some()
    }
}

impl<C: DownloadClient> DownloadClient for RateLimitedClient<C> {
    fn report_bad_message(&self, peer_id: PeerId) {
        self.inner.report_bad_message(peer_id);
    }

    fn num_connected_peers(&self) -> usize {
        self.inner.num_connected_peers()
    }
}

impl<C> HeadersClient for RateLimitedClient<C>
where
    C: HeadersClient + 'static,
{
    type Header = C::Header;
    type Output = ClientFuture<Vec<C::Header>>;

    fn get_headers_with_priority(
        &self,
        request: HeadersRequest,
        priority: Priority,
    ) -> Self::Output {
        throttle(self.limiter.clone(), self.inner.get_headers_with_priority(request, priority))
    }
}

impl<C> BodiesClient for RateLimitedClient<C>
where
    C: BodiesClient + 'static,
{
    type Body = C::Body;
    type Output = ClientFuture<Vec<C::Body>>;

    fn get_block_bodies_with_priority_and_range_hint(
        &self,
        hashes: Vec<B256>,
        priority: Priority,
        range_hint: Option<RangeInclusive<u64>>,
    ) -> Self::Output {
        throttle(
            self.limiter.clone(),
            self.inner.get_block_bodies_with_priority_and_range_hint(hashes, priority, range_hint),
        )
    }
}

impl<C> BlockClient for RateLimitedClient<C>
where
    C: BlockClient + 'static,
{
    type Block = C::Block;
}

/// Charges the RLP size of a successful response to `limiter`, then yields it.
///
/// The charge happens after the response arrives rather than before the request
/// is sent, because the size is only known then. The delay lands on the
/// response's completion, which is what paces the downloader: it awaits these
/// futures, so a throttled response holds up the request that would follow it.
fn throttle<T, F>(limiter: Option<Arc<DownloadRateLimiter>>, fut: F) -> ClientFuture<T>
where
    T: RlpSize + Send + Sync + 'static,
    F: Future<Output = PeerRequestResult<T>> + Send + Sync + 'static,
{
    Box::pin(async move {
        let response = fut.await;
        if let Some(limiter) = &limiter &&
            let Ok(response) = &response
        {
            limiter.charge(response.data().rlp_size()).await;
        }
        response
    })
}

/// The RLP-encoded size of a response payload, in bytes.
///
/// This is the wire size before `RLPx`'s snappy compression, so the limiter is
/// slightly conservative: actual bytes on the socket are somewhat fewer.
trait RlpSize {
    /// Encoded length of `self` in bytes.
    fn rlp_size(&self) -> usize;
}

impl<T: Encodable> RlpSize for Vec<T> {
    fn rlp_size(&self) -> usize {
        self.iter().map(Encodable::length).sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 1 MB/s, so byte counts and seconds line up 1:1 in the assertions.
    fn limiter() -> DownloadRateLimiter {
        DownloadRateLimiter::new(BYTES_PER_MEGABYTE as u64)
    }

    #[test]
    fn spends_the_burst_without_waiting() {
        let limiter = limiter();
        let now = Instant::now();
        // The bucket starts full, so the first charge up to capacity is free.
        assert_eq!(limiter.charge_at(limiter.capacity_bytes() as usize, now), Duration::ZERO);
    }

    #[test]
    fn charges_the_deficit_after_the_burst() {
        let limiter = limiter();
        let now = Instant::now();
        limiter.charge_at(limiter.capacity_bytes() as usize, now);

        // Two seconds' worth of bytes with an empty bucket: two seconds of wait.
        let delay = limiter.charge_at(2 * limiter.bytes_per_sec() as usize, now);
        assert!(
            (delay.as_secs_f64() - 2.0).abs() < 0.01,
            "expected ~2s, got {}s",
            delay.as_secs_f64()
        );
    }

    #[test]
    fn deficit_accumulates_across_concurrent_charges() {
        let limiter = limiter();
        let now = Instant::now();
        limiter.charge_at(limiter.capacity_bytes() as usize, now);

        let first = limiter.charge_at(limiter.bytes_per_sec() as usize, now);
        let second = limiter.charge_at(limiter.bytes_per_sec() as usize, now);
        assert!(
            second > first,
            "a later charge must wait out the earlier one too: {second:?} !> {first:?}"
        );
        assert!((second.as_secs_f64() - 2.0).abs() < 0.01, "got {}s", second.as_secs_f64());
    }

    #[test]
    fn refills_over_time() {
        let limiter = limiter();
        let start = Instant::now();
        limiter.charge_at(limiter.capacity_bytes() as usize, start);

        // Waiting a second earns a second's worth of bytes back.
        let delay =
            limiter.charge_at(limiter.bytes_per_sec() as usize, start + Duration::from_secs(1));
        assert_eq!(delay, Duration::ZERO);
    }

    #[test]
    fn capacity_is_floored_for_small_rates() {
        // 1 kB/s must still admit a single large bodies response.
        let limiter = DownloadRateLimiter::new(1_000);
        assert_eq!(limiter.capacity_bytes(), MIN_CAPACITY_BYTES);
    }

    #[test]
    fn a_zero_rate_does_not_divide_by_zero() {
        let limiter = DownloadRateLimiter::new(0);
        assert_eq!(limiter.bytes_per_sec(), 1);
        assert!(limiter.charge_at(1_000_000, Instant::now()).as_secs_f64().is_finite());
    }

    #[test]
    fn rlp_size_sums_the_items() {
        // 1-byte RLP values: each encodes as a single byte.
        let items: Vec<u8> = vec![1, 2, 3];
        assert_eq!(items.rlp_size(), 3);
    }
}
