module Mark.Internal.Parser exposing
    ( Replacement(..)
    , attribute
    , attributeList
    , float
    , getPosition
    , indentedString
    , int
    , newline
    , newlineWith
    , oneOf
    , peek
    , raggedIndentedStringAbove
    , styledText
    , withRange
    , word
    )

{-| -}

import Mark.Internal.Description exposing (..)
import Mark.Internal.Error as Error exposing (Context(..), Problem(..))
import Mark.Internal.Id as Id exposing (..)
import Mark.Internal.TolerantParser as Tolerant
import Parser.Advanced as Parser exposing ((|.), (|=), Parser)


newlineWith x =
    Parser.token (Parser.Token "\n" (Expecting x))


newline =
    Parser.token (Parser.Token "\n" Newline)


{-| -}
type alias Position =
    { offset : Int
    , line : Int
    , column : Int
    }


{-| -}
type alias Range =
    { start : Position
    , end : Position
    }


int : Parser Context Problem (Found Int)
int =
    Parser.map
        (\( pos, intResult ) ->
            case intResult of
                Ok i ->
                    Found pos i

                Err str ->
                    Unexpected
                        { range = pos
                        , problem = Error.BadInt str
                        }
        )
        (withRange
            (Parser.oneOf
                [ Parser.succeed
                    (\i str ->
                        if str == "" then
                            Ok (negate i)

                        else
                            Err (String.fromInt i ++ str)
                    )
                    |. Parser.token (Parser.Token "-" (Expecting "-"))
                    |= Parser.int Integer InvalidNumber
                    |= Parser.getChompedString (Parser.chompWhile (\c -> c /= ' ' && c /= '\n'))
                , Parser.succeed
                    (\i str ->
                        if str == "" then
                            Ok i

                        else
                            Err (String.fromInt i ++ str)
                    )
                    |= Parser.int Integer InvalidNumber
                    |= Parser.getChompedString (Parser.chompWhile (\c -> c /= ' ' && c /= '\n'))
                , Parser.succeed Err
                    |= word
                ]
            )
        )


{-| Parses a float and must end with whitespace, not additional characters.
-}
float : Parser Context Problem (Found ( String, Float ))
float =
    Parser.map
        (\( pos, floatResult ) ->
            case floatResult of
                Ok f ->
                    Found pos f

                Err str ->
                    Unexpected
                        { range = pos
                        , problem = Error.BadFloat str
                        }
        )
        (withRange
            (Parser.oneOf
                [ Parser.succeed
                    (\start fl end src extra ->
                        if extra == "" then
                            Ok ( String.slice start end src, negate fl )

                        else
                            Err (String.fromFloat fl ++ extra)
                    )
                    |= Parser.getOffset
                    |. Parser.token (Parser.Token "-" (Expecting "-"))
                    |= Parser.float FloatingPoint InvalidNumber
                    |= Parser.getOffset
                    |= Parser.getSource
                    |= Parser.getChompedString (Parser.chompWhile (\c -> c /= ' ' && c /= '\n'))
                , Parser.succeed
                    (\start fl end src extra ->
                        if extra == "" then
                            Ok ( String.slice start end src, fl )

                        else
                            Err (String.fromFloat fl ++ extra)
                    )
                    |= Parser.getOffset
                    |= Parser.float FloatingPoint InvalidNumber
                    |= Parser.getOffset
                    |= Parser.getSource
                    |= Parser.getChompedString (Parser.chompWhile (\c -> c /= ' ' && c /= '\n'))
                , Parser.succeed Err
                    |= word
                ]
            )
        )


{-| -}
indentedString : Int -> String -> Parser Context Problem (Parser.Step String String)
indentedString indentation found =
    Parser.oneOf
        -- First line, indentation is already handled by the block constructor.
        [ Parser.succeed (Parser.Done found)
            |. Parser.end End
        , Parser.succeed
            (\extra ->
                Parser.Loop <|
                    if extra then
                        found ++ "\n\n"

                    else
                        found ++ "\n"
            )
            |. newline
            |= Parser.oneOf
                [ Parser.succeed True
                    |. Parser.backtrackable (Parser.chompWhile (\c -> c == ' '))
                    |. Parser.backtrackable (Parser.token (Parser.Token "\n" Newline))
                , Parser.succeed False
                ]
        , if found == "" then
            Parser.succeed (\str -> Parser.Loop (found ++ str))
                |= Parser.getChompedString
                    (Parser.chompWhile
                        (\c -> c /= '\n')
                    )

          else
            Parser.succeed
                (\str ->
                    Parser.Loop (found ++ str)
                )
                |. Parser.token (Parser.Token (String.repeat indentation " ") (ExpectingIndentation indentation))
                |= Parser.getChompedString
                    (Parser.chompWhile
                        (\c -> c /= '\n')
                    )
        , Parser.succeed (Parser.Done found)
        ]


