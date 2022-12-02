module Keelung.Compiler.Syntax.Erase (run) where

import Control.Monad.Reader
import Data.Field.Galois (GaloisField)
import qualified Data.IntMap.Strict as IntMap
import Data.Sequence (Seq (..), (|>))
import Keelung.Compiler.Constraint2
import Keelung.Compiler.Syntax.FieldBits (FieldBits (..))
import Keelung.Compiler.Syntax.Untyped
import qualified Keelung.Syntax.Typed as T

run :: (GaloisField n, Integral n) => T.Elaborated -> TypeErased n
run (T.Elaborated expr comp) =
  let T.Computation counters aF aFI bF bFI _ _ assertions = comp
      proxy = 0
      numBitWidth = bitSize proxy
   in runM numBitWidth $ do
        -- start type erasure
        expr' <- eraseExpr expr
        sameType proxy expr'
        assignmentsF <- mapM (\(var, val) -> AssignmentF (RefF var) <$> eraseExprF val) (IntMap.toList aF)
        assignmentsFI <- mapM (\(var, val) -> AssignmentF (RefFI var) <$> eraseExprF val) (IntMap.toList aFI)
        assignmentsB <- mapM (\(var, val) -> AssignmentB (RefB var) <$> eraseExprB val) (IntMap.toList bF)
        assignmentsBI <- mapM (\(var, val) -> AssignmentB (RefBI var) <$> eraseExprB val) (IntMap.toList bFI)
        let assignments = assignmentsF ++ assignmentsFI ++ assignmentsB ++ assignmentsBI
        assertions' <- concat <$> mapM eraseExpr assertions

        return $
          TypeErased
            { erasedExpr = expr',
              erasedFieldBitWidth = numBitWidth,
              -- determine the size of output vars by looking at the length of the expression
              erasedCounters = counters,
              erasedRelations = mempty,
              erasedAssertions = assertions',
              erasedAssignments = assignments
            }
  where
    -- proxy trick for devising the bit width of field elements
    sameType :: n -> [Expr n] -> M n ()
    sameType _ _ = return ()

--------------------------------------------------------------------------------

-- monad for collecting boolean vars along the way
type M n = Reader Width

runM :: Width -> M n a -> a
runM width f = runReader f width

--------------------------------------------------------------------------------

eraseExprB :: (GaloisField n, Integral n) => T.Boolean -> M n (ExprB n)
eraseExprB expr = case expr of
  T.ValB True -> return $ ValB 1
  T.ValB False -> return $ ValB 0
  T.VarB var -> return $ VarB var
  T.InputVarB var -> return $ InputVarB var
  T.AndB x y -> chainExprsOfAssocOpAndB <$> eraseExprB x <*> eraseExprB y
  T.OrB x y -> chainExprsOfAssocOpOrB <$> eraseExprB x <*> eraseExprB y
  T.XorB x y -> XorB <$> eraseExprB x <*> eraseExprB y
  T.NotB x -> NotB <$> eraseExprB x
  T.IfB p x y -> IfB <$> eraseExprB p <*> eraseExprB x <*> eraseExprB y
  T.EqB x y -> EqB <$> eraseExprB x <*> eraseExprB y
  T.EqF x y -> EqF <$> eraseExprF x <*> eraseExprF y
  T.EqU _ x y -> EqU <$> eraseExprU x <*> eraseExprU y
  T.BitU _ x i -> BitU <$> eraseExprU x <*> pure i

eraseExprF :: (GaloisField n, Integral n) => T.Field -> M n (ExprF n)
eraseExprF expr = do
  w <- ask
  case expr of
    T.ValF x -> return $ ValF w (fromInteger x)
    T.ValFR x -> return $ ValF w (fromRational x)
    T.VarF var -> return $ VarF w var
    T.VarFI var -> return $ VarFI w var
    T.AddF x y -> chainExprsOfAssocOpAddF w <$> eraseExprF x <*> eraseExprF y
    T.SubF x y -> SubF w <$> eraseExprF x <*> eraseExprF y
    T.MulF x y -> MulF w <$> eraseExprF x <*> eraseExprF y
    T.DivF x y -> DivF w <$> eraseExprF x <*> eraseExprF y
    T.IfF p x y -> IfF w <$> eraseExprB p <*> eraseExprF x <*> eraseExprF y
    T.BtoF x -> BtoF w <$> eraseExprB x

