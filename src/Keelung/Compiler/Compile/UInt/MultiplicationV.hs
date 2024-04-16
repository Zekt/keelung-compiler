module Keelung.Compiler.Compile.UInt.MultiplicationV (compile) where

import Control.Monad.Except
import Control.Monad.RWS
import Data.Bits qualified
import Data.Field.Galois (GaloisField)
import Data.IntMap.Strict qualified as IntMap
import Keelung (FieldType (..), HasWidth (widthOf))
import Keelung.Compiler.Compile.Error qualified as Error
import Keelung.Compiler.Compile.Monad
import Keelung.Compiler.Compile.UInt.Addition
import Keelung.Compiler.Compile.UInt.Addition.LimbColumn (LimbColumn)
import Keelung.Compiler.Compile.UInt.Addition.LimbColumn qualified as LimbColumn
import Keelung.Compiler.Compile.UInt.Multiplication.Binary (compileMulB)
import Keelung.Compiler.ConstraintModule (ConstraintModule (..))
import Keelung.Compiler.Options
import Keelung.Data.FieldInfo
import Keelung.Data.LC qualified as LC
import Keelung.Data.Limb qualified as Limb
import Keelung.Data.Reference
import Keelung.Data.Slice (Slice (Slice))
import Keelung.Data.U (U)
import Keelung.Syntax (Width)

--------------------------------------------------------------------------------

-- Model of multiplication: elementary school schoolbook multiplication

-- assume that each number has been divided into L w-bit limbs
-- multiplying two numbers will result in L^2 2w-bit limbs
--
--                          a1 a2 a3
-- x                        b1 b2 b3
-- ------------------------------------------
--                             a3*b3
--                          a2*b3
--                       a1*b3
--                          a3*b2
--                       a2*b2
--                    a1*b2
--                       a3*b1
--                    a2*b1
--                 a1*b1
-- ------------------------------------------
--
-- the maximum number of operands when adding these 2w-bit limbs is 2L (with carry from the previous limb)
compile :: (GaloisField n, Integral n) => RefU -> Either RefU U -> Either RefU U -> M n ()
compile out (Right a) (Right b) = writeRefUVal out (a * b)
compile out (Right a) (Left b) = compileMul out b (Right a)
compile out (Left a) (Right b) = compileMul out a (Right b)
compile out (Left a) (Left b) = compileMul out a (Left b)

compileMul :: (GaloisField n, Integral n) => RefU -> RefU -> Either RefU U -> M n ()
compileMul out x y = do
  let outWidth = widthOf out
  let operandWidth = widthOf x -- assuming that the width of `x` is the same as the width of `y`
  fieldInfo <- gets (optFieldInfo . cmOptions)

  -- limb width limitation:
  --    2 ≤ limb width ≤ field width / 2

  -- determine the maximum and minimum limb widths
  let maxLimbWidth = fieldWidth fieldInfo `div` 2 -- cannot exceed half of the field width
  let minLimbWidth = 2 -- TEMPORARY HACK FOR ADDITION
  -- the number of limbs needed to represent an operand
  let limbNumber = operandWidth `ceilDiv` (minLimbWidth `max` outWidth `min` maxLimbWidth)
  -- the optimal width
  let limbWidth = operandWidth `ceilDiv` limbNumber

  let maxHeight = if limbWidth > 20 then 1048576 else 2 ^ limbWidth -- HACK
  case fieldTypeData fieldInfo of
    Binary _ -> compileMulB outWidth out x y
    Prime 2 -> throwError $ Error.FieldNotSupported (fieldTypeData fieldInfo)
    Prime 3 -> throwError $ Error.FieldNotSupported (fieldTypeData fieldInfo)
    Prime 5 -> throwError $ Error.FieldNotSupported (fieldTypeData fieldInfo)
    Prime 7 -> throwError $ Error.FieldNotSupported (fieldTypeData fieldInfo)
    Prime 11 -> throwError $ Error.FieldNotSupported (fieldTypeData fieldInfo)
    Prime 13 -> throwError $ Error.FieldNotSupported (fieldTypeData fieldInfo)
    _ -> mulnxn maxHeight limbWidth limbNumber out x y
  where
    -- like div, but rounds up
    ceilDiv :: Int -> Int -> Int
    ceilDiv a b = ((a - 1) `div` b) + 1