{-| -}
raggedIndentedStringAbove : Int -> String -> Parser Context Problem (Parser.Step String String)
raggedIndentedStringAbove indentation found =
    Parser.oneOf
        [ Parser.succeed
            (\extra ->
                Parser.Loop <|
                    if extra then
                        found ++ "\n\n"

                    else
                        found ++ "\n"
            )
            |. Parser.token (Parser.Token "\n" Newline)
            |= Parser.oneOf
                [ Parser.succeed True
                    |. Parser.backtrackable (Parser.chompWhile (\c -> c == ' '))
                    |. Parser.backtrackable (Parser.token (Parser.Token "\n" Newline))
                , Parser.succeed False
                ]
        , Parser.succeed
            (\indentCount str ->
                Parser.Loop (found ++ String.repeat indentCount " " ++ str)
            )
            |= Parser.oneOf
                (indentationBetween (indentation + 1) (indentation + 4))
            |= Parser.getChompedString
                (Parser.chompWhile
                    (\c -> c /= '\n')
                )
        , Parser.succeed (Parser.Done found)
        ]


{-| Parse any indentation between two bounds, inclusive.
-}
indentationBetween : Int -> Int -> List (Parser Context Problem Int)
indentationBetween lower higher =
    let
        bottom =
            min lower higher

        top =
            max lower higher
    in
    List.reverse
        (List.map
            (\numSpaces ->
                Parser.succeed numSpaces
                    |. Parser.token
                        (Parser.Token (String.repeat numSpaces " ")
                            (ExpectingIndentation numSpaces)
                        )
            )
            (List.range bottom top)
        )


oneOf blocks expectations seed =
    let
        gatherParsers myBlock details =
            let
                ( currentSeed, parser ) =
                    case myBlock of
                        Block name blk ->
                            blk.parser details.seed

                        Value val ->
                            val.parser details.seed
            in
            case blockName myBlock of
                Just name ->
                    { blockNames = name :: details.blockNames
                    , childBlocks = Parser.map Ok parser :: details.childBlocks
                    , childValues = details.childValues
                    , seed = currentSeed
                    }

                Nothing ->
                    { blockNames = details.blockNames
                    , childBlocks = details.childBlocks
                    , childValues = Parser.map Ok parser :: details.childValues
                    , seed = currentSeed
                    }

        children =
            List.foldl gatherParsers
                { blockNames = []
                , childBlocks = []
                , childValues = []
                , seed = newSeed
                }
                blocks

        blockParser =
            Parser.succeed identity
                |. Parser.token (Parser.Token "|" BlockStart)
                |. Parser.oneOf
                    [ Parser.chompIf (\c -> c == ' ') Space
                    , Parser.succeed ()
                    ]
                |= Parser.oneOf
                    (List.reverse children.childBlocks
                        ++ [ Parser.getIndent
                                |> Parser.andThen
                                    (\indentation ->
                                        Parser.succeed
                                            (\( pos, foundWord ) ->
                                                Err ( pos, Error.UnknownBlock children.blockNames )
                                            )
                                            |= withRange word
                                            |. newline
                                            |. Parser.loop "" (raggedIndentedStringAbove indentation)
                                    )
                           ]
                    )

        ( parentId, newSeed ) =
            Id.step seed
    in
    ( children.seed
    , Parser.succeed
        (\( range, result ) ->
            case result of
                Ok found ->
                    OneOf
                        { choices = List.map (Choice parentId) expectations
                        , child = Found range found
                        , id = parentId
                        }

                Err ( pos, unexpected ) ->
                    OneOf
                        { choices = List.map (Choice parentId) expectations
                        , child =
                            Unexpected
                                { range = pos
                                , problem = unexpected
                                }
                        , id = parentId
                        }
        )
        |= withRange
            (Parser.oneOf
                (blockParser :: List.reverse (unexpectedInOneOf expectations :: children.childValues))
            )
    )


