module MontyParser where

import Data.Char
import Data.Maybe
import Text.Megaparsec hiding (Pos)
import Text.Megaparsec.Char
import Text.Megaparsec.Char.Lexer
import Lens.Micro.Platform

import ParserTypes
import MorphUtils

rword :: String -> Parser ()
rword w = string w *> notFollowedBy alphaNumChar <* ws

sc :: Parser ()
sc = ws *> pure ()

ws :: Parser String
ws = many $ char ' '

ws1 :: Parser String
ws1 = some $ char ' '

commentEater :: Parser ()
commentEater = char '#' *> many (noneOf "\n") *> pure ()

-- TODO: Support CRLF and ;
singleEol :: Parser ()
singleEol = ws *> optional commentEater *> char '\n' *> pure ()

eol1 :: Parser ()
eol1 = singleEol <* (many $ try singleEol)

moduleParser :: Parser String
moduleParser = some $ alphaNumChar <|> char '.'

addPos :: a -> Parser (Pos a)
addPos expr = do
  pos <- getSourcePos
  pure $ Pos pos expr

assignmentParser :: Indent -> Parser PExpr
assignmentParser indent = do
  var  <- try $ (varIdParser indent <* ws <* char '=' <* ws)
  expr <- exprParser indent
  addPos $ ExprAssignment var expr

argParser :: Indent -> Parser Arg
argParser indent = choice $ try <$> [
    consArgParser, -- Order matters
    patternArgParser,
    idArgParser
  ]
  where
    idArgParser :: Parser Arg
    idArgParser = IdArg <$> varIdParser indent

    patternArgParser :: Parser Arg
    patternArgParser = do
      name <- typeIdParser indent <* ws
      args <- try (defArgParser indent) <|> pure []
      pure $ PatternArg name args

    consArgParser :: Parser Arg
    consArgParser = do
      headArg <- try $ idArgParser <* ws <* char '|' <* ws
      tailArg <- try idArgParser <|> try consArgParser
      pure $ PatternArg "Cons" [headArg, tailArg]

defArgParser :: Indent -> Parser [Arg]
defArgParser indent = multiParenParser '(' ')' (argParser indent) <* ws

typeConsArgParser :: Indent -> Parser [Id]
typeConsArgParser indent = multiParenParser '(' ')' (varIdParser indent) <* ws

namedDefParser :: Indent -> Parser PExpr
namedDefParser indent = do
  name <- try $ string "def" *> ws1 *> varIdParser indent
  args <- defArgParser indent <* char ':' <* eol1
  body <- bodyParser indent
  def  <- addPos $ ExprDef args body
  addPos $ ExprAssignment name def

consParser :: Indent -> Parser PExpr
consParser indent = do
  headExpr <- try $ exprParser' indent <* ws <* char '|' <* ws
  tailExpr <- exprParser indent
  exprId   <- addPos $ ExprId "Cons"
  addPos $ ExprCall exprId [headExpr, tailExpr]

-- Eats surrounding parens of an expr, for disambiguation
parenEater :: Parser PExpr -> Parser PExpr
parenEater innerParser =
    char '(' *> ws *> innerParser <* ws <* char ')'

-- Matches syntax of the form (anything, anything, ...)
multiParenParser :: Char -> Char -> Parser a -> Parser [a]
multiParenParser open close innerParser =
    char open *> delimWs *>
    sepBy (delimWs *> innerParser <* delimWs) (char ',')
    <* delimWs <* char close
  where
    delimWs = many $ oneOf "\t \n"

defParser :: Indent -> Parser PExpr
defParser indent = do
  args <- try $ rword "def" *> defArgParser indent <* char ':' <* eol1
  body <- bodyParser indent
  addPos $ ExprDef args body

lambdaParser :: Indent -> Parser PExpr
lambdaParser indent = do
  args <- try $ defArgParser indent <* char ':' <* ws
  body <- exprParser indent
  ret  <- addPos $ ExprReturn body
  addPos $ ExprDef args [ret]

returnParser :: Indent -> Parser PExpr
returnParser indent = try (rword "return") *>
  (ExprReturn <$> (exprParser indent) >>= addPos)

-- TODO: Support this `if foo: print('reeee')`
condBlockParser :: String -> Indent -> Parser CondBlock
condBlockParser initialKeyword indent = do
  cond <- try $ rword initialKeyword *> exprParser indent <* ws <* char ':' <* eol1
  body <- bodyParser indent <* eol1
  pure $ CondBlock cond body

