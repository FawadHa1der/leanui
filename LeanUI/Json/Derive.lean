module
public import Lean.Elab.Deriving.Basic
public import Lean.Elab.Deriving.Util
public import LeanUI.Json
/-!
# `deriving ToJson, FromJson` for LeanUI's JSON (compile time only)

```
module
public import LeanUI.Json
meta import LeanUI.Json.Derive      -- the handler runs in the compiler, never in the app

structure User where
  name : String
  age : Nat
  email? : Option String            -- `?`: left out of the object when `none`
  deriving LeanUI.ToJson, LeanUI.FromJson
```

This module imports the Lean compiler, so an app must reach it only through `meta import`:
the derived instances are ordinary definitions in the app's own module that call `LeanUI.Json`,
and the handler itself is not linked (zero runtime cost).

The encoding is `Lean.Json`'s:
* a structure is an object of its fields; a field named `x?` (of an `Option` type) is written
  under the key `"x"` and left out when it is `none`; a missing field decodes like `null`, so
  `Option` fields may be omitted;
* a constructor without fields is its name (`"home"`); one with named fields is
  `{"ctor": {"field": ...}}`; one unnamed field is `{"ctor": value}`; several unnamed fields
  are `{"ctor": [...]}`.

Recursive, nested and mutual types are supported (the generated functions are `partial`).
Decoding errors carry the path (`.posts[2].author.name: expected a string, got 3`).
-/
public section
namespace LeanUI.JsonDerive
open Lean Elab Command Term Meta Deriving

/-- The JSON key of a field and whether it is optional (`x?`). -/
def fieldKey (n : Name) : Bool × String :=
  let s := n.eraseMacroScopes.toString (escape := false)
  if s.endsWith "?" then (true, (s.dropEnd 1).toString) else (false, s)

