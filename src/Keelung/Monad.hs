{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

module Keelung.Monad
  ( Comp,
    runComp,
    runElab,
    Computation (..),
    Elaborated (..),
    Assignment (..),
    elaborate,
    elaborate',
    freshVar,
    -- creates an assignment
    assign,
    -- declare input vars
    freshInput,
    freshInputs,
    freshInputs2,
    freshInputs3,
    -- declare array of vars
    allocate,
    --
    access,
    access2,
    access3,
    update,
    --
    reduce,
    every,
    everyM,
    loop,
    arrayEq,
    --
    ifThenElse,
    --
    assert,
  )
where

import Control.Monad.Except
import Control.Monad.State.Strict
import Data.Field.Galois (GaloisField)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Keelung.Syntax
import Keelung.Syntax.Common
import Keelung.Util

--------------------------------------------------------------------------------

-- The monad
type Comp n = StateT (Computation n) (Except String)

-- how to run the monad
runComp :: Computation n -> Comp n a -> Either String (a, Computation n)
runComp comp f = runExcept (runStateT f comp)

runElab :: Computation n -> Comp n (Expr ty n) -> Either String (Elaborated ty n)
runElab comp f = do
  (expr, comp') <- runComp comp f
  return $ Elaborated (Just expr) comp'

-- internal function for generating one fresh variable
freshVar :: Comp n Int
freshVar = do
  index <- gets compNextVar
  modify (\st -> st {compNextVar = succ index})
  return index

-- internal function for generating many fresh variables
freshVars :: Int -> Comp n IntSet
freshVars n = do
  index <- gets compNextVar
  modify (\st -> st {compNextVar = n + index})
  return $ IntSet.fromDistinctAscList [index .. index + n - 1]

-- internal function for marking one variable as input
markVarAsInput :: Var -> Comp n ()
markVarAsInput = markVarsAsInput . IntSet.singleton

-- internal function for marking many variables as input
markVarsAsInput :: IntSet -> Comp n ()
markVarsAsInput vars =
  modify (\st -> st {compInputVars = vars <> compInputVars st})

-- internal function for allocating one fresh address
freshAddr :: Comp n Addr
freshAddr = do
  addr <- gets compNextAddr
  modify (\st -> st {compNextAddr = succ addr})
  return addr

--------------------------------------------------------------------------------

-- | Add assignment
class Proper ty where
  assign :: Ref ('V ty) -> Expr ty n -> Comp n ()
  arrayEq :: Int -> Ref ('A ('V ty)) -> Ref ('A ('V ty)) -> Comp n ()

instance Proper 'Num where
  assign var e = modify' $ \st -> st {compNumAsgns = Assignment var e : compNumAsgns st}
  arrayEq len xs ys = forM_ [0 .. len - 1] $ \i -> do
    a <- access xs i
    b <- access ys i
    assert (Var a `Eq` Var b)

instance Proper 'Bool where
  assign var e = modify' $ \st -> st {compBoolAsgns = Assignment var e : compBoolAsgns st}
  arrayEq len xs ys = forM_ [0 .. len - 1] $ \i -> do
    a <- access xs i
    b <- access ys i
    assert (Var a `BEq` Var b)

--------------------------------------------------------------------------------

data Computation n = Computation
  { -- Counter for generating fresh variables
    compNextVar :: Int,
    -- Counter for allocating fresh heap addresses
    compNextAddr :: Int,
    -- Variables marked as inputs
    compInputVars :: IntSet,
    -- Heap for arrays
    compHeap :: Heap,
    compNumAsgns :: [Assignment 'Num n],
    compBoolAsgns :: [Assignment 'Bool n],
    -- Assertions
    compAssertions :: [Expr 'Bool n]
  }

instance (Show n, GaloisField n, Bounded n, Integral n) => Show (Computation n) where
  show (Computation nextVar nextAddr inputVars _ numAsgns boolAsgns assertions) =
    "{\n  variable counter: " ++ show nextVar
      ++ "\n  address counter: "
      ++ show nextAddr
      ++ "\n  input variables: "
      ++ show (IntSet.toList inputVars)
      ++ "\n  num assignments: "
      ++ show (map (fmap DebugGF) numAsgns)
      ++ "\n  bool assignments: "
      ++ show (map (fmap DebugGF) boolAsgns)
      ++ "\n  assertions: "
      ++ show (map (fmap DebugGF) assertions)
      ++ "\n\
         \}"

--------------------------------------------------------------------------------

-- A Heap is an mapping of mappings of variables
type Heap = IntMap (IntMap Int)

--------------------------------------------------------------------------------

data Assignment ty n = Assignment (Ref ('V ty)) (Expr ty n)

instance Show n => Show (Assignment ty n) where
  show (Assignment var expr) = show var <> " := " <> show expr

instance Functor (Assignment ty) where
  fmap f (Assignment var expr) = Assignment var (fmap f expr)

--------------------------------------------------------------------------------

-- | Computation elaboration
elaborate :: Comp n (Expr ty n) -> Either String (Elaborated ty n)
elaborate = runElab (Computation 0 0 mempty mempty mempty mempty mempty)

elaborate' :: Comp n () -> Either String (Elaborated ty n)
elaborate' prog = do
  ((), comp') <- runComp (Computation 0 0 mempty mempty mempty mempty mempty) prog
  return $ Elaborated Nothing comp'


-- | The result of elaborating a computation
data Elaborated ty n = Elaborated
  { -- | The resulting 'Expr'
    elabExpr :: !(Maybe (Expr ty n)),
    -- | The state of computation after elaboration
    elabComp :: Computation n
  }

instance (Show n, GaloisField n, Bounded n, Integral n) => Show (Elaborated ty n) where
  show (Elaborated expr comp) =
    "{\n expression: "
      ++ show (fmap (fmap DebugGF) expr)
      ++ "\n  compuation state: \n"
      ++ show comp
      ++ "\n}"

--------------------------------------------------------------------------------

freshInput :: Comp n (Ref ('V ty))
freshInput = do
  var <- freshVar
  markVarAsInput var
  return $ Variable var

--------------------------------------------------------------------------------

-- | Array-relad functions
freshInputs :: Int -> Comp n (Ref ('A ty))
freshInputs 0 = throwError "input array must have size > 0"
freshInputs size = do
  -- draw new variables and mark them as inputs
  vars <- freshVars size
  markVarsAsInput vars
  -- allocate a new array and associate it's content with the new variables
  allocateArray' vars

freshInputs2 :: Int -> Int -> Comp n (Ref ('A ('A ty)))
freshInputs2 0 _ = throwError "input array must have size > 0"
freshInputs2 sizeM sizeN = do
  -- allocate `sizeM` input arrays each of size `sizeN`
  innerArrays <- replicateM sizeM (freshInputs sizeN)
  -- collect references of these arrays
  vars <- forM innerArrays $ \array -> do
    case array of Array addr -> return addr
  -- and allocate a new array with these references
  allocateArray' $ IntSet.fromList vars

freshInputs3 :: Int -> Int -> Int -> Comp n (Ref ('A ('A ('A ty))))
freshInputs3 0 _ _ = throwError "input array must have size > 0"
freshInputs3 sizeM sizeN sizeO = do
  -- allocate `sizeM` input arrays each of size `sizeN * sizeO`
  innerArrays <- replicateM sizeM (freshInputs2 sizeN sizeO)
  -- collect references of these arrays
  vars <- forM innerArrays $ \array -> do
    case array of Array addr -> return addr
  -- and allocate a new array with these references
  allocateArray' $ IntSet.fromList vars

writeHeap :: Addr -> [(Int, Var)] -> Comp n ()
writeHeap addr array = do
  let bindings = IntMap.fromList array
  heap <- gets compHeap
  let heap' = IntMap.insertWith (<>) addr bindings heap
  modify (\st -> st {compHeap = heap'})

readHeap :: (Addr, Int) -> Comp n Int
readHeap (addr, i) = do
  heap <- gets compHeap
  case IntMap.lookup addr heap of
    Nothing ->
      throwError $
        "unbound array " ++ show (addr, i)
          ++ " in heap "
          ++ show heap
    Just array -> case IntMap.lookup i array of
      Nothing ->
        throwError $
          "unbound addr " ++ show (addr, i)
            ++ " in heap "
            ++ show heap
      Just n -> return n

-- internal function for allocating an array with a set of variables to associate with
allocateArray' :: IntSet -> Comp n (Ref ('A ty))
allocateArray' vars = do
  let size = IntSet.size vars
  addr <- freshAddr
  writeHeap addr $ zip [0 .. pred size] $ IntSet.toList vars
  return $ Array addr

allocate :: Int -> Comp n (Ref ('A ty))
allocate 0 = throwError "array must have size > 0"
allocate size = do
  -- declare new variables
  vars <- freshVars size
  -- allocate a new array and associate it's content with the new variables
  allocateArray' vars

-- 1-d array access
access :: Ref ('A ('V ty)) -> Int -> Comp n (Ref ('V ty))
access (Array addr) i = Variable <$> readHeap (addr, i)

access2 :: Ref ('A ('A ('V ty))) -> (Int, Int) -> Comp n (Ref ('V ty))
access2 addr (i, j) = do
  array <- accessArr addr i
  access array j

access3 :: Ref ('A ('A ('A ('V ty)))) -> (Int, Int, Int) -> Comp n (Ref ('V ty))
access3 addr (i, j, k) = do
  addr' <- accessArr addr i
  array <- accessArr addr' j
  access array k

accessArr :: Ref ('A ('A ty)) -> Int -> Comp n (Ref ('A ty))
accessArr (Array addr) i = Array <$> readHeap (addr, i)

-- | Update array 'addr' at position 'i' to expression 'expr'
update :: Proper ty => Ref ('A ('V ty)) -> Int -> Expr ty n -> Comp n ()
update (Array addr) i (Var (Variable n)) = writeHeap addr [(i, n)]
update (Array addr) i expr = do
  ref <- freshVar
  writeHeap addr [(i, ref)]
  assign (Variable ref) expr

--------------------------------------------------------------------------------

reduce :: Foldable t => Expr ty n -> t a -> (Expr ty n -> a -> Comp n (Expr ty n)) -> Comp n (Expr ty n)
reduce a xs f = foldM f a xs

every :: Foldable t => (a -> Expr 'Bool n) -> t a -> Comp n (Expr 'Bool n)
every f xs = reduce true xs $ \accum x -> return (accum `And` f x)

everyM :: Foldable t => t a -> (a -> Comp n (Expr 'Bool n)) -> Comp n (Expr 'Bool n)
everyM xs f =
  foldM
    ( \accum x -> do
        result <- f x
        return (accum `And` result)
    )
    true
    xs

loop :: Foldable t => t a -> (a -> Comp n b) -> Comp n ()
loop = forM_

--------------------------------------------------------------------------------

ifThenElse :: Expr 'Bool n -> Comp n (Expr ty n) -> Comp n (Expr ty n) -> Comp n (Expr ty n)
ifThenElse p x y = IfThenElse p <$> x <*> y

--------------------------------------------------------------------------------

assert :: Expr 'Bool n -> Comp n ()
assert expr = modify' $ \st -> st {compAssertions = expr : compAssertions st}