ifParser :: Indent -> Parser PExpr
ifParser indent = do
    fi   <- condBlockParser "if" indent 
    file <- elifsParser
    esle <- elseParser
    addPos $ ExprIfElse fi file esle
  where
    elifsParser :: Parser [CondBlock]
    elifsParser = many (try $ condBlockParser "elif" indent)

    elseParser :: Parser [PExpr]
    elseParser =
      string indent *> rword "else" *> char ':' *> eol1 *>
      bodyParser indent

infixParser :: Indent -> Parser PExpr
infixParser indent = do
    first <- try $ exprParser' indent <* ws <* (lookAhead allOpParser)
    rest  <- many partialOpParser
    pure $ groupByPrecedence (((view _2) <$> arr)) ((Nothing, first):rest)
  where
    arr = [
        ("<>", InfixMappend),
        ("+", InfixAdd),
        ("-", InfixSub),
        ("*", InfixMul),
        ("/", InfixDiv),
        ("%", InfixMod),
        ("!=", InfixNe),
        ("==", InfixEq),
        ("is", InfixEq),
        (">", InfixGt),
        ("<", InfixLt),
        ("<=", InfixLe),
        (">=", InfixGe),
        ("and", InfixLogicAnd),
        ("or", InfixLogicOr)
      ]

    -- What a mess
    groupByPrecedence :: [InfixOp] -> [(Maybe InfixOp, PExpr)] -> PExpr
    groupByPrecedence _ [(_, x)] = x
    groupByPrecedence (o:os) xs  = joinHeadOp subCases
      where
        subCases :: [PExpr]
        subCases = groupByPrecedence os <$>
          (splitWhen ((== (Just o)) . (view _1)) xs)

        joinHeadOp :: [PExpr] -> PExpr
        joinHeadOp [y] = y
        joinHeadOp (y:ys) = foldl folderHeadOp y ys

        folderHeadOp :: PExpr -> PExpr -> PExpr
        folderHeadOp acc it = Pos (getPos it) $ ExprInfix acc o it

    opParser :: (String, InfixOp) -> Parser InfixOp
    opParser (s, o) = string s *> pure o

    allOpParser = choice $ opParser <$> arr

    partialOpParser :: Parser (Maybe InfixOp, PExpr)
    partialOpParser = do
      op  <- try $ ws *> allOpParser <* ws
      rhs <- exprParser' indent <* ws
      pure (Just op, rhs)

varIdParser :: Indent -> Parser Id
varIdParser _ = do
  x  <- char '_' <|> satisfy isLower
  xs <- many $ (char '_' <|> alphaNumChar)
  pure $ x:xs

typeIdParser :: Indent -> Parser Id
typeIdParser _ = do
  firstChar <- satisfy isUpper
  rest      <- many $ (char '_' <|> alphaNumChar)
  pure $ firstChar:rest

anyIdParser :: Indent -> Parser Id
anyIdParser indent = try (varIdParser indent) <|> typeIdParser indent

exprVarIdParser :: Indent -> Parser PExpr
exprVarIdParser indent = ExprId <$> varIdParser indent >>= addPos

exprTypeIdParser :: Indent -> Parser PExpr
exprTypeIdParser indent = ExprId <$> typeIdParser indent >>= addPos

exprTypeConsParser :: Indent -> Parser PExpr
exprTypeConsParser indent = do
  name <- ExprId <$> typeIdParser indent >>= addPos
  args <- (multiParenParser '(' ')' $ exprParser indent) <|> pure []
  addPos $ ExprCall name args

intParser :: Indent -> Parser PExpr
intParser _ = ExprInt <$> signed sc decimal >>= addPos

stringParser :: Indent -> Parser PExpr
stringParser _ = do
  startQuote <- oneOf "\"'"
  inner      <- many $ noneOf [startQuote]
  _          <- char startQuote
  addPos $ ExprString inner

-- TODO: Only allow in root scopes
classParser :: Indent -> Parser PExpr
classParser indent = do
  _ <- try $ string "class" <* ws1
  name <- typeIdParser indent
  _ <- ws <* char ':' <* eol1
  defs <- blockParser indent typeConsParser
  addPos $ ExprClass name defs

  where
    typeConsParser :: Indent -> Parser (Pos TypeCons)
    typeConsParser ind = do
      name <- typeIdParser ind <* ws
      args <- (try $ typeConsArgParser ind) <|> pure []
      addPos $ TypeCons name args

instanceParser :: Indent -> Parser PExpr
instanceParser indent = do
    name        <- try $ string "instance" *> ws1 *> typeIdParser indent
    _           <- ws1 <* string "of" <* ws1
    typeClass   <- typeIdParser indent <* ws <* char ':' <* eol1
    definitions <- blockParser indent namedDefParser
    addPos $ ExprInstanceOf name typeClass definitions

