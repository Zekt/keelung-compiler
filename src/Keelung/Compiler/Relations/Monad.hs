module Keelung.Compiler.Relations.Monad (RelM, runRelM, markChanged, Seniority (..)) where

import Control.Monad.Except
import Control.Monad.Writer
import Data.Function (on)
import Keelung.Compiler.Compile.Error (Error)
import Keelung.Data.Reference

--------------------------------------------------------------------------------

type RelM n = WriterT [()] (Except (Error n))

runRelM :: RelM n a -> Except (Error n) (Maybe a)
runRelM xs = do
  (x, changes) <- runWriterT xs
  if null changes
    then return Nothing
    else return (Just x)

markChanged :: RelM n ()
markChanged = tell [()]

--------------------------------------------------------------------------------

-- | For deciding which member gets to be the root in a equivalence class.
class Seniority a where
  compareSeniority :: a -> a -> Ordering

instance Seniority RefB where
  compareSeniority = compare `on` hasLevel

instance Seniority RefU where
  compareSeniority = compare `on` hasLevel

instance Seniority RefF where
  compareSeniority = compare `on` hasLevel

instance Seniority Ref where
  compareSeniority = compare `on` hasLevel

--------------------------------------------------------------------------------

class HasLevel a where
  hasLevel :: a -> Int

instance HasLevel RefB where
  hasLevel (RefBX _) = 0
  hasLevel (RefUBit ref _) = hasLevel ref
  hasLevel _ = 100

instance HasLevel RefU where
  hasLevel (RefUX _ _) = 0
  hasLevel _ = 100

instance HasLevel RefF where
  hasLevel (RefFX _) = 0
  hasLevel _ = 100

instance HasLevel Ref where
  hasLevel (F x) = hasLevel x
  hasLevel (B x) = hasLevel x
