#![no_main]

extern crate libfuzzer_sys;
extern crate pris;
use libfuzzer_sys::fuzz_target;
use pris::{lexer,parser};

fuzz_target!(|data: &[u8]| {
    lexer::lex(data).and_then(|tokens| parser::parse(&tokens[..]));
});
