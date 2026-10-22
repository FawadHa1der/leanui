//! A definition's value as JSON, when it is plain data: what the verify page shows of a receipt
//! (its problem and roster) comes from the very terms the kernel checked. (Decoding the export
//! file apart, in JavaScript, could read a line differently: nanoda takes the first of two equal
//! keys in a line, `JSON.parse` the last.)

use nanoda_lib::env::Declar;
use nanoda_lib::expr::Expr;
use nanoda_lib::util::{ExportFile, ExprPtr, NamePtr, TcCtx};
use serde_json::{json, Value};
use std::collections::HashMap;

/// The value of the definition `name` as JSON, or why it is not plain data. Plain data is a string
/// or Nat literal, a numeral as Lean writes them (`@OfNat.ofNat Nat n (instOfNatNat n)`), and
/// constructors applied to plain data: `Bool.true` and `Bool.false` are booleans, `Option.none`
/// is null and `Option.some x` is x, a list is an array, and any other constructor is
/// `{"Name.mk": [fields…]}` (its parameters, such as a list's type, left out). Lean writes a long
/// list literal with `let`s (a tree of them, so that no term gets too deep), so plain data may
/// also be `let x := v; e` with v and e plain data, x standing for v in e.
pub fn definition<'p>(export: &ExportFile<'p>, ctx: &TcCtx<'_, 'p>, name: &str, names: &[String]) -> Result<Value, String> {
    let Some(i) = names.iter().position(|n| n == name) else { return Err(format!("there is no {name}")) };
    let Declar::Definition { val, .. } = export.declars.get_index(i).unwrap().1 else {
        return Err(format!("{name} is not a definition"));
    };
    let ctors = export.declars.values().filter_map(|d| match d {
        Declar::Constructor(c) => Some((c.info.name, (usize::from(c.num_params), usize::from(c.num_fields)))),
        _ => None,
    });
    Data { ctx, ctors: ctors.collect(), env: Vec::new() }.value(*val)
}

struct Data<'x, 'c, 'p> {
    ctx: &'x TcCtx<'c, 'p>,
    /// the constructors' numbers of parameters and fields
    ctors: HashMap<NamePtr<'c>, (usize, usize)>,
    /// the values of the `let`s around the expression being decoded, the innermost last
    env: Vec<Value>,
}

impl<'x, 'c, 'p> Data<'x, 'c, 'p> {
    /// The name of the constant `e`, if it is one
    fn name(&self, e: ExprPtr<'c>) -> Option<String> {
        match self.ctx.read_expr(e) {
            Expr::Const { name, .. } => Some(format!("{:?}", self.ctx.debug_print(name))),
            _ => None,
        }
    }

    /// `f a₁ … aₙ` as `(f, [a₁, …, aₙ])`
    fn spine(&self, mut e: ExprPtr<'c>) -> (ExprPtr<'c>, Vec<ExprPtr<'c>>) {
        let mut args = Vec::new();
        while let Expr::App { fun, arg, .. } = self.ctx.read_expr(e) { args.push(arg); e = fun; }
        args.reverse();
        (e, args)
    }

    /// `e` as a number, if it is a Nat literal
    fn nat(&self, e: ExprPtr<'c>) -> Option<Result<Value, String>> {
        let Expr::NatLit { ptr, .. } = self.ctx.read_expr(e) else { return None };
        let n = self.ctx.read_bignum(ptr)?.to_string();
        // exact in JavaScript up to 2⁵³
        Some(n.parse::<u64>().ok().filter(|n| *n < 1 << 53).map(Value::from).ok_or(format!("the number {n} is too large")))
    }

    fn value(&mut self, e: ExprPtr<'c>) -> Result<Value, String> {
        let outside = self.env.len();
        let v = self.walk(e);
        self.env.truncate(outside);
        v
    }

    /// `value`, the `let`s it enters left in `env`. A list is walked along, not recursed into: it
    /// may be long.
    fn walk(&mut self, mut e: ExprPtr<'c>) -> Result<Value, String> {
        let mut list = Vec::new();
        loop {
            match self.ctx.read_expr(e) {
                Expr::Let { val, body, .. } => {
                    let v = self.value(val)?;
                    self.env.push(v);
                    e = body;
                    continue;
                }
                Expr::Var { dbj_idx, .. } => {
                    let v = self.env.iter().rev().nth(dbj_idx.into()).cloned().ok_or("a loose bound variable")?;
                    return match v {
                        _ if list.is_empty() => Ok(v),
                        Value::Array(rest) => { list.extend(rest); Ok(Value::Array(list)) }
                        _ => Err("a list that does not end with a list".into()),
                    };
                }
                _ => {}
            }
            let (f, args) = self.spine(e);
            match (self.name(f).as_deref(), &args[..]) {
                (Some("List.cons"), [_, x, xs]) => { let x = self.value(*x)?; list.push(x); e = *xs; }
                (Some("List.nil"), [_]) => return Ok(Value::Array(list)),
                _ if !list.is_empty() => return Err("a list that does not end with List.nil".into()),
                _ => return self.item(f, &args),
            }
        }
    }

    fn item(&mut self, f: ExprPtr<'c>, args: &[ExprPtr<'c>]) -> Result<Value, String> {
        let ptr = match self.ctx.read_expr(f) {
            Expr::StringLit { ptr, .. } if args.is_empty() => return Ok(self.ctx.read_string(ptr).as_ref().into()),
            Expr::NatLit { .. } if args.is_empty() => return self.nat(f).unwrap_or(Err("a Nat literal".into())),
            Expr::Const { name, .. } => name,
            _ => return Err("an expression that is not data".into()),
        };
        let name = format!("{:?}", self.ctx.debug_print(ptr));
        match (name.as_str(), args) {
            ("Bool.true", []) => Ok(true.into()),
            ("Bool.false", []) => Ok(false.into()),
            ("Option.none", [_]) => Ok(Value::Null),
            ("Option.some", [_, x]) => self.value(*x),
            // the numeral n, if its instance is Nat's own (another could make it mean anything). The
            // export shares equal subterms, so the same literal is the same node.
            ("OfNat.ofNat", [ty, n, inst]) if self.name(*ty).as_deref() == Some("Nat") => {
                let (i, i_args) = self.spine(*inst);
                match (self.name(i).as_deref(), &i_args[..], self.nat(*n)) {
                    (Some("instOfNatNat"), [m], Some(v)) if m == n => v,
                    _ => Err("a numeral whose instance is not instOfNatNat".into()),
                }
            }
            _ => match self.ctors.get(&ptr) {
                Some((params, fields)) if args.len() == params + fields => {
                    let fields = args[*params..].iter().map(|a| self.value(*a)).collect::<Result<Vec<_>, _>>()?;
                    Ok(json!({ name: fields }))
                }
                _ => Err(format!("{name}, which is not a constructor applied to its fields")),
            },
        }
    }
}
