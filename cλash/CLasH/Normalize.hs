{-# LANGUAGE PackageImports #-}
--
-- Functions to bring a Core expression in normal form. This module provides a
-- top level function "normalize", and defines the actual transformation passes that
-- are performed.
--
module CLasH.Normalize (getNormalized) where

-- Standard modules
import Debug.Trace
import qualified Maybe
import qualified "transformers" Control.Monad.Trans as Trans
import qualified Control.Monad as Monad
import qualified Control.Monad.Trans.Writer as Writer
import qualified Data.Map as Map
import qualified Data.Monoid as Monoid
import Data.Accessor

-- GHC API
import CoreSyn
import qualified UniqSupply
import qualified CoreUtils
import qualified Type
import qualified TcType
import qualified Id
import qualified Var
import qualified VarSet
import qualified NameSet
import qualified CoreFVs
import qualified CoreUtils
import qualified MkCore
import qualified HscTypes
import Outputable ( showSDoc, ppr, nest )

-- Local imports
import CLasH.Normalize.NormalizeTypes
import CLasH.Translator.TranslatorTypes
import CLasH.Normalize.NormalizeTools
import CLasH.VHDL.VHDLTypes
import qualified CLasH.Utils as Utils
import CLasH.Utils.Core.CoreTools
import CLasH.Utils.Core.BinderTools
import CLasH.Utils.Pretty

--------------------------------
-- Start of transformations
--------------------------------

--------------------------------
-- η abstraction
--------------------------------
eta, etatop :: Transform
eta expr | is_fun expr && not (is_lam expr) = do
  let arg_ty = (fst . Type.splitFunTy . CoreUtils.exprType) expr
  id <- Trans.lift $ mkInternalVar "param" arg_ty
  change (Lam id (App expr (Var id)))
-- Leave all other expressions unchanged
eta e = return e
etatop = notappargs ("eta", eta)

--------------------------------
-- β-reduction
--------------------------------
beta, betatop :: Transform
-- Substitute arg for x in expr
beta (App (Lam x expr) arg) = change $ substitute [(x, arg)] expr
-- Propagate the application into the let
beta (App (Let binds expr) arg) = change $ Let binds (App expr arg)
-- Propagate the application into each of the alternatives
beta (App (Case scrut b ty alts) arg) = change $ Case scrut b ty' alts'
  where 
    alts' = map (\(con, bndrs, expr) -> (con, bndrs, (App expr arg))) alts
    ty' = CoreUtils.applyTypeToArg ty arg
-- Leave all other expressions unchanged
beta expr = return expr
-- Perform this transform everywhere
betatop = everywhere ("beta", beta)

--------------------------------
-- Cast propagation
--------------------------------
-- Try to move casts as much downward as possible.
castprop, castproptop :: Transform
castprop (Cast (Let binds expr) ty) = change $ Let binds (Cast expr ty)
castprop expr@(Cast (Case scrut b _ alts) ty) = change (Case scrut b ty alts')
  where
    alts' = map (\(con, bndrs, expr) -> (con, bndrs, (Cast expr ty))) alts
-- Leave all other expressions unchanged
castprop expr = return expr
-- Perform this transform everywhere
castproptop = everywhere ("castprop", castprop)

--------------------------------
-- let recursification
--------------------------------
letrec, letrectop :: Transform
letrec (Let (NonRec b expr) res) = change $ Let (Rec [(b, expr)]) res
-- Leave all other expressions unchanged
letrec expr = return expr
-- Perform this transform everywhere
letrectop = everywhere ("letrec", letrec)

--------------------------------
-- let simplification
--------------------------------
letsimpl, letsimpltop :: Transform
-- Put the "in ..." value of a let in its own binding, but not when the
-- expression is already a local variable, or not representable (to prevent loops with inlinenonrep).
letsimpl expr@(Let (Rec binds) res) = do
  repr <- isRepr res
  local_var <- Trans.lift $ is_local_var res
  if not local_var && repr
    then do
      -- If the result is not a local var already (to prevent loops with
      -- ourselves), extract it.
      id <- Trans.lift $ mkInternalVar "foo" (CoreUtils.exprType res)
      let bind = (id, res)
      change $ Let (Rec (bind:binds)) (Var id)
    else
      -- If the result is already a local var, don't extract it.
      return expr

-- Leave all other expressions unchanged
letsimpl expr = return expr
-- Perform this transform everywhere
letsimpltop = everywhere ("letsimpl", letsimpl)

--------------------------------
-- let flattening
--------------------------------
letflat, letflattop :: Transform
letflat (Let (Rec binds) expr) = do
  -- Turn each binding into a list of bindings (possibly containing just one
  -- element, of course)
  bindss <- Monad.mapM flatbind binds
  -- Concat all the bindings
  let binds' = concat bindss
  -- Return the new let. We don't use change here, since possibly nothing has
  -- changed. If anything has changed, flatbind has already flagged that
  -- change.
  return $ Let (Rec binds') expr
  where
    -- Turns a binding of a let into a multiple bindings, or any other binding
    -- into a list with just that binding
    flatbind :: (CoreBndr, CoreExpr) -> TransformMonad [(CoreBndr, CoreExpr)]
    flatbind (b, Let (Rec binds) expr) = change ((b, expr):binds)
    flatbind (b, expr) = return [(b, expr)]
-- Leave all other expressions unchanged
letflat expr = return expr
-- Perform this transform everywhere
letflattop = everywhere ("letflat", letflat)

--------------------------------
-- Simple let binding removal
--------------------------------
-- Remove a = b bindings from let expressions everywhere
letremovetop :: Transform
letremovetop = everywhere ("letremove", inlinebind (\(b, e) -> Trans.lift $ is_local_var e))

--------------------------------
-- Function inlining
--------------------------------
-- Remove a = B bindings, with B :: a -> b, or B :: forall x . T, from let
-- expressions everywhere. This means that any value that still needs to be
-- applied to something else (polymorphic values need to be applied to a
-- Type) will be inlined, and will eventually be applied to all their
-- arguments.
--
-- This is a tricky function, which is prone to create loops in the
-- transformations. To fix this, we make sure that no transformation will
-- create a new let binding with a function type. These other transformations
-- will just not work on those function-typed values at first, but the other
-- transformations (in particular β-reduction) should make sure that the type
-- of those values eventually becomes primitive.
inlinenonreptop :: Transform
inlinenonreptop = everywhere ("inlinenonrep", inlinebind ((Monad.liftM not) . isRepr . snd))

--------------------------------
-- Scrutinee simplification
--------------------------------
scrutsimpl,scrutsimpltop :: Transform
-- Don't touch scrutinees that are already simple
scrutsimpl expr@(Case (Var _) _ _ _) = return expr
-- Replace all other cases with a let that binds the scrutinee and a new
-- simple scrutinee, but only when the scrutinee is representable (to prevent
-- loops with inlinenonrep, though I don't think a non-representable scrutinee
-- will be supported anyway...) 
scrutsimpl expr@(Case scrut b ty alts) = do
  repr <- isRepr scrut
  if repr
    then do
      id <- Trans.lift $ mkInternalVar "scrut" (CoreUtils.exprType scrut)
      change $ Let (Rec [(id, scrut)]) (Case (Var id) b ty alts)
    else
      return expr
-- Leave all other expressions unchanged
scrutsimpl expr = return expr
-- Perform this transform everywhere
scrutsimpltop = everywhere ("scrutsimpl", scrutsimpl)

--------------------------------
-- Case binder wildening
--------------------------------
casesimpl, casesimpltop :: Transform
-- This is already a selector case (or, if x does not appear in bndrs, a very
-- simple case statement that will be removed by caseremove below). Just leave
-- it be.
casesimpl expr@(Case scrut b ty [(con, bndrs, Var x)]) = return expr
-- Make sure that all case alternatives have only wild binders and simple
-- expressions.
-- This is done by creating a new let binding for each non-wild binder, which
-- is bound to a new simple selector case statement and for each complex
-- expression. We do this only for representable types, to prevent loops with
-- inlinenonrep.
casesimpl expr@(Case scrut b ty alts) = do
  (bindingss, alts') <- (Monad.liftM unzip) $ mapM doalt alts
  let bindings = concat bindingss
  -- Replace the case with a let with bindings and a case
  let newlet = (Let (Rec bindings) (Case scrut b ty alts'))
  -- If there are no non-wild binders, or this case is already a simple
  -- selector (i.e., a single alt with exactly one binding), already a simple
  -- selector altan no bindings (i.e., no wild binders in the original case),
  -- don't change anything, otherwise, replace the case.
  if null bindings then return expr else change newlet 
  where
  -- Generate a single wild binder, since they are all the same
  wild = MkCore.mkWildBinder
  -- Wilden the binders of one alt, producing a list of bindings as a
  -- sideeffect.
  doalt :: CoreAlt -> TransformMonad ([(CoreBndr, CoreExpr)], CoreAlt)
  doalt (con, bndrs, expr) = do
    -- Make each binder wild, if possible
    bndrs_res <- Monad.zipWithM dobndr bndrs [0..]
    let (newbndrs, bindings_maybe) = unzip bndrs_res
    -- Extract a complex expression, if possible. For this we check if any of
    -- the new list of bndrs are used by expr. We can't use free_vars here,
    -- since that looks at the old bndrs.
    let uses_bndrs = not $ VarSet.isEmptyVarSet $ CoreFVs.exprSomeFreeVars (`elem` newbndrs) $ expr
    (exprbinding_maybe, expr') <- doexpr expr uses_bndrs
    -- Create a new alternative
    let newalt = (con, newbndrs, expr')
    let bindings = Maybe.catMaybes (exprbinding_maybe : bindings_maybe)
    return (bindings, newalt)
    where
      -- Make wild alternatives for each binder
      wildbndrs = map (\bndr -> MkCore.mkWildBinder (Id.idType bndr)) bndrs
      -- A set of all the binders that are used by the expression
      free_vars = CoreFVs.exprSomeFreeVars (`elem` bndrs) expr
      -- Look at the ith binder in the case alternative. Return a new binder
      -- for it (either the same one, or a wild one) and optionally a let
      -- binding containing a case expression.
      dobndr :: CoreBndr -> Int -> TransformMonad (CoreBndr, Maybe (CoreBndr, CoreExpr))
      dobndr b i = do
        repr <- isRepr (Var b)
        -- Is b wild (e.g., not a free var of expr. Since b is only in scope
        -- in expr, this means that b is unused if expr does not use it.)
        let wild = not (VarSet.elemVarSet b free_vars)
        -- Create a new binding for any representable binder that is not
        -- already wild and is representable (to prevent loops with
        -- inlinenonrep).
        if (not wild) && repr
          then do
            -- Create on new binder that will actually capture a value in this
            -- case statement, and return it.
            let bty = (Id.idType b)
            id <- Trans.lift $ mkInternalVar "sel" bty
            let binders = take i wildbndrs ++ [id] ++ drop (i+1) wildbndrs
            let caseexpr = Case scrut b bty [(con, binders, Var id)]
            return (wildbndrs!!i, Just (b, caseexpr))
          else 
            -- Just leave the original binder in place, and don't generate an
            -- extra selector case.
            return (b, Nothing)
      -- Process the expression of a case alternative. Accepts an expression
      -- and whether this expression uses any of the binders in the
      -- alternative. Returns an optional new binding and a new expression.
      doexpr :: CoreExpr -> Bool -> TransformMonad (Maybe (CoreBndr, CoreExpr), CoreExpr)
      doexpr expr uses_bndrs = do
        local_var <- Trans.lift $ is_local_var expr
        repr <- isRepr expr
        -- Extract any expressions that do not use any binders from this
        -- alternative, is not a local var already and is representable (to
        -- prevent loops with inlinenonrep).
        if (not uses_bndrs) && (not local_var) && repr
          then do
            id <- Trans.lift $ mkInternalVar "caseval" (CoreUtils.exprType expr)
            -- We don't flag a change here, since casevalsimpl will do that above
            -- based on Just we return here.
            return $ (Just (id, expr), Var id)
          else
            -- Don't simplify anything else
            return (Nothing, expr)
-- Leave all other expressions unchanged
casesimpl expr = return expr
-- Perform this transform everywhere
casesimpltop = everywhere ("casesimpl", casesimpl)

--------------------------------
-- Case removal
--------------------------------
-- Remove case statements that have only a single alternative and only wild
-- binders.
caseremove, caseremovetop :: Transform
-- Replace a useless case by the value of its single alternative
caseremove (Case scrut b ty [(con, bndrs, expr)]) | not usesvars = change expr
    -- Find if any of the binders are used by expr
    where usesvars = (not . VarSet.isEmptyVarSet . (CoreFVs.exprSomeFreeVars (`elem` bndrs))) expr
-- Leave all other expressions unchanged
caseremove expr = return expr
-- Perform this transform everywhere
caseremovetop = everywhere ("caseremove", caseremove)

--------------------------------
-- Argument extraction
--------------------------------
-- Make sure that all arguments of a representable type are simple variables.
appsimpl, appsimpltop :: Transform
-- Simplify all representable arguments. Do this by introducing a new Let
-- that binds the argument and passing the new binder in the application.
appsimpl expr@(App f arg) = do
  -- Check runtime representability
  repr <- isRepr arg
  local_var <- Trans.lift $ is_local_var arg
  if repr && not local_var
    then do -- Extract representable arguments
      id <- Trans.lift $ mkInternalVar "arg" (CoreUtils.exprType arg)
      change $ Let (Rec [(id, arg)]) (App f (Var id))
    else -- Leave non-representable arguments unchanged
      return expr
-- Leave all other expressions unchanged
appsimpl expr = return expr
-- Perform this transform everywhere
appsimpltop = everywhere ("appsimpl", appsimpl)

--------------------------------
-- Function-typed argument propagation
--------------------------------
-- Remove all applications to function-typed arguments, by duplication the
-- function called with the function-typed parameter replaced by the free
-- variables of the argument passed in.
argprop, argproptop :: Transform
-- Transform any application of a named function (i.e., skip applications of
-- lambda's). Also skip applications that have arguments with free type
-- variables, since we can't inline those.
argprop expr@(App _ _) | is_var fexpr = do
  -- Find the body of the function called
  body_maybe <- Trans.lift $ getGlobalBind f
  case body_maybe of
    Just body -> do
      -- Process each of the arguments in turn
      (args', changed) <- Writer.listen $ mapM doarg args
      -- See if any of the arguments changed
      case Monoid.getAny changed of
        True -> do
          let (newargs', newparams', oldargs) = unzip3 args'
          let newargs = concat newargs'
          let newparams = concat newparams'
          -- Create a new body that consists of a lambda for all new arguments and
          -- the old body applied to some arguments.
          let newbody = MkCore.mkCoreLams newparams (MkCore.mkCoreApps body oldargs)
          -- Create a new function with the same name but a new body
          newf <- Trans.lift $ mkFunction f newbody
          -- Replace the original application with one of the new function to the
          -- new arguments.
          change $ MkCore.mkCoreApps (Var newf) newargs
        False ->
          -- Don't change the expression if none of the arguments changed
          return expr
      
    -- If we don't have a body for the function called, leave it unchanged (it
    -- should be a primitive function then).
    Nothing -> return expr
  where
    -- Find the function called and the arguments
    (fexpr, args) = collectArgs expr
    Var f = fexpr

    -- Process a single argument and return (args, bndrs, arg), where args are
    -- the arguments to replace the given argument in the original
    -- application, bndrs are the binders to include in the top-level lambda
    -- in the new function body, and arg is the argument to apply to the old
    -- function body.
    doarg :: CoreExpr -> TransformMonad ([CoreExpr], [CoreBndr], CoreExpr)
    doarg arg = do
      repr <- isRepr arg
      bndrs <- Trans.lift getGlobalBinders
      let interesting var = Var.isLocalVar var && (not $ var `elem` bndrs)
      if not repr && not (is_var arg && interesting (exprToVar arg)) && not (has_free_tyvars arg) 
        then do
          -- Propagate all complex arguments that are not representable, but not
          -- arguments with free type variables (since those would require types
          -- not known yet, which will always be known eventually).
          -- Find interesting free variables, each of which should be passed to
          -- the new function instead of the original function argument.
          -- 
          -- Interesting vars are those that are local, but not available from the
          -- top level scope (functions from this module are defined as local, but
          -- they're not local to this function, so we can freely move references
          -- to them into another function).
          let free_vars = VarSet.varSetElems $ CoreFVs.exprSomeFreeVars interesting arg
          -- Mark the current expression as changed
          setChanged
          return (map Var free_vars, free_vars, arg)
        else do
          -- Representable types will not be propagated, and arguments with free
          -- type variables will be propagated later.
          -- TODO: preserve original naming?
          id <- Trans.lift $ mkBinderFor arg "param"
          -- Just pass the original argument to the new function, which binds it
          -- to a new id and just pass that new id to the old function body.
          return ([arg], [id], mkReferenceTo id) 
-- Leave all other expressions unchanged
argprop expr = return expr
-- Perform this transform everywhere
argproptop = everywhere ("argprop", argprop)

--------------------------------
-- Function-typed argument extraction
--------------------------------
-- This transform takes any function-typed argument that cannot be propagated
-- (because the function that is applied to it is a builtin function), and
-- puts it in a brand new top level binder. This allows us to for example
-- apply map to a lambda expression This will not conflict with inlinenonrep,
-- since that only inlines local let bindings, not top level bindings.
funextract, funextracttop :: Transform
funextract expr@(App _ _) | is_var fexpr = do
  body_maybe <- Trans.lift $ getGlobalBind f
  case body_maybe of
    -- We don't have a function body for f, so we can perform this transform.
    Nothing -> do
      -- Find the new arguments
      args' <- mapM doarg args
      -- And update the arguments. We use return instead of changed, so the
      -- changed flag doesn't get set if none of the args got changed.
      return $ MkCore.mkCoreApps fexpr args'
    -- We have a function body for f, leave this application to funprop
    Just _ -> return expr
  where
    -- Find the function called and the arguments
    (fexpr, args) = collectArgs expr
    Var f = fexpr
    -- Change any arguments that have a function type, but are not simple yet
    -- (ie, a variable or application). This means to create a new function
    -- for map (\f -> ...) b, but not for map (foo a) b.
    --
    -- We could use is_applicable here instead of is_fun, but I think
    -- arguments to functions could only have forall typing when existential
    -- typing is enabled. Not sure, though.
    doarg arg | not (is_simple arg) && is_fun arg = do
      -- Create a new top level binding that binds the argument. Its body will
      -- be extended with lambda expressions, to take any free variables used
      -- by the argument expression.
      let free_vars = VarSet.varSetElems $ CoreFVs.exprFreeVars arg
      let body = MkCore.mkCoreLams free_vars arg
      id <- Trans.lift $ mkBinderFor body "fun"
      Trans.lift $ addGlobalBind id body
      -- Replace the argument with a reference to the new function, applied to
      -- all vars it uses.
      change $ MkCore.mkCoreApps (Var id) (map Var free_vars)
    -- Leave all other arguments untouched
    doarg arg = return arg

-- Leave all other expressions unchanged
funextract expr = return expr
-- Perform this transform everywhere
funextracttop = everywhere ("funextract", funextract)

--------------------------------
-- End of transformations
--------------------------------




-- What transforms to run?
transforms = [argproptop, funextracttop, etatop, betatop, castproptop, letremovetop, letrectop, letsimpltop, letflattop, scrutsimpltop, casesimpltop, caseremovetop, inlinenonreptop, appsimpltop]

-- | Returns the normalized version of the given function.
getNormalized ::
  CoreBndr -- ^ The function to get
  -> TranslatorSession CoreExpr -- The normalized function body

getNormalized bndr = Utils.makeCached bndr tsNormalized $ do
  if is_poly (Var bndr)
    then
      -- This should really only happen at the top level... TODO: Give
      -- a different error if this happens down in the recursion.
      error $ "\nNormalize.normalizeBind: Function " ++ show bndr ++ " is polymorphic, can't normalize"
    else do
      expr <- getBinding bndr
      -- Introduce an empty Let at the top level, so there will always be
      -- a let in the expression (none of the transformations will remove
      -- the last let).
      let expr' = Let (Rec []) expr
      -- Normalize this expression
      trace ("Transforming " ++ (show bndr) ++ "\nBefore:\n\n" ++ showSDoc ( ppr expr' ) ++ "\n") $ return ()
      expr'' <- dotransforms transforms expr'
      trace ("\nAfter:\n\n" ++ showSDoc ( ppr expr')) $ return ()
      return expr''

-- | Get the value that is bound to the given binder at top level. Fails when
--   there is no such binding.
getBinding ::
  CoreBndr -- ^ The binder to get the expression for
  -> TranslatorSession CoreExpr -- ^ The value bound to the binder

getBinding bndr = Utils.makeCached bndr tsBindings $ do
  -- If the binding isn't in the "cache" (bindings map), then we can't create
  -- it out of thin air, so return an error.
  error $ "Normalize.getBinding: Unknown function requested: " ++ show bndr