unexpectedInOneOf expectations =
    Parser.getIndent
        |> Parser.andThen
            (\indentation ->
                Parser.succeed
                    (\( pos, foundWord ) ->
                        Err ( pos, Error.FailMatchOneOf (List.map humanReadableExpectations expectations) )
                    )
                    |= withRange word
            )



{- TEXT PARSING -}


{-| -}
type TextCursor
    = TextCursor
        { current : Text
        , start : Position
        , found : List TextDescription
        , balancedReplacements : List String
        }


type SimpleTextCursor
    = SimpleTextCursor
        { current : Text
        , start : Position
        , text : List Text
        , balancedReplacements : List String
        }


mapTextCursor fn (TextCursor curs) =
    TextCursor (fn curs)


{-| -}
type Replacement
    = Replacement String String
    | Balanced
        { start : ( String, String )
        , end : ( String, String )
        }


empty : Text
empty =
    Text emptyStyles ""


textCursor inheritedStyles startingPos =
    TextCursor
        { current = Text inheritedStyles ""
        , found = []
        , start = startingPos
        , balancedReplacements = []
        }


styledText :
    { inlines : List InlineExpectation
    , replacements : List Replacement
    }
    -> Id.Seed
    -> Position
    -> Styling
    -> List Char
    -> Parser Context Problem Description
styledText options seed startingPos inheritedStyles until =
    let
        vacantText =
            textCursor inheritedStyles startingPos

        untilStrings =
            List.map String.fromChar until

        meaningful =
            '\\' :: '\n' :: until ++ stylingChars ++ replacementStartingChars options.replacements

        ( newId, newSeed ) =
            Id.step seed

        -- TODO: return new seed!
    in
    Parser.oneOf
        [ -- Parser.chompIf (\c -> c == ' ') CantStartTextWithSpace
          -- -- TODO: return error description
          -- |> Parser.andThen
          --     (\_ ->
          --         Parser.problem CantStartTextWithSpace
          --     )
          Parser.map
            (\( pos, textNodes ) ->
                DescribeText
                    { id = newId
                    , range = pos
                    , text = textNodes
                    }
            )
            (withRange
                (Parser.loop vacantText
                    (styledTextLoop options meaningful untilStrings)
                )
            )
        ]


{-| -}
styledTextLoop :
    { inlines : List InlineExpectation
    , replacements : List Replacement
    }
    -> List Char
    -> List String
    -> TextCursor
    -> Parser Context Problem (Parser.Step TextCursor (List TextDescription))
