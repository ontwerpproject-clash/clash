module Pretty (prettyShow) where

import Text.PrettyPrint.HughesPJClass
import Flatten

instance Pretty HsFunction where
  pPrint (HsFunction name args res) =
    text name <> char ' ' <> parens (hsep $ punctuate comma args') <> text " -> " <> res'
    where
      args' = map pPrint args
      res'  = pPrint res

instance Pretty x => Pretty (HsValueMap x) where
  pPrint (Tuple maps) = parens (hsep $ punctuate comma (map pPrint maps))
  pPrint (Single s)   = pPrint s

instance Pretty HsValueUse where
  pPrint Port            = char 'P'
  pPrint (State n)       = char 'C' <> int n
  pPrint (HighOrder _ _) = text "Higher Order"

instance Pretty FlatFunction where
  pPrint (FlatFunction args res apps conds) =
    (text "Args: ") $$ nest 10 (pPrint args)
    $+$ (text "Result: ") $$ nest 10 (pPrint res)
    $+$ (text "Apps: ") $$ nest 10 (vcat (map pPrint apps))
    $+$ (text "Conds: ") $$ nest 10 (pPrint conds)

instance Pretty FApp where
  pPrint (FApp func args res) =
    pPrint func <> text " : " <> pPrint args <> text " -> " <> pPrint res

instance Pretty SignalDef where
  pPrint (SignalDef id) = pPrint id

instance Pretty SignalUse where
  pPrint (SignalUse id) = pPrint id

instance Pretty CondDef where
  pPrint _ = text "TODO"
