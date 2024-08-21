{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# OPTIONS_GHC -Wno-missing-signatures #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}
{-# OPTIONS_GHC -Wno-unused-matches #-}
{-# OPTIONS_GHC -Wno-unused-top-binds #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use tuple-section" #-}

module ParsePCRE where

import qualified Data.Bifunctor
import Data.Char(isDigit, isAlphaNum, isLetter,
                 isAscii, isControl, isHexDigit, isSpace, toLower)
import qualified Data.HashMap.Strict as HM
import Text.ParserCombinators.ReadP

import AbsPCRE

-- Code generated by code_gen.hs
import AbsBinProp
import ParsHelpBinProp
import AbsScriptName
import ParsHelpScriptName


------------------------------------------------------------------------------
--                        Parser entrypoint

parsePCRE :: String -> Maybe Re
parsePCRE input = case readP_to_S (re <* eof) input of
    (result, "") : _ -> Just result
    _                -> Nothing


--                         Basic constructs

re :: ReadP Re
re = alt

alt :: ReadP Re
alt = Alt <$> sepBy sequencing (char '|')

sequencing :: ReadP Re
sequencing = Seq <$> (option "" comment *> many atom)

atom :: ReadP Re
atom = atom' <* option "" comment

atom' :: ReadP Re
atom'
  =   (Anchor    <$> anchor)
  <++ ((\e q m -> quantify m e q) <$> quantifiable <*> quantifier <*> quantMode)
  <++ (quantify Greedy <$> quantifiable <*> quantifier)
  <++ quantifiable
  <++ (SetStartOfMatch <$ string "\\K")
  <++ (OptSet    <$> optionSetting)
  <++ (Backtrack <$> backtrackControl)
  <++ (COut      <$> callout)
  where quantify mode e q
          = case splitQuoting e of
              Just (cs, c) ->
                -- we quantify on the last character
                Seq [Quoting cs, Quant mode q (Lit c)]
              Nothing ->
                Quant mode q e
        -- empty quoting is treated as a comment, and should not be
        -- encountered here
        splitQuoting (Quoting "") = Nothing
        splitQuoting (Quoting cs) = Just (init cs, last cs)
        -- singleton sequence or alternation: descend
        splitQuoting (Seq [e']) = splitQuoting e'
        splitQuoting (Alt [e']) = splitQuoting e'
        splitQuoting _ = Nothing

quantifiable :: ReadP Re
quantifiable
  =   (Escape    <$> escChar)
  -- a quoting is not really quantifiable, but its last character will
  -- be quanfitied, and this is handeled by the atom parser
  <++ (Quoting   <$> quoting)
  <++ group
  <++ scriptRun
  <++ lookAround
  <++ (Chartype  <$> charType)
  <++ (Cond      <$> conditional)
  <++ (Charclass <$> charClass)
  <++ (Ref       <$> backRef)
  <++ (SubRef    <$> subRef)
  <++ literal


--                               Quoting

quoting :: ReadP String
quoting
  =   (string "\\Q" *> getUntil "\\E")
  <++ (string "\\Q" *> many get <* eof)


--                        Escaped characters

escChar :: ReadP Escape
escChar
  =   (EAlert <$ string "\\a")                  -- \a
  <++ (ECtrl  <$> (string "\\c" *> nonCtrl))    -- \c non-ctrl-char
  <++ (EEsc   <$ string "\\e")                  -- \e Esc
  <++ (EFF    <$ string "\\f")                  -- \f FF
  <++ (ENL    <$ string "\\n")                  -- \n
  <++ (ECR    <$ string "\\r")                  -- \r
  <++ (ETab   <$ string "\\t")                  -- \t
  <++ (EOct   <$> (string "\\0" *> octDigits))           -- \o[0-7]{0,2}
  <++ (EOctOrBackRef <$> (string "\\" *> backRefDigits)) -- \[1-9][0-9]{2}
  <++ (EOctVar <$> (string "\\o{" *> many1 octDigit <* char '}')) -- \o{[0-7]+}
  <++ (EUni <$> (string "\\N{U+" *> many1 hexDigit <* char '}'))  -- \N{U+h+}
  <++ (EChar 'U' <$ string "\\U")                                 -- \U
  <++ (EHexVar <$> (string "\\x{" *> many1 hexDigit <* char '}')) -- \x{h+}
  <++ (EHex    <$> (string "\\x" *> hexDigits))                   -- \xh{0,2}
  <++ (EHexVar <$> (string "\\u{" *> many1 hexDigit <* char '}')) -- \u{h+}
  <++ (EHexVar <$> (string "\\u" *> count 4 hexDigit))            -- \uhhhh
  <++ (EChar   <$> (string "\\" *> nonAlphanumAscii)) -- \ non alphanum ascii


--                         Character types

charType :: ReadP Chartype
charType
  =   charTypeCommon
  <++ (CTAny <$ char '.')

charTypeCommon :: ReadP Chartype
charTypeCommon
  =   (CTCodeUnit   <$ string "\\C")
  <++ (CTDigit      <$ string "\\d")
  <++ (CTNDigit     <$ string "\\D")
  <++ (CTHSpace     <$ string "\\h")
  <++ (CTNHSpace    <$ string "\\H")
  <++ (CTNNewLine   <$ string "\\N")
  <++ (CTNewLineSeq <$ string "\\R")
  <++ (CTSpace      <$ string "\\s")
  <++ (CTNSpace     <$ string "\\S")
  <++ (CTVSpace     <$ string "\\v")
  <++ (CTNVSpace    <$ string "\\V")
  <++ (CTWordChar   <$ string "\\w")
  <++ (CTNWordChar  <$ string "\\W")
  <++ (CTUCluster   <$ string "\\X")
  <++ ctProperty

-- \p and \P character type properties
ctProperty :: ReadP Chartype
ctProperty
  =   (CTProp  <$> ((string "\\P{^" <++ string "\\p{") *> ctBody))
  <++ (CTNProp <$> ((string "\\p{^" <++ string "\\P{") *> ctBody))
  <++ (CTProp  <$> (string "\\p" *> singleCharGeneral))
  <++ (CTNProp <$> (string "\\P" *> singleCharGeneral))

-- Single character properties C, L, N, M, P, S, and Z.
singleCharGeneral :: ReadP CTProperty
singleCharGeneral = do
  c <- get
  miscProp [toLower c]

-- Everything inside \p{ } or \P{ } is converted into lower case and
-- stripped from ascii range spaces, hyphens and underscores.

ctBody :: ReadP CTProperty
ctBody = do
  body <- getUntil "}"
  case break (`elem` [':','=']) $ loosely body of
    -- Bidi classes
    (prefix, _: subject) | prefix `elem` ["bc", "bidiclass"] ->
      CTBidi <$> bidi subject
    -- Script matching, extensions
    (prefix, _: subject) | prefix `elem` ["scx", "scriptextensions"] ->
      CTScript . Extensions <$> scriptName subject
    -- Script matching, basic
    (prefix, _: subject) | prefix `elem` ["sc", "script"] ->
      CTScript . Basic <$> scriptName subject
    (subject, []) ->
      -- pcre2pattern: If a script name is given without a property type,
      -- for example, \p{Adlam}, it is treated as \p{scx:Adlam}:
      (CTScript . Extensions <$> scriptName subject)
      <++
      -- "binary properties"
      (CTBinProp <$> binProp subject)
      <++
      -- All other \p and \P properties
      -- All other \p and \P properties
      miscProp subject
    _ ->
      pfail

-- "General category properties for \p and \P" and
-- "PCRE2 special category properties for \p and \P"
miscProp :: String -> ReadP CTProperty
miscProp s = maybe pfail pure $ HM.lookup s miscProps

-- namesAndConsScriptName is gnerated from ../pcre2test/pcre2test-LS.txt
scriptName :: String -> ReadP ScriptName
scriptName s = maybe pfail pure $ HM.lookup s scriptNames
scriptNames :: HM.HashMap String ScriptName
scriptNames = HM.fromList $ flatNamesAndCons namesAndConsScriptName

-- namesAndConsBinProp is generated from ../pcre2test/pcre2test-LP.txt
binProp :: String -> ReadP BinProp
binProp s = maybe pfail pure $ HM.lookup s binProps
binProps :: HM.HashMap String BinProp
binProps = HM.fromList $ flatNamesAndCons namesAndConsBinProp

bidi :: String -> ReadP CTBidiClass
bidi s = maybe pfail pure $ lookup s bidiClasses

bidiClasses :: [(String, CTBidiClass)]
bidiClasses =
  [ ("al",  BidiAL)
  , ("an",  BidiAN)
  , ("b",   BidiB)
  , ("bn",  BidiBN)
  , ("cs",  BidiCS)
  , ("en",  BidiEN)
  , ("es",  BidiES)
  , ("et",  BidiET)
  , ("fsi", BidiFSI)
  , ("l",   BidiL)
  , ("lre", BidiLRE)
  , ("lri", BidiLRI)
  , ("lro", BidiLRO)
  , ("nsm", BidiNSM)
  , ("on",  BidiON)
  , ("pdf", BidiPDF)
  , ("pdi", BidiPDI)
  , ("r",   BidiR)
  , ("rle", BidiRLE)
  , ("rli", BidiRLI)
  , ("rlo", BidiRLO)
  , ("s",   BidiS)
  , ("ws",  BidiWS)
  ]

miscProps :: HM.HashMap String CTProperty
miscProps = HM.fromList $ concat
  [
    [ ("any", CTUAny) ],
    mapSnd (CTGenProp . Other)
    [ ("c" , C   ),   -- Other
      ("cc", Cc  ),   -- Control
      ("cf", Cf  ),   -- Format
      ("cn", Cn  ),   -- Unassigned
      ("co", Co  ),   -- Private use
      ("cs", Cs  ) ], -- , -- Surrogate
    mapSnd (CTGenProp . Letter)
    [ ("l",  L   ),   -- Letter
      ("lc", Lc  ),   -- Ll, Lu, or Lt
      ("l&", Llut),   -- "L&": Ll, Lu, or Lt
      ("ll", Ll  ),   -- Lower case letter
      ("lm", Lm  ),   -- Modifier letter
      ("lo", Lo  ),   -- Other letter
      ("lt", Lt  ),   -- Title case letter
      ("lu", Lu  ) ],   -- Upper case letter
    mapSnd (CTGenProp . Mark)
    [ ("m",   M  ),   -- Mark
      ("mc",  Mc ),   -- Spacing mark
      ("me",  Me ),   -- Enclosing mark
      ("mn",  Mn ) ], -- Non-spacing mark
    mapSnd (CTGenProp . Number)
    [ ("n",   N  ),   -- Number
      ("nd",  Nd ),   -- Decimal number
      ("nl",  Nl ),   -- Letter number
      ("no",  No ) ], -- Other number
    mapSnd (CTGenProp . Punctuation)
    [ ("p",   P  ),   -- Punctuation
      ("pc",  Pc ),   -- Connector punctuation
      ("pd",  Pd ),   -- Dash punctuation
      ("pe",  Pe ),   -- Close punctuation
      ("pf",  Pf ),   -- Final punctuation
      ("pi",  Pi ),   -- Initial punctuation
      ("po",  Po ),   -- Other punctuation
      ("ps",  Ps ) ], -- Open punctuation
    mapSnd (CTGenProp . Symbol)
    [ ("s",   S  ),   -- Symbol
      ("sc",  Sc ),   -- Currency symbol
      ("sk",  Sk ),   -- Modifier symbol
      ("sm",  Sm ),   -- Mathematical symbol
      ("so",  So ) ], -- Other symbol
    mapSnd (CTGenProp . Separator)
    [ ("z",   Z  ),   -- Separator
      ("zl",  Zl ),   -- Line separator
      ("zp",  Zp ),   -- Paragraph separator
      ("zs",  Zs ) ], -- Space separator
    mapSnd CTSpecProp
    [ ("xan", Xan),  -- Alphanumeric: union of properties L and N
      ("xps", Xps),  -- POSIX sp: property Z or tab, NL, VT, FF, CR
      ("xsp", Xsp),  -- Perl sp: property Z or tab, NL, VT, FF, CR
      ("xuc", Xuc),  -- Univ.-named character: one that can be ...
      ("xwd", Xwd) ] -- Perl word: property Xan or underscore
  ]
  where mapSnd f = map (Data.Bifunctor.second f)


--                         Character classes

charClass :: ReadP Charclass
-- special cases for emtpy classes: should be configurable
charClass
  =   postCheck checkRanges $
      fixQuoting <$> (
      (Noneof <$> (stripNullQuotes "[^" *> charClassBody' <* char ']'))
  <++ (Noneof [] <$ stripNullQuotes "[^]")
  <++ (Oneof  <$> (char   '['  *> charClassBody' <* char ']'))
  <++ (Oneof [] <$ stripNullQuotes "[]"))
  where
    charClassBody' = charClassBody <* optEmptyQuoting

    -- Character types and POSIX sets may not be part of ranges:
    checkRanges = charclassCase p p
      where p = all validRange

    validRange (Range (CCCharType _) _             ) = False
    validRange (Range _              (CCCharType _)) = False
    validRange (Range (PosixSet   _) _             ) = False
    validRange (Range _              (PosixSet   _)) = False
    validRange _                                     = True

    fixQuoting = charclassCase (Oneof . f) (Noneof . f)
      where f = removeEmtpyQuotes . fixQuotingRanges

    -- Find range endponits being non-empty quotings, and make the
    -- character adjacent to the hyphen the endpoint. This may create
    -- empty quotings, which are removed in the next pass.
    fixQuotingRanges (r@(Range a1 a2) : items) =
      case (a1, a2) of
        (CCQuoting s1, CCQuoting s2)
          | not (null s1) && not (null s2) ->
            CCAtom (CCQuoting (init s1)) :
            Range (CCLit $ last s1) (CCLit $ head s2) :
            CCAtom (CCQuoting (tail s2)) : fixQuotingRanges items
        (CCQuoting s1, a) | not (null s1) ->
           CCAtom (CCQuoting (init s1)) :
           Range (CCLit $ last s1) a : fixQuotingRanges items
        (a, CCQuoting s2) | not (null s2) ->
           Range a (CCLit $ head s2) :
           CCAtom (CCQuoting (tail s2)) : fixQuotingRanges items
        _ -> r : fixQuotingRanges items
    fixQuotingRanges (item : items) = item : fixQuotingRanges items
    fixQuotingRanges [] = []

    removeEmtpyQuotes = filter noEmptyQuoting

    noEmptyQuoting (CCAtom (CCQuoting "")) = False
    noEmptyQuoting _ = True

charClassBody :: ReadP [CharclassItem]
charClassBody
  =   ((:) . Range (CCLit ']') <$>
       (optEmptyQuoting <* stripNullQuotes "]-" *> charClassAtom) <*>
       many charClassItem)
  <++ ((CCAtom (CCLit ']') :) <$>
       (optEmptyQuoting <* char ']' *> many charClassItem))
  <++ many charClassItem

charClassRange :: ReadP CharclassItem
charClassRange
  = Range <$>
    charClassAtom <*> ((optEmptyQuoting <* char '-') *> charClassAtom)

charClassItem :: ReadP CharclassItem
charClassItem
  =   charClassRange
  <++ (CCAtom <$> charClassAtom)

charClassAtom :: ReadP CharclassAtom
charClassAtom = optEmptyQuoting *> charClassAtom'

charClassAtom' :: ReadP CharclassAtom
charClassAtom'
  =   (CCQuoting   <$> postCheck (not . null) quoting)
  <++ (CCBackspace <$  string "\\b")
  <++ (CCEsc       <$> escChar)
  <++ (CCCharType  <$> charTypeCommon)
  <++ (PosixSet    <$> posixSet)
  <++ (CCLit       <$> ccLit)

posixSet :: ReadP PosixSet
posixSet
  =   (NegSet <$> (string "[:^" *> setName <* string ":]"))
  <++ (PosSet <$> (string "[:"  *> setName <* string ":]"))

setName :: ReadP SetName
setName
  =   (SetAlnum  <$ string "alnum" ) -- alphanumeric
  <++ (SetAlpha  <$ string "alpha" ) -- alphabetic
  <++ (SetAscii  <$ string "ascii" ) -- 0-127
  <++ (SetBlank  <$ string "blank" ) -- space or tab
  <++ (SetCntrl  <$ string "cntrl" ) -- control character
  <++ (SetDigit  <$ string "digit" ) -- decimal digit
  <++ (SetGraph  <$ string "graph" ) -- printing, excluding space
  <++ (SetLower  <$ string "lower" ) -- lower case letter
  <++ (SetPrint  <$ string "print" ) -- printing, including space
  <++ (SetPunct  <$ string "punct" ) -- printing, excluding alphanumeric
  <++ (SetSpace  <$ string "space" ) -- white space
  <++ (SetUpper  <$ string "upper" ) -- upper case letter
  <++ (SetWord   <$ string "word"  ) -- same as \w
  <++ (SetXdigit <$ string "xdigit") -- hexadecimal digit

ccLit :: ReadP Char
ccLit = nonSpecial ccSpecials

-- Set of special characters that need to be escaped inside character classes
ccSpecials :: [Char]
ccSpecials = ['\\', ']']


--                           Quantifiers

quantifier :: ReadP Quantifier
quantifier = option "" comment *> quantifier'

quantifier' :: ReadP Quantifier
quantifier'
  =   (Option <$ char '?')
  <++ (Many   <$ char '*')
  <++ (Many1  <$ char '+')
  <++ (Rep    <$>
       (char '{' *> skipSpaces *> natural <* skipSpaces <* char '}'))
  -- TODO: if comments are encountered within { } the whole expression
  -- is just sequence of literals, but without the comments
  <++ (RepMin <$>
       (char '{' *> skipSpaces *> natural <* skipSpaces <*
        char ',' <* skipSpaces <* char '}'))
  <++ (RepMax <$>
       (char '{' *> skipSpaces *> char ',' *> natural <*
        skipSpaces <*  char '}'))
  <++ (RepMinMax <$>
       (char '{' *> skipSpaces *> natural <* skipSpaces <* char ',') <*>
        (skipSpaces *> natural <* skipSpaces <* char '}'))

quantMode :: ReadP QuantifierMode
quantMode = option "" comment *> quantMode'

quantMode' :: ReadP QuantifierMode
quantMode'
  =   (Possessive <$ char '+')
  <++ (Lazy <$ char '?')


--                         Anchors

anchor :: ReadP Anchor
anchor
  =   (StartOfLine          <$ char   '^')
  <++ (EndOfLine            <$ char   '$')
  <++ (StartOfSubject       <$ string "\\A")
  <++ (EndOfSubject         <$ string "\\Z")
  <++ (EndOfSubjectAbsolute <$ string "\\z")
  <++ (FirstMatchingPos     <$ string "\\G")
  <++ (WordBoundary         <$ string "\\b")
  <++ (NonWordBoundary      <$ string "\\B")
  <++ (StartOfWord          <$ string "[[:<:]]")
  <++ (EndOfWord            <$ string "[[:>:]]")


--                         Groups

group :: ReadP Re
group
  =   atomicNonCapture
  <++ nonCapture
  <++ nonCaptureOpts
  <++ namedCapture
  <++ nonCaptureReset
  <++ capture

capture :: ReadP Re
capture = Group Capture <$> (char '(' *> alt <* char ')')

nonCapture :: ReadP Re
nonCapture = Group NonCapture <$>  (string "(?:" *> alt <* char ')')

-- option setting in non-capture group (?OptsOn-OptsOff:...)
nonCaptureOpts :: ReadP Re
nonCaptureOpts
  = mkGroup <$>
    (string "(?" *> (optionsOnOff <* char ':')) <*> alt <* char ')'
  where
    mkGroup :: ([InternalOpt], [InternalOpt]) -> Re -> Re
    mkGroup (ons, offs) = Group (NonCaptureOpts ons offs)

nonCaptureReset :: ReadP Re
nonCaptureReset
  = Group NonCaptureReset <$> (string "(?|" *> alt <* char ')')

atomicNonCapture :: ReadP Re
atomicNonCapture
  = Group AtomicNonCapture <$>
    (string "(?>" <++ string "(*atomic:" *> alt <* char ')')

namedCapture :: ReadP Re
namedCapture
  =   (mkNamed <$>
       (string "(?<" *> groupName) <*> (char '>' *> alt <* char ')'))
  <++ (mkNamed <$>
       (string "(?'" *> groupName) <*> (char '\'' *> alt <* char ')'))
  <++ (mkNamed <$>
       (string "(?P<" *> groupName) <*> (char '>' *> alt <* char ')' ))
  where mkNamed name = Group (NamedCapture name)

groupName :: ReadP String
groupName = (:) <$> groupNameChar True <*> many (groupNameChar False)

--                             Comments

comment :: ReadP String
comment
  =   (string "(?#" *> getUntil ")")
  <++ emptyQuoting

emptyQuoting :: ReadP String
emptyQuoting
  =   string "\\Q\\E" -- Ignore empty quotings
  <++ string "\\E"    -- An isolated \E that is not preceded by \Q is ignored.

-- Strips away zero or more consecutive empty quotings
optEmptyQuoting :: ReadP String
optEmptyQuoting = "" <$ many emptyQuoting

--                          Option setting

optionSetting :: ReadP OptionSetting
optionSetting
  =   (StartOpt <$> (string "(*" *> startOpt <* char ')'))
  <++ (uncurry InternalOpts <$> (string "(?" *> optionsOnOff <* char ')'))

optionsOnOff :: ReadP ([InternalOpt], [InternalOpt])
optionsOnOff
  =   ((,) <$> (many internalOpt <* char '-') <*> many internalOpt)
  <++ ((\opts -> (opts, [])) <$> many internalOpt)

startOpt :: ReadP StartOpt
startOpt
  =   (LimitDepth <$> (string "LIMIT_DEPTH="     *> natural))
  <++ (LimitDepth <$> (string "LIMIT_RECURSION=" *> natural))
  <++ (LimitHeap  <$> (string "LIMIT_HEAP="      *> natural))
  <++ (LimitMatch <$> (string "LIMIT_MATCH="     *> natural))
  <++ (NotemptyAtstart <$ string "NOTEMPTY_ATSTART")
  <++ (Notempty        <$ string "NOTEMPTY")
  <++ (NoAutoPossess   <$ string "NO_AUTO_POSSESS")
  <++ (NoDotstarAnchor <$ string "NO_DOTSTAR_ANCHOR")
  <++ (NoJit      <$ string "NO_JIT")
  <++ (NoStartOpt <$ string "NO_START_OPT")
  <++ (Utf32 <$ string "UTF32")
  <++ (Utf16 <$ string "UTF16")
  <++ (Utf8  <$ string "UTF8")
  <++ (Utf <$ string "UTF")
  <++ (Ucp <$ string "UCP")
  -- Newline conventions:
  <++ (CR <$ string "CR")
  <++ (LF <$ string "LF")
  <++ (CRLF <$ string "CRLF")
  <++ (ANYCRLF <$ string "ANYCRLF")
  <++ (ANY <$ string "ANY")
  <++ (NUL <$ string "NUL")
  -- What \R matches:
  <++ (BsrAnycrlf <$ string "BSR_ANYCRLF")
  <++ (BsrUnicode <$ string "BSR_UNICODE")

internalOpt :: ReadP InternalOpt
internalOpt
  =   (CaseLess           <$ string  "i")
  <++ (AllowDupGrp        <$ string  "J")
  <++ (Multiline          <$ string  "m")
  <++ (NoAutoCapt         <$ string  "n")
  <++ (CaseLessNoMixAscii <$ string  "r")
  <++ (SingleLine         <$ string  "s")
  <++ (Ungreedy           <$ string  "U")
  <++ (IngoreWSClasses    <$ string "xx")
  <++ (IngoreWS           <$ string  "x")
  <++ (UCPAsciiD          <$ string "aD")
  <++ (UCPAsciiS          <$ string "aS")
  <++ (UCPAsciiW          <$ string "aW")
  <++ (UCPAsciiPosix      <$ string "aP")
  <++ (UCPAsciiPosixD     <$ string "aT")
  <++ (AllAscii           <$ string  "a")
  <++ (UnsetImnrsx        <$ string  "^")


--                            Lookaround

lookAround :: ReadP Re
lookAround
  =   (Look Ahead Pos <$>
       (string "(?=" <++ string "(*pla:" <++ string "(*positive_lookahead:"
      *> alt) <* char ')')
  <++ (Look Ahead Neg <$>
       (string "(?!" <++ string "(*nla:" <++ string "(*negative_lookahead:"
        *> alt) <* char ')' )
  <++ (Look Behind Pos <$>
       (string "(?<=" <++ string "(*plb:" <++ string "(*positive_lookbehind:"
        *> alt) <* char ')' )
  <++ (Look Behind Neg <$>
       (string "(?<!" <++ string "(*nlb:" <++ string "(*negative_lookbehind:"
        *> alt) <* char ')' )
  <++ (Look Ahead NonAtomicPos <$>
       (string "(?*" <++ string "(*napla:" <++
         string "(*non_atomic_positive_lookahead:"
        *> alt) <* char ')' )
  <++ (Look Behind NonAtomicPos <$>
       (string "(?<*" <++ string "(*naplb:" <++
         string "(*non_atomic_positive_lookbehind:"
        *> alt) <* char ')' )


--               Backreferences and subroutine calls

backRef :: ReadP Ref
backRef
  =   (ByName   <$> refByName  )
  <++ (Relative <$> refRelative)
  <++ (ByNumber <$> refByNumber)

refByName :: ReadP String
refByName
  =   (string "(?P=" *> groupName <* char  ')')
  <++ (string "\\k{" *> groupName <* char  '}')
  <++ (string "\\g{" *> groupName <* char  '}')
  <++ (string "\\k'" *> groupName <* char '\'')
  <++ (string "\\k<" *> groupName <* char  '>')

refRelative :: ReadP Int
refRelative
  =   (string "\\g{+" *> positive <* char '}')
  <++ (negate <$> (string "\\g{-" *> positive <* char '}'))
  <++ (string "\\g+" *> positive)
  <++ (negate <$> (string "\\g-"  *> positive))

refByNumber :: ReadP Int
refByNumber
  =   (string  "\\g{" *> positive <* char '}')
  <++ (string  "\\g"  *> positive)
  -- \ digit is handled by EOctOrBackRef

-- subroutine references (possibly recursive)
subRef :: ReadP SubRef
subRef
  =   (Recurse <$ string "(?R)" )
  <++ (CallAbs <$>
       (string "(?"    *> natural <* char ')')
        <++
        (string "\\g<"  *> natural <* char '>')
        <++
        (string "\\g'"  *> natural <* char '\''))
  <++ (CallRel <$>
       (string "(?+"   *> natural <* char ')')
        <++
        (string "\\g<+" *> natural <* char '>')
        <++
        (string "\\g'+" *> natural <* char '\''))
  <++ (CallRel . negate <$>
       (string "(?-"   *> natural <* char ')')
        <++
        (string "\\g<-" *> natural <* char '>')
        <++
        (string "\\g'-" *> natural <* char '\''))
  <++ (CallName <$>
       (string "(?&" *> groupName <* char ')')
        <++
        (string "(?P>" *> groupName <* char ')')
        <++
        (string "\\g<" *> groupName <* char '>')
        <++
        (string "\\g'" *> groupName <* char '\''))


--                           Conditionals

conditional :: ReadP Conditional
conditional
  -- sequencing is the category below alt, so we don't get '|' wrong:
  =   (CondYesNo <$>
       (string "(?(" *> condition <* char ')') <*>
       sequencing <*> (char '|' *> sequencing <* char ')'))
  <++ (CondYes <$>
       (string "(?(" *> condition <* char ')') <*> (sequencing <* char ')'))

condition :: ReadP Condition
condition
  =   (AbsRef <$> positive)
  <++ (RelRef <$> (char '+' *> positive))
  <++ (RelRef . negate <$> (char '-' *> positive))
  <++ (RecNameGrp <$> (string "R&" *> groupName))
  <++ (RecNumGrp <$> (char 'R' *> positive))
  -- From PCRE2 man page: Note the ambiguity of (?(R) and (?(Rn) which
  -- might be named reference conditions or recursion tests. Such a
  -- condition is interpreted as a reference condition if the relevant
  -- named group exists.
  <++ (Rec <$ char 'R')
  <++ (DefGrp <$ string "DEFINE")
  <++ ((\rel n m -> Version (rel ++ show n ++ "." ++ show m)) <$>
       (string "VERSION" *> string ">=" <++ string "=") <*>
       (natural <* char '.') <*> natural)
  <++ (NamedRef <$>
       (char '<' *> groupName <* char '>') <++
        (char '\'' *> groupName <* char '\'') <++
        groupName)
  <++ ((\mCallout e -> Assert mCallout Ahead Pos e) <$>
       option Nothing (Just <$> (string "?" *> calloutBody <* string ")("))
       <*>
       (string "?="  *> alt))
  <++ ((\mCallout e -> Assert mCallout Ahead Neg e) <$>
       option Nothing (Just <$> (string "?" *> calloutBody <* string ")("))
       <*>
       (string "?!"  *> alt))
  <++ ((\mCallout e -> Assert mCallout Behind Pos e) <$>
       option Nothing (Just <$> (string "?" *> calloutBody <* string ")("))
        <*>
       (string "?<="  *> alt))
  <++ ((\mCallout e -> Assert mCallout Behind Neg e) <$>
       option Nothing (Just <$> (string "?" *> calloutBody <* string ")("))
        <*>
        (string "?<!"  *> alt))


--                           Script runs

--  (*script_run:...)           ) script run, can be backtracked into
--  (*sr:...)                   )
--  (*atomic_script_run:...)    ) atomic script run
--  (*asr:...)                  )

scriptRun :: ReadP Re
scriptRun
  =   (ScriptRun NonAtomic <$>
       (string "(*script_run:" <++ string "(*sr:" *> alt) <* char ')')
  <++ (ScriptRun Atomic <$>
       (string "(*atomic_script_run:" <++ string "(*asr:" *> alt) <* char ')')


--                       Backtracking control

backtrackControl :: ReadP BacktrackControl
backtrackControl
  =   (Accept <$> (string "(*ACCEPT" *> optName <* char ')'))
  <++ (Fail   <$> ((string "(*FAIL" +++ string "(*F") *> optName <* char ')'))
  <++ (MarkName <$>
       (string "(*MARK:" <++ string "(*:" *> many1 nameChar <* char ')'))
  <++ (Commit <$> (string "(*COMMIT" *> optName <* char ')'))
  <++ (Prune <$> (string "(*PRUNE" *> optName <* char ')'))
  <++ (Skip <$> (string "(*SKIP" *> optName <* char ')'))
  <++ (Then <$> (string "(*THEN" *> optName <* char ')'))
  where optName = option Nothing (Just <$> (char ':' *> many1 nameChar))
                  +++ (Nothing <$ char ':')
        nameChar = satisfy (/=')')


--                             Callouts

callout :: ReadP Callout
callout
  = string "(?" *> calloutBody <* string ")"

calloutBody :: ReadP Callout
calloutBody
  =   (CalloutN <$> (string "C" *> natural)) -- (?Cn) with numerical data n
  <++ (CalloutS <$> (string "C" *> coutStr)) -- (?C"text") with string data
  <++ (Callout  <$  string "C")              -- (?C) (assumed number 0)

-- delimiters: ` ' " ^ % # $ and { }
coutStr :: ReadP String
coutStr
  =   coutStr_ "`"   "`"
  <++ coutStr_ "'"   "'"
  <++ coutStr_ "\"" "\""
  <++ coutStr_ "^"   "^"
  <++ coutStr_ "%"   "%"
  <++ coutStr_ "$"   "$"
  <++ coutStr_ "{"   "}"

-- The close delimiter is escaped by doubling it,
-- e.g. (?C{te{x}}t}) to escape the '}'.
coutStr_ :: String -> String -> ReadP String
coutStr_ open close
  = (\ss s -> concatMap (++ close) ss ++ s) <$>
    (string open *> many (getUntil closeTwice))
      <*> option "" (getUntil close)
  where closeTwice = close ++ close


--                             Literals

literal :: ReadP Re
literal = Lit <$> nonSpecial topLevelSpecials

nonSpecial :: Foldable t => t Char -> ReadP Char
nonSpecial specials = satisfy (not . flip elem specials)

-- Needs to be escaped on top level (outside character classes):
topLevelSpecials :: [Char]
topLevelSpecials = ['^', '\\', '|', '(', ')', '[', '$', '+', '*', '?', '.']


------------------------------------------------------------------------------
-- Parser helpers

nonCtrl :: ReadP Char
nonCtrl = satisfy (not . isControl)

nonAlphanumAscii :: ReadP Char
nonAlphanumAscii = satisfy (\c -> not (isAlphaNum c && isAscii c))

groupNameChar :: Bool -> ReadP Char
groupNameChar isFirst
  = satisfy (\c -> not isFirst && isDigit c || isLetter c || c == '_')

-- Parses 1, 2, or 3 digits starting with a positive digit
backRefDigits :: ReadP String
backRefDigits
  = count 3 backRefDigit <++ count 2 backRefDigit <++ count 1 backRefDigit

-- backRefDigit is a parser for a digit starting with [1-9]
backRefDigit :: ReadP Char
backRefDigit = posDigit <++ digit

-- posDigit is a parser for a positive digit [1-9]
posDigit :: ReadP Char
posDigit = satisfy (\c -> '1' <= c && c <= '9')

-- digit is a parser for a digit [0-9]
digit :: ReadP Char
digit = satisfy isDigit

octDigit :: ReadP Char
octDigit = satisfy (`elem` ['0'..'7'])

-- Parses 0, 1, or 2 octal digits, trying the longest match first
octDigits :: ReadP String
octDigits = count 2 octDigit <++ count 1 octDigit <++ pure []

-- Parses 1 or 2 hex digits, or an empty string, trying the longest match first
hexDigits :: ReadP String
hexDigits = count 2 hexDigit <++ count 1 hexDigit <++ pure []

-- hexDigit is a parser for a single hex digit
hexDigit :: ReadP Char
hexDigit = satisfy isHexDigit

natural :: ReadP Int
natural = read <$> many1 digit

positive :: ReadP Int
positive = postCheck (> 0) natural

-- like string, but strips away empty quotes if they occur between the
-- characters
stripNullQuotes :: String -> ReadP String
stripNullQuotes [] = pure ""
stripNullQuotes (c : cs) = (:) <$>
  char c <*> (optEmptyQuoting *> stripNullQuotes cs)

-- Get all characters cs until s appears a substring, consume s and
-- return cs
getUntil :: String -> ReadP String
getUntil s = manyTill get (string s)

postCheck :: (a -> Bool) -> ReadP a -> ReadP a
postCheck isOk p = do
  result <- p
  if isOk result
    then pure result
    else pfail

-- For "loose matching" in character type property names
loosely :: String -> String
loosely
  = map toLower . filter (\c -> not (isSpace c && isAscii c || c `elem` ['-','_']))


------------------------------------------------------------------------------
--                           Misc helpers

-- Helper to create a an association list of property names generated
-- from pcre2test -LP and -LS.
flatNamesAndCons :: [([a], b)] -> [(a, b)]
flatNamesAndCons namesAndCons = concat
  [[(nameOrAbbrev, constructor)
   | nameOrAbbrev <- nameOrAbbrevs]
  | (nameOrAbbrevs, constructor) <- namesAndCons]

charclassCase :: ([CharclassItem] -> a) -> ([CharclassItem] -> a) -> Charclass -> a
charclassCase fOneof fNoneof charclass =
  case charclass of
    Oneof  items -> fOneof  items
    Noneof items -> fNoneof items
