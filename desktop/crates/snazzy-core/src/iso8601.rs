//! Dates as Swift's `.iso8601` strategy and `ISO8601DateFormatter()` write them:
//! UTC, whole seconds, `2026-01-02T03:04:05Z`. Reading also accepts an offset
//! (`+01:00`), as Foundation does, but not fractional seconds (Foundation
//! refuses those too).

use time::format_description::FormatItem;
use time::macros::format_description;
use time::{OffsetDateTime, UtcOffset};

const FORMAT: &[FormatItem<'static>] =
    format_description!("[year]-[month]-[day]T[hour]:[minute]:[second]Z");

/// A point in time, kept to whole seconds like the Mac's files.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Date(pub OffsetDateTime);

impl Date {
    pub fn now() -> Self {
        let now = OffsetDateTime::now_utc();
        Self(now.replace_nanosecond(0).unwrap_or(now))
    }

    pub fn from_unix(seconds: i64) -> Option<Self> {
        OffsetDateTime::from_unix_timestamp(seconds).ok().map(Self)
    }

    pub fn unix(&self) -> i64 {
        self.0.unix_timestamp()
    }

    pub fn format(&self) -> String {
        self.0
            .to_offset(UtcOffset::UTC)
            .format(FORMAT)
            .unwrap_or_default()
    }

    pub fn parse(text: &str) -> Option<Self> {
        if text.contains('.') || text.contains(',') {
            return None;
        }
        OffsetDateTime::parse(text, &time::format_description::well_known::Rfc3339)
            .ok()
            .map(Self)
    }
}

impl serde::Serialize for Date {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.format())
    }
}

impl<'de> serde::Deserialize<'de> for Date {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let text = String::deserialize(d)?;
        Date::parse(&text).ok_or_else(|| {
            serde::de::Error::custom(format!("expected an ISO 8601 date, got {text:?}"))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_like_foundation() {
        let d = Date::from_unix(1_767_323_045).unwrap();
        assert_eq!(d.format(), "2026-01-02T03:04:05Z");
        assert_eq!(Date::parse("2026-01-02T03:04:05Z"), Some(d));
        assert_eq!(Date::parse("2026-01-02T04:04:05+01:00"), Some(d));
        assert_eq!(Date::parse("2026-01-02T03:04:05.5Z"), None);
        assert_eq!(Date::parse("yesterday"), None);
    }
}
