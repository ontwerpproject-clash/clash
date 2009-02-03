module Main(main) where
import GHC
import CoreSyn
import qualified CoreUtils
import qualified Var
import qualified Type
import qualified TyCon
import qualified DataCon
import qualified Maybe
import qualified Module
import qualified Control.Monad.State as State
import Name
import Data.Generics
import NameEnv ( lookupNameEnv )
import HscTypes ( cm_binds, cm_types )
import MonadUtils ( liftIO )
import Outputable ( showSDoc, ppr )
import GHC.Paths ( libdir )
import DynFlags ( defaultDynFlags )
import List ( find )
import qualified List
import qualified Monad

-- The following modules come from the ForSyDe project. They are really
-- internal modules, so ForSyDe.cabal has to be modified prior to installing
-- ForSyDe to get access to these modules.
import qualified ForSyDe.Backend.VHDL.AST as AST
import qualified ForSyDe.Backend.VHDL.Ppr
import qualified ForSyDe.Backend.VHDL.FileIO
import qualified ForSyDe.Backend.Ppr
-- This is needed for rendering the pretty printed VHDL
import Text.PrettyPrint.HughesPJ (render)

main = 
    do
      defaultErrorHandler defaultDynFlags $ do
        runGhc (Just libdir) $ do
          dflags <- getSessionDynFlags
          setSessionDynFlags dflags
          --target <- guessTarget "adder.hs" Nothing
          --liftIO (print (showSDoc (ppr (target))))
          --liftIO $ printTarget target
          --setTargets [target]
          --load LoadAllTargets
          --core <- GHC.compileToCoreSimplified "Adders.hs"
          core <- GHC.compileToCoreSimplified "Adders.hs"
          --liftIO $ printBinds (cm_binds core)
          let binds = Maybe.mapMaybe (findBind (cm_binds core)) ["dff"]
          liftIO $ printBinds binds
          -- Turn bind into VHDL
          let (vhdl, sess) = State.runState (mkVHDL binds) (VHDLSession 0 [])
          liftIO $ putStr $ render $ ForSyDe.Backend.Ppr.ppr vhdl
          liftIO $ ForSyDe.Backend.VHDL.FileIO.writeDesignFile vhdl "../vhdl/vhdl/output.vhdl"
          liftIO $ putStr $ "\n\nFinal session:\n" ++ show sess
          return ()
  where
    -- Turns the given bind into VHDL
    mkVHDL binds = do
      -- Add the builtin functions
      mapM (uncurry addFunc) builtin_funcs
      -- Create entities and architectures for them
      units <- mapM expandBind binds
      return $ AST.DesignFile 
        []
        (concat units)

printTarget (Target (TargetFile file (Just x)) obj Nothing) =
  print $ show file

printBinds [] = putStr "done\n\n"
printBinds (b:bs) = do
  printBind b
  putStr "\n"
  printBinds bs

printBind (NonRec b expr) = do
  putStr "NonRec: "
  printBind' (b, expr)

