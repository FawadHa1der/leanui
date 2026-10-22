//! The Roster verify page's checker (roster/README.md): nanoda, a Lean kernel written apart from
//! Lean's own, checks a receipt (an export file: NDJSON, Lean's export format) and pretty-prints
//! the declarations it is asked for. It is a WASI command: worker.js runs it in the browser on a
//! small shim, and any WASI runtime runs it as is (`wasmtime checker.wasm NAME… < receipt.ndjson`).
//!
//! stdin: the receipt. Arguments: the names to print. stdout: one line of JSON, either
//!   {"ok":true,"declarations":n,"axioms":[…],"printed":{name:{"type":…,"text":…} or null}}
//!   {"ok":false,"error":…,"during":"checking Roster.Receipt.valid"}
//! `type` is the declaration's type alone (what a theorem states), `text` the whole declaration
//! (proofs elided); `axioms` are the receipt's axioms, all of them permitted ones.
//!
//! WASI rather than wasm32-unknown-unknown: nanoda_lib reads export files only from a path or
//! from stdin.

use nanoda_lib::env::Declar;
use nanoda_lib::util::Config;
use serde_json::{json, Map, Value};
use std::sync::Mutex;

/// nanoda_bin's configuration file (nanoda's README): the standard axioms, and the Nat and String
/// extensions that Lean's kernel has too (`decide +kernel` evaluates with them). Any other axiom
/// in the receipt is an error, used or not.
const CONFIG: &str = r#"{
  "use_stdin": true,
  "permitted_axioms": ["propext", "Classical.choice", "Quot.sound"],
  "unpermitted_axiom_hard_error": true,
  "nat_extension": true,
  "string_extension": true
}"#;

/// What the checker is doing. nanoda rejects a declaration by panicking, and wasm cannot unwind
/// (panic = "abort"), so the panic hook writes the verdict.
static DOING: Mutex<String> = Mutex::new(String::new());

fn doing(what: String) { *DOING.lock().unwrap() = what; }

fn reply(v: Value) { println!("{v}"); }

fn main() {
    std::panic::set_hook(Box::new(|info| {
        // the file name only: the path is the build machine's
        let at = info.location().map_or(String::new(), |l| {
            format!(" ({}:{})", l.file().rsplit('/').next().unwrap_or_default(), l.line())
        });
        let during = DOING.lock().map_or(String::new(), |d| d.clone());
        let error = format!("{}{at}", info.payload_as_str().unwrap_or("panic"));
        reply(json!({"ok": false, "error": error, "during": during}));
    }));
    doing("reading the receipt".into());
    let config: Config = serde_json::from_str(CONFIG).unwrap();
    let export = match config.to_export_file() {
        Ok((export, _skipped)) => export, // none: unpermitted axioms are errors
        Err(e) => return reply(json!({"ok": false, "error": e.to_string(), "during": "reading the receipt"})),
    };
    let names: Vec<String> =
        export.with_ctx(|ctx| export.declars.keys().map(|n| format!("{:?}", ctx.debug_print(*n))).collect());
    // nanoda's check_all_declars on one thread, saying which declaration is being checked
    for (name, d) in names.iter().zip(export.declars.values()) {
        doing(format!("checking {name}"));
        export.check_declar(d);
    }
    let axioms: Vec<&String> = names.iter().zip(export.declars.values())
        .filter(|(_, d)| matches!(d, Declar::Axiom { .. }))
        .map(|(n, _)| n)
        .collect();
    let printed: Map<String, Value> = std::env::args().skip(1).map(|want| {
        doing(format!("printing {want}"));
        let found = names.iter().position(|n| *n == want).map(|i| {
            let (n, d) = export.declars.get_index(i).unwrap();
            export.with_pp(|pp| json!({"type": pp.pp_expr(d.info().ty), "text": pp.pp_declar(*n)}))
        });
        (want, found.unwrap_or(Value::Null))
    }).collect();
    reply(json!({"ok": true, "declarations": names.len(), "axioms": axioms, "printed": printed}));
}
