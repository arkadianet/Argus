#![cfg_attr(not(feature = "std"), no_std)]

#[cfg(feature = "std")]
pub mod io {
    pub use std::io::*;
    pub use std::io::{
        BufRead, BufReader, Cursor, Error, ErrorKind, Read, Result, Seek, SeekFrom, Write,
    };
}

#[cfg(not(feature = "std"))]
pub mod io {
    // no_std stubs - not actually used by sigma-rust with std feature
}