styledTextLoop options meaningful untilStrings found =
    Parser.oneOf
        [ Parser.oneOf (replace options.replacements found)
            |> Parser.map Parser.Loop

        -- If a char matches the first character of a replacement,
        -- but didn't match the full replacement captured above,
        -- then stash that char.
        , Parser.oneOf (almostReplacement options.replacements found)
            |> Parser.map Parser.Loop

        -- Capture style command characters
        , Parser.succeed
            (Parser.Loop << changeStyle found)
            |= Parser.oneOf
                [ Parser.map (always Italic) (Parser.token (Parser.Token "/" (Expecting "/")))
                , Parser.map (always Strike) (Parser.token (Parser.Token "~" (Expecting "~")))
                , Parser.map (always Bold) (Parser.token (Parser.Token "*" (Expecting "*")))
                ]

        -- `verbatim`{label| attr = maybe this is here}
        , Parser.succeed
            (\start verbatimString maybeToken end ->
                case Debug.log "verbatim" maybeToken of
                    Nothing ->
                        let
                            note =
                                InlineVerbatim
                                    { name = Nothing
                                    , text = Text emptyStyles verbatimString
                                    , range =
                                        { start = start
                                        , end = end
                                        }
                                    , attributes = []
                                    }
                        in
                        found
                            |> commitText
                            |> addToTextCursor note
                            |> advanceTo end
                            |> Parser.Loop

                    Just (Err errors) ->
                        let
                            note =
                                InlineVerbatim
                                    { name = Nothing
                                    , text = Text emptyStyles verbatimString
                                    , range =
                                        { start = start
                                        , end = end
                                        }
                                    , attributes = []
                                    }
                        in
                        found
                            |> commitText
                            |> addToTextCursor note
                            |> advanceTo end
                            |> Parser.Loop

                    Just (Ok ( name, attrs )) ->
                        let
                            note =
                                InlineVerbatim
                                    { name = Just name
                                    , text = Text emptyStyles verbatimString
                                    , range =
                                        { start = start
                                        , end = end
                                        }
                                    , attributes = attrs
                                    }
                        in
                        found
                            |> commitText
                            |> addToTextCursor note
                            |> advanceTo end
                            |> Parser.Loop
            )
            |= getPosition
            |. Parser.token (Parser.Token "`" (Expecting "`"))
            |= Parser.getChompedString
                (Parser.chompWhile (\c -> c /= '`' && c /= '\n'))
            |. Parser.chompWhile (\c -> c == '`')
            |= Parser.oneOf
                [ Parser.map Just
                    (attrContainer
                        { attributes = List.filterMap onlyVerbatim options.inlines
                        , onError = Tolerant.skip
                        }
                    )
                , Parser.succeed Nothing
                ]
            |= getPosition

        -- {token| withAttributes = True}
        , Parser.succeed
            (\start maybeToken end ->
                case maybeToken of
                    Err errors ->
                        let
                            er =
                                UnexpectedInline
                                    { range =
                                        { start = start
                                        , end = end
                                        }
                                    , problem =
                                        Error.UnknownInline
                                            (options.inlines
                                                |> List.map inlineExample
                                            )

                                    -- TODO: FIX THIS
                                    --
                                    -- TODO: This is the wrong error
                                    -- It could be:
                                    --   unexpected attributes
                                    --   missing control characters
                                    }
                        in
                        found
                            |> commitText
                            |> addToTextCursor er
                            |> advanceTo end
                            |> Parser.Loop

                    Ok ( name, attrs ) ->
                        let
                            note =
                                InlineToken
                                    { name = name
                                    , range =
                                        { start = start
                                        , end = end
                                        }
                                    , attributes = attrs
                                    }
                        in
                        found
                            |> commitText
                            |> addToTextCursor note
                            |> advanceTo end
                            |> Parser.Loop
            )
            |= getPosition
            |= attrContainer
                { attributes = List.filterMap onlyTokens options.inlines
                , onError = Tolerant.skip
                }
            |= getPosition

        -- [Some styled /text/]{token| withAttribtues = True}
        , Parser.succeed
            (\start almostNote end ->
                case almostNote of
                    Ok ( noteText, TextCursor childCursor, ( name, attrs ) ) ->
                        let
                            note =
                                InlineAnnotation
                                    { name = name
                                    , text = noteText
                                    , range =
                                        { start = start
                                        , end = end
                                        }
                                    , attributes = attrs
                                    }
                        in
                        found
                            |> commitText
                            |> addToTextCursor note
                            |> resetBalancedReplacements childCursor.balancedReplacements
                            |> resetTextWith childCursor.current
                            |> advanceTo end
                            |> Parser.Loop

                    Err errs ->
                        let
                            er =
                                UnexpectedInline
                                    { range =
                                        { start = start
                                        , end = end
                                        }
                                    , problem =
                                        Error.UnknownInline
                                            (options.inlines
                                                |> List.map inlineExample
                                            )
                                    }
                        in
                        found
                            |> commitText
                            |> addToTextCursor er
                            |> advanceTo end
                            |> Parser.Loop
            )
            |= getPosition
            |= inlineAnnotation options found
            |= getPosition
        , -- chomp until a meaningful character
          Parser.succeed
            (\( new, final ) ->
                let
                    _ =
                        Debug.log "gathered" ( new, final )
                in
                if new == "" || final then
                    case commitText (addText (String.trimRight new) found) of
                        TextCursor txt ->
                            let
                                styling =
                                    case txt.current of
                                        Text s _ ->
                                            s
                            in
                            -- TODO: What to do on unclosed styling?
                            -- if List.isEmpty styling then
                            Parser.Done (List.reverse txt.found)
                    -- else
                    -- Parser.problem (UnclosedStyles styling)

                else
                    Parser.Loop (addText new found)
            )
            |= (Parser.getChompedString (Parser.chompWhile (\c -> not (List.member c meaningful)))
                    |> Parser.andThen
                        (\str ->
                            Parser.oneOf
                                [ Parser.succeed ( str, True )
                                    |. Parser.token (Parser.Token "\n\n" Newline)
                                , Parser.succeed ( str ++ "\n", False )
                                    |. newline
                                , Parser.succeed ( str, True )
                                    |. Parser.end End
                                , Parser.succeed ( str, False )
                                ]
                        )
               )

        -- |> Parser.andThen
        --     (\new ->
        --     )
        ]