eraseExprU :: (GaloisField n, Integral n) => T.UInt -> M n (ExprU n)
eraseExprU expr = case expr of
  T.ValU w n -> return $ ValU w (fromIntegral n)
  T.VarU w var -> return $ VarU w var
  T.InputVarU w var -> return $ InputVarU w var
  T.AddU w x y -> AddU w <$> eraseExprU x <*> eraseExprU y
  T.SubU w x y -> SubU w <$> eraseExprU x <*> eraseExprU y
  T.MulU w x y -> MulU w <$> eraseExprU x <*> eraseExprU y
  T.AndU w x y -> chainExprsOfAssocOpAndU w <$> eraseExprU x <*> eraseExprU y
  T.OrU w x y -> chainExprsOfAssocOpOrU w <$> eraseExprU x <*> eraseExprU y
  T.XorU w x y -> XorU w <$> eraseExprU x <*> eraseExprU y
  T.NotU w x -> NotU w <$> eraseExprU x
  T.RoLU w i x -> RoLU w i <$> eraseExprU x
  T.ShLU w i x -> ShLU w i <$> eraseExprU x
  T.IfU w p x y -> IfU w <$> eraseExprB p <*> eraseExprU x <*> eraseExprU y
  T.BtoU w x -> BtoU w <$> eraseExprB x

eraseExpr :: (GaloisField n, Integral n) => T.Expr -> M n [Expr n]
eraseExpr expr = case expr of
  T.Unit -> return []
  T.Boolean x -> do
    x' <- eraseExprB x
    return [ExprB x']
  T.Field x -> do
    x' <- eraseExprF x
    return [ExprF x']
  T.UInt x -> do
    x' <- eraseExprU x
    return [ExprU x']
  -- T.Var ref -> pure <$> eraseRef3 ref
  T.Array exprs -> do
    exprss <- mapM eraseExpr exprs
    return (concat exprss)

-- | Flatten and chain expressions with associative operator together when possible
chainExprsOfAssocOpAddF :: Width -> ExprF n -> ExprF n -> ExprF n
chainExprsOfAssocOpAddF w x y = case (x, y) of
  (AddF _ x0 x1 xs, AddF _ y0 y1 ys) ->
    AddF w x0 x1 (xs <> (y0 :<| y1 :<| ys))
  (AddF _ x0 x1 xs, _) ->
    AddF w x0 x1 (xs |> y)
  (_, AddF _ y0 y1 ys) ->
    AddF w x y0 (y1 :<| ys)
  -- there's nothing left we can do
  _ -> AddF w x y mempty

chainExprsOfAssocOpAndB :: ExprB n -> ExprB n -> ExprB n
chainExprsOfAssocOpAndB x y = case (x, y) of
  (AndB x0 x1 xs, AndB y0 y1 ys) ->
    AndB x0 x1 (xs <> (y0 :<| y1 :<| ys))
  (AndB x0 x1 xs, _) ->
    AndB x0 x1 (xs |> y)
  (_, AndB y0 y1 ys) ->
    AndB x y0 (y1 :<| ys)
  -- there's nothing left we can do
  _ -> AndB x y mempty

chainExprsOfAssocOpAndU :: Width -> ExprU n -> ExprU n -> ExprU n
chainExprsOfAssocOpAndU w x y = case (x, y) of
  (AndU _ x0 x1 xs, AndU _ y0 y1 ys) ->
    AndU w x0 x1 (xs <> (y0 :<| y1 :<| ys))
  (AndU _ x0 x1 xs, _) ->
    AndU w x0 x1 (xs |> y)
  (_, AndU _ y0 y1 ys) ->
    AndU w x y0 (y1 :<| ys)
  -- there's nothing left we can do
  _ -> AndU w x y mempty

chainExprsOfAssocOpOrB :: ExprB n -> ExprB n -> ExprB n
chainExprsOfAssocOpOrB x y = case (x, y) of
  (OrB x0 x1 xs, OrB y0 y1 ys) ->
    OrB x0 x1 (xs <> (y0 :<| y1 :<| ys))
  (OrB x0 x1 xs, _) ->
    OrB x0 x1 (xs |> y)
  (_, OrB y0 y1 ys) ->
    OrB x y0 (y1 :<| ys)
  -- there's nothing left we can do
  _ -> OrB x y mempty

chainExprsOfAssocOpOrU :: Width -> ExprU n -> ExprU n -> ExprU n
chainExprsOfAssocOpOrU w x y = case (x, y) of
  (OrU _ x0 x1 xs, OrU _ y0 y1 ys) ->
    OrU w x0 x1 (xs <> (y0 :<| y1 :<| ys))
  (OrU _ x0 x1 xs, _) ->
    OrU w x0 x1 (xs |> y)
  (_, OrU _ y0 y1 ys) ->
    OrU w x y0 (y1 :<| ys)
  -- there's nothing left we can do
  _ -> OrU w x y mempty