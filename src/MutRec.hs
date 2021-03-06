{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
module MutRec where

import Data.Graph as Graph

import GHC.Arr

import Error
import Parser
import AST
 
import System.Exit
import Debug.Trace

class SPLGraph a where
    toGraph :: a -> [(Decl, IDLoc, [IDLoc])]

class Callees a where 
    getCallees :: a -> [IDLoc]

instance SPLGraph a => SPLGraph [a] where
    toGraph [] = []
    toGraph (x:xs) = toGraph x ++ toGraph xs

instance Callees a => Callees [a] where
    getCallees [] = []
    getCallees (x:xs) = getCallees x ++ getCallees xs

instance SPLGraph SPL where
    toGraph (SPL []) = []
    toGraph (SPL x) = toGraph x
 
instance SPLGraph Decl where
    toGraph (VarMain (VarDeclVar id e)) = [(VarMain  $ VarDeclVar id e, id, getCallees e)]
    toGraph (VarMain (VarDeclType t id e)) = [(VarMain $ VarDeclType t id e, id, getCallees e)]
    toGraph (FuncMain (FunDecl id args t d s)) = let fd = FunDecl id args t d s in [(FuncMain fd, id, getCallees fd)]

instance Callees Decl where
    getCallees (VarMain e) = getCallees e
    getCallees (FuncMain e) = getCallees e

instance Callees FunDecl where
    getCallees (FunDecl _ _ _ vs stmts) = getCallees vs ++ getCallees stmts

instance Callees VarDecl where
    getCallees (VarDeclVar _ e) = getCallees e
    getCallees (VarDeclType _ _ e) = getCallees e
    
instance Callees Stmt where
    getCallees (StmtIf e xs (Just ys) _) = getCallees e ++ getCallees xs ++ getCallees ys
    getCallees (StmtIf e xs Nothing _) = getCallees e ++ getCallees xs
    getCallees (StmtWhile e xs _) = getCallees e ++ getCallees xs
    getCallees (StmtAssignVar id _ e _) = id:getCallees e
    getCallees (StmtFuncCall (FunCall _ id e _ _) _) = id:getCallees e
    getCallees (StmtReturn (Just e) _) = getCallees e
    getCallees (StmtReturn Nothing _) = []

instance Callees Exp where
    getCallees (ExpFunCall (FunCall _ id e _ _) ) = id : getCallees e
    getCallees (ExpOp2 _ e1 op e2 _) = getCallees e1 ++ getCallees e2
    getCallees (ExpOp1 _ op e _) = getCallees e
    getCallees (ExpBracket e) = getCallees e
    getCallees (ExpList _ e _ _) = getCallees e
    getCallees (ExpTuple _ (e1, e2) _ _) = getCallees e1 ++ getCallees e2
    getCallees (ExpId id fields) = [id]
    getCallees _ = []

removeMutRec :: [Decl] -> [Decl]
removeMutRec (MutRec x:xs) = (FuncMain <$> x) ++ removeMutRec xs 
removeMutRec [] = []
removeMutRec (x:xs) = x:removeMutRec xs

showSCC :: [SCC (Decl, String, [String])] -> IO()
showSCC [] = return ()
showSCC [x] = print x
showSCC (x:xs) = do
    print x
    showSCC xs

getCyclics :: [SCC (Decl, String, [String])] -> [SCC (Decl, String, [String])]
getCyclics ((CyclicSCC x):xs) = CyclicSCC x : getCyclics xs
getCyclics (_:xs) = getCyclics xs
getCyclics [] = []

fromGraph :: [SCC (Decl, IDLoc, [IDLoc])]  -> Either Error SPL
fromGraph [] = return (SPL [])
fromGraph (AcyclicSCC (x,_,_):xs) = do
    (SPL second) <- fromGraph xs
    return (SPL $ x:second)
fromGraph (CyclicSCC ys:xs) = do
    (SPL second) <- fromGraph xs
    decl <- castCyclicToMutRec ys
    return (SPL (decl:second))

castCyclicToMutRec :: [(Decl, IDLoc, [IDLoc])] -> Either Error Decl
castCyclicToMutRec ys | onlyFuncMain ys =
     Right $ MutRec (map (\(FuncMain f,_,_) -> f) ys)
castCyclicToMutRec _ =
     Left $ Error defaultLoc "Mutual recursion between variables detected. This is not allowed."

onlyFuncMain :: [(Decl, IDLoc, [IDLoc])] -> Bool
onlyFuncMain [] = True
onlyFuncMain ((VarMain x,_,_):xs) = False
onlyFuncMain ((FuncMain x,_,_):xs) = onlyFuncMain xs
onlyFuncMain ((MutRec x,_,_):xs) = False

-- ===== Remove dead code =====
removeDeadCode :: SPL -> Either Error SPL
removeDeadCode nodes = do
    let (graph, getNode, getVertex) = graphFromEdges $ toGraph nodes
    case getVertex (ID defaultLoc "main" defaultLoc) of
        Nothing -> Left $ Error defaultLoc "Required main function not found."
        Just mainVertex -> 
            let code = reachable graph mainVertex 
            in Right nodes


mainMutRecToIO :: String -> IO()
mainMutRecToIO filename = do
       file <- readFile $ "../SPL_test_code/"++filename
       case tokeniseAndParse mainSegments file of
        --    Right (x,xs) -> let (g, v, f) = graphFromEdges $ toGraph x in print $ scc g
            Right (x,xs) -> do
                let Right spl = fromGraph $ stronglyConnCompR $ toGraph x
                putStr $ pp spl
            Left x -> print x

mainMutRecToFile :: String -> IO()
mainMutRecToFile filename = do
       file <- readFile $ splFilePath++filename
       case tokeniseAndParse mainSegments file of 
                Right (x, _) -> do
                    let Right spl = fromGraph $ stronglyConnCompR $ toGraph x
                    writeFile "../SPL_test_code/out.spl" $ pp spl
                Left x -> do
                    print x
                    exitFailure

mutRec :: SPL -> Either Error SPL
mutRec code = do
    fromGraph $ stronglyConnCompR $ toGraph code