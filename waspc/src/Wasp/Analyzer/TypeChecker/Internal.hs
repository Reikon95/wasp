{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

-- | This module implements the type rules defined by the wasplang document
-- in two phases.
--
-- = Hoisting Declarations
--
-- First, the variables bound by each declaration statement, e.g.
--
-- @
-- app Todo {
--   title: "Todo App"
-- }
-- @
--
-- are created, without checking any types. In the above example, the bindings
-- created would be @[("Todo", DeclType "app")]@.
--
-- = Statement Type Checking
--
-- In this second phase, the types of the argument to each declaration are checked
-- to ensure they are valid for the declaration type. The implementation of the
-- type inference rules is in "inferExprType", "unifyTypes", and "weaken".
module Wasp.Analyzer.TypeChecker.Internal
  ( check,
    hoistDeclarations,
    checkAST,
    checkStmt,
    inferExprType,
    unify,
    unifyTypes,
    weaken,
  )
where

import Control.Arrow (left, second)
import Control.Monad (foldM, void)
import Data.Either (fromRight)
import qualified Data.HashMap.Strict as M
import qualified Data.HashSet as Set
import Data.List.NonEmpty (NonEmpty ((:|)), nonEmpty, toList)
import Data.Maybe (fromJust)
import Wasp.Analyzer.Parser (AST)
import qualified Wasp.Analyzer.Parser as P
import Wasp.Analyzer.Parser.Ctx (fromWithCtx)
import Wasp.Analyzer.Type
import Wasp.Analyzer.TypeChecker.AST
import Wasp.Analyzer.TypeChecker.Monad
import Wasp.Analyzer.TypeChecker.TypeError
import qualified Wasp.Analyzer.TypeDefinitions as TD
import Wasp.Util.Control.Monad (foldMapM')

check :: AST -> TypeChecker TypedAST
check ast = hoistDeclarations ast >> checkAST ast

hoistDeclarations :: AST -> TypeChecker ()
hoistDeclarations (P.AST stmts) = mapM_ hoistDeclaration stmts
  where
    hoistDeclaration :: P.WithCtx P.Stmt -> TypeChecker ()
    hoistDeclaration (P.WithCtx _ (P.Decl typeName ident _)) =
      setType ident $ DeclType typeName

checkAST :: AST -> TypeChecker TypedAST
checkAST (P.AST stmts) = TypedAST <$> mapM checkStmt stmts

checkStmt :: P.WithCtx P.Stmt -> TypeChecker (WithCtx TypedStmt)
checkStmt (P.WithCtx ctx (P.Decl typeName name expr)) =
  lookupDeclType typeName >>= \case
    Nothing -> throw $ mkTypeError ctx $ NoDeclarationType typeName
    Just (TD.DeclType _ expectedType _) -> do
      -- Decides whether the argument to the declaration has the correct type
      mTypedExpr <- weaken expectedType <$> inferExprType expr
      case mTypedExpr of
        Left e -> throw $ mkTypeError ctx $ WeakenError e
        Right typedExpr -> return $ WithCtx ctx $ Decl name typedExpr (DeclType typeName)

-- | Determine the type of an expression, following the inference rules described in
-- the wasplang document. Some of these rules are referenced by name in the comments
-- of the following functions using [Brackets].
inferExprType :: P.WithCtx P.Expr -> TypeChecker (WithCtx TypedExpr)
inferExprType = P.withCtx $ \ctx -> \case
  P.StringLiteral s -> return $ WithCtx ctx $ StringLiteral s
  P.IntegerLiteral s -> return $ WithCtx ctx $ IntegerLiteral s
  P.DoubleLiteral s -> return $ WithCtx ctx $ DoubleLiteral s
  P.BoolLiteral s -> return $ WithCtx ctx $ BoolLiteral s
  P.ExtImport n s -> return $ WithCtx ctx $ ExtImport n s
  P.Var ident ->
    lookupType ident >>= \case
      Nothing -> throw $ mkTypeError ctx $ UndefinedIdentifier ident
      Just typ -> return $ WithCtx ctx $ Var ident typ
  -- For now, the two quoter types are hardcoded here, it is an error to use a different one
  -- TODO: this will change when quoters are added to "Analyzer.TypeDefinitions".
  P.Quoter "json" s -> return $ WithCtx ctx $ JSON s
  P.Quoter "psl" s -> return $ WithCtx ctx $ PSL s
  P.Quoter tag _ -> throw $ mkTypeError ctx $ QuoterUnknownTag tag
  -- The type of a list is the unified type of its values.
  -- This poses a problem for empty lists, there is not enough information to choose a type.
  -- TODO: Fix this in the future, probably by adding an additional phase to resolve type variables
  --       that would be assigned here.
  P.List values -> do
    typedValues <- mapM inferExprType values
    case unify ctx <$> nonEmpty typedValues of
      -- Apply [EmptyList].
      Nothing -> return $ WithCtx ctx $ List [] EmptyListType
      Just (Left e) -> throw e
      Just (Right (unifiedValues, unifiedType)) ->
        return $ WithCtx ctx $ List (toList unifiedValues) (ListType unifiedType)
  -- Apply [Dict], and also check that there are no duplicate keys in the dictionary.
  P.Dict entries -> do
    typedEntries <- mapM (\(key, expr) -> (key,) <$> inferExprType expr) entries
    dictType <-
      foldM (insertIfUniqueElseThrow ctx) M.empty $
        second (withCtx . const $ DictRequired . exprType) <$> typedEntries
    return $ WithCtx ctx $ Dict typedEntries (DictType dictType)
  P.Tuple (value1, value2, restOfValues) -> do
    typedValue1 <- inferExprType value1
    typedValue2 <- inferExprType value2
    typedRestOfValues <- mapM inferExprType restOfValues
    let typedValues = (typedValue1, typedValue2, typedRestOfValues)
    let tupleType =
          TupleType
            ( exprType' typedValue1,
              exprType' typedValue2,
              exprType' <$> typedRestOfValues
            )
    return $ WithCtx ctx $ Tuple typedValues tupleType
  where
    exprType' :: WithCtx TypedExpr -> Type
    exprType' = exprType . P.fromWithCtx

    insertIfUniqueElseThrow :: P.Ctx -> M.HashMap Identifier v -> (Identifier, v) -> TypeChecker (M.HashMap Identifier v)
    insertIfUniqueElseThrow ctx m (key, value)
      | key `M.member` m = throw $ mkTypeError ctx $ DictDuplicateField key
      | otherwise = return $ M.insert key value m

-- | Finds the strongest common type for all of the given expressions, "common" meaning
-- all the expressions can be typed with it and "strongest" meaning it is as specific
-- as possible. We know such a type exists because we can always unify non-overlapping types
-- into a union type.
--
-- The following property is gauranteed:
--
-- * IF   @unify exprs == (exprs', commonType)@
--   THEN @all ((==commonType) . exprType . fromWithCtx) exprs'@
--
-- TODO: write tests.
unify :: NonEmpty (WithCtx TypedExpr) -> (NonEmpty (WithCtx TypedExpr), Type)
unify texprs =
  let superType = foldl1 unifyTypes $ exprType . fromWithCtx <$> texprs
      weakenedTexprs =
        fromRight
          (error "This should never happen: there should be no weaken errors during unification.")
          (mapM (weaken superType) texprs)
   in (weakenedTexprs, superType)

-- | @unifyTypes t texpr@ finds the strongest type that both type @t@ and
-- type of typed expression @texpr@ are a sub-type of.
-- NOTE: The reason it operates on Type and TypedExpr and not just two Types is that
--   having a TypedExpr allows us to report the source position when we encounter a type error.
--   Anyway unification always happens for some typed expressions, so this makes sense.

-- 1. T1 == T2 -> T1
-- 2. T1 != T2 -> reducedSumType(T1, T2)
-- 3. T1 != T2, but both are lists ->
--       1. If one is empty and another is not -> return non-empty one (its type). (same as we had so far)
--       2. If it is two lists, none of them empty -> just construct union type from them (so this is same step (2) above, not a special case at all actually).

-- TODO: Remove Either from here, we don't return error any more!
-- TODO: I think we can even skip WithCtx -> no need for it anymore, we don't return errors!
--   So this can now just be :: Type -> Type -> Type
unifyTypes :: Type -> Type -> Type
unifyTypes t1 t2 | t1 == t2 = t1
-- Apply [AnyList]: an empty list can unify with any other list
unifyTypes EmptyListType t2@(ListType _) = t2
unifyTypes t1@(ListType _) EmptyListType = t1
unifyTypes t1 t2 = makeUnionType t1 t2

-- TODO: Perhaps it makes sense to move this to Analyzer/Types.hs and make
-- it a smart constructor.
makeUnionType :: Type -> Type -> Type
makeUnionType t1 t2 = reduceUnionType (UnionType t1 t2)

-- TODO: Write tests
reduceUnionType :: Type -> Type
reduceUnionType unionType@(UnionType _ _) = foldl1 (flip UnionType) . Set.toList $ flatten unionType
  where
    flatten :: Type -> Set.HashSet Type
    flatten (UnionType t1 t2) = Set.union (flatten t1) (flatten t2)
    flatten t = Set.singleton t
reduceUnionType _ = error "Cannot reduce non union type"

-- -- Two non-empty lists unify only if their inner types unify
-- unifyTypes typ@(ListType list1ElemType) texpr@(WithCtx _ (List (list2ElemTexpr1 : _) (ListType _))) =
--   -- NOTE: We use first element from the typed list (list2ElemTexpr1) as a "sample" to run unification against.
--   --   This is ok because this list is already typed, so we know all other elements have the same type.
--   --   We could have alternatively picked any other element from that list.
--   annotateError $ ListType <$> unifyTypes list1ElemType list2ElemTexpr1
--   where
--     annotateError = left (TypeCoercionError texpr typ . ReasonList)
-- -- Declarations and enums can not unify with anything
-- unifyTypes t@(DeclType _) texpr = Left $ TypeCoercionError texpr t ReasonDecl
-- unifyTypes t@(EnumType _) texpr = Left $ TypeCoercionError texpr t ReasonEnum
-- -- The unification of two dictionaries is defined by the [DictNone] and [DictSome] rules
-- unifyTypes t@(DictType dict1EntryTypes) texpr@(WithCtx _ (Dict dict2Entries (DictType dict2EntryTypes))) = do
--   let keys = M.keysSet dict1EntryTypes <> M.keysSet dict2EntryTypes
--   unifiedType <- foldMapM' (\key -> M.singleton key <$> unifyEntryTypesForKey key) keys
--   return $ DictType unifiedType
--   where
--     unifyEntryTypesForKey :: String -> Either TypeCoercionError DictEntryType
--     unifyEntryTypesForKey key =
--       annotateError key $
--         case (M.lookup key dict1EntryTypes, M.lookup key dict2EntryTypes) of
--           (Nothing, Nothing) ->
--             error $
--               "impossible: unifyTypes.unifyEntryTypesForKey should be called"
--                 ++ "with only the keys of entryTypes1 and entryTypes2"
--           -- [DictSome] on s, [DictNone] on t
--           (Just sType, Nothing) ->
--             Right $ DictOptional $ dictEntryType sType
--           -- [DictNone] on s, [DictSome] on t
--           (Nothing, Just tType) ->
--             Right $ DictOptional $ dictEntryType tType
--           -- Both require @key@, so it must be a required entry of the unified entry types
--           (Just (DictRequired sType), Just (DictRequired _)) ->
--             DictRequired <$> unifyTypes sType (fromJust $ lookup key dict2Entries)
--           -- One of s or t has @key@ optionally, so it must be an optional entry of the unified entry types
--           (Just sType, Just _) ->
--             DictOptional <$> unifyTypes (dictEntryType sType) (fromJust $ lookup key dict2Entries)

--     annotateError :: String -> Either TypeCoercionError a -> Either TypeCoercionError a
--     annotateError key = left (TypeCoercionError texpr t . ReasonDictWrongKeyType key)
-- unifyTypes t texpr = Left $ TypeCoercionError texpr t ReasonUncoercable

-- | Converts a typed expression from its current type to the given weaker type, "weaker"
-- meaning it is a super-type of the original type. If that is possible, it returns the
-- converted expression. If not, an error is returned.
--
-- The following property is guaranteed:
--
-- * If @weaken typ expr == Right expr'@ then @(exprType . fromWithCtx) expr' == typ@
--
-- When a @Left@ value is returned, then @expr@ can not be typed as @typ@.
weaken :: Type -> WithCtx TypedExpr -> Either TypeCoercionError (WithCtx TypedExpr)
weaken t texprwc@(WithCtx _ texpr)
  | exprType texpr == t = Right texprwc
-- Apply [AnyList]: An empty list can be weakened to any list type
weaken t@(ListType _) (WithCtx ctx (List [] EmptyListType)) = return $ WithCtx ctx $ List [] t
-- A non-empty list can be weakened to type @t@ if
-- - @t@ is of the form @ListType elemType@
-- - Every value in the list can be weakened to type @elemType@
weaken t@(ListType elemType) texprwc@(WithCtx ctx ((List elems _))) = do
  elems' <- annotateError $ mapM (weaken elemType) elems
  return $ WithCtx ctx $ List elems' t
  where
    annotateError = left (TypeCoercionError texprwc elemType . ReasonList)
weaken t@(DictType entryTypes) texprwc@(WithCtx ctx (Dict entries _)) = do
  entries' <- mapM weakenEntry entries
  mapM_ ensureExprSatisifiesEntryType $ M.toList entryTypes
  return $ WithCtx ctx $ Dict entries' t
  where
    -- Tries to apply [DictSome] and [DictNone] rules to the entries of the dict
    weakenEntry :: (Identifier, WithCtx TypedExpr) -> Either TypeCoercionError (Identifier, WithCtx TypedExpr)
    weakenEntry (key, value) = case M.lookup key entryTypes of
      -- @key@ is missing from @typ'@ => extra keys are not allowed
      Nothing -> Left $ TypeCoercionError texprwc t (ReasonDictExtraKey key)
      -- @key@ is required and present => only need to weaken the value's type
      Just (DictRequired valueTyp) -> (key,) <$> annotateKeyTypeError key (weaken valueTyp value)
      -- @key@ is optional and present => weaken value's type + use [DictSome]
      Just (DictOptional valueTyp) -> (key,) <$> annotateKeyTypeError key (weaken valueTyp value)

    -- Checks that all DictRequired entries in typ' exist in entries
    ensureExprSatisifiesEntryType :: (Identifier, DictEntryType) -> Either TypeCoercionError ()
    ensureExprSatisifiesEntryType (key, DictOptional typ) = case lookup key entries of
      -- @key@ is optional and missing => use [DictNone]
      Nothing -> Right ()
      -- @key@ is optional and present => weaken the value's type + use [DictSome]
      Just entryVal -> void $ annotateKeyTypeError key $ weaken typ entryVal
    ensureExprSatisifiesEntryType (key, DictRequired typ) = case lookup key entries of
      -- @key@ is required and missing => not allowed
      Nothing -> Left $ TypeCoercionError texprwc t (ReasonDictNoKey key)
      -- @key@ is required and present => only need to weaken value's type
      Just entryVal -> void $ annotateKeyTypeError key $ weaken typ entryVal

    -- Wraps a ReasonDictWrongKeyType error around a type error
    annotateKeyTypeError :: String -> Either TypeCoercionError a -> Either TypeCoercionError a
    annotateKeyTypeError key = left (TypeCoercionError texprwc t . ReasonDictWrongKeyType key)
-- All other cases can not be weakened
weaken typ' expr = Left $ TypeCoercionError expr typ' ReasonUncoercable
