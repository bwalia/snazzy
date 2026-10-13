//! API keys, tokens and stream keys in the OS credential store: Windows
//! Credential Manager, the Linux Secret Service (GNOME Keyring, KWallet), and
//! the macOS Keychain when developing on a Mac. Never in files, logs or settings.
//!
//! Accounts match the Mac app (`com.snazzy.pro.api-keys`): `anthropic`,
//! `mcp.server.token`, `broadcast.<platform>`, `github.token`, …

use thiserror::Error;

/// The credential store service name, shared with the Mac app's Keychain items.
pub const SERVICE: &str = "com.snazzy.pro.api-keys";

#[derive(Debug, Error)]
pub enum SecretError {
    #[error("The credential store isn't available: {0}")]
    Unavailable(String),
    #[error("Couldn't use the credential store: {0}")]
    Failed(String),
}

/// Somewhere to keep secrets. The app uses [`CredentialStore`]; tests use [`MemoryStore`].
pub trait SecretStore: Send + Sync {
    fn get(&self, account: &str) -> Result<Option<String>, SecretError>;
    fn set(&self, account: &str, secret: &str) -> Result<(), SecretError>;
    fn delete(&self, account: &str) -> Result<(), SecretError>;
}

/// The operating system's credential store.
pub struct CredentialStore {
    service: String,
}

impl CredentialStore {
    pub fn new() -> Self {
        Self {
            service: SERVICE.to_string(),
        }
    }

    fn entry(&self, account: &str) -> Result<keyring::Entry, SecretError> {
        keyring::Entry::new(&self.service, account).map_err(map)
    }
}

impl Default for CredentialStore {
    fn default() -> Self {
        Self::new()
    }
}

fn map(e: keyring::Error) -> SecretError {
    match e {
        keyring::Error::PlatformFailure(err) | keyring::Error::NoStorageAccess(err) => {
            SecretError::Unavailable(err.to_string())
        }
        other => SecretError::Failed(other.to_string()),
    }
}

impl SecretStore for CredentialStore {
    fn get(&self, account: &str) -> Result<Option<String>, SecretError> {
        match self.entry(account)?.get_password() {
            Ok(s) => Ok(Some(s)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(map(e)),
        }
    }

    fn set(&self, account: &str, secret: &str) -> Result<(), SecretError> {
        if secret.is_empty() {
            return self.delete(account);
        }
        self.entry(account)?.set_password(secret).map_err(map)
    }

    fn delete(&self, account: &str) -> Result<(), SecretError> {
        match self.entry(account)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(map(e)),
        }
    }
}

/// Secrets in memory, for tests and the self-tests.
#[derive(Default)]
pub struct MemoryStore {
    items: std::sync::Mutex<std::collections::HashMap<String, String>>,
}

impl SecretStore for MemoryStore {
    fn get(&self, account: &str) -> Result<Option<String>, SecretError> {
        Ok(self
            .items
            .lock()
            .map_err(|e| SecretError::Failed(e.to_string()))?
            .get(account)
            .cloned())
    }
    fn set(&self, account: &str, secret: &str) -> Result<(), SecretError> {
        let mut items = self
            .items
            .lock()
            .map_err(|e| SecretError::Failed(e.to_string()))?;
        if secret.is_empty() {
            items.remove(account);
        } else {
            items.insert(account.to_string(), secret.to_string());
        }
        Ok(())
    }
    fn delete(&self, account: &str) -> Result<(), SecretError> {
        self.items
            .lock()
            .map_err(|e| SecretError::Failed(e.to_string()))?
            .remove(account);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_store_round_trip() {
        let s = MemoryStore::default();
        assert_eq!(s.get("anthropic").unwrap(), None);
        s.set("anthropic", "test-value").unwrap();
        assert_eq!(s.get("anthropic").unwrap().as_deref(), Some("test-value"));
        s.set("anthropic", "").unwrap();
        assert_eq!(s.get("anthropic").unwrap(), None);
        s.delete("missing").unwrap();
    }

    /// Touches the real credential store, so it only runs when asked:
    /// `SNAZZY_KEYRING_TESTS=1 cargo test -p snazzy-platform`.
    #[test]
    fn credential_store_round_trip() {
        if std::env::var("SNAZZY_KEYRING_TESTS").as_deref() != Ok("1") {
            return;
        }
        let s = CredentialStore {
            service: format!("{SERVICE}.test"),
        };
        s.set("round-trip", "value-1").unwrap();
        assert_eq!(s.get("round-trip").unwrap().as_deref(), Some("value-1"));
        s.delete("round-trip").unwrap();
        assert_eq!(s.get("round-trip").unwrap(), None);
    }
}