printBind (Rec binds) = do
  putStr "Rec: \n"  
  foldl1 (>>) (map printBind' binds)

printBind' (b, expr) = do
  putStr $ getOccString b
  putStr $ showSDoc $ ppr expr
  putStr "\n"

findBind :: [CoreBind] -> String -> Maybe CoreBind
findBind binds lookfor =
  -- This ignores Recs and compares the name of the bind with lookfor,
  -- disregarding any namespaces in OccName and extra attributes in Name and
  -- Var.
  find (\b -> case b of 
    Rec l -> False
    NonRec var _ -> lookfor == (occNameString $ nameOccName $ getName var)
  ) binds

getPortMapEntry ::
  SignalNameMap  -- The port name to bind to
  -> SignalNameMap 
                            -- The signal or port to bind to it
  -> AST.AssocElem          -- The resulting port map entry
  
-- Accepts a port name and an argument to map to it.
-- Returns the appropriate line for in the port map
getPortMapEntry (Single (portname, _)) (Single (signame, _)) = 
  (Just portname) AST.:=>: (AST.ADName (AST.NSimple signame))
expandExpr ::
  [(CoreBndr, SignalNameMap)] 
                                         -- A list of bindings in effect
  -> CoreExpr                            -- The expression to expand
  -> VHDLState (
       [AST.SigDec],                     -- Needed signal declarations
       [AST.ConcSm],                     -- Needed component instantations and
                                         -- signal assignments.
       [SignalNameMap],       -- The signal names corresponding to
                                         -- the expression's arguments
       SignalNameMap)         -- The signal names corresponding to
                                         -- the expression's result.
expandExpr binds lam@(Lam b expr) = do
  -- Generate a new signal to which we will expect this argument to be bound.
  signal_name <- uniqueName ("arg_" ++ getOccString b)
  -- Find the type of the binder
  let (arg_ty, _) = Type.splitFunTy (CoreUtils.exprType lam)
  -- Create signal names for the binder
  -- TODO: We assume arguments are ports here
  let arg_signal = getPortNameMapForTy signal_name arg_ty (useAsPort arg_ty)
  -- Create the corresponding signal declarations
  let signal_decls = mkSignalsFromMap arg_signal
  -- Add the binder to the list of binds
  let binds' = (b, arg_signal) : binds
  -- Expand the rest of the expression
  (signal_decls', statements', arg_signals', res_signal') <- expandExpr binds' expr
  -- Properly merge the results
  return (signal_decls ++ signal_decls',
          statements',
          arg_signal : arg_signals',
          res_signal')

expandExpr binds (Var id) =
  return ([], [], [], bind)
  where
    -- Lookup the id in our binds map
    bind = Maybe.fromMaybe
      (error $ "Argument " ++ getOccString id ++ "is unknown")
      (lookup id binds)

expandExpr binds l@(Let (NonRec b bexpr) expr) = do
  (signal_decls, statements, arg_signals, res_signals) <- expandExpr binds bexpr
  let binds' = (b, res_signals) : binds
  (signal_decls', statements', arg_signals', res_signals') <- expandExpr binds' expr
  return (
    signal_decls ++ signal_decls',
    statements ++ statements',
    arg_signals',
    res_signals')

expandExpr binds app@(App _ _) = do
  -- Is this a data constructor application?
  case CoreUtils.exprIsConApp_maybe app of
    -- Is this a tuple construction?
    Just (dc, args) -> if DataCon.isTupleCon dc 
      then
        expandBuildTupleExpr binds (dataConAppArgs dc args)
      else
        error "Data constructors other than tuples not supported"
    otherise ->
      -- Normal function application, should map to a component instantiation
      let ((Var f), args) = collectArgs app in
      expandApplicationExpr binds (CoreUtils.exprType app) f args

expandExpr binds expr@(Case (Var v) b _ alts) =
  case alts of
    [alt] -> expandSingleAltCaseExpr binds v b alt
    otherwise -> error $ "Multiple alternative case expression not supported: " ++ (showSDoc $ ppr expr)

expandExpr binds expr@(Case _ b _ _) =
  error $ "Case expression with non-variable scrutinee not supported: " ++ (showSDoc $ ppr expr)

expandExpr binds expr = 
  error $ "Unsupported expression: " ++ (showSDoc $ ppr $ expr)

-- Expands the construction of a tuple into VHDL
expandBuildTupleExpr ::
  [(CoreBndr, SignalNameMap)] 
                                         -- A list of bindings in effect
  -> [CoreExpr]                          -- A list of expressions to put in the tuple
  -> VHDLState ( [AST.SigDec], [AST.ConcSm], [SignalNameMap], SignalNameMap)
                                         -- See expandExpr
expandBuildTupleExpr binds args = do
  -- Split the tuple constructor arguments into types and actual values.
  -- Expand each of the values in the tuple
  (signals_declss, statementss, arg_signalss, res_signals) <-
    (Monad.liftM List.unzip4) $ mapM (expandExpr binds) args
  if any (not . null) arg_signalss
    then error "Putting high order functions in tuples not supported"
    else
      return (
        concat signals_declss,
        concat statementss,
        [],
        Tuple res_signals)

-- Expands the most simple case expression that scrutinizes a plain variable
-- and has a single alternative. This simple form currently allows only for
-- unpacking tuple variables.
expandSingleAltCaseExpr ::
  [(CoreBndr, SignalNameMap)] 
                            -- A list of bindings in effect
  -> Var.Var                -- The scrutinee
  -> CoreBndr               -- The binder to bind the scrutinee to
  -> CoreAlt                -- The single alternative
  -> VHDLState ( [AST.SigDec], [AST.ConcSm], [SignalNameMap], SignalNameMap)
                                         -- See expandExpr

expandSingleAltCaseExpr binds v b alt@(DataAlt datacon, bind_vars, expr) =
  if not (DataCon.isTupleCon datacon) 
    then
      error $ "Dataconstructors other than tuple constructors not supported in case pattern of alternative: " ++ (showSDoc $ ppr alt)
    else
      let
        -- Lookup the scrutinee (which must be a variable bound to a tuple) in
        -- the existing bindings list and get the portname map for each of
        -- it's elements.
        Tuple tuple_ports = Maybe.fromMaybe 
          (error $ "Case expression uses unknown scrutinee " ++ getOccString v)
          (lookup v binds)
        -- TODO include b in the binds list
        -- Merge our existing binds with the new binds.
        binds' = (zip bind_vars tuple_ports) ++ binds 
      in
        -- Expand the expression with the new binds list
        expandExpr binds' expr

expandSingleAltCaseExpr _ _ _ alt =
  error $ "Case patterns other than data constructors not supported in case alternative: " ++ (showSDoc $ ppr alt)
      

-- Expands the application of argument to a function into VHDL
expandApplicationExpr ::
  [(CoreBndr, SignalNameMap)] 
                                         -- A list of bindings in effect
  -> Type                                -- The result type of the function call
  -> Var.Var                             -- The function to call
  -> [CoreExpr]                          -- A list of argumetns to apply to the function
  -> VHDLState ( [AST.SigDec], [AST.ConcSm], [SignalNameMap], SignalNameMap)
                                         -- See expandExpr
expandApplicationExpr binds ty f args = do
  let name = getOccString f
  -- Generate a unique name for the application
  appname <- uniqueName ("app_" ++ name)
  -- Lookup the hwfunction to instantiate
  HWFunction vhdl_id inports outport <- getHWFunc (appToHsFunction f args ty)
  -- Expand each of the args, so each of them is reduced to output signals
  (arg_signal_decls, arg_statements, arg_res_signals) <- expandArgs binds args
  -- Bind each of the input ports to the expanded arguments
  let inmaps = concat $ zipWith createAssocElems inports arg_res_signals
  -- Create signal names for our result
  -- TODO: We assume the result is a port here
  let res_signal = getPortNameMapForTy (appname ++ "_out") ty (useAsPort ty)
  -- Create the corresponding signal declarations
  let signal_decls = mkSignalsFromMap res_signal
  -- Bind each of the output ports to our output signals
  let outmaps = mapOutputPorts outport res_signal
  -- Instantiate the component
  let component = AST.CSISm $ AST.CompInsSm
        (AST.unsafeVHDLBasicId appname)
        (AST.IUEntity (AST.NSimple vhdl_id))
        (AST.PMapAspect (inmaps ++ outmaps))
  -- Merge the generated declarations
  return (
    signal_decls ++ arg_signal_decls,
    component : arg_statements,
    [], -- We don't take any extra arguments; we don't support higher order functions yet
    res_signal)
  
-- Creates a list of AssocElems (port map lines) that maps the given signals
-- to the given ports.
createAssocElems ::
  SignalNameMap      -- The port names to bind to
  -> SignalNameMap   -- The signals to bind to it
  -> [AST.AssocElem]            -- The resulting port map lines
  
createAssocElems (Single (port_id, _)) (Single (signal_id, _)) = 
  [(Just port_id) AST.:=>: (AST.ADName (AST.NSimple signal_id))]

createAssocElems (Tuple ports) (Tuple signals) = 
  concat $ zipWith createAssocElems ports signals

-- Generate a signal declaration for a signal with the given name and the
-- given type and no value. Also returns the id of the signal.
mkSignal :: String -> AST.TypeMark -> (AST.VHDLId, AST.SigDec)
mkSignal name ty =
  (id, mkSignalFromId id ty)
  where 
    id = AST.unsafeVHDLBasicId name

mkSignalFromId :: AST.VHDLId -> AST.TypeMark -> AST.SigDec
mkSignalFromId id ty =
  AST.SigDec id ty Nothing

-- Generates signal declarations for all the signals in the given map
mkSignalsFromMap ::
  SignalNameMap 
  -> [AST.SigDec]

mkSignalsFromMap (Single (id, ty)) =
  [mkSignalFromId id ty]

mkSignalsFromMap (Tuple signals) =
  concat $ map mkSignalsFromMap signals

expandArgs :: 
  [(CoreBndr, SignalNameMap)] -- A list of bindings in effect
  -> [CoreExpr]                          -- The arguments to expand
  -> VHDLState ([AST.SigDec], [AST.ConcSm], [SignalNameMap])  
                                         -- The resulting signal declarations,
                                         -- component instantiations and a
                                         -- VHDLName for each of the
                                         -- expressions passed in.
expandArgs binds (e:exprs) = do
  -- Expand the first expression
  (signal_decls, statements, arg_signals, res_signal) <- expandExpr binds e
  if not (null arg_signals)
    then error $ "Passing functions as arguments not supported: " ++ (showSDoc $ ppr e)
    else do
      (signal_decls', statements', res_signals') <- expandArgs binds exprs
      return (
        signal_decls ++ signal_decls',
        statements ++ statements',
        res_signal : res_signals')

expandArgs _ [] = return ([], [], [])

-- Extract the arguments from a data constructor application (that is, the
-- normal args, leaving out the type args).
dataConAppArgs :: DataCon -> [CoreExpr] -> [CoreExpr]
dataConAppArgs dc args =
    drop tycount args
  where
    tycount = length $ DataCon.dataConAllTyVars dc

mapOutputPorts ::
  SignalNameMap      -- The output portnames of the component
  -> SignalNameMap   -- The output portnames and/or signals to map these to
  -> [AST.AssocElem]            -- The resulting output ports

-- Map the output port of a component to the output port of the containing
-- entity.
mapOutputPorts (Single (portname, _)) (Single (signalname, _)) =
  [(Just portname) AST.:=>: (AST.ADName (AST.NSimple signalname))]

-- Map matching output ports in the tuple
mapOutputPorts (Tuple ports) (Tuple signals) =
  concat (zipWith mapOutputPorts ports signals)

expandBind ::
  CoreBind                        -- The binder to expand into VHDL
  -> VHDLState [AST.LibraryUnit]  -- The resulting VHDL

expandBind (Rec _) = error "Recursive binders not supported"

expandBind bind@(NonRec var expr) = do
  -- Create the function signature
  let ty = CoreUtils.exprType expr
  let hsfunc = mkHsFunction var ty
  hwfunc <- mkHWFunction bind hsfunc
  -- Add it to the session
  addFunc hsfunc hwfunc 
  arch <- getArchitecture hwfunc expr
  let entity = getEntity hwfunc
  return $ [
    AST.LUEntity entity,
    AST.LUArch arch ]

getArchitecture ::
  HWFunction                -- The function to generate an architecture for
  -> CoreExpr               -- The expression that is bound to the function
  -> VHDLState AST.ArchBody -- The resulting architecture
   
getArchitecture hwfunc expr = do
  -- Unpack our hwfunc
  let HWFunction vhdl_id inports outport = hwfunc
  -- Expand the expression into an architecture body
  (signal_decls, statements, arg_signals, res_signal) <- expandExpr [] expr
  let inport_assigns = concat $ zipWith createSignalAssignments arg_signals inports
  let outport_assigns = createSignalAssignments outport res_signal
  return $ AST.ArchBody
    (AST.unsafeVHDLBasicId "structural")
    (AST.NSimple vhdl_id)
    (map AST.BDISD signal_decls)
    (inport_assigns ++ outport_assigns ++ statements)

-- Generate a VHDL entity declaration for the given function
getEntity :: HWFunction -> AST.EntityDec  
getEntity (HWFunction vhdl_id inports outport) = 
  AST.EntityDec vhdl_id ports
  where
    ports = 
      (concat $ map (mkIfaceSigDecs AST.In) inports)
      ++ mkIfaceSigDecs AST.Out outport

mkIfaceSigDecs ::
  AST.Mode                        -- The port's mode (In or Out)
  -> SignalNameMap        -- The ports to generate a map for
  -> [AST.IfaceSigDec]            -- The resulting ports
  
mkIfaceSigDecs mode (Single (port_id, ty)) =
  [AST.IfaceSigDec port_id mode ty]

mkIfaceSigDecs mode (Tuple ports) =
  concat $ map (mkIfaceSigDecs mode) ports

-- Unused values (state) don't generate ports
mkIfaceSigDecs mode Unused =
  []

-- Create concurrent assignments of one map of signals to another. The maps
-- should have a similar form.
createSignalAssignments ::
  SignalNameMap         -- The signals to assign to
  -> SignalNameMap      -- The signals to assign
  -> [AST.ConcSm]                  -- The resulting assignments

-- A simple assignment of one signal to another (greatly complicated because
-- signal assignments can be conditional with multiple conditions in VHDL).
createSignalAssignments (Single (dst, _)) (Single (src, _)) =
    [AST.CSSASm assign]
  where
    src_name  = AST.NSimple src
    src_expr  = AST.PrimName src_name
    src_wform = AST.Wform [AST.WformElem src_expr Nothing]
    dst_name  = (AST.NSimple dst)
    assign    = dst_name AST.:<==: (AST.ConWforms [] src_wform Nothing)

createSignalAssignments (Tuple dsts) (Tuple srcs) =
  concat $ zipWith createSignalAssignments dsts srcs

createSignalAssignments Unused (Single (src, _)) =
  -- Write state
  []

createSignalAssignments (Single (src, _)) Unused =
  -- Read state
  []

createSignalAssignments dst src =
  error $ "Non matching source and destination: " ++ show dst ++ " <= " ++  show src

type SignalNameMap = HsValueMap (AST.VHDLId, AST.TypeMark)

-- | A datatype that maps each of the single values in a haskell structure to
-- a mapto. The map has the same structure as the haskell type mapped, ie
-- nested tuples etc.
data HsValueMap mapto =
  Tuple [HsValueMap mapto]
  | Single mapto
  | Unused
  deriving (Show, Eq)

-- | Creates a HsValueMap with the same structure as the given type, using the
--   given function for mapping the single types.
mkHsValueMap ::
  ((Type, s) -> (HsValueMap mapto, s))
                                -- ^ A function to map single value Types
                                --   (basically anything but tuples) to a
                                --   HsValueMap (not limited to the Single
                                --   constructor) Also accepts and produces a
                                --   state that will be passed on between
                                --   each call to the function.
  -> s                          -- ^ The initial state
  -> Type                       -- ^ The type to map to a HsValueMap
  -> (HsValueMap mapto, s)      -- ^ The resulting map and state

mkHsValueMap f s ty =
  case Type.splitTyConApp_maybe ty of
    Just (tycon, args) ->
      if (TyCon.isTupleTyCon tycon) 
        then
          let (args', s') = mapTuple f s args in
          -- Handle tuple construction especially
          (Tuple args', s')
        else
          -- And let f handle the rest
          f (ty, s)
    -- And let f handle the rest
    Nothing -> f (ty, s)
  where
    mapTuple f s (ty:tys) =
      let (map, s') = mkHsValueMap f s ty in
      let (maps, s'') = mapTuple f s' tys in
      (map: maps, s'')
    mapTuple f s [] = ([], s)

-- Generate a port name map (or multiple for tuple types) in the given direction for
-- each type given.
getPortNameMapForTys :: String -> Int -> [Type] -> [HsUseMap] -> [SignalNameMap]
getPortNameMapForTys prefix num [] [] = [] 
getPortNameMapForTys prefix num (t:ts) (u:us) =
  (getPortNameMapForTy (prefix ++ show num) t u) : getPortNameMapForTys prefix (num + 1) ts us

getPortNameMapForTy :: String -> Type -> HsUseMap -> SignalNameMap
getPortNameMapForTy name _ (Single (State _)) =
  Unused

getPortNameMapForTy name ty use =
  if (TyCon.isTupleTyCon tycon) then
    let (Tuple uses) = use in
    -- Expand tuples we find
    Tuple (getPortNameMapForTys name 0 args uses)
  else -- Assume it's a type constructor application, ie simple data type
    Single ((AST.unsafeVHDLBasicId name), (vhdl_ty ty))
  where
    (tycon, args) = Type.splitTyConApp ty 

data HWFunction = HWFunction { -- A function that is available in hardware
  vhdlId    :: AST.VHDLId,
  inPorts   :: [SignalNameMap],
  outPort   :: SignalNameMap
  --entity    :: AST.EntityDec
} deriving (Show)

-- Turns a CoreExpr describing a function into a description of its input and
-- output ports.
mkHWFunction ::
  CoreBind                                   -- The core binder to generate the interface for
  -> HsFunction                              -- The HsFunction describing the function
  -> VHDLState HWFunction                    -- The function interface

mkHWFunction (NonRec var expr) hsfunc =
    return $ HWFunction (mkVHDLId name) inports outport
  where
    name = getOccString var
    ty = CoreUtils.exprType expr
    (args, res) = Type.splitFunTys ty
    inports = case args of
      -- Handle a single port specially, to prevent an extra 0 in the name
      [port] -> [getPortNameMapForTy "portin" port (head $ hsArgs hsfunc)]
      ps     -> getPortNameMapForTys "portin" 0 ps (hsArgs hsfunc)
    outport = getPortNameMapForTy "portout" res (hsRes hsfunc)

mkHWFunction (Rec _) _ =
  error "Recursive binders not supported"

-- | How is a given (single) value in a function's type (ie, argument or
-- return value) used?
data HsValueUse = 
  Port        -- ^ Use it as a port (input or output)
  | State Int -- ^ Use it as state (input or output). The int is used to
              --   match input state to output state.
  deriving (Show, Eq)

useAsPort :: Type -> HsUseMap
useAsPort = fst . (mkHsValueMap (\(ty, s) -> (Single Port, s)) 0)
useAsState :: Type -> HsUseMap
useAsState = fst . (mkHsValueMap (\(ty, s) -> (Single $ State s, s + 1)) 0)

type HsUseMap = HsValueMap HsValueUse

-- | This type describes a particular use of a Haskell function and is used to
--   look up an appropriate hardware description.  
data HsFunction = HsFunction {
  hsName :: String,                      -- ^ What was the name of the original Haskell function?
  hsArgs :: [HsUseMap],                  -- ^ How are the arguments used?
  hsRes  :: HsUseMap                     -- ^ How is the result value used?
} deriving (Show, Eq)

-- | Translate a function application to a HsFunction. i.e., which function
--   do you need to translate this function application.
appToHsFunction ::
  Var.Var         -- ^ The function to call
  -> [CoreExpr]   -- ^ The function arguments
  -> Type         -- ^ The return type
  -> HsFunction   -- ^ The needed HsFunction

appToHsFunction f args ty =
  HsFunction hsname hsargs hsres
  where
    hsargs = map (useAsPort . CoreUtils.exprType) args
    hsres  = useAsPort ty
    hsname = getOccString f

-- | Translate a top level function declaration to a HsFunction. i.e., which
--   interface will be provided by this function. This function essentially
--   defines the "calling convention" for hardware models.
mkHsFunction ::
  Var.Var         -- ^ The function defined
  -> Type         -- ^ The function type (including arguments!)
  -> HsFunction   -- ^ The resulting HsFunction

mkHsFunction f ty =
  HsFunction hsname hsargs hsres
  where
    hsname  = getOccString f
    (arg_tys, res_ty) = Type.splitFunTys ty
    -- The last argument must be state
    state_ty = last arg_tys
    state    = useAsState state_ty
    -- All but the last argument are inports
    inports = map useAsPort (init arg_tys)
    hsargs   = inports ++ [state]
    hsres    = case splitTupleType res_ty of
      -- Result type must be a two tuple (state, ports)
      Just [outstate_ty, outport_ty] -> if Type.coreEqType state_ty outstate_ty
        then
          Tuple [state, useAsPort outport_ty]
        else
          error $ "Input state type of function " ++ hsname ++ ": " ++ (showSDoc $ ppr state_ty) ++ " does not match output state type: " ++ (showSDoc $ ppr outstate_ty)
      otherwise                -> error $ "Return type of top-level function " ++ hsname ++ " must be a two-tuple containing a state and output ports."

data VHDLSession = VHDLSession {
  nameCount :: Int,                       -- A counter that can be used to generate unique names
  funcs     :: [(HsFunction, HWFunction)] -- All functions available
} deriving (Show)

type VHDLState = State.State VHDLSession

-- Add the function to the session
addFunc :: HsFunction -> HWFunction -> VHDLState ()
addFunc hsfunc hwfunc = do
  fs <- State.gets funcs -- Get the funcs element from the session
  State.modify (\x -> x {funcs = (hsfunc, hwfunc) : fs }) -- Prepend name and f

-- Lookup the function with the given name in the current session. Errors if
-- it was not found.
getHWFunc :: HsFunction -> VHDLState HWFunction
getHWFunc hsfunc = do
  fs <- State.gets funcs -- Get the funcs element from the session
  return $ Maybe.fromMaybe
    (error $ "Function " ++ (hsName hsfunc) ++ "is unknown? This should not happen!")
    (lookup hsfunc fs)

-- | Splits a tuple type into a list of element types, or Nothing if the type
--   is not a tuple type.
splitTupleType ::
  Type              -- ^ The type to split
  -> Maybe [Type]   -- ^ The tuples element types

splitTupleType ty =
  case Type.splitTyConApp_maybe ty of
    Just (tycon, args) -> if TyCon.isTupleTyCon tycon 
      then
        Just args
      else
        Nothing
    Nothing -> Nothing

-- Makes the given name unique by appending a unique number.
-- This does not do any checking against existing names, so it only guarantees
-- uniqueness with other names generated by uniqueName.
uniqueName :: String -> VHDLState String
uniqueName name = do
  count <- State.gets nameCount -- Get the funcs element from the session
  State.modify (\s -> s {nameCount = count + 1})
  return $ name ++ "_" ++ (show count)

-- Shortcut
mkVHDLId :: String -> AST.VHDLId
mkVHDLId = AST.unsafeVHDLBasicId

builtin_funcs = 
  [ 
    (HsFunction "hwxor" [(Single Port), (Single Port)] (Single Port), HWFunction (mkVHDLId "hwxor") [Single (mkVHDLId "a", vhdl_bit_ty), Single (mkVHDLId "b", vhdl_bit_ty)] (Single (mkVHDLId "o", vhdl_bit_ty))),
    (HsFunction "hwand" [(Single Port), (Single Port)] (Single Port), HWFunction (mkVHDLId "hwand") [Single (mkVHDLId "a", vhdl_bit_ty), Single (mkVHDLId "b", vhdl_bit_ty)] (Single (mkVHDLId "o", vhdl_bit_ty))),
    (HsFunction "hwor" [(Single Port), (Single Port)] (Single Port), HWFunction (mkVHDLId "hwor") [Single (mkVHDLId "a", vhdl_bit_ty), Single (mkVHDLId "b", vhdl_bit_ty)] (Single (mkVHDLId "o", vhdl_bit_ty))),
    (HsFunction "hwnot" [(Single Port)] (Single Port), HWFunction (mkVHDLId "hwnot") [Single (mkVHDLId "i", vhdl_bit_ty)] (Single (mkVHDLId "o", vhdl_bit_ty)))
  ]

vhdl_bit_ty :: AST.TypeMark
vhdl_bit_ty = AST.unsafeVHDLBasicId "Bit"

-- Translate a Haskell type to a VHDL type
vhdl_ty :: Type -> AST.TypeMark
vhdl_ty ty = Maybe.fromMaybe
  (error $ "Unsupported Haskell type: " ++ (showSDoc $ ppr ty))
  (vhdl_ty_maybe ty)

-- Translate a Haskell type to a VHDL type
vhdl_ty_maybe :: Type -> Maybe AST.TypeMark
vhdl_ty_maybe ty =
  case Type.splitTyConApp_maybe ty of
    Just (tycon, args) ->
      let name = TyCon.tyConName tycon in
        -- TODO: Do something more robust than string matching
        case getOccString name of
          "Bit"      -> Just vhdl_bit_ty
          otherwise  -> Nothing
    otherwise -> Nothing

-- vim: set ts=8 sw=2 sts=2 expandtab:
