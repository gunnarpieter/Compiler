module TIMul where

import Error
import Lexer
import AST
import Parser
import MutRec

import Data.Map as Map
import Data.Set as Set
import Data.Maybe

import Data.These

import Control.Applicative
import Control.Monad.Reader
import Control.Monad.Except
import Control.Monad.Chronicle
import Control.Monad.State
import System.Exit
import System.Directory

import Debug.Trace

-- ===================== Type inference data types ============================
-- type TIState = Int
-- type TI a = ExceptT Error (State TIState) a

-- runTI :: TI a -> (Either Error a, TIState)
-- runTI t = runState (runExceptT t) initTIState
--   where initTIState = 0


type TIState = Int
type TI a = ChronicleT [Error] (State TIState) a

-- ChronicleT [Error] (State TIState) (These [Error] b0)

runTI :: TI a -> (These [Error] a, TIState)
runTI t = runState (runChronicleT t) initTIState
  where initTIState = 0


-- ===================== TypeEnv ============================
newtype TypeEnv = TypeEnv (Map IDLoc Scheme)
    deriving (Show)

insert :: TypeEnv -> IDLoc -> Scheme -> TypeEnv
insert (TypeEnv env) id scheme = TypeEnv (Map.insert id scheme env)

insertID :: TypeEnv -> IDLoc -> SPLType -> TypeEnv
insertID (TypeEnv env) id t = TypeEnv (Map.insert id (Scheme [] t) env)

insertMore :: TypeEnv -> [(IDLoc,SPLType)] -> TypeEnv
insertMore env [] = env
insertMore (TypeEnv env) [(id,t)] = TypeEnv (Map.insert id (Scheme [] t) env)
insertMore (TypeEnv env) ((id,t):xs) = insertMore (TypeEnv (Map.insert id (Scheme [] t) env)) xs

remove :: TypeEnv -> IDLoc -> TypeEnv
remove (TypeEnv env) var = TypeEnv (Map.delete var env)

find :: IDLoc -> TypeEnv -> Maybe Scheme
find id (TypeEnv env) = Map.lookup id env

generalize :: TypeEnv -> SPLType -> Scheme
generalize env t  = Scheme vars t
  where vars = Set.toList (ftv t Set.\\ ftv env)

generalizeFuncs :: TypeEnv -> [IDLoc] -> TI TypeEnv
generalizeFuncs env [] = return env
generalizeFuncs (TypeEnv env) (x:xs) = case Map.lookup x env of
    Just (Scheme _ t) -> let scheme = generalize (TypeEnv env) t in
        generalizeFuncs (TypeEnv $ Map.insert x scheme env) xs
    _ -> confess [Error (getLoc x) ("Function " ++ pp x ++  " is mutual recursive and should therefore be in the type environment but it is not.")]

-- ===================== Scheme ============================
data Scheme = Scheme [IDLoc] SPLType
    deriving (Show, Eq)

-- ===================== Substitution ============================
type Subst = Map.Map IDLoc SPLType

nullSubst :: Subst
nullSubst = Map.empty

applySubst :: Subst -> Subst -> Subst
applySubst s1 = Map.map $ apply s1

composeSubst::Subst -> Subst -> Subst
composeSubst s1 s2 = Map.map (apply s1) s2 `Map.union` s1

-- ===================== ftv and apply implementations ============================
class Types a where
    ftv :: a -> Set IDLoc
    apply :: Subst -> a -> a

instance Types a => Types [a] where
    ftv l = Prelude.foldr (Set.union . ftv) Set.empty l
    apply s = Prelude.map (apply s)

instance Types TypeEnv where
    ftv (TypeEnv env)      =  ftv (Map.elems env)
    apply s (TypeEnv env)  =  TypeEnv (Map.map (apply s) env)

instance Types Scheme where
    ftv (Scheme vars t) = ftv t Set.\\ Set.fromList vars
    apply s (Scheme vars t) = Scheme vars (apply (Prelude.foldr Map.delete s vars) t)

instance Types SPLType where
    ftv (Void _) = Set.empty
    ftv (TypeBasic x _) = Set.empty
    ftv (TupleType (x,y) _) = ftv x `Set.union` ftv y
    ftv (ArrayType x _) = ftv x
    ftv (FunType args ret) = ftv args `Set.union` ftv ret
    ftv (IdType x ) = Set.singleton x
    apply s (IdType x) = case Map.lookup x s of
                        Just t -> t
                        Nothing -> IdType x
    apply s (FunType args ret) = FunType (apply s args) (apply s ret)
    apply s (TupleType (x,y) loc) = TupleType (apply s x, apply s y) loc
    apply s (ArrayType x loc) = ArrayType (apply s x) loc
    apply _ x = x

instance Types a =>  Types (Maybe a) where
    ftv (Just a) = ftv a
    ftv Nothing = Set.empty
    apply s (Just a) = Just $ apply s a
    apply s Nothing = Nothing

newSPLVar :: TI SPLType
newSPLVar =
    do  s <- get
        put (s + 1)
        return $ IdType (idLocCreator (reverse (toTyVar s)))
  where
    toTyVar :: Int -> String
    toTyVar c | c < 26    =  [toEnum (97+c)]
              | otherwise = let (n, r) = c `divMod` 26
                            in toEnum (97+r) : toTyVar (n-1)

instantiate :: Scheme -> TI SPLType
instantiate (Scheme vars t) = do  nvars <- mapM (const newSPLVar) vars
                                  let s = Map.fromList (zip vars nvars)
                                  return $ apply s t

-- ===================== Most General Unifier ============================
class MGU a where
    mgu :: a -> a -> TI Subst
    generateError :: a -> a -> Error

instance MGU a => MGU [a] where
    mgu [] [] = return nullSubst
    mgu (x:xs) (y:ys) = do s1 <- mgu x y
                           s2 <- mgu xs ys
                           return (s1 `composeSubst` s2)
    generateError xs ys = undefined

instance MGU a => MGU (Maybe a) where
    mgu (Just l) (Just r) = mgu l r
    mgu Nothing _ = return nullSubst
    mgu _ Nothing = return nullSubst
    generateError (Just l) (Just r) = generateError l r

instance MGU SPLType where
    mgu (TypeBasic x _) (TypeBasic y _) | x == y = return nullSubst
    mgu (TypeBasic x loc) (TypeBasic y loc') =  confess [generateError (TypeBasic x loc) (TypeBasic y loc')]

    mgu (Void _) (Void _) = return nullSubst

    mgu (TupleType (l1,r1) _) (TupleType (l2,r2) _) = do
        s1 <- mgu l1 l2
        s2 <- mgu r1 r2
        return (s1 `composeSubst` s2)
    mgu (ArrayType x _) (ArrayType y _) = mgu x y
    mgu (IdType id) r = varBind id r
    mgu l (IdType id) = varBind id l

    mgu (FunType arg ret) (FunType arg' ret') = do
        s1 <- mgu arg arg'
        s2 <- mgu (apply s1 ret) (apply s1 ret')
        return (s2 `composeSubst` s1)

    mgu t1 t2 =  confess [generateError t1 t2]

    generateError t1 t2 = case getLoc t1 `compare` getLoc t2 of
        LT -> Error (getLoc t2) ("Type "++ pp t1 ++" "++ showLoc t2 ++" does not unify with: " ++ pp t2)
        GT -> Error (getLoc t1) ("Type "++ pp t1 ++" "++ showLoc t1 ++" does not unify with: " ++ pp t2 ++" "++ showLoc t2)
        EQ -> case getLoc t2 of
                        (Loc (-1) (-1)) -> Error defaultLoc ("Types do not unify: " ++ pp t1 ++ " vs. " ++ pp t2)
                        x -> Error x ("Type "++ pp t1 ++" "++ showLoc t1 ++" does not unify with: " ++ pp t2 ++" "++ showLoc t2)

varBind :: IDLoc -> SPLType -> TI Subst
varBind id (IdType t) | id == t = return nullSubst
varBind id (IdType t) = return $ Map.singleton id (IdType t)
varBind id t | id `Set.member` ftv t = confess [Error defaultLoc ("occurs check fails: " ++ pp id ++ " vs. " ++ show t)]
varBind id t = return $ Map.singleton id t

-- ===================== Type inference ============================
tiSPL :: SPL -> TI (Subst, TypeEnv, SPL)
tiSPL (SPL decls) = do
    stdEnv <- stdLib
    (s1, env', decls') <- tiDecls stdEnv decls
    return (s1, env', SPL decls')

tiDecls :: TypeEnv -> [Decl] -> TI (Subst, TypeEnv,[Decl])
tiDecls env [] = return (nullSubst, env, [])
tiDecls env (decl:decls) = do
            (s1, env', x) <- tiDecl env decl
            (s2, env'', xs) <- tiDecls env' decls
            let cs1 = s2 `composeSubst` s1
            return (cs1, env'', x:xs)

tiDecl :: TypeEnv -> Decl -> TI (Subst, TypeEnv, Decl)
tiDecl env (VarMain x) = do
    (s1, env, varDecl) <- tiVarDecl env x
    return (s1, env,VarMain varDecl)
tiDecl env (FuncMain x) = do
    (s1, env, funDecl) <- tiFunDecl env x
    return (s1, env, FuncMain funDecl)
tiDecl env (MutRec [func]) = do
    (s1, env, funDecl) <- tiFunDecl env func
    return (s1, env, FuncMain funDecl)
tiDecl env (MutRec funcs) = do
    fTypes <- getFuncTypes funcs
    let env' = insertMore env fTypes
    (s1, env'', decls) <- tiMutRecFunDecls env' funcs
    env''' <- generalizeFuncs env'' (Prelude.map fst fTypes)
    return (s1, env''', MutRec decls)

tiVarDecls :: TypeEnv -> [VarDecl] -> TI (Subst, TypeEnv, [VarDecl])
tiVarDecls env [] = return (nullSubst, env, [])
tiVarDecls env (varDecl:varDecls) = do
    (s1, env', varDecl') <- tiVarDecl env varDecl
    (s2, env'', varDecls') <- tiVarDecls env' varDecls
    return (s2 `composeSubst` s1, env'', varDecl':varDecls')

tiVarDecl :: TypeEnv -> VarDecl -> TI (Subst, TypeEnv, VarDecl)
tiVarDecl (TypeEnv env) (VarDeclVar id e) = case Map.lookup id env of
    Just x -> confess [doubleDef id]
    Nothing -> do
        (s1, t1, e') <- tiExp (TypeEnv env) e
        let scheme = Scheme [] t1
        let env' = TypeEnv (Map.insert id scheme env)
        return (s1, apply s1 env', VarDeclType t1 id e')
tiVarDecl (TypeEnv env) (VarDeclType t id e) = case Map.lookup id env of
    Just x -> confess [doubleDef id]
    Nothing -> do
        (s1, t1, e') <- tiExp (TypeEnv env) e
        s2 <- mgu (apply s1 t) t1
        let cs1 = s2 `composeSubst` s1
        let t' = Scheme [] t1
        let env' = TypeEnv (Map.insert id t' env)
        return (cs1, apply cs1 env', VarDeclType (apply cs1 t) id e')

tiMutRecFunDecls :: TypeEnv -> [FunDecl] -> TI (Subst, TypeEnv, [FunDecl])
tiMutRecFunDecls env [] = return (nullSubst, env, [])
tiMutRecFunDecls (TypeEnv env) ((FunDecl funName args (Just funType) vars stmts):xs) = do
    let (argTypes, retType) = let a = getArgsTypes funType in (init a, last a)
    let env' = insertMore (TypeEnv env) (zip args argTypes) -- With this function + args inserted

    (s1, env'', vars') <- tiVarDecls env' vars

    (s2, t1, stmts') <- tiStmts env'' stmts

    let cs1 = s2 `composeSubst` s1

    let t1' = fromMaybe (Void defaultLoc) t1
    s3 <- mgu (apply cs1 t1') retType

    let cs2 = s3 `composeSubst` cs1

    (s4, env'', funDecls) <- tiMutRecFunDecls (apply cs2 (TypeEnv env)) xs

    let cs3 = s4 `composeSubst` cs2

    let funDecl = FunDecl funName args (Just $ apply cs3 funType) vars' stmts'

    return (cs3, apply cs3 env'', funDecl:funDecls)
tiMutRecFunDecls (TypeEnv env) ((FunDecl funName args Nothing vars stmts):xs) = do
    case Map.lookup funName env of
        Just (Scheme [] funType) -> do
            let (argTypes, retType) = let a = getArgsTypes funType in (init a, last a)
            let env' = insertMore (TypeEnv env) (zip args argTypes) -- With this function + args inserted

            (s1, env'', vars') <- tiVarDecls env' vars

            (s2,t1, stmts') <- tiStmts env'' stmts

            let cs1 = s2 `composeSubst` s1

            let t1' = fromMaybe (Void defaultLoc) t1
            s3 <- mgu (apply cs1 t1') retType

            let cs2 = s3 `composeSubst` cs1

            (s4, env''', funDecls') <- tiMutRecFunDecls (apply cs1 (TypeEnv env)) xs

            let cs3 = s4 `composeSubst` cs2

            let funDecl' = FunDecl funName args (Just $ apply cs3 funType) vars' stmts'

            return (cs3, apply cs2 env''', funDecl':funDecls')
        nothing -> confess [Error (getLoc funName) "Function is mutual recursive and should therefore be in the type environment but it is not."]

tiFunDecl :: TypeEnv -> FunDecl -> TI (Subst, TypeEnv, FunDecl)
tiFunDecl env (FunDecl funName args (Just funType) vars stmts) = do
    let (argTypes, retType) = let a = getArgsTypes funType in (init a, last a)
    case length args `compare` length argTypes of
        LT -> confess [funcCallLessArgs funName]
        GT -> confess [funcCallMoreArgs funName]
        EQ -> do
            let env' = TIMul.insertID env funName funType -- With only this function inserted
            let env'' = insertMore env' (zip args argTypes) -- With this function + args inserted
            (s1, env''', vars') <- tiVarDecls env'' vars -- With this function + args + local varDecls inserted

            (s2,t1, stmts') <- tiStmts env''' stmts

            let cs1 = s2 `composeSubst` s1

            let t1' = fromMaybe (Void defaultLoc) t1
            s3 <- mgu (apply cs1 t1') retType

            let cs2 = s3 `composeSubst` cs1

            let Just (Scheme _ funType') = find funName (apply cs2 env''')
            let func = generalize env funType'

            return (cs2, TIMul.insert env' funName func, FunDecl funName args (Just funType') vars' stmts')
tiFunDecl env (FunDecl funName args Nothing vars stmts) = do

    argTypes <- replicateM (length args) newSPLVar
    retType <- newSPLVar

    let fType = if not (Prelude.null argTypes) then foldr1 FunType (argTypes ++ [retType]) else retType
    let env' = TIMul.insertID env funName fType -- With only this function inserted
    let env'' = insertMore env' (zip args argTypes) -- With this function + args inserted
    (s1, env''', vars') <- tiVarDecls env'' vars -- With this function + args + local varDecls inserted

    (s2, t1, stmts') <- tiStmts env''' stmts

    let cs1 = s2 `composeSubst` s1
    let t1' = fromMaybe (Void defaultLoc) t1

    s3 <- mgu (apply cs1 t1') retType
    let cs2 = s3 `composeSubst` cs1

    let Just (Scheme _ funType') = find funName (apply cs2 env''')
    let func = generalize env funType'

    let (polyExp, polyFunCall) = findOverloadedFuncs vars' stmts'

    if not (Prelude.null polyExp || Prelude.null polyFunCall) 
    then 
        confess [Error defaultLoc ("WE GOT ONE BOYS" ++ pp funName)]
    else
        trace ("HELLO \n"++show polyExp) $ return (cs2, TIMul.insert (apply cs2 env) funName func, FunDecl funName args (Just funType') vars' stmts')


tiStmts :: TypeEnv -> [Stmt] -> TI (Subst, Maybe SPLType, [Stmt])
tiStmts env [e] = do
    (s1, t1, stmt') <- tiStmt env e
    return (s1, t1, [stmt'])
tiStmts env (e:es) = do
        (s1, t1, stmt') <- tiStmt env e
        (s2, retType, stmts') <- tiStmts (apply s1 env) es
        let cs1 = s2 `composeSubst` s1
        s3 <- mgu (apply cs1 t1) retType
        let cs2 = s3 `composeSubst` cs1
        return (cs2, retType, stmt':stmts')

tiStmt :: TypeEnv -> Stmt -> TI (Subst, Maybe SPLType, Stmt)
tiStmt env (StmtIf e stmts (Just els) loc) = do
    (s1, conditionType, e') <- injectErrLoc (tiExp env e) (getLoc e)
    s2 <- injectErrLocMsg (mgu conditionType (TypeBasic BasicBool defaultLoc)) (getLoc e) ("Given condition does not have type Bool " ++ showLoc e)

    let cs1 = s2 `composeSubst` s1
    (s3, retIf, ifStmts) <- tiStmts (apply cs1 env) stmts

    let cs2 = s3 `composeSubst` cs1
    (s4, retElse, elseStmts) <- tiStmts (apply cs2 env) els

    let cs3 = s4 `composeSubst`cs2
    s5 <- mgu (apply cs3 retIf) (apply cs3 retElse)

    let cs4 = s5 `composeSubst` cs3
    return (cs4, apply cs4 retIf, StmtIf e' ifStmts (Just elseStmts) loc)
tiStmt env (StmtIf e stmts els loc) | els == Just [] || isNothing els = do
    (s1, conditionType, e') <- injectErrLoc (tiExp env e) (getLoc e)
    s2 <- injectErrLocMsg (mgu conditionType (TypeBasic BasicBool defaultLoc)) (getLoc e) ("Given condition does not have type Bool " ++ showLoc e)

    let cs1 = s2 `composeSubst` s1
    (s3, t2, stmts') <- tiStmts (apply cs1 env) stmts

    let cs2 = s3 `composeSubst` cs1
    return (cs2, apply cs2 t2, StmtIf e' stmts' els loc)
tiStmt env (StmtWhile e stmts loc) = do
    (s1, conditionType, e') <- injectErrMsgAddition (tiExp env e) (getLoc e) "tiStmt while"
    s2 <- injectErrLocMsg (mgu conditionType (TypeBasic BasicBool defaultLoc)) (getLoc e) ("Given condition does not have type Bool " ++ showLoc e)
    let cs1 = s2 `composeSubst` s1

    (s3, t3, stmts') <- tiStmts (apply cs1 env) stmts
    let cs2 = s3 `composeSubst` cs1

    return (cs2, apply cs2 t3, StmtWhile e' stmts' loc)
tiStmt (TypeEnv env) (StmtFuncCall (FunCall id e _) loc) = case Map.lookup id env of
    Just scheme -> do
        t <- instantiate scheme
        let argTypes = init $ getArgsTypes t
        (s1, e') <- typeCheckExps id (TypeEnv env) e argTypes
        return (s1, Nothing, StmtFuncCall (FunCall id e' (Just $ apply s1 t)) loc)
    Nothing -> confess [refBeforeDec "Function:" id]

tiStmt env (StmtReturn Nothing loc) = return (nullSubst, Just (Void loc), StmtReturn Nothing loc)
tiStmt env (StmtReturn (Just e) loc) = do
    (s1, t1, e') <- tiExp env e
    return (s1, Just t1, StmtReturn (Just e') loc)

tiStmt (TypeEnv env) (StmtAssignVar id (Field []) e _) = case Map.lookup id env of
    Just (Scheme ids t) -> do
        (s1, t1, e') <- tiExp (TypeEnv env) e
        s2 <- mgu (apply s1 t) t1
        let cs1 = s2 `composeSubst` s1
        return (cs1, Nothing, StmtAssignVar id (Field []) e' (Just t1))
    Nothing -> confess [refBeforeDec "Variable:" id]
tiStmt (TypeEnv env) (StmtAssignVar id (Field fields) e _) = case Map.lookup id env of
    Just (Scheme ids t) -> do
        (s1, t1, e') <- tiExp (TypeEnv env) e
        (s2, t', ret) <- getType t fields
        let cs1 = s2 `composeSubst` s1
        s3 <- mgu (apply cs1 ret) t1
        let cs2 = s3 `composeSubst` cs1
        s4 <- mgu (apply cs2 t') t
        let cs3 = s4 `composeSubst` cs2
        return (cs3, Nothing, StmtAssignVar id (Field fields) e' (Just $ apply cs3 ret))
    Nothing -> confess [refBeforeDec "Variable:" id]

typeCheckExps :: IDLoc -> TypeEnv -> [Exp] -> [SPLType] -> TI (Subst, [Exp])
typeCheckExps id env [] [] = return (nullSubst, [])
typeCheckExps id env [x] [] = confess [funcCallMoreArgs id]
typeCheckExps id env [] [x] = confess [funcCallLessArgs id]
typeCheckExps id env (e:es) (t:ts) = do
    (s1,t1, e') <- injectErrMsgAddition (tiExp env e) (getLoc e) "typeCheckExps"
    s2 <- injectErrLocMsg (mgu (apply s1 t) t1) (getLoc e) ("Argument '"++ pp e ++ "' should have type "++ pp t)
    let cs1 = s2 `composeSubst` s1
    (s3, es') <- typeCheckExps id (apply cs1 env) es ts
    return (s3 `composeSubst` cs1, e':es')

tiExpsList :: TypeEnv -> [Exp] -> TI (Subst, SPLType, Exp)
tiExpsList env [e] = do
    (s1, t1, e') <- tiExp env e
    let arrayType = ArrayType t1 (getLoc t1)
    let opType = Op2 Con (Just $ FunType t1 (FunType arrayType arrayType))
    return (s1, t1, ExpOp2 e' opType (ExpEmptyList (getLoc e)) (getLoc e))
tiExpsList env (e:es) = do
    (s1, t1, e' ) <- tiExp env e
    (s2, t2, es') <- tiExpsList (apply s1 env) es
    let cs1 = s2 `composeSubst` s1
    s3 <- injectErrLoc (mgu (apply cs1 t1) t2) (getLoc e)

    let cs2 = s3 `composeSubst` cs1

    let arrayType = ArrayType t2 (getLoc t2)
    let opType = Op2 Con (Just $ FunType t1 (FunType arrayType arrayType))

    return (cs2, t2, ExpOp2 e' opType es' (getLoc e))

tiExp :: TypeEnv -> Exp -> TI (Subst, SPLType, Exp)
tiExp env (ExpId id (Field [])) = do
    case find id env of
        Just (Scheme _ t) -> return (nullSubst, t, ExpId id (Field []))
        Nothing -> confess [refBeforeDec "Variable:" id]
tiExp (TypeEnv env) (ExpId id (Field fields)) = case Map.lookup id env of
    Just (Scheme ids t) -> do
        (s1, t', ret) <- getType t fields
        return (s1, ret, ExpId id (Field fields))
    Nothing -> confess [Error (getLoc id) ("id: '" ++ pp id ++ "', referenced " ++ showLoc id ++ ", has not been defined yet: (i.e. reference before declaration)")]
tiExp _ (ExpInt i loc)  = return (nullSubst, TypeBasic BasicInt loc, ExpInt i loc)
tiExp _ (ExpBool b loc) = return (nullSubst, TypeBasic BasicBool loc, ExpBool b loc)
tiExp _ (ExpChar c loc) = return (nullSubst, TypeBasic BasicChar loc, ExpChar c loc)
tiExp env (ExpBracket e) = do
    (s1, t1, e') <- tiExp env e
    return (s1, t1, ExpBracket e')
tiExp env (ExpList [] loc _) = confess [Error loc "Removed ExpList [] because lists as [1,2,3] are converted to 1:2:3:[]"]
tiExp env (ExpEmptyList loc) = do
      tv <- newSPLVar
      return (nullSubst, ArrayType tv defaultLoc, ExpEmptyList loc)
tiExp env (ExpList es loc Nothing) = do
    (s1, t1, es') <- tiExpsList env es
    return (s1, ArrayType t1 loc, es')
tiExp env (ExpTuple (e1, e2) loc Nothing) = do
    (s1, t1, e1') <- tiExp env e1
    (s2, t2, e2') <- tiExp (apply s1 env) e2
    let cs1 = s2 `composeSubst` s1
    return (cs1, apply cs1 (TupleType (t1,t2) loc), ExpTuple (e1', e2') loc (Just $ TupleType (t1, t2) loc) )
tiExp env (ExpOp2 e1 (Op2 op _) e2 loc) = do
    (t1, t2, t3, opType) <- op2Type op
    (s1, t1', e1') <- injectErrLoc (tiExp env e1) (getLoc e1)

    s2 <- injectErrLoc (mgu t1' (apply s1 t1)) (getLoc e1)
    let cs1 = s2 `composeSubst` s1

    (s3, t2', e2') <- injectErrLoc (tiExp (apply cs1 env) e2) (getLoc e2)
    let cs2 = s3 `composeSubst` cs1

    s4 <- injectErrLoc (mgu (apply cs2 t2') (apply cs2  t2)) (getLoc e2)
    let cs3 = s4 `composeSubst` cs2

    let finalOpType = apply cs3 opType
    -- if containsIDType finalOpType
    --     then confess $
    --         Error loc ("Operator '" ++ pp op ++"' "++ showLoc loc++" does not support 'polymorphic' like overloading. " ++
    --                     "\nProviding a rigid type will solve this error.")
    --     else 
    return (cs3, apply cs3 t3, ExpOp2 e1' (Op2 op (Just finalOpType)) e2' loc)
        -- _ -> confess $ Error loc ("Operator '"++ pp op ++"' on "++ pp loc ++ " is only supported for basic types Int, Bool and Char per the Grammar of SPL." )
tiExp env (ExpOp1 op e loc) = case op of
    Neg -> do
        (s1, t1, e') <- tiExp env e
        s2 <- mgu t1 (TypeBasic BasicInt (getLoc t1))
        return (s2 `composeSubst` s1, t1, ExpOp1 op e' loc)
    Not -> do
        (s1, t1, e') <- tiExp env e
        s2 <- mgu t1 (TypeBasic BasicBool (getLoc t1))
        return (s2 `composeSubst` s1, t1, ExpOp1 op e' loc)
tiExp (TypeEnv env) (ExpFunCall (FunCall (ID n l) args Nothing) loc) = {-- trace ("ExpFunCall "++n++" \n\n" ++printEnv (Map.toList env)) $ --} case Map.lookup (ID n l) env of
    Just scheme -> do
        t <- instantiate scheme
        let argTypes = getArgsTypes t
        (s1, args') <- typeCheckExps (ID n l) (TypeEnv env) args (init argTypes)
        let returnType = last argTypes
        return (s1, apply s1 returnType, ExpFunCall (FunCall (ID n l) args' (Just $ apply s1 t)) loc)
    Nothing -> confess [refBeforeDec "Function:" (ID n l)]

-- ===================== Helper functions ============================
getFuncTypes :: [FunDecl] -> TI [(IDLoc, SPLType)]
getFuncTypes [] = return []
getFuncTypes ((FunDecl funName args (Just fType) vars stmts):xs) = do
    fTypes <- getFuncTypes xs
    return $ (funName, fType):fTypes
getFuncTypes ((FunDecl funName args Nothing vars stmts):xs) = do
    argTypes <- replicateM (length args) newSPLVar
    retType <- newSPLVar
    let fType = if not (Prelude.null argTypes) then foldr1 FunType (argTypes ++ [retType]) else retType
    fTypes <- getFuncTypes xs
    return $ (funName, fType):fTypes

getType :: SPLType -> [StandardFunction] -> TI (Subst, SPLType, SPLType)
getType t [] = do
    tv <- newSPLVar
    return (nullSubst, tv, tv)
getType t [Head loc] = do
    tv <- newSPLVar
    let t' = ArrayType tv defaultLoc
    s1 <- mgu t t'
    return (s1, apply s1  t', tv)
getType t [Tail loc] = case t of
    TupleType (a, b) _ -> do
        return(nullSubst, t, b)
    _ -> do
        tv <- newSPLVar
        let t' = ArrayType tv defaultLoc
        let retType = ArrayType tv defaultLoc
        s1 <- mgu t t'
        return (s1, apply s1 t', t')
getType t [Fst loc] = case t of
    TupleType (a, b) _ -> do
        return(nullSubst, t, a)
    _ -> do
        a <- newSPLVar
        b <- newSPLVar
        let t' = TupleType (a, b) defaultLoc
        s1 <- mgu t t'
        return (s1, apply s1 t', apply s1 a)
getType t [Snd loc] = do
    a <- newSPLVar
    b <- newSPLVar
    let t' = TupleType (a, b) defaultLoc
    s1 <- mgu t t'
    return (s1, apply s1  t', b)
getType t (x:xs) = do
    (s1, t', ret) <- getType t [x]
    (s2, t'', ret') <- getType ret xs
    let cs1 = s2 `composeSubst` s1
    let s3 = applySubst s2 s1
    return (s3, apply s3 t, ret')

op2Type :: Op2 -> TI (SPLType, SPLType, SPLType, SPLType)
op2Type x | x == Plus || x == Min || x == Mult || x == Div || x == Mod =
    let t = TypeBasic BasicInt defaultLoc in
    return (t, t, t, FunType t (FunType t t))
op2Type x | x == Eq || x == Neq = do
    tv <- newSPLVar
    let t = TypeBasic BasicBool defaultLoc
    return (tv, tv, t, FunType tv (FunType tv t))
op2Type x | x == Le || x == Ge || x == Leq || x == Geq  = do
    tv <- newSPLVar
    let t = TypeBasic BasicBool defaultLoc
    return (tv, tv, t, FunType tv (FunType tv t))
op2Type x | x== And || x == Or =
    let t = TypeBasic BasicBool defaultLoc in
    return (t, t, t, FunType t (FunType t t))
op2Type Con = do
    tv <- newSPLVar
    let t = ArrayType tv defaultLoc
    return (tv, t, t, FunType tv (FunType t t))

findOverloadedFuncs :: [VarDecl] -> [Stmt] -> ([Exp],[FunCall])
findOverloadedFuncs xs ys = combineOverFuncs (findOverFuncsVarDecls xs) (findOverFuncsStmts ys)

findOverFuncsStmts :: [Stmt] -> ([Exp],[FunCall])
findOverFuncsStmts = Prelude.foldr (combineOverFuncs . findOverFuncsStmt) ([], [])

findOverFuncsStmt :: Stmt -> ([Exp], [FunCall])
findOverFuncsStmt  (StmtIf e stmts (Just els) loc) = combineOverFuncs (findOverFuncsStmts els)  $ combineOverFuncs (findOverFuncsExp e) (findOverFuncsStmts stmts)
findOverFuncsStmt  (StmtIf e stmts Nothing loc) = combineOverFuncs (findOverFuncsExp e) (findOverFuncsStmts stmts)
findOverFuncsStmt  (StmtWhile e stmts loc) = combineOverFuncs (findOverFuncsExp e) (findOverFuncsStmts stmts)
findOverFuncsStmt  (StmtAssignVar id fields e _) =  findOverFuncsExp e
findOverFuncsStmt  (StmtFuncCall (FunCall (ID "print" l) args (Just t)) loc) | containsIDType t = ([],[FunCall (ID "print" l) args (Just t)])
findOverFuncsStmt  (StmtReturn (Just e) loc) = findOverFuncsExp e
findOverFuncsStmt  _ = ([],[])

findOverFuncsVarDecls :: [VarDecl] -> ([Exp],[FunCall])
findOverFuncsVarDecls [] = ([],[])
findOverFuncsVarDecls ((VarDeclType t id e):xs) = combineOverFuncs (findOverFuncsExp e) (findOverFuncsVarDecls xs)

findOverFuncsExp :: Exp -> ([Exp],[FunCall])
findOverFuncsExp (ExpOp2 e1 (Op2 op (Just t)) e2 loc) | containsIDType t =  ([ExpOp2 e1 (Op2 op (Just t)) e2 loc],[])
findOverFuncsExp (ExpFunCall (FunCall (ID "print" l) args (Just t)) loc) | containsIDType t =  ([],[FunCall (ID "print" l) args (Just t)])
findOverFuncsExp _  =  ([],[])

combineOverFuncs (a,b) (c,d) = (a++c, b++d)

containsIDType :: SPLType -> Bool
containsIDType (Void _) = False
containsIDType (TypeBasic _ _) = False
containsIDType (IdType _) = True
containsIDType (TupleType (t1, t2) _) = containsIDType t1 || containsIDType t2
containsIDType (ArrayType a1 _) = containsIDType a1
containsIDType (FunType arg f) = containsIDType arg || containsIDType f

-- ===================== Error Injection ============================
injectErrLoc :: TI a -> Loc -> TI a
injectErrLoc runable loc = case runTI runable of
    (That a, state) -> return a
    (These errs a, state) -> runable
    (This (Error _ msg:xs), state) -> confess (Error loc msg:xs)

    -- (Left (Error _ msg), state) -> confess $ Error loc msg

injectErrLocMsg :: TI a -> Loc -> String -> TI a
injectErrLocMsg runable loc m = case runTI runable of
    (That a, state) -> return a
    (These errs a, state) -> runable
    (This (Error _ _:xs), state) -> confess (Error loc m:xs)

injectErrMsgAddition :: TI a -> Loc -> String -> TI a
injectErrMsgAddition runable loc m = case runTI runable of
    (That a, state) -> return a
    (These errs a, state) -> runable
    (This (Error _ msg:xs), state) -> confess (Error loc (m++" "++msg):xs)

-- ===================== Standard Lib Functions ============================
stdLib :: TI TypeEnv
stdLib = do
    let env = TypeEnv Map.empty
    t1 <- newSPLVar
    let isEmptyType = FunType (ArrayType t1 defaultLoc) (TypeBasic BasicBool defaultLoc)
    let env' = TIMul.insert env (idLocCreator "isEmpty") (generalize env isEmptyType)

    t2 <- newSPLVar
    let printType = FunType t2 (Void defaultLoc)
    let env'' = TIMul.insert env' (idLocCreator "print") (generalize env' printType)
    return env''

-- ===================== Printing ============================
printEnv :: [(IDLoc, Scheme)] -> String
printEnv [] = ""
printEnv ((ID id _,Scheme _ t):xs) = id ++" :: " ++ pp t ++ "\n"++ printEnv xs


printSubst :: [(IDLoc,SPLType)] -> String
printSubst [] = ""
printSubst ((ID id _,t):xs) = id ++ " -> " ++ pp t ++ "\n"++ printSubst xs

-- ===================== Main Type Inference ============================
typeInference :: SPL -> Either [Error] (Subst, TypeEnv, SPL)
typeInference code = do
    case runTI (tiSPL code) of
        (That (s1, env, SPL code'), state) -> Right (s1, env, updateTypes (SPL $ removeMutRec code') s1 env)
        (These errs a, state) -> Left errs
        (This errs, state) -> Left errs

class UpdateTypes a where
    updateTypes :: a -> Subst -> TypeEnv -> a

instance (Show a, UpdateTypes a) => UpdateTypes [a] where
    updateTypes [] s env = []
    updateTypes (x:xs) s env =  updateTypes x s env:updateTypes xs s env

instance UpdateTypes SPL where
    updateTypes (SPL []) s env = SPL []
    updateTypes (SPL x) s env = SPL $ updateTypes x s env

instance UpdateTypes Decl where
    updateTypes (VarMain varDecl) s env = VarMain $ updateTypes varDecl s env
    updateTypes (FuncMain funDecl) s env = FuncMain $ updateTypes funDecl s env
    updateTypes (MutRec x) s env = trace ("Error in UpdateTypes FunDecl\n" ++ pp (MutRec  x)) undefined

instance UpdateTypes VarDecl where
    updateTypes (VarDeclType t (ID id loc) e) s env = VarDeclType (apply s t) (ID id loc) e
    updateTypes e s env = e

instance UpdateTypes FunDecl where
    updateTypes (FunDecl funName args funType varDecls stmts) s env = do
        let varDecls' = updateTypes varDecls s env
        let stmts' = updateTypes stmts s env
        FunDecl funName args funType varDecls' stmts'

instance UpdateTypes Stmt where
    updateTypes (StmtIf e stmts Nothing loc) s env = do
        let e' = updateTypes e s env
        let stmts' = updateTypes stmts s env
        StmtIf e' stmts' Nothing loc
    updateTypes (StmtIf e stmts (Just els) loc) s env = do
        let e' = updateTypes e s env
        let stmts' = updateTypes stmts s env
        let els' = updateTypes els s env
        StmtIf e' stmts' (Just els') loc
    updateTypes (StmtAssignVar id fields e typ) s env = do
        let e' = updateTypes e s env
        StmtAssignVar id fields e' (apply s typ)
    updateTypes (StmtFuncCall fCall loc) s env = do
        let fCall' = updateTypes fCall s env
        StmtFuncCall fCall' loc
    updateTypes (StmtReturn (Just e) loc) s env = do
        let e' = updateTypes e s env
        StmtReturn (Just e') loc
    updateTypes e s env = e

instance UpdateTypes Exp where
    updateTypes (ExpOp2 e1 (Op2 op (Just t)) e2 loc) s env = do
        let t' = apply s t
        let e1' = updateTypes e1 s env
        let e2' = updateTypes e2 s env
        ExpOp2 e1' (Op2 op (Just t')) e2' loc
    updateTypes (ExpFunCall fCall loc) s env =  do
        let fCall' = updateTypes fCall s env
        ExpFunCall fCall' loc
    updateTypes (ExpList es loc typ) s env = do
        let es' = updateTypes es s env
        ExpList es' loc (apply s typ)
    updateTypes (ExpTuple (e1, e2) loc typ) s env = do
        let e1' = updateTypes e1 s env
        let e2' = updateTypes e2 s env
        ExpTuple (e1', e2') loc (apply s typ)
    updateTypes (ExpBracket e) s env = ExpBracket (updateTypes e s env)
    updateTypes (ExpOp1 op e loc) s env = let e' = updateTypes e s env in ExpOp1 op e' loc
    updateTypes e s env = e

instance UpdateTypes FunCall where
    updateTypes (FunCall (ID name l) es (Just t)) s env = do
        let es' = updateTypes es s env
        FunCall (ID name l) es' (Just $ apply s t)
    updateTypes (FunCall (ID name l) es Nothing) s env =  FunCall (ID name l) es Nothing

mainTITest filename = do
      -- path <- getCurrentDirectory
      -- print path
      file <- readFile  ("../SPL_test_code/" ++ filename)
      case tokeniseAndParse mainSegments file >>= (mutRec . fst) of
            Right spl ->
                trace "HOI" $ print $ typeInference spl
            Left x -> trace "doei" $ print $ showPlaceOfError file x


mainTI filename = do
      -- path <- getCurrentDirectory
      -- print path
      file <- readFile  ("../SPL_test_code/" ++ filename)
      case tokeniseAndParse mainSegments file >>= (mutRec . fst) of
            Right spl ->
                case typeInference spl of 
                    Right (s1, TypeEnv env, code) -> do
                        writeFile "../SPL_test_code/ti-out.spl"$ pp code
                        putStr $ "\nEnv:\n" ++ printEnv (Map.toList env)
                        putStr $ "\nSubst:\n" ++ printSubst (Map.toList s1)
                    Left x -> putStr $ showPlacesOfErrors file x
            Left x -> putStr $ showPlaceOfError file x