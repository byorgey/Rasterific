{-# LANGUAGE FlexibleContexts #-}
-- | Compositor handle the pixel composition, which
-- leads to texture composition.
-- Very much a work in progress
module Graphics.Rasterific.Compositor
    ( Compositor
    , Modulable( .. )
    , compositionDestination
    , compositionAlpha
    ) where

import Data.Bits( unsafeShiftR )
import Data.Word( Word8, Word32 )

import Codec.Picture.Types( Pixel( .. ) )

type Compositor px =
    (PixelBaseComponent px) ->
        (PixelBaseComponent px) -> px -> px -> px

-- | Typeclass intented at pixel value modulation.
-- May be throwed out soon.
class (Ord a, Num a) => Modulable a where
  -- | Empty value representing total transparency for the given type.
  emptyValue :: a
  -- | Full value representing total opacity for a given type.
  fullValue  :: a
  -- | Given a Float in [0; 1], return the coverage in [emptyValue; fullValue]
  -- The second value is the inverse coverage
  clampCoverage :: Float -> (a, a)

  -- | Modulate two elements, staying in the [emptyValue; fullValue] range.
  modulate :: a -> a -> a

  -- | Implement a division between two elements.
  modiv :: a -> a -> a

  alphaOver :: a -- ^ coverage
            -> a -- ^ inverse coverage
            -> a -- ^ background
            -> a -- ^ foreground
            -> a
  alphaCompose :: a -> a -> a -> a -> a

  -- | Like modulate but also return the inverse coverage.
  coverageModulate :: a -> a -> (a, a)
  coverageModulate c a = (clamped, fullValue - clamped)
    where clamped = modulate a c

instance Modulable Float where
  emptyValue = 0
  fullValue = 1
  clampCoverage f = (f, 1 - f)
  modulate = (*)
  modiv = (/)
  alphaCompose coverage inverseCoverage backAlpha _ =
      coverage + backAlpha * inverseCoverage
  alphaOver coverage inverseCoverage background painted =
      coverage * painted + background * inverseCoverage

instance Modulable Word8 where
  emptyValue = 0
  fullValue = 255
  clampCoverage f = (fromIntegral c, fromIntegral $ 255 - c)
     where c = toWord8 f

  modulate c a = fromIntegral $ (v + (v `unsafeShiftR` 8)) `unsafeShiftR` 8
    where fi :: Word8 -> Word32
          fi = fromIntegral
          v = fi c * fi a + 128

  modiv c 0 = c
  modiv c a = fromIntegral . min 255 $ (fi c * 255) `div` fi a
    where fi :: Word8 -> Word32
          fi = fromIntegral

  alphaCompose coverage inverseCoverage backgroundAlpha _ =
      fromIntegral $ (v + (v `unsafeShiftR` 8)) `unsafeShiftR` 8
        where fi :: Word8 -> Word32
              fi = fromIntegral
              v = fi coverage * 255
                + fi backgroundAlpha * fi inverseCoverage + 128

  alphaOver coverage inverseCoverage background painted =
      fromIntegral $ (v + (v `unsafeShiftR` 8)) `unsafeShiftR` 8
    where fi :: Word8 -> Word32
          fi = fromIntegral
          v = fi coverage * fi painted + fi background * fi inverseCoverage + 128


toWord8 :: Float -> Int
toWord8 r = floor $ r * 255 + 0.5

compositionDestination :: (Pixel px, Modulable (PixelBaseComponent px))
                       => Compositor px
compositionDestination c _ _ a = colorMap (modulate c) $ a

compositionAlpha :: (Pixel px, Modulable (PixelBaseComponent px))
                 => Compositor px
{-# INLINE compositionAlpha #-}
compositionAlpha c ic
    | c == emptyValue = const
    | c == fullValue = \_ n -> n
    | otherwise = \bottom top ->
        let bottomOpacity = pixelOpacity bottom
            alphaOut = alphaCompose c ic bottomOpacity (pixelOpacity top)
            colorComposer _ back fore =
                (alphaOver c ic (back `modulate` bottomOpacity) fore)
                    `modiv` alphaOut
        in
        mixWithAlpha colorComposer (\_ _ -> alphaOut) bottom top

