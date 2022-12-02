{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
-- Interpreter for Keelung.Syntax.Typed
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use lambda-case" #-}

module Keelung.Compiler.Interpret.Typed (InterpretError (..), runAndOutputWitnesses, run, runAndCheck) where

import Control.DeepSeq (NFData)
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Data.Bits (Bits (..))
import Data.Field.Galois (GaloisField)
import Data.Foldable (toList)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.Semiring (Semiring (..))
import qualified Data.Sequence as Seq
import Data.Serialize (Serialize)
import GHC.Generics (Generic)
import Keelung (N (N))
import qualified Keelung.Compiler.Interpret.Kinded as Kinded
import Keelung.Compiler.Syntax.Inputs (Inputs)
import qualified Keelung.Compiler.Syntax.Inputs as Inputs
import Keelung.Compiler.Util
import Keelung.Syntax.Counters
import Keelung.Syntax.Typed
import Keelung.Types

--------------------------------------------------------------------------------

-- | Interpret a program with inputs and return outputs along with the witness
runAndOutputWitnesses :: (GaloisField n, Integral n) => Elaborated -> Inputs n -> Either (InterpretError n) ([n], Witness n)
runAndOutputWitnesses (Elaborated expr comp) inputs = runM inputs $ do
  -- interpret assignments of values first
  assignmentsF <-
    filterM
      ( \(var, e) -> case e of
          ValF val -> interpret val >>= addBinding var >> return False
          _ -> return True
      )
      (IntMap.toList (compAssignmentF comp))
  assignmentsB <-
    filterM
      ( \(var, e) -> case e of
          ValB val -> interpret val >>= addBinding var >> return False
          _ -> return True
      )
      (IntMap.toList (compAssignmentB comp))
  -- interpret the rest of the assignments
  forM_ assignmentsF $ \(var, e) -> interpret e >>= addBinding var
  forM_ assignmentsB $ \(var, e) -> interpret e >>= addBinding var

  -- let numAssignments = reverse (compNumAsgns comp)
  -- forM_ numAssignments $ \x -> case x of
  --   AssignmentN var e -> do
  --     values <- interpret e
  --     addBinding var values
  --   AssignmentNI var e -> do
  --     values <- interpret e
  --     addBinding var values
  --   _ -> error "[ panic ] runAndOutputWitnesses: unexpected assignment"

  -- let boolAssignments = reverse (compBoolAsgns comp)
  -- forM_ boolAssignments $ \x -> case x of
  --   AssignmentB var e -> do
  --     values <- interpret e
  --     addBinding var values
  --   AssignmentBI var e -> do
  --     values <- interpret e
  --     addBinding var values
  --   _ -> error "[ panic ] runAndOutputWitnesses: unexpected assignment"

  -- interpret the assertions next
  -- throw error if any assertion fails
  forM_ (compAssertions comp) $ \e -> do
    values <- interpret e
    when (values /= [1]) $ do
      let (freeVarFIs, freeInputVarBs, freeCustomInputVars, freeIntermediateVars) = freeVars e
      numInputBindings <- mapM (\var -> ("$N" <> show var,) <$> lookupVarFI var) $ IntSet.toList freeVarFIs
      boolInputBindings <- mapM (\var -> ("$B" <> show var,) <$> lookupInputVarB var) $ IntSet.toList freeInputVarBs
      customInputBindings <-
        concat
          <$> mapM
            (\(width, vars) -> mapM (\var -> ("$U" <> show var,) <$> lookupInputVarU width var) (IntSet.toList vars))
            (IntMap.toList freeCustomInputVars)
      intermediateBindings <- mapM (\var -> ("$" <> show var,) <$> lookupVar var) $ IntSet.toList freeIntermediateVars
      -- collect variables and their bindings in the expression and report them
      throwError $ InterpretAssertionError e (numInputBindings <> boolInputBindings <> customInputBindings <> intermediateBindings)

  -- lastly interpret the expression and return the result
  interpret expr

-- | Interpret a program with inputs.
run :: (GaloisField n, Integral n) => Elaborated -> Inputs n -> Either (InterpretError n) [n]
run elab inputs = fst <$> runAndOutputWitnesses elab inputs

-- | Interpret a program with inputs and run some additional checks.
runAndCheck :: (GaloisField n, Integral n) => Elaborated -> Inputs n -> Either (InterpretError n) [n]
runAndCheck elab inputs = do
  (output, witness) <- runAndOutputWitnesses elab inputs

  -- See if input size is valid
  let expectedInputSize = getCountBySort OfInput (compCounters (elabComp elab))
  let actualInputSize = Inputs.size inputs
  when (expectedInputSize /= actualInputSize) $ do
    throwError $ InterpretInputSizeError expectedInputSize actualInputSize

  -- See if free variables of the program and the witness are the same
  let variables = freeIntermediateVarsOfElab elab
  let varsInWitness = IntMap.keysSet witness
  when (variables /= varsInWitness) $ do
    let missingInWitness = variables IntSet.\\ varsInWitness
    let missingInProgram = IntMap.withoutKeys witness variables
    throwError $ InterpretVarUnassignedError missingInWitness missingInProgram

  return output

--------------------------------------------------------------------------------

-- | The interpreter typeclass
class Interpret a n where
  interpret :: a -> M n [n]

instance GaloisField n => Interpret Bool n where
  interpret True = return [one]
  interpret False = return [zero]

instance (GaloisField n, Integral n) => Interpret Boolean n where
  interpret expr = case expr of
    ValB b -> interpret b
    VarB var -> pure <$> lookupVar var
    InputVarB var -> pure <$> lookupInputVarB var
    AndB x y -> zipWith bitWiseAnd <$> interpret x <*> interpret y
    OrB x y -> zipWith bitWiseOr <$> interpret x <*> interpret y
    XorB x y -> zipWith bitWiseXor <$> interpret x <*> interpret y
    NotB x -> map bitWiseNot <$> interpret x
    IfB p x y -> do
      p' <- interpret p
      case p' of
        [0] -> interpret y
        _ -> interpret x
    EqB x y -> do
      x' <- interpret x
      y' <- interpret y
      interpret (x' == y')
    EqF x y -> do
      x' <- interpret x
      y' <- interpret y
      interpret (x' == y')
    EqU _ x y -> do
      x' <- interpret x
      y' <- interpret y
      interpret (x' == y')
    BitU _ x i -> do
      xs <- interpret x
      if testBit (toInteger (head xs)) i
        then return [one]
        else return [zero]

instance GaloisField n => Interpret Integer n where
  interpret n = return [fromIntegral n]

instance (GaloisField n, Integral n) => Interpret Field n where
  interpret expr = case expr of
    ValF n -> return [fromIntegral n]
    ValFR n -> return [fromRational n]
    VarF var -> pure <$> lookupVar var
    VarFI var -> pure <$> lookupVarFI var
    AddF x y -> zipWith (+) <$> interpret x <*> interpret y
    SubF x y -> zipWith (-) <$> interpret x <*> interpret y
    MulF x y -> zipWith (*) <$> interpret x <*> interpret y
    DivF x y -> zipWith (/) <$> interpret x <*> interpret y
    IfF p x y -> do
      p' <- interpret p
      case p' of
        [0] -> interpret y
        _ -> interpret x
    BtoF x -> interpret x

instance (GaloisField n, Integral n) => Interpret UInt n where
  interpret expr = case expr of
    ValU _ n -> return [fromIntegral n]
    VarU _ var -> pure <$> lookupVar var
    InputVarU w var -> pure <$> lookupInputVarU w var
    AddU _ x y -> zipWith (+) <$> interpret x <*> interpret y
    SubU _ x y -> zipWith (-) <$> interpret x <*> interpret y
    MulU _ x y -> zipWith (*) <$> interpret x <*> interpret y
    AndU _ x y -> zipWith bitWiseAnd <$> interpret x <*> interpret y
    OrU _ x y -> zipWith bitWiseOr <$> interpret x <*> interpret y
    XorU _ x y -> zipWith bitWiseXor <$> interpret x <*> interpret y
    NotU _ x -> map bitWiseNot <$> interpret x
    RoLU w i x -> map (Kinded.bitWiseRotateL w i) <$> interpret x
    ShLU w i x -> map (Kinded.bitWiseShiftL w i) <$> interpret x
    IfU _ p x y -> do
      p' <- interpret p
      case p' of
        [0] -> interpret y
        _ -> interpret x
    BtoU _ x -> interpret x

instance (GaloisField n, Integral n) => Interpret Expr n where
  interpret expr = case expr of
    Unit -> return []
    Boolean e -> interpret e
    Field e -> interpret e
    UInt e -> interpret e
    Array xs -> concat <$> mapM interpret xs

-- Bit x i -> do
--   xs <- interpret x
--   if testBit (toInteger (head xs)) i
--     then return [one]
--     else return [zero]

--------------------------------------------------------------------------------

-- | The interpreter monad
type M n = ReaderT (Inputs n) (StateT (IntMap n) (Except (InterpretError n)))

runM :: Inputs n -> M n a -> Either (InterpretError n) (a, Witness n)
runM inputs p = runExcept (runStateT (runReaderT p inputs) mempty)

-- | A `Ref` is given a list of numbers
-- but in reality it should be just a single number.
-- addBinding :: Ref -> [n] -> M n ()
-- addBinding _ [] = error "addBinding: empty list"
-- addBinding (VarF var) val = modify (IntMap.insert var (head val))
-- addBinding (VarB var) val = modify (IntMap.insert var (head val))
-- addBinding _ _ = error "addBinding: not VarF or VarB"
addBinding :: Var -> [n] -> M n ()
addBinding var vals = modify (IntMap.insert var (head vals))

lookupVar :: Show n => Var -> M n n
lookupVar var = do
  bindings <- get
  case IntMap.lookup var bindings of
    Nothing -> throwError $ InterpretUnboundVarError var bindings
    Just val -> return val

lookupVarFI :: Show n => Var -> M n n
lookupVarFI var = do
  inputs <- asks Inputs.numInputs
  case inputs Seq.!? var of
    Nothing -> throwError $ InterpretUnboundVarError var (IntMap.fromDistinctAscList (zip [0 ..] (toList inputs)))
    Just val -> return val

lookupInputVarB :: Show n => Var -> M n n
lookupInputVarB var = do
  inputs <- asks Inputs.boolInputs
  case inputs Seq.!? var of
    Nothing -> throwError $ InterpretUnboundVarError var (IntMap.fromDistinctAscList (zip [0 ..] (toList inputs)))
    Just val -> return val

lookupInputVarU :: Show n => Int -> Var -> M n n
lookupInputVarU width var = do
  inputss <- asks Inputs.uintInputs
  case IntMap.lookup width inputss of
    Nothing -> error ("lookupInputVarU: no UInt of such bit width: " <> show width)
    Just inputs ->
      case inputs Seq.!? var of
        Nothing -> throwError $ InterpretUnboundVarError var (IntMap.fromDistinctAscList (zip [0 ..] (toList inputs)))
        Just val -> return val

--------------------------------------------------------------------------------

-- | Collect free variables of an elaborated program (that should also be present in the witness)
freeIntermediateVarsOfElab :: Elaborated -> IntSet
freeIntermediateVarsOfElab (Elaborated value context) =
  let (_, _, _, inOutputValue) = freeVars value
      inBindingsF =
        map
          (\(var, val) -> let (_, _, _, vars) = freeVarsF val in IntSet.insert var vars) -- collect both the var and its value
          (IntMap.toList (compAssignmentF context))
      inBindingsB =
        map
          (\(var, val) -> let (_, _, _, vars) = freeVarsB val in IntSet.insert var vars) -- collect both the var and its value
          (IntMap.toList (compAssignmentB context))
   in inOutputValue
        <> IntSet.unions inBindingsF
        <> IntSet.unions inBindingsB

-- | Collect variables of an expression and group them into sets of:
--    1. Field input variables
--    2. Boolean input variables
--    3. UInt input variables
--    4. intermediate variables
freeVars :: Expr -> (IntSet, IntSet, IntMap IntSet, IntSet)
freeVars expr = case expr of
  Unit -> (mempty, mempty, mempty, mempty)
  Boolean e -> freeVarsB e
  Field e -> freeVarsF e
  UInt e -> freeVarsU e
  Array xs ->
    let unzip4 = foldr (\(u, y, z, w) (us, ys, zs, ws) -> (u : us, y : ys, z : zs, w : ws)) mempty
        (ns, bs, cs, os) = unzip4 $ toList $ fmap freeVars xs
     in (IntSet.unions ns, IntSet.unions bs, IntMap.unionsWith (<>) cs, IntSet.unions os)

freeVarsB :: Boolean -> (IntSet, IntSet, IntMap IntSet, IntSet)
freeVarsB expr = case expr of
  ValB _ -> mempty
  VarB _ -> mempty
  InputVarB var -> (mempty, IntSet.singleton var, mempty, mempty)
  AndB x y -> freeVarsB x <> freeVarsB y
  OrB x y -> freeVarsB x <> freeVarsB y
  XorB x y -> freeVarsB x <> freeVarsB y
  NotB x -> freeVarsB x
  IfB p x y -> freeVarsB p <> freeVarsB x <> freeVarsB y
  EqB x y -> freeVarsB x <> freeVarsB y
  EqF x y -> freeVarsF x <> freeVarsF y
  EqU _ x y -> freeVarsU x <> freeVarsU y
  BitU _ x _ -> freeVarsU x

freeVarsF :: Field -> (IntSet, IntSet, IntMap IntSet, IntSet)
freeVarsF expr = case expr of
  ValF _ -> mempty
  ValFR _ -> mempty
  VarF _ -> mempty
  VarFI var -> (IntSet.singleton var, mempty, mempty, mempty)
  AddF x y -> freeVarsF x <> freeVarsF y
  SubF x y -> freeVarsF x <> freeVarsF y
  MulF x y -> freeVarsF x <> freeVarsF y
  DivF x y -> freeVarsF x <> freeVarsF y
  IfF p x y -> freeVarsB p <> freeVarsF x <> freeVarsF y
  BtoF x -> freeVarsB x

freeVarsU :: UInt -> (IntSet, IntSet, IntMap IntSet, IntSet)
freeVarsU expr = case expr of
  ValU _ _ -> mempty
  VarU _ _ -> mempty
  InputVarU w var -> (mempty, mempty, IntMap.singleton w (IntSet.singleton var), mempty)
  AddU _ x y -> freeVarsU x <> freeVarsU y
  SubU _ x y -> freeVarsU x <> freeVarsU y
  MulU _ x y -> freeVarsU x <> freeVarsU y
  AndU _ x y -> freeVarsU x <> freeVarsU y
  OrU _ x y -> freeVarsU x <> freeVarsU y
  XorU _ x y -> freeVarsU x <> freeVarsU y
  NotU _ x -> freeVarsU x
  RoLU _ _ x -> freeVarsU x
  ShLU _ _ x -> freeVarsU x
  IfU _ p x y -> freeVarsB p <> freeVarsU x <> freeVarsU y
  BtoU _ x -> freeVarsB x

--------------------------------------------------------------------------------

data InterpretError n
  = InterpretUnboundVarError Var (Witness n)
  | InterpretUnboundAddrError Addr Heap
  | InterpretAssertionError Expr [(String, n)]
  | InterpretVarUnassignedError IntSet (Witness n)
  | InterpretInputSizeError Int Int
  deriving (Eq, Generic, NFData)

instance Serialize n => Serialize (InterpretError n)

instance (GaloisField n, Integral n) => Show (InterpretError n) where
  show (InterpretUnboundVarError var witness) =
    "unbound variable $" ++ show var
      ++ " in witness "
      ++ showWitness witness
  show (InterpretUnboundAddrError var heap) =
    "unbound address " ++ show var
      ++ " in heap "
      ++ show heap
  show (InterpretAssertionError expr assignments) =
    "assertion failed: " <> show expr
      <> "\nassignment of variables:\n"
      <> unlines (map (\(var, val) -> "  " <> var <> " := " <> show (N val)) assignments)
  show (InterpretVarUnassignedError missingInWitness missingInProgram) =
    ( if IntSet.null missingInWitness
        then ""
        else
          "these variables have no bindings:\n  "
            ++ show (IntSet.toList missingInWitness)
    )
      <> if IntMap.null missingInProgram
        then ""
        else
          "these bindings are not in the program:\n  "
            ++ showWitness missingInProgram
  show (InterpretInputSizeError expected actual) =
    "expecting " ++ show expected ++ " inputs but got " ++ show actual
      ++ " inputs"

--------------------------------------------------------------------------------

bitWiseAnd :: (GaloisField n, Integral n) => n -> n -> n
bitWiseAnd x y = fromInteger $ (Data.Bits..&.) (toInteger x) (toInteger y)

bitWiseOr :: (GaloisField n, Integral n) => n -> n -> n
bitWiseOr x y = fromInteger $ (Data.Bits..|.) (toInteger x) (toInteger y)

bitWiseXor :: (GaloisField n, Integral n) => n -> n -> n
bitWiseXor x y = fromInteger $ Data.Bits.xor (toInteger x) (toInteger y)

bitWiseNot :: (GaloisField n, Integral n) => n -> n
bitWiseNot x = fromInteger $ Data.Bits.complement (toInteger x)