-- | n-limb by n-limb multiplication
--                       .. x2 x1 x0
-- x                     .. y2 y1 y0
-- ------------------------------------------
--                             x0*y0
--                          x1*y0
--                       x2*y0
--                    .....
--                          x0*y1
--                       x1*y1
--                    x2*y1
--                 .....
--                       x0*y2
--                    x1*y2
--                 x2*y2
--               .....
-- ------------------------------------------
mulnxn :: (GaloisField n, Integral n) => Int -> Width -> Int -> RefU -> RefU -> Either RefU U -> M n ()
mulnxn maxHeight limbWidth limbNumber out ref operand = do
  let outWidth = widthOf out
  -- generate pairs of indices for choosing limbs
  let indices = [(xi, columnIndex - xi) | columnIndex <- [0 .. limbNumber - 1], xi <- [0 .. columnIndex]]
  -- generate pairs of limbs to be added together
  limbColumns <-
    foldM
      ( \columns (xi, yi) -> do
          -- current limb width may be smaller than
          --    1. the default limb width in the highest limbs
          --    2. the width of the RefU
          let currentLimbWidthX = limbWidth `min` widthOf ref `min` (outWidth - (limbWidth * xi))
          let currentLimbWidthY = limbWidth `min` widthOf ref `min` (outWidth - (limbWidth * yi))

          let x = Slice ref (limbWidth * xi) (limbWidth * xi + currentLimbWidthX)
          let y = case operand of
                Right constant -> Left $ sum [(if Data.Bits.testBit constant (limbWidth * yi + i) then 1 else 0) * (2 ^ i) | i <- [0 .. currentLimbWidthY - 1]]
                Left refY -> Right (0, Slice refY (limbWidth * yi) (limbWidth * yi + currentLimbWidthY))
          let index = xi + yi

          (lowerLimb, upperLimb) <- mul2Limbs limbWidth (0, x) y
          -- insert the lower limb into the columns
          let columns' =
                if lowerLimb == mempty
                  then columns
                  else IntMap.insertWith (<>) index lowerLimb columns
          -- insert the upper limb into the columns
          let columns'' =
                if upperLimb == mempty || index == (limbNumber * 2) - 1 -- throw limbs higher than `limbNumber * 2` away
                  then columns'
                  else IntMap.insertWith (<>) (index + 1) upperLimb columns'
          return columns''
      )
      mempty
      indices
  -- write the result to the output RefU
  foldM_
    ( \previousCarryLimbs index -> do
        -- calculate the segment of the output RefU to be written
        let limbStart = limbWidth * index
        let currentLimbWidth = limbWidth `min` (outWidth - limbStart)
        let outputSlice = Slice out limbStart (limbStart + currentLimbWidth)

        -- see if there's a stack of limbs to be added to the output limb
        case IntMap.lookup index limbColumns of
          Just limbs -> addLimbColumn maxHeight outputSlice (previousCarryLimbs <> limbs)
          Nothing -> do
            if previousCarryLimbs == mempty
              then do
                writeSliceVal outputSlice 0
                return mempty -- no carry
              else addLimbColumn maxHeight outputSlice previousCarryLimbs
    )
    mempty
    [0 .. limbNumber * 2 - 1]

mul2Limbs :: (GaloisField n, Integral n) => Width -> (n, Slice) -> Either n (n, Slice) -> M n (LimbColumn, LimbColumn)
mul2Limbs currentLimbWidth (a, x) operand = do
  case operand of
    Left 0 -> do
      -- if the constant is 0, then the resulting limbs should be empty
      return (mempty, mempty)
    Left 1 -> do
      -- if the constant is 1, then the resulting limbs should be the same as the input
      return (LimbColumn.new 0 [Limb.newOperand x True], mempty)
    Left constant -> do
      -- (a + x) * constant = (lower + upper * 2^currentLimbWidth)
      -- the total amount of bits to represent the product = currentLimbWidth * (1 + ceil(lg(constant)))
      let upperLimbWidth = ceiling (logBase 2 (fromIntegral constant :: Double)) :: Int
      lowerSlice <- allocSlice currentLimbWidth
      upperSlice <- allocSlice upperLimbWidth

      writeAdd
        (a * constant)
        []
        [ (lowerSlice, -1),
          (upperSlice, -(2 ^ currentLimbWidth)),
          (x, constant)
        ]
      let lowerLimb = Limb.newOperand lowerSlice True
      let upperLimb = Limb.newOperand upperSlice True
      return (LimbColumn.singleton lowerLimb, LimbColumn.singleton upperLimb)
    Right (b, y) -> do
      let carryLimbWidth = widthOf x + widthOf y - currentLimbWidth
      -- (a + x) * (b + y) = (lower + upper * 2^currentLimbWidth)
      let firstOperand = LC.new a [] [(x, 1)]
      let secondOperand = LC.new b [] [(y, 1)]

      lowerSlice <- allocSlice currentLimbWidth
      upperSlice <- allocSlice carryLimbWidth
      let rightHandSide = LC.new 0 [] [(lowerSlice, 1), (upperSlice, 2 ^ currentLimbWidth)]
      writeMulWithLC firstOperand secondOperand rightHandSide

      let lowerLimb = Limb.newOperand lowerSlice True
      let upperLimb = Limb.newOperand upperSlice True
      return (LimbColumn.singleton lowerLimb, LimbColumn.singleton upperLimb)
