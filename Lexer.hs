{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE FlexibleInstances #-}
module Lexer where
import Data.List
import Control.Applicative
import Data.Char

data Error = Error Int Int String

instance Eq Error where
  (==) (Error line col m) (Error line' col' m') =  line == line' && col == col'

instance Ord Error where
  (Error line col m) `compare` (Error line' col' m') = if line == line' then compare col col' else compare line line'

instance Show Error where
       show (Error line col message) = message ++ ", on line: " ++show line ++ " and character: " ++ show col 

instance Alternative (Either Error) where
  empty = Left $ Error 0 0 ""
  Left x <|> Left y = Left $ max x y
  Left _ <|> e2 = e2
  e1 <|> _ = e1


newtype Code = Code [(Char, Int, Int)]
  deriving (Show, Eq)

data Token
  = VarToken | IntToken Integer | BoolToken Bool| CharToken Char
  | TypeIntToken| TypeBoolToken| TypeCharToken
  | SemiColToken| CommaToken| IsToken
  | FunTypeToken| ArrowToken| VoidToken| ReturnToken
  | EmptyListToken| BrackOToken| BrackCToken| CBrackOToken| CBrackCToken| SBrackOToken| SBrackCToken
  | HdToken| TlToken| FstToken| SndToken| IsEmptyToken
  | PlusToken| MinToken| MultToken| DivToken| ModToken 
  | EqToken| LeToken | GeToken | LeqToken | GeqToken| NeqToken| AndToken| OrToken| ConstToken| NotToken
  | IdToken String
  | IfToken| ElseToken| WhileToken
  deriving (Eq)
instance Show Token where
  show VarToken = "var"
  show (IntToken x) = show x
  show (BoolToken x) = show x
  show (CharToken x) = show x
  show TypeIntToken = "Int"
  show TypeBoolToken = "Bool"
  show TypeCharToken = "Char"
  show SemiColToken = ";"
  show CommaToken = ","
  show IsToken = "="
  show FunTypeToken = "::"
  show ArrowToken = "->"
  show VoidToken = "Void"
  show ReturnToken = "return"
  show EmptyListToken = "[]"
  show BrackOToken = "("
  show BrackCToken = ")"
  show CBrackCToken = "}"
  show CBrackOToken = "{"
  show SBrackCToken = "]"
  show SBrackOToken = "["
  show HdToken = ".hd"
  show TlToken = ".tl"
  show FstToken = ".fst"
  show SndToken = ".snd"
  show IsEmptyToken = ".isEmpty"
  show PlusToken = "+"
  show MinToken = "-"
  show MultToken = "*"
  show DivToken = "/"
  show ModToken = "%"
  show EqToken = "=="
  show LeToken = "<"
  show GeToken = ">"
  show LeqToken = "<="
  show GeqToken = ">="
  show NeqToken = "!="
  show AndToken = "&&"
  show OrToken = "||"
  show ConstToken = ":"
  show NotToken = "!"
  show (IdToken x) = "id["++x++"]"
  show IfToken = "if"
  show ElseToken = "else"
  show WhileToken = "while"

stringToCode x = Code <$> concat $ zipWith (\s line -> zip3 s (repeat line) [1 ..]) (lines x) [1 ..]

alphaCheck :: [Char] -> Bool
alphaCheck xs = null xs || not (isAlphaNum (head xs))

acTokens = [VarToken, ReturnToken, VoidToken, BoolToken True, BoolToken False, TypeBoolToken, TypeIntToken, TypeCharToken, IfToken, ElseToken, WhileToken, 
            HdToken, TlToken, FstToken, SndToken, IsEmptyToken]
tokens = [EmptyListToken, BrackOToken,BrackCToken,CBrackOToken,CBrackCToken,SBrackOToken,SBrackCToken,FunTypeToken,ArrowToken,SemiColToken,EqToken,LeqToken,GeqToken,
          NotToken,AndToken,OrToken,IsToken,PlusToken,MinToken,MultToken,DivToken,ModToken,LeToken,GeToken,ConstToken,NotToken,CommaToken]

runTokenise :: String -> Either Error [(Token, Int, Int)]
runTokenise x = tokenise x 0 0

tokenise:: String -> Int -> Int -> Either Error [(Token, Int, Int)]
tokenise ('/' : '*' : xs) line col = gulp xs line col
  where
    gulp ('*' : '/' : rest) line col = tokenise rest line (col + 2)
    gulp (c : rest) line col = gulp rest line (col + 1)
    gulp [] line col = Right []
tokenise ('/' : '/' : xs) line col = tokenise (dropWhile (/= '\n') xs) (line + 1) 0
tokenise (' ' : xs) line col = tokenise xs line (col + 1)
tokenise ('\t' : xs) line col = tokenise xs line (col + 2)
tokenise ('\n' : xs) line col = tokenise xs (line + 1) 0
tokenise ('\'' : x : '\'' : xs) line col = ((CharToken x, line, col) :) <$> tokenise xs line (col + 3)
tokenise input line col = tokenise2 acTokens tokens input line col


tokenise2 :: [Token] -> [Token] -> String -> Int -> Int -> Either Error [(Token, Int, Int)]
tokenise2 (at:art) ts (stripPrefix (show at) -> Just rc) l c | alphaCheck rc =  ((at, l, c) :) <$> tokenise rc l (c + length (show at))
tokenise2 (at:art) ts x l c = tokenise2 art ts x l c
tokenise2 ats (t:rt) (stripPrefix (show t) -> Just rc) l c =  ((t, l, c) :) <$> tokenise rc l (c + length (show t))
tokenise2 ats (t:rt) x l c = tokenise2 ats rt x l c

tokenise2 _ _ (c : xs) line col
  | isSpace c = tokenise xs line (col+1)
  | isDigit c = spanToken isDigit line col (IntToken . read) (c : xs)
  | isAlpha c = spanToken (\c -> isAlphaNum c || c == '_') line col IdToken (c : xs)
  | otherwise = Left $ Error line col ("Unrecognized character: " ++ show c)

tokenise2 _ _ [] line col = Right []

spanToken ::  (Char -> Bool) -> Int -> Int -> ([Char] -> Token) -> [Char] -> Either Error [(Token, Int, Int)]
spanToken p line col t = (\(ds, rest) -> ((t ds, line, col) :) <$> tokenise rest line (col + length ds)) . span p
