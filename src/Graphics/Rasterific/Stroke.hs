module Graphics.Rasterific.Stroke
    ( flatten
    , dashize
    , strokize
    , dashedStrokize
    )  where

import Control.Applicative( Applicative, (<$>), pure )
import Data.Monoid( Monoid, (<>), mempty )
import Data.Foldable( Foldable, foldMap )
import Linear( V2( .. )
             , (^-^)
             , (^+^)
             , (^*)
             , dot
             )

import Graphics.Rasterific.Operators
import Graphics.Rasterific.Types
import Graphics.Rasterific.QuadraticBezier
import Graphics.Rasterific.CubicBezier
import Graphics.Rasterific.Line

lastPoint :: Primitive -> Point
lastPoint (LinePrim (Line _ x1)) = x1
lastPoint (BezierPrim (Bezier _ _ x2)) = x2
lastPoint (CubicBezierPrim (CubicBezier _ _ _ x3)) = x3

lastPointAndNormal :: Primitive -> (Point, Vector)
lastPointAndNormal (LinePrim (Line a b)) = (b, a `normal` b)
lastPointAndNormal (BezierPrim (Bezier _ b c)) = (c, b `normal` c)
lastPointAndNormal (CubicBezierPrim (CubicBezier _ _ c d)) = (d, c `normal` d)

firstPointAndNormal :: Primitive -> (Point, Vector)
firstPointAndNormal (LinePrim (Line a b)) = (a, a `normal` b)
firstPointAndNormal (BezierPrim (Bezier a b _)) = (a, a `normal` b)
firstPointAndNormal (CubicBezierPrim (CubicBezier a b _ _)) = (a, a `normal` b)

reversePrimitive :: Primitive -> Primitive
reversePrimitive (LinePrim (Line a b)) = (LinePrim (Line b a))
reversePrimitive (BezierPrim (Bezier a b c)) =
    (BezierPrim (Bezier c b a))
reversePrimitive (CubicBezierPrim (CubicBezier a b c d)) =
    (CubicBezierPrim (CubicBezier d c b a))

-- | Create a "rounded" join or cap
roundJoin :: Float -> Point -> Vector -> Vector -> Container Primitive
roundJoin offset p = go
  where go u v
          -- If we're already on a nice curvature,
          -- don't bother doing anything
          | u `dot` w >= 0.9 = pure . BezierPrim $ Bezier a b c
          | otherwise = go w v <> go u w
          where --     ^
                --     |w
                -- a X---X c
                --    \ /
                --     Xp
                -- ^  / \  ^
                -- u\/   \/v
                --  /     \
                a = p ^+^ u ^* offset
                c = p ^+^ v ^* offset

                w = (a `normal` c) `ifZero` u

                -- Same as offseting
                n = p ^+^ w ^* offset
                b = n ^* 2 ^-^ (a `midPoint` c)

-- | Put a cap at the end of a bezier curve, depending
-- on the kind of cap wanted.
cap :: Float -> Cap -> Primitive -> Container Primitive
cap offset CapRound prim = roundJoin offset p u (- u)
  where (p, u) = lastPointAndNormal prim

cap offset (CapStraight cVal) prim =
   pure (d `lineFromTo` e) <> pure (e `lineFromTo` f)
                           <> pure (f `lineFromTo` g)
  where -- The usual "normal"
        (p, u@(V2 ux uy)) = lastPointAndNormal prim
        -- Vector pointing in the direction of the curve
        -- of norm 1
        v = V2 uy $ negate ux

        -- Finishing points around the edge
        -- -u*offset u*offset
        --       <-><->
        --     d/  /  /g
        --     /  /  /
        --    /  /  /
        --      /
        --     / curve
        --
        d = p ^+^ u ^* offset
        g = p ^-^ u ^* offset

        -- Create the "far" points
        --
        --       e        f
        --        /     /   ^
        --       /     /   / v * offset * cVal
        --     d/  /  /g
        --     /  /  /
        --    /  /  /
        --      /
        --     / curve
        --
        e = d ^+^ v ^* (offset * cVal)
        f = g ^+^ v ^* (offset * cVal)

lineFromTo :: Point -> Point -> Primitive
lineFromTo a b = LinePrim (Line a b)

miterJoin :: Float -> Float -> Point -> Vector -> Vector
          -> Container Primitive
miterJoin offset l point u v
  | uDotW > l / max 1 l && uDotW > 0 =
      pure (m `lineFromTo` c) <> pure (a `lineFromTo` m)
  -- A simple straight junction
  | otherwise = pure $ a `lineFromTo` c
  where --      X m
        --     /\
        --    /|w\
        -- a X---X c
        --    \ /
        --     Xp
        -- ^  / \  ^
        -- u\/   \/v
        --  /     \
        a = point ^+^ u ^* offset
        c = point ^+^ v ^* offset
        w = (a `normal` c) `ifZero` u

        uDotW =  u `dot` w

        -- Calculate the maximum distance on the
        -- u axis
        p = offset / uDotW
        -- middle point for "straight joining"
        m = point + w ^* p

