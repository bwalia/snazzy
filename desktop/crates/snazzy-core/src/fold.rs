//! Text folding without ICU: what search and folder names need of Foundation's
//! `folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])`
//! and `applyingTransform(.stripCombiningMarks)`.
//!
//! Covered: case (Unicode lower case, plus `ß`/`ẞ` → `ss`, final sigma → `σ`, Latin
//! ligatures `ﬀ…ﬆ`), accents on precomposed Latin, Greek and Cyrillic letters and
//! stray combining marks, fullwidth ASCII, halfwidth katakana and symbols.
//! Not covered (see docs/specs/search.md): other full case foldings, other scripts'
//! marks, and the halfwidth voiced-sound marks combining with the kana before them.

use crate::fold_table::{STRIP, WIDTH};

fn lookup(table: &[(char, char)], c: char) -> Option<char> {
    table
        .binary_search_by_key(&c, |&(from, _)| from)
        .ok()
        .map(|i| table[i].1)
}

/// A nonspacing combining mark (the common blocks).
pub fn is_combining_mark(c: char) -> bool {
    matches!(c as u32, 0x0300..=0x036F | 0x0483..=0x0489 | 0x0591..=0x05BD | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F | 0x3099..=0x309A)
}

/// The base letter of a precomposed letter with accents (`é` → `e`), else itself.
pub fn strip_accent(c: char) -> char {
    let mut c = c;
    // Some decompose in steps (ǖ → ü → u): the table maps straight to the base, but be safe.
    while let Some(base) = lookup(STRIP, c) {
        if base == c {
            break;
        }
        c = base;
    }
    c
}

fn width(c: char) -> char {
    match c as u32 {
        0xFF01..=0xFF5E => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c),
        _ => lookup(WIDTH, c).unwrap_or(c),
    }
}

/// Case, accent and width folding for search (`DeckSearch.fold`).
pub fn fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        let c = width(c);
        match c {
            'ß' | 'ẞ' => out.push_str("ss"),
            'ς' => out.push('σ'),
            'ﬀ' => out.push_str("ff"),
            'ﬁ' => out.push_str("fi"),
            'ﬂ' => out.push_str("fl"),
            'ﬃ' => out.push_str("ffi"),
            'ﬄ' => out.push_str("ffl"),
            'ﬅ' | 'ﬆ' => out.push_str("st"),
            c if is_combining_mark(c) => {}
            c => {
                for l in strip_accent(c).to_lowercase() {
                    if !is_combining_mark(l) {
                        out.push(strip_accent(l));
                    }
                }
            }
        }
    }
    out
}

/// Accents and combining marks removed, nothing else changed.
pub fn strip_marks(s: &str) -> String {
    s.chars()
        .filter(|&c| !is_combining_mark(c))
        .map(strip_accent)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folds() {
        assert_eq!(fold("CRÈME BRÛLÉE"), "creme brulee");
        assert_eq!(fold("İstanbul"), "istanbul");
        assert_eq!(fold("e\u{301}"), "e");
        assert_eq!(fold("ǖ"), "u");
        assert_eq!(strip_marks("Ça va"), "Ca va");
    }
}
