// Pris -- A language for designing slides
// Copyright 2017 Ruud van Asseldonk

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License version 3. A copy
// of the License is available in the root of the repository.

extern crate lalrpop_util;
extern crate libc;

mod ast;
mod builtins;
mod cairo;
mod driver;
mod elements;
mod error;
mod interpreter;
mod pretty;
mod runtime;
mod syntax;
mod types;

use std::io;
use std::io::Read;
use lalrpop_util::ParseError;

fn report_error(input: &str, location: usize, len: usize) {
    let mut line = 1;
    let mut start = 0;
    for (c, i) in input.chars().zip(0..) {
        if i == location { break; }
        if c == '\n' {
            line += 1;
            start = i + 1;
        }
    }
    let line_content = &input[start..].lines().next().unwrap();
    println!("Parse error at line {}:\n", line);
    println!("{}", line_content);
    for _ in 0..location - start { print!(" "); }
    print!("^");
    for _ in 1..len { print!("~"); }
    print!("\n\nError: ");

}

fn parse_or_abort<'a>(input: &'a str) -> ast::Document<'a> {
    match syntax::parse_document(&input) {
        Ok(doc) => return doc,
        Err(err) => {
            match err {
                ParseError::InvalidToken { location } => {
                    report_error(input, location, 1);
                    println!("invalid token.");
                }
                ParseError::UnrecognizedToken { token, expected } => {
                    if let Some((location, _, loc2)) = token {
                        report_error(input, location, loc2 - location);
                        println!("unrecognized token.");
                        if expected.len() > 0 {
                            println!("Expected one of ");
                            let mut exp_i = expected.iter();
                            print!("\"{}\"", exp_i.next().unwrap());
                            for e in exp_i {
                                print!(", \"{}\"", e);
                            }
                            println!(".");
                        }
                    } else {
                        println!("Parse error somewhere. That is all I know.");
                    }
                }
                ParseError::ExtraToken { token } => {
                    let (location, _, loc2) = token;
                    report_error(input, location, loc2 - location);
                    println!("extra token (whatever that means).");
                }
                ParseError::User { .. } => {
                    panic!("ProgrammerBehindKeyboardError");
                }
            }
            std::process::exit(1)
        }
    }
}

fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let doc = parse_or_abort(&input);

    println!("Evaluating document ...");

    let mut frames = Vec::new();
    let mut context_frame = runtime::Frame::new();
    for statement in &doc.0 {
        let result = match interpreter::eval_statement(&mut context_frame, statement) {
            Ok(x) => x,
            Err(e) => { e.print(); panic!("Abort after error.") }
        };
        if let Some(frame) = result { frames.push(frame); }
    }

    let surf = cairo::Surface::new("test.pdf", 1920.0, 1080.0);
    let mut cr = cairo::Cairo::new(surf);
    cr.set_source_rgb(0.0, 0.0, 0.0);
    cr.set_line_width(6.0);

    for (i, frame) in frames.iter().enumerate() {
        println!("[{}/{}] Painting frame ...", i + 1, frames.len());
        driver::render_frame(&mut cr, frame);
    }
}