{-| -}
almostReplacement : List Replacement -> TextCursor -> List (Parser Context Problem TextCursor)
almostReplacement replacements existing =
    let
        captureChar char =
            Parser.succeed
                (\c ->
                    addText c existing
                )
                |= Parser.getChompedString
                    (Parser.chompIf (\c -> c == char && char /= '{' && char /= '*' && char /= '/') EscapedChar)

        first repl =
            case repl of
                Replacement x y ->
                    firstChar x

                Balanced range ->
                    firstChar (Tuple.first range.start)

        allFirstChars =
            List.filterMap first replacements
    in
    List.map captureChar allFirstChars



-- inlineAnnotation : () -> () -> Tolerant.Parser Context Problem ( List Text, TextCursor, ( String, List InlineAttribute ) )


inlineAnnotation options found =
    Tolerant.succeed
        (\( text, cursor ) maybeNameAndAttrs ->
            ( text, cursor, maybeNameAndAttrs )
        )
        |> Tolerant.ignore
            (Tolerant.token
                { match = "["
                , problem = InlineStart
                , onError = Tolerant.skip
                }
            )
        |> Tolerant.keep
            (Tolerant.try
                (Parser.loop
                    (textCursor (getCurrentStyles found)
                        { offset = 0
                        , line = 1
                        , column = 1
                        }
                    )
                    (simpleStyledTextTill [ '\n', ']' ] options.replacements)
                )
            )
        |> Tolerant.ignore
            (Tolerant.token
                { match = "]"
                , problem = InlineEnd
                , onError = Tolerant.fastForwardTo [ '}', '\n' ]
                }
            )
        |> Tolerant.keep
            (attrContainer
                { attributes = List.filterMap onlyAnnotations options.inlines
                , onError = Tolerant.fastForwardTo [ '}', '\n' ]
                }
            )


simpleStyledTextTill :
    List Char
    -> List Replacement
    -> TextCursor
    -> Parser Context Problem (Parser.Step TextCursor ( List Text, TextCursor ))
simpleStyledTextTill until replacements cursor =
    -- options meaningful untilStrings found =
    Parser.oneOf
        [ Parser.oneOf (replace replacements cursor)
            |> Parser.map Parser.Loop

        -- If a char matches the first character of a replacement,
        -- but didn't match the full replacement captured above,
        -- then stash that char.
        , Parser.oneOf (almostReplacement replacements cursor)
            |> Parser.map Parser.Loop

        -- Capture style command characters
        , Parser.succeed
            (Parser.Loop << changeStyle cursor)
            |= Parser.oneOf
                [ Parser.map (always Italic) (Parser.token (Parser.Token "/" (Expecting "/")))
                , Parser.map (always Strike) (Parser.token (Parser.Token "~" (Expecting "~")))
                , Parser.map (always Bold) (Parser.token (Parser.Token "*" (Expecting "*")))
                ]
        , -- chomp until a meaningful character
          Parser.chompWhile
            (\c ->
                not (List.member c ('\\' :: '\n' :: until ++ stylingChars ++ replacementStartingChars replacements))
            )
            |> Parser.getChompedString
            |> Parser.andThen
                (\new ->
                    if new == "" || new == "\n" then
                        case commitText cursor of
                            TextCursor txt ->
                                let
                                    styling =
                                        case txt.current of
                                            Text s _ ->
                                                s
                                in
                                Parser.succeed
                                    (Parser.Done
                                        ( List.reverse <| List.filterMap toText txt.found
                                        , TextCursor txt
                                        )
                                    )

                    else
                        Parser.succeed (Parser.Loop (addText new cursor))
                )
        ]


toText textDesc =
    case textDesc of
        Styled _ txt ->
            Just txt

        _ ->
            Nothing