typeParser :: Indent -> Parser PExpr
typeParser indent = do
    _    <- try $ string "type" <* ws1
    name <- typeIdParser indent <* ws <* char ':' <* eol1
    body <- blockParser indent $ typeBodyParser name
    addPos $ ExprType name body
  where
    typeBodyParser :: Id -> Indent -> Parser (Pos DefSignature)
    typeBodyParser typeName ind = do
      name <- string "def" *> ws1 *> varIdParser ind
      args <- multiParenParser '(' ')' (varIdParser ind)
      addPos $ DefSignature typeName name (nameToArg <$> args)

    nameToArg :: Id -> Arg
    nameToArg "self" = SelfArg
    nameToArg  name  = IdArg name

wrapParser :: Indent -> Parser PExpr
wrapParser indent = do
  _      <- try $ string "wrap" <* ws <* char '('
  toWrap <- exprParser indent <* char ')'
  addPos $ ExprWrap toWrap

unwrapParser :: Indent -> Parser PExpr
unwrapParser indent = do
    _       <- try $ string "unwrap" <* ws <* char ':' <* eol1
    content <- blockParser indent wrappableParser
    addPos $ ExprUnwrap content
  where
    wrappableParser :: Indent -> Parser PExpr
    wrappableParser ind = wrapParser ind <|> bindParser ind

    bindParser :: Indent -> Parser PExpr
    bindParser ind = do
      varName <- try $ varIdParser ind <* ws <* string "<-" <* ws
      value   <- exprParser ind
      addPos $ ExprBind varName value

listParser :: Indent -> Parser PExpr
listParser indent =
  ExprList <$> multiParenParser '[' ']' (exprParser indent) >>= addPos

chainableParser :: Indent -> PExpr -> Parser PExpr
chainableParser indent previous =
    sugarCallParser previous <|> normalCallParser previous <|> pure previous
  where
    sugarCallParser :: PExpr -> Parser PExpr
    sugarCallParser prev = do
      _       <- char '.'
      fun     <- exprVarIdParser indent
      argList <- multiParenParser '(' ')' $ exprParser indent
      final   <- addPos $ ExprCall fun (prev:argList)
      chainableParser indent final

    normalCallParser :: PExpr -> Parser PExpr 
    normalCallParser prev = do
      argList <- multiParenParser '(' ')' $ exprParser indent
      final   <- addPos $ ExprCall prev argList
      chainableParser indent final

exprParser' :: Indent -> Parser PExpr
exprParser' indent = chainableParser indent =<< 
    (try (parenEater $ exprParser indent) <|> content)
  where
    content = choice $ ($ indent) <$> [
        instanceParser,
        unwrapParser,
        returnParser,
        classParser,
        namedDefParser,
        defParser,
        ifParser,
        typeParser,
        exprVarIdParser,
        exprTypeConsParser,
        intParser,
        listParser,
        stringParser
      ]

exprParser :: Indent -> Parser PExpr
exprParser indent = choice $ ($ indent) <$> [
    lambdaParser,
    infixParser,
    assignmentParser,
    consParser,
    exprParser'
  ]

-- Pretty epic
blockParser :: Indent -> (Indent -> Parser a) -> Parser [a]
blockParser base parser = do
    nextIndent <- (<>) <$> string base <*> ws1
    first      <- parser nextIndent <* lookAhead (singleEol <|> eof)
    rest       <- many $ stmt nextIndent
    pure $ first:rest
  where
    stmt nextIndent = (try $ eol1 *> string nextIndent) *> parser nextIndent

bodyParser :: Indent -> Parser [PExpr]
bodyParser base = blockParser base exprParser

-- import PackageName
importParser :: Parser PExpr
importParser = do
  _    <- try (rword "import")
  path <- sepBy1 (varIdParser "") (char '.')
  addPos $ ExprImport path

rootBodyParser :: Parser [PExpr]
rootBodyParser = do
    _ <- many $ try singleEol
    imports <- many (importParser <* eol1)
    _ <- many $ try singleEol
    first <- exprParser "" <* lookAhead singleEol
    rest  <- many stmt <* eof
    pure $ imports <> (first:(catMaybes rest))
  where
    stmt :: Parser (Maybe PExpr)
    stmt = try blankLine <|> something
      where
        blankLine :: Parser (Maybe PExpr)
        blankLine = eol1 *> pure Nothing

        something :: Parser (Maybe PExpr)
        something = Just <$> exprParser ""