/-- A constructor's fields: a fresh variable each, plus the user-facing names when every field
has one (`| user (id : Nat)`), `none` for anonymous fields (`| pair : Nat → Nat → T`). -/
def ctorFields (indVal : InductiveVal) (ctorInfo : ConstructorVal) : TermElabM (Array Ident × Option (Array Name)) :=
  forallTelescopeReducing ctorInfo.type fun xs _ => do
    let mut vars := #[]
    let mut names := #[]
    for i in [:ctorInfo.numFields] do
      let decl ← xs[indVal.numParams + i]!.fvarId!.getDecl
      if !decl.userName.hasMacroScopes then names := names.push decl.userName
      vars := vars.push (mkIdent (← mkFreshUserName `a))
    return (vars, if names.size == vars.size then some names else none)

/-! ## ToJson -/

def toJsonStruct (header : Header) (indName : Name) : TermElabM Term := do
  let fields := getStructureFieldsFlattened (← getEnv) indName (includeSubobjectFields := false)
  let target := mkIdent header.targetNames[0]!
  let parts ← fields.mapM fun field => do
    let (opt, key) := fieldKey field
    if opt then ``(LeanUI.Json.opt $(quote key) (Option.map LeanUI.ToJson.toJson ($target).$(mkIdent field):ident))
    else ``([($(quote key), LeanUI.ToJson.toJson ($target).$(mkIdent field):ident)])
  ``(LeanUI.Json.mkObj (List.flatten [$parts,*]))

def toJsonInduct (header : Header) (indVal : InductiveVal) : TermElabM Term := do
  let discrs ← mkDiscrs header indVal
  let mut alts : Array (TSyntax ``Parser.Term.matchAlt) := #[]
  for ctorName in indVal.ctors do
    let ctorInfo ← getConstInfoCtor ctorName
    let (vars, names?) ← ctorFields indVal ctorInfo
    let mut patterns := #[]
    for _ in [:indVal.numIndices] do patterns := patterns.push (← `(_))
    let mut args : Array Term := #[]
    for _ in [:indVal.numParams] do args := args.push (← `(_))
    args := args ++ vars.map fun v => (⟨v.raw⟩ : Term)
    patterns := patterns.push (← `(@$(mkIdent ctorName):ident $args:term*))
    let tag := quote (ctorName.eraseMacroScopes.getString!)
    let rhs ← match vars.size, names? with
      | 0, _ => ``(LeanUI.Json.str $tag)
      | _, some names =>
        let parts ← (vars.zip names).mapM fun (v, n) => do
          let (opt, key) := fieldKey n
          if opt then ``(LeanUI.Json.opt $(quote key) (Option.map LeanUI.ToJson.toJson $v))
          else ``([($(quote key), LeanUI.ToJson.toJson $v)])
        ``(LeanUI.Json.mkObj [($tag, LeanUI.Json.mkObj (List.flatten [$parts,*]))])
      | 1, none => ``(LeanUI.Json.mkObj [($tag, LeanUI.ToJson.toJson $(vars[0]!))])
      | _, none =>
        let xs ← vars.mapM fun v => ``(LeanUI.ToJson.toJson $v)
        ``(LeanUI.Json.mkObj [($tag, LeanUI.Json.arr #[$xs,*])])
    alts := alts.push (← `(Parser.Term.matchAltExpr| | $[$patterns:term],* => $rhs))
  `(match $[$discrs],* with $alts:matchAlt*)

def mkToJsonCmds (declName : Name) : TermElabM (Array Command) := do
  let ctx ← mkContext ``LeanUI.ToJson "toJson" declName
  let mut defs := #[]
  for i in [:ctx.typeInfos.size] do
    let indVal := ctx.typeInfos[i]!
    let header ← mkHeader ``LeanUI.ToJson 1 indVal
    let body ←
      if isStructure (← getEnv) indVal.name then toJsonStruct header indVal.name
      else toJsonInduct header indVal
    let name := mkIdent ctx.auxFunNames[i]!
    if ctx.usePartial || indVal.isRec then
      let body ← mkLet (← mkLocalInstanceLetDecls ctx ``LeanUI.ToJson header.argNames) body
      defs := defs.push (← `(partial def $name:ident $header.binders:bracketedBinder* : LeanUI.Json := $body:term))
    else
      defs := defs.push (← `(def $name:ident $header.binders:bracketedBinder* : LeanUI.Json := $body:term))
  return #[← `(mutual $defs:command* end)] ++ (← mkInstanceCmds ctx ``LeanUI.ToJson #[declName])

/-! ## FromJson -/

/-- `let v ← decode-field; ...` for named fields read from object `obj`. -/
def readNamed (obj : Term) (vars : Array Ident) (names : Array Name) : TermElabM (Array (TSyntax `doElem)) :=
  (vars.zip names).mapM fun (v, n) => do
    let key := quote (fieldKey n).2
    `(doElem| let $v:ident ← LeanUI.Json.getObjValAs? $obj _ $key)

/-- A structure: required fields first, then the fields that have a default value, which keep
their default when the key is missing. -/
def fromJsonStruct (indName : Name) (type : Term) (json : Ident) : TermElabM Term := do
  let env ← getEnv
  let fields := getStructureFieldsFlattened env indName (includeSubobjectFields := false)
  let (withDefault, required) := fields.partition fun f => (getEffectiveDefaultFnForField? env indName f).isSome
  let reqVars := required.map mkIdent
  let reads ← readNamed json reqVars required
  let r := mkIdent `r
  let mut overrides : Array (TSyntax `doElem) := #[]
  for f in withDefault do
    let v := mkIdent (← mkFreshUserName `o)
    let key := quote (fieldKey f).2
    overrides := overrides.push (← `(doElem| let $v:ident ← LeanUI.Json.getObjValAsOpt? $json _ $key))
    overrides := overrides.push (← `(doElem| let $r:ident := match $v:ident with
      | some x => { $r:ident with $(mkIdent f):ident := x }
      | none => $r:ident))
  `(do $[$reads:doElem]*
       let $r:ident : $type := { $[$reqVars:ident := $(id reqVars)],* }
       $[$overrides:doElem]*
       return $r:ident)

def fromJsonInduct (indVal : InductiveVal) (json : Ident) : TermElabM Term := do
  let tagVar := mkIdent `tag
  let payload := mkIdent `payload
  let mut alts : Array (TSyntax ``Parser.Term.matchAlt) := #[]
  for ctorName in indVal.ctors do
    let ctorInfo ← getConstInfoCtor ctorName
    let (vars, names?) ← ctorFields indVal ctorInfo
    let tagStr := ctorName.eraseMacroScopes.getString!
    let ctor := mkIdent ctorName
    let rhs ← match vars.size, names? with
      | 0, _ => `(pure $ctor:ident)
      | _, some names =>
        let reads ← readNamed payload vars names
        `(do $[$reads:doElem]*
             return $ctor:ident $vars*)
      | 1, none =>
        let v := vars[0]!
        `(do let $v:ident ← LeanUI.FromJson.fromJson? $payload
             return $ctor:ident $v)
      | n, none =>
        let xs := mkIdent `xs
        let reads ← vars.mapIdxM fun i v =>
          `(doElem| let $v:ident ← LeanUI.Json.withPath $(quote s!"[{i}]") (LeanUI.FromJson.fromJson? ($xs)[$(quote i)]!))
        `(do let $xs:ident ← LeanUI.Json.getArrN? $payload $(quote n)
             $[$reads:doElem]*
             return $ctor:ident $vars*)
    let rhs ← `(LeanUI.Json.withPath $(quote (LeanUI.Json.fieldStep tagStr)) $rhs)
    alts := alts.push (← `(Parser.Term.matchAltExpr| | $(quote tagStr):str => $rhs))
  let names := indVal.ctors.map fun c => c.eraseMacroScopes.getString!
  let unknown ← `(Parser.Term.matchAltExpr| | _ =>
      throw ("unknown constructor " ++ LeanUI.Json.escape $tagVar ++ ", expected one of " ++ $(quote (", ".intercalate names))))
  alts := alts.push unknown
  -- a term-level `match` (a `match` directly inside `do` would expect `do` alternatives)
  `(LeanUI.Json.getTag? $json >>= fun ($tagVar, $payload) => match $tagVar:ident with $alts:matchAlt*)

def mkFromJsonCmds (declName : Name) : TermElabM (Array Command) := do
  let ctx ← mkContext ``LeanUI.FromJson "fromJson" declName
  let mut defs := #[]
  for i in [:ctx.typeInfos.size] do
    let indVal := ctx.typeInfos[i]!
    let header ← mkHeader ``LeanUI.FromJson 0 indVal
    let json := mkIdent `json
    let binders := header.binders.push (← `(Lean.Parser.Term.bracketedBinderF| ($json : LeanUI.Json)))
    let body ←
      if isStructure (← getEnv) indVal.name then fromJsonStruct indVal.name (← mkInductiveApp indVal header.argNames) json
      else fromJsonInduct indVal json
    let name := mkIdent ctx.auxFunNames[i]!
    let ret ← `(Except String $(← mkInductiveApp indVal header.argNames))
    if ctx.usePartial || indVal.isRec then
      let body ← mkLet (← mkLocalInstanceLetDecls ctx ``LeanUI.FromJson header.argNames) body
      defs := defs.push (← `(partial def $name:ident $binders:bracketedBinder* : $ret := $body:term))
    else
      defs := defs.push (← `(def $name:ident $binders:bracketedBinder* : $ret := $body:term))
  return #[← `(mutual $defs:command* end)] ++ (← mkInstanceCmds ctx ``LeanUI.FromJson #[declName])

/-! ## Registration -/

def handler (mk : Name → TermElabM (Array Command)) (declNames : Array Name) : CommandElabM Bool := do
  if declNames.isEmpty || !(← declNames.allM isInductive) then return false
  for d in declNames do
    let cmds ← liftTermElabM (mk d)
    cmds.forM elabCommand
  return true

initialize
  registerDerivingHandler ``LeanUI.ToJson (handler mkToJsonCmds)
  registerDerivingHandler ``LeanUI.FromJson (handler mkFromJsonCmds)

end LeanUI.JsonDerive