{-| Match one of the attribute containers

    {mytoken| attributeList }
    ^                       ^

Because there is no styled text here, we know the following can't happen:

    1. Change in text styles
    2. Any Replacements

This parser is configureable so that it will either

    fastForward or skip.

If the attributes aren't required (i.e. in a oneOf), then we want to skip to allow testing of other possibilities.

If they are required, then we can fastforward to a specific condition and continue on.

-}
attrContainer :
    { attributes : List ( String, List AttrExpectation )
    , onError : Tolerant.OnError
    }
    -> Tolerant.Parser Context Problem ( String, List InlineAttribute )
attrContainer config =
    Tolerant.succeed identity
        |> Tolerant.ignore
            (Tolerant.token
                { match = "{"
                , problem = InlineStart
                , onError = config.onError
                }
            )
        |> Tolerant.ignore (Tolerant.chompWhile (\c -> c == ' '))
        |> Tolerant.keep
            (Tolerant.oneOf InlineStart
                (List.map tokenBody config.attributes)
            )
        |> Tolerant.ignore (Tolerant.chompWhile (\c -> c == ' '))
        |> Tolerant.ignore
            (Tolerant.token
                { match = "}"
                , problem = InlineEnd
                , onError = Tolerant.fastForwardTo [ '}', '\n' ]
                }
            )


tokenBody : ( String, List AttrExpectation ) -> Tolerant.Parser Context Problem ( String, List InlineAttribute )
tokenBody ( name, attrs ) =
    case attrs of
        [] ->
            Tolerant.map (always ( name, [] )) <|
                Tolerant.keyword
                    { match = name
                    , problem = ExpectingInlineName name
                    , onError = Tolerant.skip
                    }

        _ ->
            Tolerant.succeed (\attributes -> ( name, attributes ))
                |> Tolerant.ignore
                    (Tolerant.keyword
                        { match = name
                        , problem = ExpectingInlineName name
                        , onError = Tolerant.skip
                        }
                    )
                |> Tolerant.ignore (Tolerant.chompWhile (\c -> c == ' '))
                |> Tolerant.ignore
                    (Tolerant.symbol
                        { match = "|"
                        , problem = Expecting "|"
                        , onError = Tolerant.fastForwardTo [ '}', '\n' ]
                        }
                    )
                |> Tolerant.ignore
                    (Tolerant.chompWhile (\c -> c == ' '))
                |> Tolerant.ignore (Tolerant.chompWhile (\c -> c == ' '))
                |> Tolerant.keep (Parser.loop ( attrs, [] ) attributeList)


{-| Parse a set of attributes.

They can be parsed in any order.

-}
attributeList :
    ( List AttrExpectation, List InlineAttribute )
    -> Parser Context Problem (Parser.Step ( List AttrExpectation, List InlineAttribute ) (Result (List Problem) (List InlineAttribute)))
attributeList ( attrExpectations, found ) =
    case attrExpectations of
        [] ->
            Parser.succeed (Parser.Done (Ok (List.reverse found)))

        _ ->
            let
                parseAttr i expectation =
                    Parser.succeed
                        (\attr ->
                            Parser.Loop
                                ( removeByIndex i attrExpectations
                                , attr :: found
                                )
                        )
                        |= attribute expectation
                        |. (if List.length attrExpectations > 1 then
                                Parser.succeed ()
                                    |. Parser.chompIf (\c -> c == ',') (Expecting ",")
                                    |. Parser.chompWhile (\c -> c == ' ')

                            else
                                Parser.succeed ()
                           )
            in
            Parser.oneOf
                (List.indexedMap parseAttr attrExpectations
                    -- TODO: ADD MISSING ATTRIBUTES HERE!!
                    ++ [ Parser.map (always (Parser.Done (Err []))) parseTillEnd ]
                )


attribute : AttrExpectation -> Parser Context Problem InlineAttribute
attribute attr =
    case attr of
        ExpectAttrString inlineName ->
            Parser.succeed
                (\start equals str end ->
                    AttrString
                        { name = inlineName
                        , range =
                            { start = start
                            , end = end
                            }
                        , value = str
                        }
                )
                |= getPosition
                |. Parser.keyword
                    (Parser.Token
                        inlineName
                        (ExpectingFieldName inlineName)
                    )
                |. Parser.chompWhile (\c -> c == ' ')
                |= Parser.oneOf
                    [ Parser.map (always True) (Parser.chompIf (\c -> c == '=') (Expecting "="))
                    , Parser.succeed False
                    ]
                |= Parser.getChompedString
                    (Parser.chompWhile (\c -> c /= '|' && c /= '}' && c /= '\n' && c /= ','))
                |= getPosition



