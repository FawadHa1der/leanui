//! Fingerprints of declarations, to tell the published ones from look-alikes. A fingerprint is a
//! SHA-256 of what the kernel checks: the declaration's kind, universe parameters and type, and
//! its value (a definition's or a theorem's), its constructors (an inductive type's) or what ties
//! it to its type (a constructor's, a recursor's). Expressions are hashed by structure and
//! constants by name, so a fingerprint does not depend on the export's numbering: a declaration
//! has the same one in every export file. Binder names and kinds do not count (nor whether a `let`
//! is marked non-dependent): the kernel ignores them, and they vary between exports, which share
//! subterms equal up to them, so a declaration can come out with another one's binder names.
//!
//! The verify page compares a receipt's fingerprints with the reference's, an export of the
//! published source (roster/verify/reference.mjs): a receipt cannot redefine what it proves.

use nanoda_lib::env::{Declar, ReducibilityHint};
use nanoda_lib::expr::Expr;
use nanoda_lib::level::Level;
use nanoda_lib::util::{ExprPtr, LevelPtr, NamePtr, TcCtx};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

type Hash = [u8; 32];

/// The bytes of one hash: a tag, then numbers as they are and strings with their length first, so
/// that no two different inputs give the same bytes.
struct Hasher(Sha256);

impl Hasher {
    fn new(tag: &str) -> Self { Hasher(Sha256::new()).str(tag) }
    fn num(mut self, n: u64) -> Self { self.0.update(n.to_le_bytes()); self }
    fn str(self, s: &str) -> Self { let mut h = self.num(s.len() as u64); h.0.update(s.as_bytes()); h }
    fn hash(mut self, h: &Hash) -> Self { self.0.update(h); self }
    fn done(self) -> Hash { self.0.finalize().into() }
}

pub struct Fingerprints<'c, 't, 'p> {
    ctx: &'c TcCtx<'t, 'p>,
    /// An export file is a DAG (subterms are shared): each node is hashed once.
    exprs: HashMap<ExprPtr<'t>, Hash>,
    levels: HashMap<LevelPtr<'t>, Hash>,
    /// Each inductive type's constructors, in order: nanoda keeps to itself the list an inductive
    /// declaration gives, and checks it against the constructors declared.
    ctors: HashMap<NamePtr<'t>, Vec<(u16, NamePtr<'t>)>>,
}

impl<'c, 't, 'p> Fingerprints<'c, 't, 'p> {
    pub fn new(ctx: &'c TcCtx<'t, 'p>, declars: impl Iterator<Item = &'c Declar<'t>>) -> Self where 't: 'c {
        let mut ctors: HashMap<_, Vec<_>> = HashMap::new();
        for d in declars {
            if let Declar::Constructor(c) = d {
                ctors.entry(c.inductive_name).or_default().push((c.ctor_idx, c.info.name));
            }
        }
        for cs in ctors.values_mut() { cs.sort_by_key(|(i, _)| *i); }
        Fingerprints { ctx, exprs: HashMap::new(), levels: HashMap::new(), ctors }
    }

