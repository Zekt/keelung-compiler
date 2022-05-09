{-# LANGUAGE BangPatterns #-}
{-# OPTIONS_GHC -Wno-type-defaults #-}

module Keelung.Constraint where

import Data.Field.Galois (GaloisField)
import Data.Foldable (toList)
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Keelung.Syntax.Common
import Keelung.Util (DebugGF (DebugGF))
import Keelung.Constraint.Vector (Vector)
import qualified Keelung.Constraint.Vector as Vector

--------------------------------------------------------------------------------

-- | Constraint
--      CAdd: 0 = c + c₀x₀ + c₁x₁ ... cₙxₙ
--      CMul: ax * by = c or ax * by = cz
--      CNQZ: if x == 0 then m = 0 else m = recip x
data Constraint n
  = CAdd !(Vector n)
  | CMul !(n, Var) !(n, Var) !(n, Maybe Var)
  | CNQZ Var Var -- x & m
  deriving (Eq)

-- | Smart constructor for the CAdd constraint
cadd :: GaloisField n => n -> [(Var, n)] -> Constraint n
cadd !c !xs = CAdd $ Vector.build c xs

instance (Show n, Eq n, Num n, Bounded n, Integral n, Fractional n) => Show (Constraint n) where
  show (CAdd xs) = "A " ++ show xs
  show (CMul (a, x) (b, y) (c, z)) =
    let showTerm 1 var = "$" <> show var
        showTerm coeff var = show (DebugGF coeff) <> "$" <> show var
     in "M " ++ showTerm a x <> " * " <> showTerm b y
          <> " = "
          <> case z of
            Nothing -> show $ DebugGF c
            Just z' -> showTerm c z'
  show (CNQZ x m) = "Q $" <> show x <> " $" <> show m

instance Ord n => Ord (Constraint n) where
  {-# SPECIALIZE instance Ord (Constraint GF181) #-}
  compare CMul {} CAdd {} = GT
  compare CAdd {} CMul {} = LT
  compare (CAdd xs) (CAdd ys) = compare xs ys 
  compare (CMul (a, x) (b, y) (c, z)) (CMul (a', x') (b', y') (c', z')) =
    -- perform lexicographical comparison with tuples
    compare (x, y, z, a, b, c) (x', y', z', a', b', c')
  compare CNQZ {} CNQZ {} = EQ
  compare CNQZ {} _ = LT
  compare _ CNQZ {} = GT

--------------------------------------------------------------------------------

-- | Return the list of variables occurring in constraints
varsInConstraint :: Constraint a -> IntSet
varsInConstraint (CAdd xs) = Vector.vars xs 
varsInConstraint (CMul (_, x) (_, y) (_, Nothing)) = IntSet.fromList [x, y]
varsInConstraint (CMul (_, x) (_, y) (_, Just z)) = IntSet.fromList [x, y, z]
varsInConstraint (CNQZ x y) = IntSet.fromList [x, y]

varsInConstraints :: Set (Constraint a) -> IntSet
varsInConstraints = IntSet.unions . Set.map varsInConstraint

--------------------------------------------------------------------------------

-- | Constraint System
data ConstraintSystem n = ConstraintSystem
  { csConstraints :: !(Set (Constraint n)),
    csBooleanInputVarConstraints :: ![Constraint n],
    csVars :: !IntSet,
    csInputVars :: !IntSet,
    csOutputVar :: !(Maybe Var)
  }
  deriving (Eq)

-- | return the number of constraints (including constraints of boolean input vars)
numberOfConstraints :: ConstraintSystem n -> Int
numberOfConstraints (ConstraintSystem cs cs' _ _ _) = Set.size cs + length cs'

instance (Show n, Bounded n, Integral n, Fractional n) => Show (ConstraintSystem n) where
  show (ConstraintSystem constraints boolConstraints vars inputVars outputVar) =
    "ConstraintSystem {\n\
    \  constraints ("
      <> show (length constraints)
      <> ")"
      <> ( if Set.size constraints < 30 
             then ":\n  \n" <> printConstraints (toList constraints) <> "\n"
             else "\n"
         )
      <> "  boolean constraints ("
      <> show (length boolConstraints)
      <> ")"
      <> ( if length boolConstraints < 20
             then ":\n  \n" <> printConstraints boolConstraints <> "\n"
             else "\n"
         )
      <> "  number of variables: "
      <> show (IntSet.size vars)
      <> "\n\
         \  number of input variables: "
      <> show (IntSet.size inputVars)
      <> ":\n    " <> show (IntSet.toList inputVars) <> "\n"
      -- <> ( if IntSet.size inputVars < 20
      --        then ":\n    " <> show (IntSet.toList inputVars) <> "\n"
      --        else "\n"
      --    )
      <> "\n  output variable: $"
      <> show outputVar
      <> "\n\
         \}"
    where
      printConstraints = unlines . map (\c -> "    " <> show c)

-- | Sequentially renumber term variables '0..max_var'.  Return
--   renumbered constraints, together with the total number of
--   variables in the (renumbered) constraint set and the (possibly
--   renumbered) in and out variables.
renumberConstraints :: Ord n => ConstraintSystem n -> ConstraintSystem n
renumberConstraints cs =
  ConstraintSystem
    (Set.map renumberConstraint (csConstraints cs))
    (map renumberConstraint (csBooleanInputVarConstraints cs))
    (IntSet.fromList renumberedVars)
    (IntSet.map renumber (csInputVars cs))
    (renumber <$> csOutputVar cs)
  where
    -- variables in constraints (that should be kept after renumbering!)
    vars = varsInConstraints (csConstraints cs)

    -- variables after renumbering (should have the same size as `vars`)
    renumberedVars = [0 .. IntSet.size vars - 1]

    -- mapping of old variables to new variables
    -- input variables are placed in the front
    variableMap = Map.fromList $ zip vars' renumberedVars
      where
        otherVars = IntSet.difference vars (csInputVars cs)
        vars' = IntSet.toList (csInputVars cs) ++ IntSet.toList otherVars

    renumber var = case Map.lookup var variableMap of
      Nothing ->
        error
          ( "can't find a binding for variable " ++ show var
              ++ " in map "
              ++ show variableMap
          )
      Just var' -> var'

    renumberConstraint constraint = case constraint of
      CAdd xs ->
        CAdd $ Vector.mapVars renumber xs
      CMul (a, x) (b, y) (c, z) ->
        CMul (a, renumber x) (b, renumber y) (c, renumber <$> z)
      CNQZ x y ->
        CNQZ (renumber x) (renumber y)
