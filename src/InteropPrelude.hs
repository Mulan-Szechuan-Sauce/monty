{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
module InteropPrelude (preludeDefinitions) where

import Control.Monad.State.Strict

import ParserTypes
import PrettyPrint
import TypeUtils
import RunnerTypes
import RunnerUtils
import CallableUtils
import Data.Foldable (foldrM)
import Data.Char (ord, chr)

debugImpl :: [Value] -> Scoper Value
debugImpl [input] = do
  liftIO $ putStrLn $ prettyPrint input
  pure input

-- Zero or more
manyImpl :: [Value] -> Scoper Value
manyImpl [value] = do
    undefined
  where
    noneV :: Scoper Value
    noneV = pure $ VList []

    oneV :: Value -> Scoper Value
    oneV val = pure $ VList [val]

-- #     many :: f a -> f [a]
-- #     many v = many_v
-- #       where
-- #         many_v = some_v <|> pure []
-- #         some_v = liftA2 (:) v many_v

consMapImpl :: [Value] -> Scoper Value
consMapImpl [x, (VList xs), func] = do
    ranHead <- runFun func [x]
    ranTail <- sequence $ ree ranHead <$> xs
    pure $ VList (ranHead:ranTail)
  where
    ree :: Value -> Value -> Scoper Value
    ree headVal el = do
      ranEl <- runFun func [el]
      if typesEqual headVal ranEl
        then pure ranEl
        else stackTrace $
            "A mapped function must always return the same type" <>
            show headVal <> "," <> show ranEl

nilMapImpl :: [Value] -> Scoper Value
nilMapImpl _ = pure $ VList []

consFoldlImpl :: [Value] -> Scoper Value
consFoldlImpl [x, (VList xs), initial, folder] =
    foldM nativeFolder initial (x:xs)
  where
    nativeFolder :: Value -> Value -> Scoper Value
    nativeFolder acc it = runFun folder [acc, it]

nilFoldlImpl :: [Value] -> Scoper Value
nilFoldlImpl [initial, _] = pure initial

consFoldrImpl :: [Value] -> Scoper Value
consFoldrImpl [x, (VList xs), initial, folder] =
    foldrM nativeFolder initial (x:xs)
  where
    nativeFolder :: Value -> Value -> Scoper Value
    nativeFolder it acc = runFun folder [it, acc]

nilFoldrImpl :: [Value] -> Scoper Value
nilFoldrImpl [initial, _] = pure initial

consLenImpl :: [Value] -> Scoper Value
consLenImpl [x, (VList xs)] = pure $ VInt $ length (x:xs)

nilLenImpl :: [Value] -> Scoper Value
nilLenImpl [] = pure $ VInt 0

consBindImpl :: [Value] -> Scoper Value
consBindImpl [consHead, consTail, func] = do
    mapped <- consMapImpl [consHead, consTail, func]
    case mapped of
      VList values -> joinValues values
      _            -> stackTrace "Result of map in bind wasn't a list"
  where
    unList :: Value -> Scoper [Value]
    unList (VList vals)               = pure vals
    unList (VInferred "wrap" _ [val]) = pure [val]
    unList _ = stackTrace "Result of bind on list must be a list"

    joinValues :: [Value] -> Scoper Value
    joinValues values = do
      vals <- sequence $ unList <$> values
      pure $ VList $ join vals

nilBindImpl :: [Value] -> Scoper Value
nilBindImpl [_] = pure $ VList []

listWrapImpl :: [Value] -> Scoper Value
listWrapImpl [value] = pure $ VList [value]

consImpl :: [Value] -> Scoper Value
consImpl [cHead, (VList cTail)] = pure $ VList (cHead:cTail)

listAppendImpl :: [Value] -> Scoper Value
listAppendImpl [first@(VList xs), second@(VList ys)] = do
  assert (typesEqual first second) "Lists must be of the same type"
  pure $ VList (xs <> ys)
listAppendImpl _ = stackTrace "You must append a list to a list"

listMemptyImpl :: [Value] -> Scoper Value
listMemptyImpl [] = pure $ VList []

intCompareImpl :: [Value] -> Scoper Value
intCompareImpl [(VInt first), (VInt second)] =
  pure $ ordToVal $ compare first second

intStrImpl :: [Value] -> Scoper Value
intStrImpl [(VInt value)] = pure $ VList $ VChar <$> show value

intChrImpl :: [Value] -> Scoper Value
intChrImpl [(VInt val)] = pure $ VChar $ chr val

intIntImpl :: [Value] -> Scoper Value
intIntImpl [(VList vals)] = pure $ VInt $ read $ toStr vals
  where
    toStr :: [Value] -> String
    toStr vals = vChr <$> vals

charCompareImpl :: [Value] -> Scoper Value
charCompareImpl [(VChar first), (VChar second)] =
  pure $ ordToVal $ compare first second

charStrImpl :: [Value] -> Scoper Value
charStrImpl v@[(VChar _)] = pure $ VList v

charEqualsImpl :: [Value] -> Scoper Value
charEqualsImpl [(VChar first), (VChar second)] =
  pure $ toBoolValue (first == second)

charOrdImpl :: [Value] -> Scoper Value
charOrdImpl [(VChar val)] = pure $ VInt $ ord val

ordToVal :: Ordering -> Value
ordToVal a = VTypeInstance "Ordering" (show a) []

listDefinitions :: [(Id, Id, [FunctionCase])]
listDefinitions = [
    ("List", "map", [
        generateInteropCase
          [PatternArg "Cons" [IdArg "head", IdArg "tail"], IdArg "func"]
          consMapImpl,
        generateInteropCase
          [PatternArg "Nil" [], IdArg "func"]
          nilMapImpl
    ]),
    ("List", "foldl", [
        generateInteropCase
          [PatternArg "Cons" [IdArg "head", IdArg "tail"],
           IdArg "initial",
           IdArg "folder"]
          consFoldlImpl,
        generateInteropCase
          [PatternArg "Nil" [],
           IdArg "initial",
           IdArg "folder"]
          nilFoldlImpl
    ]),
    ("List", "foldr", [
        generateInteropCase
          [PatternArg "Cons" [IdArg "head", IdArg "tail"],
           IdArg "initial",
           IdArg "folder"]
          consFoldrImpl,
        generateInteropCase
          [PatternArg "Nil" [],
           IdArg "initial",
           IdArg "folder"]
          nilFoldrImpl
    ]),
    ("List", "len", [
        generateInteropCase
          [PatternArg "Cons" [IdArg "head", IdArg "tail"]]
          consLenImpl,
        generateInteropCase
          [PatternArg "Nil" []]
          nilLenImpl
    ]),
    ("List", "bind", [
        generateInteropCase
          [PatternArg "Cons" [IdArg "head", IdArg "tail"],
           IdArg "func"]
          consBindImpl,
        generateInteropCase
          [PatternArg "Nil" [],
           IdArg "func"]
          nilBindImpl
    ]),
    ("List", "wrap", [
        generateInteropCase
          [IdArg "val"]
          listWrapImpl
    ]),
    ("List", "append", [
        generateInteropCase
          [TypedIdArg "first" "List", TypedIdArg "second" "List"]
          listAppendImpl
    ]),
    ("List", "mempty", [
        generateInteropCase
          []
          listMemptyImpl
    ]),
    ("List", "Nil", [generateInteropCase [] (const . pure $ VList [])]),
    ("List", "Cons", [generateInteropCase [IdArg "head", IdArg "tail"] consImpl])
  ]

intDefinitions :: [(Id, Id, [FunctionCase])]
intDefinitions = [
    ("Int", "compare", [
        generateInteropCase
          [TypedIdArg "first" "Int", TypedIdArg "second" "Int"]
          intCompareImpl
    ]),
    ("Int", "str", [
        generateInteropCase
          [TypedIdArg "value" "Int"]
          intStrImpl
    ]),
    ("Int", "chr", [
        generateInteropCase
          [TypedIdArg "value" "Int"]
          intChrImpl
    ]),
    ("List", "int", [
        generateInteropCase
          [TypedIdArg "value" "List"]
          intIntImpl
    ])
  ]

charDefinitions :: [(Id, Id, [FunctionCase])]
charDefinitions = [
    ("Char", "compare", [
        generateInteropCase
          [TypedIdArg "first" "Char", TypedIdArg "second" "Char"]
          charCompareImpl
    ]),
    ("Char", "str", [
        generateInteropCase
          [TypedIdArg "value" "Char"]
          charStrImpl
    ]),
    ("Char", "equals", [
        generateInteropCase
          [TypedIdArg "first" "Char", TypedIdArg "second" "Char"]
          charEqualsImpl
    ]),
    ("Char", "ord", [
        generateInteropCase
          [TypedIdArg "val" "Char"]
          charOrdImpl
    ])
  ]

miscDefinitions :: [(Id, Id, [FunctionCase])]
miscDefinitions = [
    ("Any", "debug", [generateInteropCase [IdArg "value"] debugImpl])
    --("Any", "many",  [generateInteropCase [IdArg "value"] manyImpl])
  ]

preludeDefinitions :: [(Id, Id, [FunctionCase])]
preludeDefinitions =
  listDefinitions <> intDefinitions <> charDefinitions <> miscDefinitions
