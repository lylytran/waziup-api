{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveAnyClass #-}

module Keycloak.Types where

import           Data.Aeson
import           Data.Aeson.Casing
import           Data.Hashable
import           Data.Text hiding (head, tail, map, toLower, drop)
import           Data.Text.Encoding
import           Data.String.Conversions
import           Data.Maybe
import           Data.Map hiding (drop, map)
import qualified Data.ByteString as BS
import qualified Data.Word8 as W8 (isSpace, toLower)
import           Data.Char
import           Control.Monad.Except (ExceptT, runExceptT)
import           Control.Monad.Reader as R
import           Control.Lens hiding ((.=))
import           GHC.Generics (Generic)
import           Web.HttpApiData (FromHttpApiData(..), ToHttpApiData(..))
import           Network.HTTP.Client as HC hiding (responseBody)

-- * Keycloak Monad

-- | Keycloak Monad stack: a simple Reader monad containing the config, and an ExceptT to handle HTTPErrors and parse errors.
type Keycloak a = ReaderT KCConfig (ExceptT KCError IO) a

-- | Contains HTTP errors and parse errors.
data KCError = HTTPError HttpException  -- ^ Keycloak returned an HTTP error.
             | ParseError Text          -- ^ Failed when parsing the response
             | EmptyError               -- ^ Empty error to serve as a zero element for Monoid.
             deriving (Show)

-- | Configuration of Keycloak.
data KCConfig = KCConfig {
  _confBaseUrl       :: Text,
  _confRealm         :: Text,
  _confClientId      :: Text,
  _confClientSecret  :: Text} deriving (Eq, Show)

-- | Default configuration
defaultKCConfig :: KCConfig
defaultKCConfig = KCConfig {
  _confBaseUrl       = "http://localhost:8080/auth",
  _confRealm         = "waziup",
  _confClientId      = "api-server",
  _confClientSecret  = "4e9dcb80-efcd-484c-b3d7-1e95a0096ac0"}

-- | Run a Keycloak monad within IO.
runKeycloak :: Keycloak a -> KCConfig -> IO (Either KCError a)
runKeycloak kc conf = runExceptT $ runReaderT kc conf

type Path = Text


-- * Token

-- | Wrapper for tokens.
newtype Token = Token {unToken :: BS.ByteString} deriving (Eq, Show, Generic)

instance ToJSON Token where
  toJSON (Token t) = String $ convertString t

-- | parser for Authorization header
instance FromHttpApiData Token where
  parseQueryParam = parseHeader . encodeUtf8
  parseHeader (extractBearerAuth -> Just tok) = Right $ Token tok
  parseHeader _ = Left "cannot extract auth Bearer"

extractBearerAuth :: BS.ByteString -> Maybe BS.ByteString
extractBearerAuth bs =
    let (x, y) = BS.break W8.isSpace bs
    in if BS.map W8.toLower x == "bearer"
        then Just $ BS.dropWhile W8.isSpace y
        else Nothing

-- | Create Authorization header
instance ToHttpApiData Token where
  toQueryParam (Token token) = "Bearer " <> (decodeUtf8 token)
 
-- | Keycloak Token additional claims
tokNonce, tokAuthTime, tokSessionState, tokAtHash, tokCHash, tokName, tokGivenName, tokFamilyName, tokMiddleName, tokNickName, tokPreferredUsername, tokProfile, tokPicture, tokWebsite, tokEmail, tokEmailVerified, tokGender, tokBirthdate, tokZoneinfo, tokLocale, tokPhoneNumber, tokPhoneNumberVerified,tokAddress, tokUpdateAt, tokClaimsLocales, tokACR :: Text
tokNonce               = "nonce";
tokAuthTime            = "auth_time";
tokSessionState        = "session_state";
tokAtHash              = "at_hash";
tokCHash               = "c_hash";
tokName                = "name";
tokGivenName           = "given_name";
tokFamilyName          = "family_name";
tokMiddleName          = "middle_name";
tokNickName            = "nickname";
tokPreferredUsername   = "preferred_username";
tokProfile             = "profile";
tokPicture             = "picture";
tokWebsite             = "website";
tokEmail               = "email";
tokEmailVerified       = "email_verified";
tokGender              = "gender";
tokBirthdate           = "birthdate";
tokZoneinfo            = "zoneinfo";
tokLocale              = "locale";
tokPhoneNumber         = "phone_number";
tokPhoneNumberVerified = "phone_number_verified";
tokAddress             = "address";
tokUpdateAt            = "updated_at";
tokClaimsLocales       = "claims_locales";
tokACR                 = "acr";

-- | Token reply from Keycloak
data TokenRep = TokenRep {
  accessToken       :: Text,
  expiresIn         :: Int,
  refreshExpriresIn :: Int,
  refreshToken      :: Text,
  tokenType         :: Text,
  notBeforePolicy   :: Int,
  sessionState      :: Text,
  tokenScope        :: Text} deriving (Show, Eq)

instance FromJSON TokenRep where
  parseJSON (Object v) = TokenRep <$> v .: "access_token"
                                  <*> v .: "expires_in"
                                  <*> v .: "refresh_expires_in"
                                  <*> v .: "refresh_token"
                                  <*> v .: "token_type"
                                  <*> v .: "not-before-policy"
                                  <*> v .: "session_state"
                                  <*> v .: "scope"
  parseJSON _ = error "Not an object"

-- * Permissions

-- | Scope name
newtype ScopeName = ScopeName {unScopeName :: Text} deriving (Eq, Generic, Ord, Hashable)

--JSON instances
instance ToJSON ScopeName where
  toJSON = genericToJSON (defaultOptions {unwrapUnaryRecords = True})

instance FromJSON ScopeName where
  parseJSON = genericParseJSON (defaultOptions {unwrapUnaryRecords = True})

instance Show ScopeName where
  show (ScopeName s) = convertString s

-- | Scope Id
newtype ScopeId = ScopeId {unScopeId :: Text} deriving (Show, Eq, Generic)

--JSON instances
instance ToJSON ScopeId where
  toJSON = genericToJSON (defaultOptions {unwrapUnaryRecords = True})

instance FromJSON ScopeId where
  parseJSON = genericParseJSON (defaultOptions {unwrapUnaryRecords = True})

-- | Keycloak scope
data Scope = Scope {
  scopeId   :: Maybe ScopeId,
  scopeName :: ScopeName
  } deriving (Generic, Show, Eq)

instance ToJSON Scope where
  toJSON = genericToJSON defaultOptions {fieldLabelModifier = unCapitalize . drop 5, omitNothingFields = True}

instance FromJSON Scope where
  parseJSON = genericParseJSON defaultOptions {fieldLabelModifier = unCapitalize . drop 5}

-- | Keycloak permission on a resource
data Permission = Permission 
  { permRsid   :: Maybe ResourceId,   -- Resource ID, can be Nothing in case of scope-only permission request
    permRsname :: Maybe ResourceName, -- Resrouce Name
    permScopes :: [ScopeName]         -- Scopes that are accessible Non empty
  } deriving (Generic, Show, Eq)

instance ToJSON Permission where
  toJSON = genericToJSON defaultOptions {fieldLabelModifier = unCapitalize . drop 4, omitNothingFields = True}

instance FromJSON Permission where
  parseJSON = genericParseJSON defaultOptions {fieldLabelModifier = unCapitalize . drop 4}

-- | permission request
data PermReq = PermReq 
  { permReqResourceId :: Maybe ResourceId, -- Requested ressource Ids. Nothing means "All resources".
    permReqScopes     :: [ScopeName]       -- Scopes requested. [] means "all scopes".
  } deriving (Generic, Eq, Ord, Hashable)

instance Show PermReq where
  show (PermReq (Just (ResourceId res1)) scopes) = (show res1) <> " " <> (show scopes)
  show (PermReq Nothing scopes)                  = "none " <> (show scopes)



-- * User

type Username = Text
type Password = Text
type First = Int
type Max = Int

-- | Id of a user
newtype UserId = UserId {unUserId :: Text} deriving (Show, Eq, Generic)

--JSON instances
instance ToJSON UserId where
  toJSON = genericToJSON (defaultOptions {unwrapUnaryRecords = True})

instance FromJSON UserId where
  parseJSON = genericParseJSON (defaultOptions {unwrapUnaryRecords = True})

-- | User 
data User = User
  { userId        :: Maybe UserId   -- ^ The unique user ID 
  , userUsername  :: Username       -- ^ Username
  , userFirstName :: Maybe Text     -- ^ First name
  , userLastName  :: Maybe Text     -- ^ Last name
  , userEmail     :: Maybe Text     -- ^ Email
  , userAttributes :: Maybe (Map Text [Text]) 
  } deriving (Show, Eq, Generic)

unCapitalize :: String -> String
unCapitalize (a:as) = toLower a : as
unCapitalize [] = []

instance FromJSON User where
  parseJSON = genericParseJSON defaultOptions {fieldLabelModifier = unCapitalize . drop 4}

instance ToJSON User where
  toJSON = genericToJSON defaultOptions {fieldLabelModifier = unCapitalize . drop 4, omitNothingFields = True}



-- * Owner

-- | A resource owner
data Owner = Owner {
  ownId   :: Maybe Text,
  ownName :: Maybe Username
  } deriving (Generic, Show)

instance FromJSON Owner where
  parseJSON = genericParseJSON $ aesonDrop 3 snakeCase 

instance ToJSON Owner where
  toJSON = genericToJSON $ (aesonDrop 3 snakeCase) {omitNothingFields = True}


-- * Resource

type ResourceName = Text
type ResourceType = Text

-- | A resource Id
newtype ResourceId = ResourceId {unResId :: Text} deriving (Show, Eq, Generic, Ord, Hashable)

-- JSON instances
instance ToJSON ResourceId where
  toJSON = genericToJSON (defaultOptions {unwrapUnaryRecords = True})

instance FromJSON ResourceId where
  parseJSON = genericParseJSON (defaultOptions {unwrapUnaryRecords = True})

-- | A complete resource
data Resource = Resource {
     resId                 :: Maybe ResourceId,
     resName               :: ResourceName,
     resType               :: Maybe ResourceType,
     resUris               :: [Text],
     resScopes             :: [Scope],
     resOwner              :: Owner,
     resOwnerManagedAccess :: Bool,
     resAttributes         :: [Attribute]
  } deriving (Generic, Show)

instance FromJSON Resource where
  parseJSON (Object v) = do
    rId     <- v .:? "_id"
    rName   <- v .:  "name"
    rType   <- v .:? "type"
    rUris   <- v .:  "uris"
    rScopes <- v .:  "scopes"
    rOwn    <- v .:  "owner"
    rOMA    <- v .:  "ownerManagedAccess"
    rAtt    <- v .:? "attributes"
    let atts = if isJust rAtt then toList $ fromJust rAtt else []
    return $ Resource rId rName rType rUris rScopes rOwn rOMA (map (\(a, b) -> Attribute a b) atts)
  parseJSON _ = error "not an object"

instance ToJSON Resource where
  toJSON (Resource rid name typ uris scopes own uma attrs) =
    object ["_id"                .= toJSON rid,
            "name"               .= toJSON name,
            "type"               .= toJSON typ,
            "uris"               .= toJSON uris,
            "scopes"             .= toJSON scopes,
            "owner"              .= (toJSON $ ownName own),
            "ownerManagedAccess" .= toJSON uma,
            "attributes"         .= object (map (\(Attribute aname vals) -> aname .= toJSON vals) attrs)]

-- | A resource attribute
data Attribute = Attribute {
  attName   :: Text,
  attValues :: [Text]
  } deriving (Generic, Show)

instance FromJSON Attribute where
  parseJSON = genericParseJSON $ aesonDrop 3 camelCase 

instance ToJSON Attribute where
  toJSON (Attribute name vals) = object [name .= toJSON vals] 



makeLenses ''KCConfig
