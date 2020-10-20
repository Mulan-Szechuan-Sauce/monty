module ModuleLoader (loadModule) where

import System.Directory
import System.Exit
import System.FilePath
import Data.List
import Control.Monad.State.Strict
import Text.Megaparsec

import ParserTypes
import RunnerTypes
import RunnerUtils
import Parser.Root

loadModule :: [String] -> Scoper ()
loadModule components = do
    isFile <- liftIO $ doesFileExist (path <> ".my")
    isDir  <- liftIO $ doesDirectoryExist path

    if isFile then
      loadFiles [path <> ".my"]
    else if isDir then do
      content <- (liftIO $ listDirectory path)
      loadFiles $ constructPath <$> filter isMontyFile content
    else
      stackTrace $ "Could not find module " <> intercalate "." components
  where
    path = intercalate [pathSeparator] components
    constructPath = (<>) $ path <> [pathSeparator]
    isMontyFile = (== ".my") . takeExtension

loadFiles :: [FilePath] -> Scoper ()
loadFiles paths = do
    sequence_ (loadFile <$> paths)
    pure ()
  where
    parseFromFile p file = runParser p file <$> readFile file

    evalPNotMain :: PExpr -> Scoper Value
    evalPNotMain (Pos _ (ExprAssignment (IdArg "__main__") _)) = pure voidValue
    evalPNotMain other = evalP other

    loadFile :: String -> Scoper ()
    loadFile path = do
      parsed <- liftIO $ parseFromFile rootBodyParser path

      case parsed of
        (Right exprs) -> (sequence $ evalPNotMain <$> exprs) *> pure ()
        (Left a) -> liftIO $ die $ errorBundlePretty a
