module
public import Vir.Resources.Assets
/-- The Life app's package and the interpreter that runs it (`lake exe publish` writes them out). -/
public def LeanUIVir.LifeResources.resources : Vir.Resources.ResourceSet :=
  include_vir_assets (modules := #[LeanUIVir.LifeApp])
