module
public import Vir.Resources.Assets
public def LeanUIVir.TestResources.resources : Vir.Resources.ResourceSet :=
  include_vir_assets (modules := #[LeanUIVir.TestApp])