{- Style Helpers -}


changeStyle (TextCursor cursor) styleToken =
    let
        cursorText =
            case cursor.current of
                Text _ txt ->
                    txt

        newText =
            cursor.current
                |> flipStyle styleToken
                |> clearText
    in
    if cursorText == "" then
        TextCursor
            { found = cursor.found
            , current = newText
            , start = cursor.start
            , balancedReplacements = cursor.balancedReplacements
            }

    else
        let
            end =
                measure cursor.start cursorText
        in
        TextCursor
            { found =
                Styled
                    { start = cursor.start
                    , end = end
                    }
                    cursor.current
                    :: cursor.found
            , start = end
            , current = newText
            , balancedReplacements = cursor.balancedReplacements
            }


clearText (Text styles _) =
    Text styles ""


flipStyle newStyle textStyle =
    case textStyle of
        Text styles str ->
            case newStyle of
                Bold ->
                    Text { styles | bold = not styles.bold } str

                Italic ->
                    Text { styles | italic = not styles.italic } str

                Strike ->
                    Text { styles | strike = not styles.strike } str


advanceTo target (TextCursor cursor) =
    TextCursor
        { found = cursor.found
        , current = cursor.current
        , start = target
        , balancedReplacements = cursor.balancedReplacements
        }


getCurrentStyles (TextCursor cursor) =
    getStyles cursor.current


getStyles (Text styles _) =
    styles


measure start textStr =
    let
        len =
            String.length textStr
    in
    { start
        | offset = start.offset + len
        , column = start.column + len
    }


commitText ((TextCursor cursor) as existingTextCursor) =
    case cursor.current of
        Text _ "" ->
            -- nothing to commit
            existingTextCursor

        Text styles cursorText ->
            let
                end =
                    measure cursor.start cursorText
            in
            TextCursor
                { found =
                    Styled
                        { start = cursor.start
                        , end = end
                        }
                        cursor.current
                        :: cursor.found
                , start = end
                , current = Text styles ""
                , balancedReplacements = cursor.balancedReplacements
                }


addToTextCursor new (TextCursor cursor) =
    TextCursor { cursor | found = new :: cursor.found }


resetBalancedReplacements newBalance (TextCursor cursor) =
    TextCursor { cursor | balancedReplacements = newBalance }


resetTextWith (Text styles _) (TextCursor cursor) =
    TextCursor { cursor | current = Text styles "" }



-- |> resetStylesTo cursor.current
{- REPLACEMENT HELPERS -}


{-| **Reclaimed typography**

This function will replace certain characters with improved typographical ones.
Escaping a character will skip the replacement.

    -> "<>" -> a non-breaking space.
        - This can be used to glue words together so that they don't break
        - It also avoids being used for spacing like `&nbsp;` because multiple instances will collapse down to one.
    -> "--" -> "en-dash"
    -> "---" -> "em-dash".
    -> Quotation marks will be replaced with curly quotes.
    -> "..." -> ellipses

-}
replace : List Replacement -> TextCursor -> List (Parser Context Problem TextCursor)
replace replacements existing =
    let
        -- Escaped characters are captured as-is
        escaped =
            Parser.succeed
                (\esc ->
                    addText esc existing
                )
                |. Parser.token
                    (Parser.Token "\\" Escape)
                |= Parser.getChompedString
                    (Parser.chompIf (always True) EscapedChar)

        replaceWith repl =
            case repl of
                Replacement x y ->
                    Parser.succeed
                        (\_ ->
                            addText y existing
                        )
                        |. Parser.token (Parser.Token x (Expecting x))
                        |= Parser.succeed ()

                Balanced range ->
                    let
                        balanceCache =
                            case existing of
                                TextCursor cursor ->
                                    cursor.balancedReplacements

                        id =
                            balanceId range
                    in
                    -- TODO: implement range replacement
                    if List.member id balanceCache then
                        case range.end of
                            ( x, y ) ->
                                Parser.succeed
                                    (addText y existing
                                        |> removeBalance id
                                    )
                                    |. Parser.token (Parser.Token x (Expecting x))

                    else
                        case range.start of
                            ( x, y ) ->
                                Parser.succeed
                                    (addText y existing
                                        |> addBalance id
                                    )
                                    |. Parser.token (Parser.Token x (Expecting x))
    in
    escaped :: List.map replaceWith replacements


