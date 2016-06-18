module Graphics.Vty.Input.Mouse
    ( requestMouseEvents
    , disableMouseEvents
    , isMouseEvent
    , classifyMouseEvent
    ) where

import Graphics.Vty.Input.Events
import Graphics.Vty.Input.Classify.Types

import Control.Monad.Trans.Maybe
import Control.Monad.State
import Data.List (isPrefixOf)
import Data.Maybe (catMaybes)
import Data.Bits ((.&.))

-- This implementation was informed by
--
-- http://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-Mouse-Tracking

-- A mouse event in SGR extended mode is
--
-- '\ESC' '[' '<' B ';' X ';' Y ';' ('M'|'m')
--
-- where
--
-- * B is the number with button and modifier bits set,
-- * X is the X coordinate of the event starting at 1
-- * Y is the Y coordinate of the event starting at 1
-- * the final character is 'M' for a press, 'm' for a release

-- | These sequences set xterm-based terminals to send mouse event
-- sequences.
requestMouseEvents :: String
requestMouseEvents = "\ESC[?1000h\ESC[?1002h\ESC[?1006h\ESC[?1005h"

-- | These sequences disable mouse events.
disableMouseEvents :: String
disableMouseEvents = "\ESC[?1000l\ESC[?1002l\ESC[?1006l\ESC[?1005l"

-- | Does the specified string begin with a mouse event?"
isMouseEvent :: String -> Bool
isMouseEvent s = isSGREvent s || isNormalEvent s

isSGREvent :: String -> Bool
isSGREvent = isPrefixOf sgrPrefix

sgrPrefix :: String
sgrPrefix = "\ESC[M"

isNormalEvent :: String -> Bool
isNormalEvent = isPrefixOf normalPrefix

normalPrefix :: String
normalPrefix = "\ESC[<"

-- Modifier bits:
shiftBit :: Int
shiftBit = 4

metaBit :: Int
metaBit = 8

ctrlBit :: Int
ctrlBit = 16

-- These bits indicate the buttons involved:
buttonMask :: Int
buttonMask = 3

leftButton :: Int
leftButton = 0

middleButton :: Int
middleButton = 1

rightButton :: Int
rightButton = 2

hasBitSet :: Int -> Int -> Bool
hasBitSet val bit = val .&. bit > 0

classifyMouseEvent :: String -> KClass
classifyMouseEvent s = runParser s $ do
    when (not $ isMouseEvent s) failParse

    expectChar '\ESC'
    expectChar '['
    ty <- readChar
    case ty of
        '<' -> classifySGRMouseEvent
        'M' -> classifyNormalMouseEvent
        _   -> failParse

-- Given a modifer/button value, determine which button was indicated
getSGRButton :: Int -> Parser Button
getSGRButton mods =
    let buttonMap = [ (leftButton,   BLeft)
                    , (middleButton, BMiddle)
                    , (rightButton,  BRight)
                    ]
    in case lookup (mods .&. buttonMask) buttonMap of
        Nothing -> failParse
        Just b -> return b

getModifiers :: Int -> [Modifier]
getModifiers mods =
    catMaybes [ if mods `hasBitSet` shiftBit then Just MShift else Nothing
              , if mods `hasBitSet` metaBit  then Just MMeta  else Nothing
              , if mods `hasBitSet` ctrlBit  then Just MCtrl  else Nothing
              ]

type Parser a = MaybeT (State String) a

runParser :: String -> Parser Event -> KClass
runParser s parser =
    case runState (runMaybeT parser) s of
        (Nothing, _)        -> Invalid
        (Just e, remaining) -> Valid e remaining

failParse :: Parser a
failParse = fail "invalid parse"

readInt :: Parser Int
readInt = do
    s <- get
    case (reads :: ReadS Int) s of
        [(i, rest)] -> do
            put rest
            return i
        _ -> failParse

readChar :: Parser Char
readChar = do
    s <- get
    case s of
        c:rest -> put rest >> return c
        _ -> failParse

expectChar :: Char -> Parser ()
expectChar c = do
    c' <- readChar
    if c' == c then return () else failParse

-- Attempt to classify a control sequence as a "normal" mouse event. To
-- get here we should have already read "\ESC[M" so that will not be
-- included in the string to be parsed.
classifyNormalMouseEvent :: Parser Event
classifyNormalMouseEvent = do
    statusChar <- readChar
    xCoordChar <- readChar
    yCoordChar <- readChar

    let xCoord = fromEnum xCoordChar - 32
        yCoord = fromEnum yCoordChar - 32
        status = fromEnum statusChar
        modifiers = getModifiers status

    let press = status .&. buttonMask /= 3
    case press of
            True -> do
                button <- getSGRButton status
                return $ EvMouseDown xCoord yCoord button modifiers
            False -> return $ EvMouseUp xCoord yCoord Nothing

-- Attempt to classify a control sequence as an SGR mouse event. To
-- get here we should have already read "\ESC[<" so that will not be
-- included in the string to be parsed.
classifySGRMouseEvent :: Parser Event
classifySGRMouseEvent = do
    mods <- readInt
    expectChar ';'
    xCoord <- readInt
    expectChar ';'
    yCoord <- readInt
    final <- readChar

    let modifiers = getModifiers mods
    button <- getSGRButton mods
    case final of
        'M' -> return $ EvMouseDown xCoord yCoord button modifiers
        'm' -> return $ EvMouseUp   xCoord yCoord (Just button)
        _ -> failParse
