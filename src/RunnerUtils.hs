module RunnerUtils where

import Debug.Trace
import Data.List (intercalate)
import qualified Data.HashMap.Strict as HM
import Control.Monad.State.Strict
import System.Exit
import RunnerTypes
import ParserTypes

runtimeError :: String -> Scoper a
runtimeError message = do
  _ <- lift $ die message
  -- Will never get reached, but hey, it fixes compiler errors
  undefined

typeOfValue :: Value -> String
typeOfValue (VInt _)                = "Int"
typeOfValue (VString _)             = "String"
typeOfValue (VBoolean _)            = "Bool"
typeOfValue (VFunction _)           = "Function" -- TODO: Become a signature
typeOfValue (VTypeCons _ _)         = "TypeCons"
typeOfValue (VTypeDef _ _)          = "TypeDef"
typeOfValue (VTypeFunction _ _ _ _) = "Function" -- TODO: Become a signature
typeOfValue (VScoped val _)         = typeOfValue val
typeOfValue (VClass)                = "Class"
typeOfValue (VList [])              = "List()"
typeOfValue (VList (x:_))           = "List(" <> typeOfValue x <> ")"
typeOfValue (VDict)                 = "Dict"
typeOfValue (VTuple)                = "Tuple"
typeOfValue (VTypeInstance typeName values) =
  typeName <> "(" <> intercalate "," (typeOfValue <$> values) <> ")"

-- TODO: Don't allow overriding of values in top scope
addToScope :: String -> Value -> Scoper ()
addToScope key value = modify addToScope'
  where
    addToScope' (topScope:lowerScopes) = newTop:lowerScopes
      where newTop = HM.insert key value topScope
    addToScope' [] = undefined

unionTopScope :: [(Id, Value)] -> Scoper ()
unionTopScope = modify . unionTopScope' . HM.fromList
  where
    unionTopScope' new (topScopeBlock:bottomBlocks) =
      (HM.union new topScopeBlock):bottomBlocks
    unionTopScope' _ [] = undefined

-- Returns the value for the given key, and the scope block where it is defined
findInScope :: String -> Scoper (Maybe (Value, Scope))
findInScope = gets . findInScope'
  where
    findInScope' _ [] = Nothing
    findInScope' key (top:lower) =
      case HM.lookup key top of
        Nothing    -> findInScope' key lower
        Just value -> Just (value, top:lower)

findInTopScope :: String -> Scoper (Maybe Value)
findInTopScope = gets . findInScope'
  where
    findInScope' key (top:_) = HM.lookup key top
    findInScope' _ _         = Nothing

pushScopeBlock :: ScopeBlock -> Scoper ()
pushScopeBlock block = do
  scope <- get
  put (block:scope)

pushEmptyScopeBlock :: Scoper ()
pushEmptyScopeBlock = pushScopeBlock HM.empty

popScopeBlock :: Scoper ()
popScopeBlock = do
  scopes <- get
  case scopes of 
    []     -> pure ()
    (_:xs) -> put xs

scoperAssert :: Bool -> String -> Scoper ()
scoperAssert False message = runtimeError message
scoperAssert True _ = pure ()

runScopeWithSetup :: Scoper () -> Scoper Value -> Scoper Value
runScopeWithSetup scopeSetup body = do
  previousScope <- get
  scopeSetup
  retVal <- body
  put previousScope
  pure retVal

runWithScope :: Scope -> Scoper Value -> Scoper Value
runWithScope = runScopeWithSetup . put

runWithTempScope :: Scoper Value -> Scoper Value
runWithTempScope = runScopeWithSetup pushEmptyScopeBlock