balanceId balance =
    let
        join ( x, y ) =
            x ++ y
    in
    join balance.start ++ join balance.end


addBalance id (TextCursor cursor) =
    TextCursor <|
        { cursor | balancedReplacements = id :: cursor.balancedReplacements }


removeBalance id (TextCursor cursor) =
    TextCursor <|
        { cursor | balancedReplacements = List.filter ((/=) id) cursor.balancedReplacements }


addTextToText newString textNodes =
    case textNodes of
        [] ->
            [ Text emptyStyles newString ]

        (Text styles txt) :: remaining ->
            Text styles (txt ++ newString) :: remaining


addText newTxt (TextCursor cursor) =
    case cursor.current of
        Text styles txt ->
            TextCursor { cursor | current = Text styles (txt ++ newTxt) }


stylingChars =
    [ '~'
    , '['
    , '/'
    , '*'
    , '\n'
    , '{'
    , '`'
    ]


firstChar str =
    case String.uncons str of
        Nothing ->
            Nothing

        Just ( fst, _ ) ->
            Just fst


replacementStartingChars replacements =
    let
        first repl =
            case repl of
                Replacement x y ->
                    firstChar x

                Balanced range ->
                    firstChar (Tuple.first range.start)
    in
    List.filterMap first replacements



{- GENERAL HELPERS -}


withRange : Parser Context Problem thing -> Parser Context Problem ( Range, thing )
withRange parser =
    Parser.succeed
        (\start val end ->
            ( { start = start
              , end = end
              }
            , val
            )
        )
        |= getPosition
        |= parser
        |= getPosition


word : Parser Context Problem String
word =
    Parser.chompWhile Char.isAlphaNum
        |> Parser.getChompedString


peek : String -> Parser c p thing -> Parser c p thing
peek name parser =
    Parser.succeed
        (\start val end src ->
            let
                highlightParsed =
                    String.repeat (start.column - 1) " " ++ String.repeat (max 0 (end.column - start.column)) "^"

                fullLine =
                    String.slice (max 0 (start.offset - start.column)) end.offset src

                _ =
                    Debug.log name
                        -- fullLine
                        (String.slice start.offset end.offset src)

                -- _ =
                --     Debug.log name
                --         highlightParsed
            in
            val
        )
        |= getPosition
        |= parser
        |= getPosition
        |= Parser.getSource


getPosition : Parser c p Position
getPosition =
    Parser.succeed
        (\offset ( row, col ) ->
            { offset = offset
            , line = row
            , column = col
            }
        )
        |= Parser.getOffset
        |= Parser.getPosition


parseTillEnd =
    Parser.succeed
        (\str endsWithBracket ->
            endsWithBracket
        )
        |= Parser.chompWhile (\c -> c /= '\n' && c /= '}')
        |= Parser.oneOf
            [ Parser.map (always True) (Parser.token (Parser.Token "}" InlineEnd))
            , Parser.succeed False
            ]



{- MISC HELPERS -}


onlyTokens inline =
    case inline of
        ExpectAnnotation name attrs ->
            Nothing

        ExpectToken name attrs ->
            Just ( name, attrs )

        ExpectVerbatim name _ ->
            Nothing


onlyAnnotations inline =
    case inline of
        ExpectAnnotation name attrs ->
            Just ( name, attrs )

        ExpectToken name attrs ->
            Nothing

        ExpectVerbatim name _ ->
            Nothing


onlyVerbatim inline =
    case inline of
        ExpectAnnotation name attrs ->
            Nothing

        ExpectToken name attrs ->
            Nothing

        ExpectVerbatim name attrs ->
            Just ( name, attrs )


getInlineName inline =
    case inline of
        ExpectAnnotation name attrs ->
            name

        ExpectToken name attrs ->
            name

        ExpectVerbatim name _ ->
            name


removeByIndex index list =
    List.foldl
        (\item ( cursor, passed ) ->
            if cursor == index then
                ( cursor + 1, passed )

            else
                ( cursor + 1, item :: passed )
        )
        ( 0, [] )
        list
        |> Tuple.second
        |> List.reverse