    /// A name as main.rs prints it, where no two declarations print the same.
    fn name(&self, n: NamePtr<'t>) -> String { format!("{:?}", self.ctx.debug_print(n)) }

    fn level(&mut self, l: LevelPtr<'t>) -> Hash {
        if let Some(h) = self.levels.get(&l) { return *h; }
        let h = match self.ctx.read_level(l) {
            Level::Zero => Hasher::new("zero").done(),
            Level::Succ(a, _) => Hasher::new("succ").hash(&self.level(a)).done(),
            Level::Max(a, b, _) => Hasher::new("max").hash(&self.level(a)).hash(&self.level(b)).done(),
            Level::IMax(a, b, _) => Hasher::new("imax").hash(&self.level(a)).hash(&self.level(b)).done(),
            Level::Param(n, _) => Hasher::new("param").str(&self.name(n)).done(),
        };
        self.levels.insert(l, h);
        h
    }

    fn levels(&mut self, mut h: Hasher, ls: &[LevelPtr<'t>]) -> Hasher {
        h = h.num(ls.len() as u64);
        for l in ls { h = h.hash(&self.level(*l)); }
        h
    }

    fn expr(&mut self, e: ExprPtr<'t>) -> Hash {
        if let Some(h) = self.exprs.get(&e) { return *h; }
        let h = match self.ctx.read_expr(e) {
            Expr::Var { dbj_idx, .. } => Hasher::new("var").num(dbj_idx.into()).done(),
            Expr::Sort { level, .. } => Hasher::new("sort").hash(&self.level(level)).done(),
            Expr::Const { name, levels, .. } => {
                let h = Hasher::new("const").str(&self.name(name));
                self.levels(h, &self.ctx.read_levels(levels)).done()
            }
            Expr::App { fun, arg, .. } => Hasher::new("app").hash(&self.expr(fun)).hash(&self.expr(arg)).done(),
            Expr::Pi { binder_type, body, .. } =>
                Hasher::new("pi").hash(&self.expr(binder_type)).hash(&self.expr(body)).done(),
            Expr::Lambda { binder_type, body, .. } =>
                Hasher::new("lambda").hash(&self.expr(binder_type)).hash(&self.expr(body)).done(),
            Expr::Let { binder_type, val, body, .. } => Hasher::new("let")
                .hash(&self.expr(binder_type)).hash(&self.expr(val)).hash(&self.expr(body)).done(),
            Expr::NatLit { ptr, .. } => {
                let n = self.ctx.read_bignum(ptr).expect("Nat literals need the Nat extension");
                Hasher::new("nat").str(&n.to_string()).done()
            }
            Expr::StringLit { ptr, .. } => Hasher::new("string").str(self.ctx.read_string(ptr)).done(),
            Expr::Proj { ty_name, idx, structure, .. } =>
                Hasher::new("proj").str(&self.name(ty_name)).num(idx as u64).hash(&self.expr(structure)).done(),
            // free variables exist only while checking, never in an export file
            Expr::Local { .. } => unreachable!("a free variable in an export file"),
        };
        self.exprs.insert(e, h);
        h
    }

    /// The fingerprint of `d`, in hex.
    pub fn declar(&mut self, d: &Declar<'t>) -> String {
        let kind = match d {
            Declar::Axiom { .. } => "axiom",
            Declar::Quot { .. } => "quot",
            Declar::Theorem { .. } => "theorem",
            Declar::Definition { .. } => "definition",
            Declar::Opaque { .. } => "opaque",
            Declar::Inductive(_) => "inductive",
            Declar::Constructor(_) => "constructor",
            Declar::Recursor(_) => "recursor",
        };
        let info = d.info();
        let mut h = self.levels(Hasher::new(kind), &self.ctx.read_levels(info.uparams));
        h = h.hash(&self.expr(info.ty));
        h = match d {
            Declar::Axiom { .. } | Declar::Quot { .. } => h,
            Declar::Theorem { val, .. } | Declar::Opaque { val, .. } => h.hash(&self.expr(*val)),
            Declar::Definition { val, hint, .. } => {
                let h = h.hash(&self.expr(*val));
                match hint {
                    ReducibilityHint::Opaque => h.str("opaque"),
                    ReducibilityHint::Abbrev => h.str("abbrev"),
                    ReducibilityHint::Regular(n) => h.str("regular").num((*n).into()),
                }
            }
            Declar::Inductive(_) => {
                let cs = self.ctors.get(&info.name).cloned().unwrap_or_default();
                h = h.num(cs.len() as u64);
                for (_, c) in cs { h = h.str(&self.name(c)); }
                h
            }
            Declar::Constructor(c) => h.str(&self.name(c.inductive_name)).num(c.ctor_idx.into())
                .num(c.num_params.into()).num(c.num_fields.into()),
            Declar::Recursor(r) => {
                h = h.num(r.all_inductives.len() as u64);
                for i in r.all_inductives.iter() { h = h.str(&self.name(*i)); }
                h = h.num(r.num_params.into()).num(r.num_indices.into()).num(r.num_motives.into())
                    .num(r.num_minors.into()).num(r.is_k.into()).num(r.rec_rules.len() as u64);
                for rule in r.rec_rules.iter() {
                    h = h.str(&self.name(rule.ctor_name)).num(rule.ctor_telescope_size_wo_params.into())
                        .hash(&self.expr(rule.val));
                }
                h
            }
        };
        h.done().iter().map(|b| format!("{b:02x}")).collect()
    }
}