joinPrimitives :: StrokeWidth -> Join -> Primitive -> Primitive
               -> Container Primitive
joinPrimitives offset join prim1 prim2  =
  case join of
    JoinRound -> roundJoin offset p u v
    JoinMiter l -> miterJoin offset l p u v
  where (p, u) = lastPointAndNormal prim1
        (_, v) = firstPointAndNormal prim2

offsetPrimitives :: Float -> Primitive -> Container Primitive
offsetPrimitives offset (LinePrim (Line x1 x2)) =
    offsetPrimitives offset . BezierPrim $ straightLine x1 x2
offsetPrimitives offset (BezierPrim b) = offsetBezier offset b
offsetPrimitives offset (CubicBezierPrim c) = offsetCubicBezier offset c

offsetAndJoin :: Float -> Join -> Cap -> [Primitive]
              -> Container Primitive
offsetAndJoin _ _ _ [] = mempty
offsetAndJoin offset join caping (firstShape:rest) = go firstShape rest
  where joiner = joinPrimitives offset join
        offseter = offsetPrimitives offset
        (firstPoint, _) = firstPointAndNormal firstShape

        go prev []
           | firstPoint `isNearby` lastPoint prev = joiner prev firstShape <> offseter prev
           | otherwise = cap offset caping prev <> offseter prev
        go prev (x:xs) =
             joiner prev x <> offseter prev <> go x xs

approximateLength :: Primitive -> Float
approximateLength (LinePrim l) = lineLength l
approximateLength (BezierPrim b) = bezierLengthApproximation b
approximateLength (CubicBezierPrim c) = cubicBezierLengthApproximation c


sanitize :: Primitive -> Container Primitive
sanitize (LinePrim l) = sanitizeLine l
sanitize (BezierPrim b) = sanitizeBezier b
sanitize (CubicBezierPrim c) = sanitizeCubicBezier c

strokize :: StrokeWidth -> Join -> (Cap, Cap) -> [Primitive]
         -> [Primitive]
strokize width join (capStart, capEnd) beziers =
    offseter capEnd sanitized <>
        offseter capStart (reverse $ reversePrimitive <$> sanitized)
  where sanitized = foldMap sanitize beziers
        offseter = offsetAndJoin (width / 2) join

flattenPrimitive :: Primitive -> Container Primitive
flattenPrimitive (BezierPrim bezier) = flattenBezier bezier
flattenPrimitive (CubicBezierPrim bezier) = flattenCubicBezier bezier
flattenPrimitive (LinePrim line) = flattenLine line

breakPrimitiveAt :: Primitive -> Float -> (Primitive, Primitive)
breakPrimitiveAt (BezierPrim bezier) at = (BezierPrim a, BezierPrim b)
  where (a, b) = bezierBreakAt bezier at
breakPrimitiveAt (CubicBezierPrim bezier) at = (CubicBezierPrim a, CubicBezierPrim b)
  where (a, b) = cubicBezierBreakAt bezier at
breakPrimitiveAt (LinePrim line) at = (LinePrim a, LinePrim b)
  where (a, b) = lineBreakAt line at


flatten :: Container Primitive -> Container Primitive
flatten = foldMap flattenPrimitive

splitPrimitiveUntil :: Float -> [Primitive] -> ([Primitive], [Primitive])
splitPrimitiveUntil at = go at
  where
    go _ [] = ([], [])
    go left lst
      | left <= 0 = ([], lst)
    go left (x : xs)
      | left > primLength = (x : inInterval, afterInterval)
      | otherwise = ([beforeStop], afterStop : xs)
      where
        primLength = approximateLength x
        (inInterval, afterInterval) = go (left - primLength) xs

        (beforeStop, afterStop) =
            breakPrimitiveAt x $ left / primLength

dropPattern :: Float -> DashPattern -> DashPattern
dropPattern = go
  where
    go _ [] = []
    go offset (x:xs)
        | x < 0 = (x:xs) -- sanitizing
        | offset < x = x - offset : xs
        | otherwise {- offset >= x -} = go (offset - x) xs

dashize :: Float -> DashPattern -> [Primitive] -> [[Primitive]]
dashize offset pattern =
    taker infinitePattern . concatMap flattenPrimitive . concatMap sanitize
  where
    realOffset | offset >= 0 = offset
               | otherwise = offset + sum pattern

    infinitePattern =
        dropPattern realOffset . cycle $ filter (> 0) pattern

    taker _ [] = []
    taker [] _ = [] -- Impossible by construction, pattern is infinite
    taker (atValue:atRest) stream = toKeep : droper atRest next
      where (toKeep, next) = splitPrimitiveUntil atValue stream

    droper _ [] = []
    droper [] _ = [] -- Impossible by construction, pattern is infinite
    droper (atValue:atRest) stream = taker atRest next
      where (_toKeep, next) = splitPrimitiveUntil atValue stream

dashedStrokize :: Float -> DashPattern -> StrokeWidth
               -> Join -> (Cap, Cap) -> [Primitive]
               -> [[Primitive]]
dashedStrokize offset dashPattern width join capping beziers =
    strokize width join capping <$> dashize offset dashPattern beziers

