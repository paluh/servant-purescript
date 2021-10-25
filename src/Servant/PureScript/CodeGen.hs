{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

module Servant.PureScript.CodeGen where

import Control.Lens hiding (List, op)
import Data.List (intersperse)
import qualified Data.Map as Map
import Data.Maybe (mapMaybe, maybeToList)
import qualified Data.Set as Set
import Data.Text (Text, toUpper)
import qualified Data.Text.Encoding as T
import Language.PureScript.Bridge (PSType, typeModule, TypeInfo (TypeInfo), renderText, ImportLines, mergeImportLines, typeInfoToDecl, importLineToText, typesToImportLines)
import Language.PureScript.Bridge.PSTypes (psString, psUnit)
import Network.HTTP.Types.URI (urlEncode)
import Servant.Foreign
import Servant.PureScript.Internal
import Text.PrettyPrint.Mainland

typeInfoToText :: PSType -> Text
typeInfoToText = renderText . typeInfoToDecl

genModule :: Settings -> [Req PSType] -> Doc
genModule opts reqs =
  let allParams = concatMap reqToParams reqs
      rParams = getReaderParams opts allParams
      apiImports = reqsToImportLines reqs
      imports = mergeImportLines (_standardImports opts) apiImports
   in docIntercalate
        (line <> line)
        [ genModuleHeader (_apiModuleName opts) imports,
          "foreign import encodeURIComponent :: String -> String",
          genType "SPSettings_" $ genRecord rParams,
          genClass
            (mkPsType "HasSPSettings" [mkPsType "a" []])
            [ Param "spSettings" $ mkPsType "a -> SPSettings_" []
            ],
          docIntercalate (line <> line) (map (genFunction rParams) reqs)
        ]

genModuleHeader :: Text -> ImportLines -> Doc
genModuleHeader moduleName imports =
  let importLines = map (strictText . renderText . importLineToText) . Map.elems $ imports
   in "-- File auto generated by servant-purescript! --"
        </> "module" <+> strictText moduleName <+> "where" <> line
        </> "import Prelude" <> line
        </> docIntercalate line importLines
        </> "import Affjax.RequestBody (json) as Request"
        </> "import Affjax.ResponseFormat (json) as Response"

getReaderParams :: Settings -> [PSParam] -> [PSParam]
getReaderParams opts allParams =
  let isReaderParam = (`Set.member` _readerParams opts) . _pName
      rParamsDirty = filter isReaderParam allParams
      rParamsMap = Map.fromListWith useOld . map toPair $ rParamsDirty
      rParams = map fromPair . Map.toList $ rParamsMap
      -- Helpers
      toPair (Param n t) = (n, t)
      fromPair (n, t) = Param n t
      useOld = const id
   in rParams

genType :: Text -> Doc -> Doc
genType name def =
  hang 2 ("type" <+> strictText name </> hang 2 ("=" <+> def))

genNewtype :: Text -> Doc -> Doc
genNewtype name def =
  hang 2 ("newtype" <+> strictText name </> hang 2 ("=" <+> strictText name </> def))

genDecl :: Param PSType -> Doc
genDecl param =
  param ^. (pName . to psVar) <+> "::" <+> param ^. pType . to (strictText . typeInfoToText)

genRecord :: [PSParam] -> Doc
genRecord params = lbrace <+> docIntercalate (line <> ", ") (genDecl <$> params) </> rbrace

genData :: Text -> [PSType] -> Doc
genData name ctors =
  hang 2 $
    "data"
      <+> strictText name </> "="
      <+> docIntercalate (line <> "| ") (map (strictText . typeInfoToText) ctors)

genClass :: PSType -> [Param PSType] -> Doc
genClass classType methods =
  hang 2 $
    "class"
      <+> strictText (typeInfoToText classType)
      <+> "where"
      </> docIntercalate line (map genDecl methods)

genInstance :: Text -> [PSType] -> PSType -> [Param ([Text], Doc)] -> Doc
genInstance name constraints instanceType implementations =
  "instance"
    <+> strictText name
    <+> "::"
    <+> ( if null constraints
            then mempty
            else
              lparen
                <> docIntercalate ", " (map (strictText . typeInfoToText) constraints)
                <> rparen
                <+> "=> "
        )
    <> strictText (typeInfoToText instanceType)
    <+> "where"
    </> "  "
    <> docIntercalate line (map genImplementation implementations)
  where
    genImplementation impl =
      let fName = impl ^. pName
          args = impl ^. pType . to fst
          body = impl ^. pType . to snd
       in strictText fName <+> docIntercalate space (map strictText args) <+> "=" <+> body

genFunction :: [PSParam] -> Req PSType -> Doc
genFunction allRParams req =
  let rParamsSet = Set.fromList allRParams
      fnName = req ^. reqFuncName . jsCamelCaseL
      allParamsList = baseURLParam : reqToParams req
      allParams = Set.fromList allParamsList
      fnParams = filter (not . flip Set.member rParamsSet) allParamsList -- Use list not set, as we don't want to change order of parameters
      rParams = Set.toList $ rParamsSet `Set.intersection` allParams

      pTypes = map _pType fnParams
      pNames = map _pName fnParams
      constraints =
        [ mkPsType "HasSPSettings" [mkPsType "env" []],
          mkPsType "MonadAsk" [mkPsType "env" [], mkPsType "m" []],
          mkPsType "MonadError" [mkPsType "AjaxError" [], mkPsType "m" []],
          mkPsType "MonadAff" [mkPsType "m" []]
        ]
      signature = genSignature fnName ["env", "m"] constraints pTypes (req ^. reqReturnType)
      body = genFnHead fnName pNames <+> genFnBody rParams req
   in signature </> body

genGetReaderParams :: [PSParam] -> Doc
genGetReaderParams = stack . map (genGetReaderParam . psVar . _pName)
  where
    genGetReaderParam pName' = "let" <+> pName' <+> "= spSettings." <> pName'

genSignature :: Text -> [Text] -> [PSType] -> [PSType] -> Maybe PSType -> Doc
genSignature fnName variables constraints params mRet =
  hang 2 $
    strictText fnName <+> "::"
      <> ( if null variables
             then mempty
             else line <> "forall" <+> docIntercalate space (strictText <$> variables) <> "."
         )
      <> ( if null constraints
             then mempty
             else
               line
                 <> docIntercalate
                   (" =>" <> line)
                   (map (strictText . typeInfoToText) constraints)
                 <+> "=>"
         )
      </> docIntercalate (" ->" <> line) (strictText . typeInfoToText <$> (params <> [retType]))
  where
    retType = maybe psUnit (mkPsType "m" . pure) mRet

genFnHead :: Text -> [Text] -> Doc
genFnHead fnName params = fName <+> align (docIntercalate softline docParams <+> "=")
  where
    docParams = map psVar params
    fName = strictText fnName

genFnBody :: [PSParam] -> Req PSType -> Doc
genFnBody rParams req =
  "do"
    </> indent
      2
      ( "spSettings <- asks spSettings"
          </> genGetReaderParams rParams
          </> "let httpMethod = Left"
          <+> (req ^. reqMethod . to T.decodeUtf8 . to toUpper . to strictText)
          </> hang
            4
            ( "let"
                </> "encodeQueryItem :: forall a. ToURLPiece a => String -> a -> String"
                </> "encodeQueryItem name val = name <> \"=\" <> toURLPiece val"
            )
          </> hang
            4
            ( "let"
                </> "queryArgs :: Array String"
                </> hang
                  2
                  ( "queryArgs ="
                      </> hang
                        2
                        ( docIntercalate (line <> "<> ") $
                            "[]" : req ^. reqUrl . queryStr . to (map genBuildQueryArg)
                        )
                  )
            )
          </> "let queryString = if null queryArgs then \"\" else \"?\" <> (joinWith \"&\" queryArgs)"
          </> hang
            4
            ( "let"
                </> hang
                  2
                  ( "reqURL ="
                      </> genBuildURL (req ^. reqUrl)
                  )
            )
          </> hang
            4
            ( "let"
                </> hang
                  2
                  ( "reqHeaders ="
                      </> req ^. reqHeaders . to genBuildHeaders
                  )
            )
          </> hang
            4
            ( "let"
                </> hang
                  2
                  ( "affReq ="
                      </> hang
                        2
                        ( "defaultRequest"
                            </> "{ method =" <+> "httpMethod"
                            </> ", url =" <+> "reqURL"
                            </> ", headers =" <+> "defaultRequest.headers <> reqHeaders"
                            </> ", responseFormat =" <+> "Response.json"
                            <> ( case req ^. reqBody of
                                   Nothing -> mempty
                                   Just _ -> line <> ", content = Just $ Request.json $ encodeJson reqBody"
                               )
                            </> "}"
                        )
                  )
            )
          </> "result <- liftAff $ request affReq"
          </> hang
            2
            ( "response <- case result of"
                </> "Left err -> throwError $ { request: affReq, description: ConnectingError err }"
                </> "Right r -> pure r"
            )
          </> hang
            2
            ( "when (unwrap response.status < 200 || unwrap response.status >= 299) $"
                </> "throwError $ { request: affReq, description: UnexpectedHTTPStatus response }"
            )
          </> case req ^. reqReturnType of
            Nothing -> "pure unit"
            Just _ ->
              hang
                2
                ( "case decodeJson response.body of"
                    </> "Left err -> throwError $ { request: affReq, description: DecodingError err }"
                    </> "Right body -> pure body"
                )
      )

genBuildURL :: Url PSType -> Doc
genBuildURL url =
  hang 2 $
    docIntercalate (line <> "<> ") $
      psVar baseURLId : genBuildPath (url ^. path) <> [strictText "queryString"]

----------
genBuildPath :: Path PSType -> [Doc]
genBuildPath = intersperse (dquotes "/") . map (genBuildSegment . unSegment)

genBuildSegment :: SegmentType PSType -> Doc
genBuildSegment (Static (PathSegment seg)) = dquotes $ strictText (textURLEncode False seg)
genBuildSegment (Cap arg) =
  "encodeURIComponent (toURLPiece "
    <+> arg ^. argName . to unPathSegment . to psVar
    <+> ")"

----------
genBuildQueryArg :: QueryArg PSType -> Doc
genBuildQueryArg arg = case arg ^. queryArgType of
  Normal -> "fromFoldable (encodeQueryItem" <+> argString <+> "<$>" <+> psVar argText <> ")"
  Flag -> lbracket <+> "encodeQueryItem" <+> argString <+> psVar argText <+> rbracket
  List -> lparen <+> "encodeQueryItem" <+> argString <+> "<$>" <+> psVar argText <+> rparen
  where
    argText = arg ^. queryArgName . argName . to unPathSegment
    argString = dquotes . strictText . textURLEncode True $ argText

-----------

genBuildHeaders :: [HeaderArg PSType] -> Doc
genBuildHeaders headers = lbracket <+> docIntercalate ", " (genBuildHeader <$> headers) </> "]"

genBuildHeader :: HeaderArg PSType -> Doc
genBuildHeader (HeaderArg arg) =
  let argText = arg ^. argName . to unPathSegment
      encodedArgName = strictText . textURLEncode True $ argText
   in "RequestHeader" <+> dquotes encodedArgName <+> "$" <+> "toURLPiece" <+> psVar argText
genBuildHeader (ReplaceHeaderArg _ _) = error "ReplaceHeaderArg - not yet implemented!"

reqsToImportLines :: [Req PSType] -> ImportLines
reqsToImportLines =
  typesToImportLines
    . Set.fromList
    . filter (("Prim" /=) . view typeModule)
    . concatMap reqToPSTypes

reqToPSTypes :: Req PSType -> [PSType]
reqToPSTypes req = map _pType (reqToParams req) ++ maybeToList (req ^. reqReturnType)

-- | Extract all function parameters from a given Req.
reqToParams :: Req PSType -> [Param PSType]
reqToParams req =
  Param baseURLId psString :
  fmap headerArgToParam (req ^. reqHeaders)
    ++ maybeToList (reqBodyToParam (req ^. reqBody))
    ++ urlToParams (req ^. reqUrl)

urlToParams :: Url PSType -> [Param PSType]
urlToParams url = mapMaybe (segmentToParam . unSegment) (url ^. path) ++ map queryArgToParam (url ^. queryStr)

segmentToParam :: SegmentType f -> Maybe (Param f)
segmentToParam (Static _) = Nothing
segmentToParam (Cap arg) =
  Just
    Param
      { _pType = arg ^. argType,
        _pName = arg ^. argName . to unPathSegment
      }

mkPsType :: Text -> [PSType] -> PSType
mkPsType = TypeInfo "" ""

mkPsMaybe :: PSType -> PSType
mkPsMaybe = mkPsType "Maybe" . pure

psJson :: PSType
psJson = mkPsType "Json" []

queryArgToParam :: QueryArg PSType -> Param PSType
queryArgToParam arg =
  Param
    { _pType = arg ^. queryArgName . argType,
      _pName = arg ^. queryArgName . argName . to unPathSegment
    }

headerArgToParam :: HeaderArg f -> Param f
headerArgToParam (HeaderArg arg) =
  Param
    { _pName = arg ^. argName . to unPathSegment,
      _pType = arg ^. argType
    }
headerArgToParam _ = error "We do not support ReplaceHeaderArg - as I have no idea what this is all about."

reqBodyToParam :: Maybe f -> Maybe (Param f)
reqBodyToParam = fmap (Param "reqBody")

docIntercalate :: Doc -> [Doc] -> Doc
docIntercalate i = mconcat . punctuate i

textURLEncode :: Bool -> Text -> Text
textURLEncode spaceIsPlus = T.decodeUtf8 . urlEncode spaceIsPlus . T.encodeUtf8

-- | Little helper for generating valid variable names
psVar :: Text -> Doc
psVar = strictText . toPSVarName
