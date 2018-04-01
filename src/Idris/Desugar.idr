module Idris.Desugar

import Core.Binary
import Core.Context
import Core.Core
import Core.TT

import Data.StringMap

import Utils.Shunting
import Idris.Syntax

import TTImp.TTImp

-- Convert high level Idris declarations (PDecl from Idris.Syntax) into
-- TTImp, recording any high level syntax info on the way (e.g. infix
-- operators)

-- Desugaring from high level Idris syntax to TTImp involves:

-- Done:
-- * Shunting infix operators into function applications according to precedence
-- * Replacing 'do' notating with applications of (>>=)
-- * Replacing pattern matching binds with 'case'

-- Still TODO:
-- * Replacing !-notation
-- * Changing tuples to 'Pair/MkPair'
-- * Dependent pair notation
-- * Idiom brackets
-- * List notation

%default covering

public export
record SyntaxInfo where
  constructor MkSyntax
  -- Keep infix/prefix, then we can define operators which are both
  -- (most obviously, -)
  infixes : StringMap (Fixity, Nat)
  prefixes : StringMap Nat

export
TTC annot Fixity where
  toBuf b InfixL = tag 0
  toBuf b InfixR = tag 1
  toBuf b Infix = tag 2
  toBuf b Prefix = tag 3

  fromBuf s b 
      = case !getTag of
             0 => pure InfixL
             1 => pure InfixR
             2 => pure Infix
             3 => pure Prefix
             _ => corrupt "Fixity"

export
TTC annot SyntaxInfo where
  toBuf b syn 
      = do toBuf b (toList (infixes syn))
           toBuf b (toList (prefixes syn))

  fromBuf s b 
      = do inf <- fromBuf s b
           pre <- fromBuf s b
           pure (MkSyntax (fromList inf) (fromList pre))

export
initSyntax : SyntaxInfo
initSyntax = MkSyntax empty empty

-- A label for Syntax info in the global state
export
data Syn : Type where

export
extend : {auto s : Ref Syn SyntaxInfo} ->
         SyntaxInfo -> Core annot ()
extend newsyn
    = do syn <- get Syn
         put Syn (record { infixes $= mergeLeft (infixes newsyn),
                           prefixes $= mergeLeft (prefixes newsyn) } syn)

-- Whether names are turned into IBindVar or not
-- on the lhs and in types, by default, lower case variable names which
-- are not bound explicitly are turned ito IBindVar
public export
data BindMode = LowerCase | None

lowerFirst : String -> Bool
lowerFirst "" = False
lowerFirst str = assert_total (isLower (strHead str))

-- Bind lower case names in argument position
-- Don't go under lambda, case let, or local bindings, or IAlternative
bindNames : (arg : Bool) -> List Name -> RawImp annot -> RawImp annot
bindNames True env (IVar fc (UN n))
    = if not (UN n `elem` env) && lowerFirst n
         then IBindVar fc n
         else IVar fc (UN n)
bindNames arg env (IPi fc rig p mn aty retty)
    = let env' = case mn of
                      Nothing => env
                      Just n => n :: env in
          IPi fc rig p mn (bindNames True env' aty) (bindNames True env' retty)
bindNames arg env (IApp fc fn av)
    = IApp fc (bindNames False env fn) (bindNames True env av)
bindNames arg env (IImplicitApp fc fn n av)
    = IImplicitApp fc (bindNames False env fn) n (bindNames True env av)
bindNames arg env (IAs fc n pat)
    = IAs fc n (bindNames arg env pat)
bindNames arg env (IAlternative fc u alts)
    = IAlternative fc u (map (bindNames arg env) alts)
-- We've skipped lambda, case, let and local - rather than guess where the
-- name should be bound, leave it to the programmer
bindNames arg env tm = tm

-- Add 'IMustUnify' for any duplicated names, and any function application
addDots : RawImp annot -> RawImp annot
addDots tm = tm

mkPrec : Fixity -> Nat -> OpPrec
mkPrec InfixL p = AssocL p
mkPrec InfixR p = AssocR p
mkPrec Infix p = NonAssoc p
mkPrec Prefix p = Prefix p

toTokList : {auto s : Ref Syn SyntaxInfo} ->
            PTerm -> Core FC (List (Tok FC PTerm))
toTokList (POp fc op l r)
    = do syn <- get Syn
         case lookup op (infixes syn) of
              Nothing => throw (GenericMsg fc $ "Unknown operator '" ++ op ++ "'")
              Just (Prefix, _) =>
                      throw (GenericMsg fc $ "'" ++ op ++ "' is a prefix operator")
              Just (fix, prec) =>
                   do rtoks <- toTokList r
                      pure (Expr l :: Op fc op (mkPrec fix prec) :: rtoks)
