//! HTTP clients for Argus's own requests.
//!
//! reqwest 0.13 verifies certificates with the platform verifier unless it is
//! handed a TLS config, and on Android that verifier needs JNI setup the app
//! does not do. Every client here gets the config reqwest 0.12's `rustls-tls`
//! feature built: rustls with the ring provider, the bundled Mozilla roots from
//! webpki-roots, and HTTP/1.1 only.

use std::sync::{Arc, LazyLock};

static TLS_CONFIG: LazyLock<rustls::ClientConfig> = LazyLock::new(|| {
    let roots = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("ring supports the default TLS versions")
        .with_root_certificates(roots)
        .with_no_client_auth();
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    config
});

/// Use instead of `reqwest::Client::builder()`.
pub fn client_builder() -> reqwest::ClientBuilder {
    reqwest::Client::builder().tls_backend_preconfigured(TLS_CONFIG.clone())
}

/// Use instead of `reqwest::Client::new()`; like it, panics if the client
/// cannot be built.
pub fn client() -> reqwest::Client {
    client_builder().build().expect("HTTP client")
}
