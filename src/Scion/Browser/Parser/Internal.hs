{-# LANGUAGE RankNTypes #-}

module Scion.Browser.Parser.Internal where

import Control.Monad
import Data.Char (isControl)
import Data.List (intercalate, last)
import qualified Data.Map as M
import Data.Maybe (maybe)
import Distribution.Package (PackageIdentifier(..), PackageName(..))
import Distribution.Version
import Language.Haskell.Exts.Annotated.Syntax
import Language.Haskell.Exts.Extension
import qualified Language.Haskell.Exts.Parser as Parser
import Scion.Browser
import Scion.Browser.Parser.Documentable
import Text.Parsec.ByteString as BS
import Text.Parsec.Char
import Text.Parsec.Combinator
import Text.Parsec.Prim

type BSParser a = forall st. BS.GenParser Char st a

hoogleParser :: BSParser (Documented Package)
hoogleParser = do spaces
                  many initialComment
                  spaces
                  pkgDoc <- docComment
                  spacesOrEol1
                  pkgName <- package
                  spacesOrEol1
                  pkgVersion <- version
                  spaces0
                  modules <- many $ try (spacesOrEol0 >> documented module_)
                  spaces
                  eof
                  return $ Package (docFromString pkgDoc)
                                   (PackageIdentifier (PackageName pkgName)
                                                      pkgVersion)
                                   (M.fromList $ map (\m -> (getModuleName m, m)) modules)

initialComment :: BSParser String
initialComment = do try $ string "-- " >> notFollowedBy (char '|')
                    restOfLine
                    eol

docComment :: BSParser String
docComment = do string "-- | "
                initialLine <- restOfLine
                restOfLines <- many $ try (eol >> string "--   ") >> restOfLine
                return $ intercalate "\n" (initialLine:restOfLines)

documented :: (Doc -> BSParser a) -> BSParser a
documented p =   try (do d <- try docComment
                         try eol
                         p (docFromString d))
             <|> try (p NoDoc)

package :: BSParser String
package = do string "@package"
             spaces1
             name <- restOfLine
             spaces0
             return name

version :: BSParser Version
version = do string "@version"
             spaces1
             number <- number `sepBy` char '.'
             restOfLine
             return $ Version number []

module_ :: Doc -> BSParser (Documented Module)
module_ doc = do string "module"
                 spaces1
                 name <- moduleName
                 spaces0
                 decls <- many $ try (spacesOrEol0 >> documented decl)
                 return $ Module doc
                                 (Just (ModuleHead NoDoc name Nothing Nothing))
                                 []
                                 []
                                 (concat decls)

moduleName :: BSParser (Documented ModuleName)
moduleName = do cons <- conid `sepBy` char '.'
                let name = intercalate "." (map getid cons)
                return $ ModuleName NoDoc name

getModuleName :: Documented Module -> String
getModuleName (Module _ (Just (ModuleHead _ (ModuleName _ name) _ _)) _ _ _) = name

decl :: Doc -> BSParser [Documented Decl]
decl doc =  choice [ listed $ function doc
                   , listed $ instance_ doc
                   , listed $ class_ doc
                   , listed $ type_ doc
                   , listedPair $ data_ doc
                   , listedPair $ newtype_ doc
                   , lonelyComment
                   ]

listed :: BSParser a -> BSParser [a]
listed p = do result <- p
              return [result]

listedPair :: BSParser (a, [a]) -> BSParser [a]
listedPair p = do (h, t) <- p
                  return (h:t)

lonelyComment :: BSParser [Documented Decl]
lonelyComment = try (docComment >> return [])

parseTypeMode :: Parser.ParseMode
parseTypeMode = Parser.ParseMode "" knownExtensions False False []

parseType :: String -> BSParser (Documented Type)
parseType st = do     
                  let -- Parse using haskell-src-exts
                      parsed = Parser.parseTypeWithMode parseTypeMode (eliminateUnwanted st)
                  case parsed of
                    Parser.ParseFailed _ e -> unexpected $ e ++ " on '" ++ st ++ "'"
                    Parser.ParseOk ty -> return $ document NoDoc ty

-- HACK: Types with ! are not parsed by haskell-src-exts
-- HACK: Control characters (like EOF) may appear
-- HACK: {-# UNPACK #-} comments and greek letters may appear
-- HACK: Greek letters may appear
eliminateUnwanted :: String -> String
eliminateUnwanted "" = ""
eliminateUnwanted ('{':('-':('#':(' ':('U':('N':('P':('A':('C':('K':(' ':('#':('-':('}': xs)))))))))))))) = eliminateUnwanted xs
eliminateUnwanted (x:xs) | x == '!'    = eliminateUnwanted xs
                         | isControl x = eliminateUnwanted xs
                         | x == 'α'    = 'a' : (eliminateUnwanted xs)
                         | x == 'β'    = 'b' : (eliminateUnwanted xs)
                         | x == 'γ'    = 'c' : (eliminateUnwanted xs)
                         | x == 'δ'    = 'd' : (eliminateUnwanted xs)
                         | otherwise   = x : (eliminateUnwanted xs)

functionLike :: BSParser (Documented Name) -> BSParser (Documented Name, Documented Type)
functionLike p = do name <- p
                    spaces0
                    string "::"
                    spaces0
                    rest <- restOfLine
                    ty <- parseType rest
                    return (name, ty)

function :: Doc -> BSParser (Documented Decl)
function doc = do (name, ty) <- functionLike varid
                  return $ TypeSig doc [name] ty

constructor :: Doc -> BSParser (Documented GadtDecl)
constructor doc = do (name, ty) <- functionLike conid
                     return $ GadtDecl doc name ty

constructorOrFunction :: Doc -> BSParser (Either (Documented Decl) (Documented GadtDecl))
constructorOrFunction doc = do f <- function doc
                               return $ Left f
                            <|>
                            do c <- constructor doc
                               return $ Right c

kind :: BSParser (Documented Kind)
kind = try (do k1 <- kindL
               spaces0
               string "->"
               spaces0
               k2 <- kind
               return $ KindFn NoDoc k1 k2)
       <|> kindL

kindL :: BSParser (Documented Kind)
kindL = (do char '('
            spaces0
            k <- kind
            spaces0
            char ')'
            return $ KindParen NoDoc k)
        <|>
        (do char '*'
            return $ KindStar NoDoc)
        <|>
        (do char '!'
            return $ KindBang NoDoc)
        <|>
        (do n <- varid
            return $ KindVar NoDoc n)

instance_ :: Doc -> BSParser (Documented Decl)
instance_ doc = do string "instance"
                   -- HACK: in some Hoogle files things like [overlap ok] appear
                   optional $ try (do spaces0
                                      char '['
                                      many $ noneOf "]\r\n"
                                      char ']')
                   spaces1
                   rest <- restOfLine
                   ty' <- parseType rest
                   let (ctx, ty) = getContextAndType ty'
                       ((TyCon _ qname):params) = lineariseType ty
                   return $ InstDecl doc ctx (IHead NoDoc qname params) Nothing

type_ :: Doc -> BSParser (Documented Decl)
type_ doc = do string "type"
               spaces1
               con <- conid
               vars <- many (try (spaces1 >> tyVarBind))
               spaces0
               char '='
               spaces0
               rest <- restOfLine
               ty <- parseType rest
               return $ TypeDecl doc (DHead NoDoc con vars) ty

tyVarBind :: BSParser (Documented TyVarBind)
tyVarBind = (do char '('
                spaces0
                var <- varid
                spaces0
                string "::"
                spaces0
                k <- kind
                spaces0
                char ')'
                return $ KindedVar NoDoc var k)
            <|>
            (do var <- varid
                return $ UnkindedVar NoDoc var)

-- Here we return not only the datatype or newtype,
-- but also functions around them, that are put
-- between constructors when using record syntax.
dataOrNewType :: String -> (Documented DataOrNew) -> Doc -> BSParser (Documented Decl, [Documented Decl])
dataOrNewType keyword dOrN doc = do string keyword
                                    spaces0
                                    rests <- many1 possibleKind
                                    let rest = concat $ map fst rests
                                        k = snd (last rests)
                                    {- rest <- many $ allButDoubleColon
                                    k <- optionMaybe (do string "::"
                                                         spaces0
                                                         kind) -}
                                    ty <- parseType rest
                                    let (ctx, head) = typeToContextAndHead ty
                                    consAndFns <- many $ try (spacesOrEol0 >> documented constructorOrFunction)
                                    let (fns, cons) = divideConstructorAndFunctions consAndFns
                                    return $ (GDataDecl doc dOrN ctx head k cons Nothing, fns)

divideConstructorAndFunctions :: [Either (Documented Decl) (Documented GadtDecl)] -> ([Documented Decl], [Documented GadtDecl])
divideConstructorAndFunctions []     = ([], [])
divideConstructorAndFunctions (x:xs) = let (fns, cons) = divideConstructorAndFunctions xs
                                       in  case x of
                                             Left fn   -> (fn:fns, cons)
                                             Right con -> (fns, con:cons)

possibleKind :: BSParser (String, Maybe (Documented Kind))
possibleKind = do rest <- many1 $ allButDoubleColon
                  k <- optionMaybe (do string "::"
                                       spaces0
                                       kind)
                  return (rest, k)

allButDoubleColon :: BSParser Char
allButDoubleColon = try (do char ':'
                            notFollowedBy $ char ':'
                            return ':')
                    <|> (noneOf ":\r\n")

data_ :: Doc -> BSParser (Documented Decl, [Documented Decl])
data_ = dataOrNewType "data" (DataType NoDoc)

newtype_ :: Doc -> BSParser (Documented Decl, [Documented Decl])
newtype_ = dataOrNewType "newtype" (NewType NoDoc)

class_ :: Doc -> BSParser (Documented Decl)
class_ doc = do string "class"
                spaces0
                rest <- many $ allButWhereColonPipe
                fd' <- optionMaybe (do string "|"
                                       spaces0
                                       iFunDep <- funDep
                                       rFunDep <- many $ try (spaces0 >> char ',' >> spaces0 >> funDep)
                                       return $ iFunDep:rFunDep)
                -- HACK: if a type family is introduced here, just discard it
                optional $ string "where" >> restOfLine
                -- HACK: in some Hoogle files, kinds are added to the class
                optional $ string "::" >> restOfLine
                ty <- parseType rest
                let (ctx, head) = typeToContextAndHead ty
                    fd = maybe [] id fd'
                return $ ClassDecl doc ctx head fd Nothing

allButWhereColonPipe :: BSParser Char
allButWhereColonPipe = try (do char ':'
                               notFollowedBy $ char ':'
                               return ':')
                        <|>
                        try (do char 'w'
                                notFollowedBy $ string "here"
                                return 'w')
                        <|> (noneOf "w|:\r\n")               

funDep :: BSParser (Documented FunDep)
funDep = do iVarLeft <- varid
            rVarLeft <- many $ try (spaces1 >> varid)
            spaces0
            string "->"
            spaces0
            iVarRight <- varid
            rVarRight <- many $ try (spaces1 >> varid)
            return $ FunDep NoDoc (iVarLeft:rVarLeft) (iVarRight:rVarRight)

{-
qualifiedVarid :: BSParser [String]
qualifiedVarid =    do id <- varid
                       return [id]
               <|>  do mod <- many1 (do m <- conid
                                        char '.'
                                        return m)
                       id <- varid
                       return $ mod ++ [id]

qualifiedConid :: BSParser [String]
qualifiedConid = conid `sepBy` char '.'
-}

varid :: BSParser (Documented Name)
varid = try (do initial <- lower <|> char '_'
                rest <- many $ alphaNum <|> oneOf allowedSpecialCharactersInIds
                let id = initial:rest
                guard $ not (id `elem` haskellKeywords)
                return $ Ident NoDoc id)
        <|> 
        try (do initial <- oneOf (tail specialCharacters)
                rest <- many (oneOf specialCharacters)
                let id = initial:rest
                guard $ not (id `elem` haskellReservedOps)
                return $ Symbol NoDoc id)
        <|>
        try (do char '('
                id <- varid
                char ')'
                return id)

conid :: BSParser (Documented Name)
conid = (do initial <- upper
            rest <- many $ alphaNum <|> oneOf allowedSpecialCharactersInIds
            return $ Ident NoDoc (initial:rest))
        <|> 
        try (do initial <- char ':'
                rest <- many (oneOf specialCharacters)
                let id = initial:rest
                guard $ not (id `elem` haskellReservedOps)
                return $ Symbol NoDoc id)
        <|>
        try (do char '('
                id <- conid
                char ')'
                return id)

getid :: Documented Name -> String
getid (Ident _ s)  = s
getid (Symbol _ s) = '(' : (s ++ ")" )

haskellKeywords :: [String]
haskellKeywords = [ "case", "class", "data", "default", "deriving", "do"
                  , "else", "foreign", "if", "import", "in", "infix", "infixl"
                  , "infixr", "instance", "let", "module", "newtype", "of"
                  , "then", "type", "where", "_" ]

haskellReservedOps :: [String]
haskellReservedOps = [ "..", ":",  "::",  "=",  "\\", "|", "<-", "->", "@", "~", "=>" ]

allowedSpecialCharactersInIds :: [Char]
allowedSpecialCharactersInIds = "_'-[]#"

specialCharacters :: [Char]
specialCharacters = ":!#$%&*+./<=>?@\\^|-~"

restOfLine :: BSParser String
restOfLine = many $ noneOf "\r\n"

eol :: BSParser String
eol =   try (string "\r\n")
    <|> try (string "\r")
    <|> string "\n"
    -- <|> (lookAhead eof >> return "\n")
    <?> "new line"

number :: BSParser Int
number = do n <- many1 digit
            return $ read n

spaces0 :: BSParser String
spaces0 = many $ char ' '

spaces1 :: BSParser String
spaces1 = many1 $ char ' '

spacesOrEol0 :: BSParser String
spacesOrEol0 = many $ oneOf " \r\n\t"

spacesOrEol1 :: BSParser String
spacesOrEol1 = many1 $ oneOf " \r\n\t"

-- working with types

getContextAndType :: (Documented Type) -> (Maybe (Documented Context), Documented Type)
getContextAndType (TyForall _ _ ctx ty) = (ctx, ty)
getContextAndType ty                    = (Nothing, ty)

lineariseType :: Documented Type -> [Documented Type]
lineariseType (TyApp d x y) = (lineariseType x) ++ [y]
lineariseType ty            = [ty]

typeToContextAndHead :: (Documented Type) -> (Maybe (Documented Context), Documented DeclHead)
typeToContextAndHead t = let (ctx, ty) = getContextAndType t
                             ((TyCon _ (UnQual _ name)):params) = lineariseType ty
                             vars = toKindedVars params
                         in  (ctx, DHead NoDoc name vars)

toKindedVars []         = []
toKindedVars ((TyVar d (Ident _ n1)):( (TyList _ (TyVar _ (Ident _ n2))): xs )) =
  (UnkindedVar d (Ident NoDoc $ n1 ++ "[" ++ n2 ++ "]")) : toKindedVars xs
toKindedVars ((TyVar d n):xs) = (UnkindedVar d n) : toKindedVars xs
toKindedVars (x:xs)           = error $ show x