toTokList (PPrefixOp fc op arg)
    = do syn <- get Syn
         case lookup op (prefixes syn) of
              Nothing =>
                   throw (GenericMsg fc $ "'" ++ op ++ "' is not a prefix operator")
              Just prec =>
                   do rtoks <- toTokList arg
                      pure (Op fc op (Prefix prec) :: rtoks)
toTokList t = pure [Expr t]

mutual
  export
  desugar : {auto s : Ref Syn SyntaxInfo} ->
            PTerm -> Core FC (RawImp FC)
  desugar (PRef fc x) = pure $ IVar fc x
  desugar (PPi fc rig p mn argTy retTy) 
      = pure $ IPi fc rig p mn !(desugar argTy) 
                               !(desugar retTy)
  desugar (PLam fc rig p n argTy scope) 
      = pure $ ILam fc rig p n !(desugar argTy) 
                               !(desugar scope)
  desugar (PLet fc rig n nTy nVal scope) 
      = pure $ ILet fc rig n !(desugar nTy) !(desugar nVal) 
                             !(desugar scope)
  desugar (PCase fc x xs) 
      = pure $ ICase fc !(desugar x) 
                        !(traverse desugarClause xs)
  desugar (PLocal fc xs scope) 
      = pure $ ILocal fc (concat !(traverse desugarDecl xs)) 
                         !(desugar scope)
  desugar (PApp fc x y) 
      = pure $ IApp fc !(desugar x) !(desugar y)
  desugar (PImplicitApp fc x argn y) 
      = pure $ IImplicitApp fc !(desugar x) argn !(desugar y)
  desugar (PBracketed fc e) = desugar e
  desugar (POp fc op l r) 
      = do ts <- toTokList (POp fc op l r)
           desugarTree !(parseOps ts)
  desugar (PPrefixOp fc op arg) 
      = do ts <- toTokList (PPrefixOp fc op arg)
           desugarTree !(parseOps ts)
  desugar (PSectionL fc op arg) 
      = do syn <- get Syn
           -- It might actually be a prefix argument rather than a section
           -- so check that first, otherwise desugar as a lambda
           case lookup op (prefixes syn) of
                Nothing => 
                   desugar (PLam fc RigW Explicit (MN "arg" 0) (PImplicit fc)
                               (POp fc op (PRef fc (MN "arg" 0)) arg))
                Just prec => desugar (PPrefixOp fc op arg)
  desugar (PSectionR fc arg op)
      = desugar (PLam fc RigW Explicit (MN "arg" 0) (PImplicit fc)
                 (POp fc op arg (PRef fc (MN "arg" 0))))
  desugar (PSearch fc depth) = pure $ ISearch fc depth
  desugar (PPrimVal fc (BI x))
      = pure $ IAlternative fc (UniqueDefault (IPrimVal fc (BI x)))
                               [IPrimVal fc (BI x), 
                                IPrimVal fc (I (fromInteger x))]
  desugar (PPrimVal fc x) = pure $ IPrimVal fc x
  desugar (PHole fc holename) = pure $ IHole fc holename
  desugar (PType fc) = pure $ IType fc
  desugar (PAs fc vname pattern) 
      = pure $ IAs fc vname !(desugar pattern)
  desugar (PDotted fc x) 
      = pure $ IMustUnify fc !(desugar x)
  desugar (PImplicit fc) = pure $ Implicit fc
  desugar (PDoBlock fc block)
      = expandDo fc block
  desugar (PPair fc l r) 
      = do l' <- desugar l
           r' <- desugar r
           pure $ IAlternative fc Unique
                  [apply (IVar fc (UN "Pair")) [l', r'],
                   apply (IVar fc (UN "MkPair")) [l', r']]
  desugar (PUnit fc) 
      = pure $ IAlternative fc Unique 
               [IVar fc (UN "Unit"), 
                IVar fc (UN "MkUnit")]
  
  expandDo : {auto s : Ref Syn SyntaxInfo} ->
             FC -> List PDo -> Core FC (RawImp FC)
  expandDo fc [] = throw (GenericMsg fc "Do block cannot be empty")
  expandDo _ [DoExp fc tm] = desugar tm
  expandDo fc [e] 
      = throw (GenericMsg (getLoc e) 
                  "Last statement in do block must be an expression") 
  expandDo topfc (DoExp fc tm :: rest)
      = do tm' <- desugar tm
           rest' <- expandDo topfc rest
           pure $ IApp fc (IApp fc (IVar fc (UN ">>=")) tm')
                     (ILam fc RigW Explicit (UN "__bind") (Implicit fc) rest')
  expandDo topfc (DoBind fc n tm :: rest)
      = do tm' <- desugar tm
           rest' <- expandDo topfc rest
           pure $ IApp fc (IApp fc (IVar fc (UN ">>=")) tm')
                     (ILam fc RigW Explicit n (Implicit fc) rest')
  expandDo topfc (DoBindPat fc pat exp alts :: rest)
      = do pat' <- desugar pat
           exp' <- desugar exp
           alts' <- traverse desugarClause alts
           rest' <- expandDo topfc rest
           pure $ IApp fc (IApp fc (IVar fc (UN ">>=")) exp')
                    (ILam fc RigW Explicit (MN "bind" 0) (Implicit fc)
                          (ICase fc (IVar fc (MN "bind" 0))
                               (PatClause fc (bindNames False [] pat') rest' 
                                  :: alts')))
  expandDo topfc (DoLet fc n rig tm :: rest) 
      = do tm' <- desugar tm
           rest' <- expandDo topfc rest
           pure $ ILet fc rig n (Implicit fc) tm' rest'
  expandDo topfc (DoLetPat fc pat tm alts :: rest) 
      = do pat' <- desugar pat
           tm' <- desugar tm
           alts' <- traverse desugarClause alts
           rest' <- expandDo topfc rest
           pure $ ICase fc tm' (PatClause fc (bindNames False [] pat') rest'
                                  :: alts')

  desugarTree : {auto s : Ref Syn SyntaxInfo} ->
                Tree FC PTerm -> Core FC (RawImp FC)
  desugarTree (Inf loc op l r)
      = do l' <- desugarTree l
           r' <- desugarTree r
           pure (IApp loc (IApp loc (IVar loc (UN op)) l') r')
  desugarTree (Pre loc op arg)
      = do arg' <- desugarTree arg
           pure (IApp loc (IVar loc (UN op)) arg')
  desugarTree (Leaf t) = desugar t

  desugarType : {auto s : Ref Syn SyntaxInfo} ->
                PTypeDecl -> Core FC (ImpTy FC)
  desugarType (MkPTy fc n ty) 
      = pure $ MkImpTy fc n (bindNames True [] !(desugar ty))

  desugarClause : {auto s : Ref Syn SyntaxInfo} ->
                  PClause -> Core FC (ImpClause FC)
  desugarClause (MkPatClause fc lhs rhs wheres)
      = do ws <- traverse desugarDecl wheres
           rhs' <- desugar rhs
           pure $ PatClause fc (bindNames False [] !(desugar lhs)) 
                     (case ws of
                           [] => rhs'
                           _ => ILocal fc (concat ws) rhs')
  desugarClause (MkImpossible fc lhs) 
      = pure $ ImpossibleClause fc (bindNames False [] !(desugar lhs))

  desugarData : {auto s : Ref Syn SyntaxInfo} ->
                PDataDecl -> Core FC (ImpData FC)
  desugarData (MkPData fc n tycon opts datacons) 
      = pure $ (MkImpData fc n (bindNames True [] !(desugar tycon))
                               opts
                              !(traverse desugarType datacons))

  -- Given a high level declaration, return a list of TTImp declarations
  -- which process it, and update any necessary state on the way.
  export
  desugarDecl : {auto s : Ref Syn SyntaxInfo} ->
                PDecl -> Core FC (List (ImpDecl FC))
  desugarDecl (PClaim fc vis opts ty) 
      = pure [IClaim fc vis opts !(desugarType ty)]
  desugarDecl (PDef fc n clauses) 
      = pure [IDef fc n !(traverse desugarClause clauses)]
  desugarDecl (PData fc vis ddecl) 
      = pure [IData fc vis !(desugarData ddecl)]
  desugarDecl (PReflect fc tm)
      = pure [IReflect fc !(desugar tm)]
  desugarDecl (PFixity fc Prefix prec n) 
      = do syn <- get Syn
           put Syn (record { prefixes $= insert n prec } syn)
           pure []
  desugarDecl (PFixity fc fix prec n) 
      = do syn <- get Syn
           put Syn (record { infixes $= insert n (fix, prec) } syn)
           pure []
  desugarDecl (PNamespace fc ns decls)
      = pure [INamespace fc ns (concat !(traverse desugarDecl decls))]
  desugarDecl (PDirective fc d) 
      = case d of
             Logging i => pure [ILog i]
             LazyNames ty d f => pure [IPragma (\defs => setLazy fc ty d f)]

