--
-- Functions to generate VHDL from FlatFunctions
--
module VHDL where

import Data.Traversable
import qualified Data.Foldable as Foldable
import qualified Maybe

import qualified Type
import qualified Name
import qualified TyCon
import Outputable ( showSDoc, ppr )

import qualified ForSyDe.Backend.VHDL.AST as AST

import VHDLTypes
import FlattenTypes
import TranslatorTypes

-- | Create an entity for a given function
createEntity ::
  HsFunction        -- | The function signature
  -> FuncData       -- | The function data collected so far
  -> FuncData       -- | The modified function data

createEntity hsfunc fdata = 
  let func = flatFunc fdata in
  case func of
    -- Skip (builtin) functions without a FlatFunction
    Nothing -> fdata
    -- Create an entity for all other functions
    Just flatfunc ->
      
      let 
        s       = sigs flatfunc
        a       = args flatfunc
        r       = res  flatfunc
        args'   = map (fmap (mkMap s)) a
        res'    = fmap (mkMap s) r
        ent_decl' = createEntityAST hsfunc args' res'
        entity' = Entity args' res' (Just ent_decl')
      in
        fdata { entity = Just entity' }
  where
    mkMap :: Eq id => [(id, SignalInfo)] -> id -> (AST.VHDLId, AST.TypeMark)
    mkMap sigmap id =
      (mkVHDLId nm, vhdl_ty ty)
      where
        info = Maybe.fromMaybe
          (error $ "Signal not found in the name map? This should not happen!")
          (lookup id sigmap)
        nm = Maybe.fromMaybe
          (error $ "Signal not named? This should not happen!")
          (sigName info)
        ty = sigTy info

-- | Create the VHDL AST for an entity
createEntityAST ::
  HsFunction            -- | The signature of the function we're working with
  -> [VHDLSignalMap]    -- | The entity's arguments
  -> VHDLSignalMap      -- | The entity's result
  -> AST.EntityDec      -- | The entity with the ent_decl filled in as well

createEntityAST hsfunc args res =
  AST.EntityDec vhdl_id ports
  where
    vhdl_id = mkEntityId hsfunc
    ports = concatMap (mapToPorts AST.In) args
            ++ mapToPorts AST.Out res
    mapToPorts :: AST.Mode -> VHDLSignalMap -> [AST.IfaceSigDec] 
    mapToPorts mode m =
      map (mkIfaceSigDec mode) (Foldable.toList m)

-- | Create a port declaration
mkIfaceSigDec ::
  AST.Mode                         -- | The mode for the port (In / Out)
  -> (AST.VHDLId, AST.TypeMark)    -- | The id and type for the port
  -> AST.IfaceSigDec               -- | The resulting port declaration

mkIfaceSigDec mode (id, ty) = AST.IfaceSigDec id mode ty

-- | Generate a VHDL entity name for the given hsfunc
mkEntityId hsfunc =
  -- TODO: This doesn't work for functions with multiple signatures!
  mkVHDLId $ hsFuncName hsfunc

-- | Create an architecture for a given function
createArchitecture ::
  HsFunction        -- | The function signature
  -> FuncData       -- | The function data collected so far
  -> FuncData       -- | The modified function data

createArchitecture hsfunc fdata = 
  let func = flatFunc fdata in
  case func of
    -- Skip (builtin) functions without a FlatFunction
    Nothing -> fdata
    -- Create an architecture for all other functions
    Just flatfunc ->
      let 
        s        = sigs flatfunc
        a        = args flatfunc
        r        = res  flatfunc
        entity_id = Maybe.fromMaybe
                      (error $ "Building architecture without an entity? This should not happen!")
                      (getEntityId fdata)
        sig_decs = [mkSigDec info | (id, info) <- s, (all (id `Foldable.notElem`) (r:a)) ]
        arch     = AST.ArchBody (mkVHDLId "structural") (AST.NSimple entity_id) (map AST.BDISD sig_decs) []
      in
        fdata { funcArch = Just arch }

mkSigDec :: SignalInfo -> AST.SigDec
mkSigDec info =
    AST.SigDec (mkVHDLId name) (vhdl_ty ty) Nothing
  where
    name = Maybe.fromMaybe
      (error $ "Unnamed signal? This should not happen!")
      (sigName info)
    ty = sigTy info
    
-- | Extracts the generated entity id from the given funcdata
getEntityId :: FuncData -> Maybe AST.VHDLId
getEntityId fdata =
  case entity fdata of
    Nothing -> Nothing
    Just e  -> case ent_decl e of
      Nothing -> Nothing
      Just (AST.EntityDec id _) -> Just id

getLibraryUnits ::
  (HsFunction, FuncData)      -- | A function from the session
  -> [AST.LibraryUnit]        -- | The library units it generates

getLibraryUnits (hsfunc, fdata) =
  case entity fdata of 
    Nothing -> []
    Just ent -> case ent_decl ent of
      Nothing -> []
      Just decl -> [AST.LUEntity decl]
  ++
  case funcArch fdata of
    Nothing -> []
    Just arch -> [AST.LUArch arch]

-- | The VHDL Bit type
bit_ty :: AST.TypeMark
bit_ty = AST.unsafeVHDLBasicId "Bit"

-- Translate a Haskell type to a VHDL type
vhdl_ty :: Type.Type -> AST.TypeMark
vhdl_ty ty = Maybe.fromMaybe
  (error $ "Unsupported Haskell type: " ++ (showSDoc $ ppr ty))
  (vhdl_ty_maybe ty)

-- Translate a Haskell type to a VHDL type
vhdl_ty_maybe :: Type.Type -> Maybe AST.TypeMark
vhdl_ty_maybe ty =
  case Type.splitTyConApp_maybe ty of
    Just (tycon, args) ->
      let name = TyCon.tyConName tycon in
        -- TODO: Do something more robust than string matching
        case Name.getOccString name of
          "Bit"      -> Just bit_ty
          otherwise  -> Nothing
    otherwise -> Nothing

-- Shortcut
mkVHDLId :: String -> AST.VHDLId
mkVHDLId = AST.unsafeVHDLBasicId
