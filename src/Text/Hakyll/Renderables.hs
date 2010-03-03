module Text.Hakyll.Renderables
    ( createCustomPage
    , createListing
    , createListingWith
    , PagePath
    , createPagePath
    , CombinedRenderable
    , combine
    , combineWithUrl
    ) where

import qualified Data.Map as M
import Control.Arrow (second)
import Control.Monad (liftM, liftM2, mplus)
import Control.Applicative ((<$>))

import Data.Binary

import Text.Hakyll.Hakyll (Hakyll)
import Text.Hakyll.Page
import Text.Hakyll.Renderable
import Text.Hakyll.File
import Text.Hakyll.Context
import Text.Hakyll.Render
import Text.Hakyll.RenderAction

-- | Create a custom page.
--   
--   The association list given maps keys to values for substitution. Note
--   that as value, you can either give a @String@ or a @Hakyll String@.
--   A @Hakyll String@ is preferred for more complex data, since it allows
--   dependency checking. A @String@ is obviously more simple to use in some
--   cases.
createCustomPage :: String
                 -> [FilePath]
                 -> [(String, Either String (Hakyll String))]
                 -> RenderAction () Context
createCustomPage url dependencies association = RenderAction
    { actionDependencies = dependencies
    , actionDestination  = Just $ return url
    , actionFunction     = actionFunction'
    }
  where
    mtuple (a, b) = b >>= \b' -> return (a, b')
    actionFunction' () = M.fromList <$> mapM (mtuple . second (either return id)) association

-- | A @createCustomPage@ function specialized in creating listings.
--
--   This function creates a listing of a certain list of @Renderable@s. Every
--   item in the list is created by applying the given template to every
--   renderable. You can also specify additional context to be included in the
--   @CustomPage@.
--
--   > let customPage = createListingWith 
--   >                      "index.html" -- Destination of the page.
--   >                      "templates/postitem.html" -- Path to template to
--   >                                                -- render the items with.
--   >                      posts -- ^ Renderables to create the list with.
--   >                      [("title", "Home")] -- ^ Additional context
createListing :: (Renderable a)
              => String -- ^ Destination of the page.
              -> FilePath -- ^ Template to render all items with.
              -> [a] -- ^ Renderables in the list.
              -> [(String, String)] -- ^ Additional context.
              -> RenderAction () Context
createListing = createListingWith id

-- | A @createCustomPage@ function specialized in creating listings.
--
--   In addition to @createListing@, this function allows you to specify an
--   extra @ContextManipulation@ for all @Renderable@s given.
createListingWith :: (Renderable a)
                  => ContextManipulation -- ^ Manipulation for the renderables.
                  -> String -- ^ Destination of the page.
                  -> FilePath -- ^ Template to render all items with.
                  -> [a] -- ^ Renderables in the list.
                  -> [(String, String)] -- ^ Additional context.
                  -> RenderAction () Context
createListingWith manipulation url template renderables additional =
    createCustomPage url dependencies context
  where
    dependencies = template : concatMap getDependencies renderables
    context = ("body", Right concatenation) : additional'
    concatenation = renderAndConcatWith manipulation [template] renderables
    additional' = map (second Left) additional

-- | PagePath is a class that wraps a FilePath. This is used to render Pages
--   without reading them first through use of caching.
newtype PagePath = PagePath FilePath
                 deriving (Ord, Eq, Read, Show)

-- | Create a PagePath from a FilePath.
createPagePath :: FilePath -> PagePath
createPagePath = PagePath

-- We can render filepaths
instance Renderable PagePath where
    getDependencies (PagePath path) = return path
    getUrl (PagePath path) = toUrl path
    toContext (PagePath path) = readPage path >>= toContext

-- We can serialize filepaths
instance Binary PagePath where
    put (PagePath path) = put path
    get = liftM PagePath get

-- | A combination of two other renderables.
data CombinedRenderable a b = CombinedRenderable a b
                            | CombinedRenderableWithUrl FilePath a b
                            deriving (Ord, Eq, Read, Show)

-- | Combine two renderables. The url will always be taken from the first
--   @Renderable@. Also, if a `$key` is present in both renderables, the
--   value from the first @Renderable@ will be taken as well.
--
--   Since renderables are always more or less key-value maps, you can see
--   this as a @union@ between two maps.
combine :: RenderAction () Context -> RenderAction () Context
        -> RenderAction () Context
combine x y = RenderAction
    { actionDependencies = actionDependencies x ++ actionDependencies y
    , actionDestination  = actionDestination x `mplus` actionDestination y
    , actionFunction     = \_ -> liftM2 (M.union) (actionFunction x ()) (actionFunction y ())
    }

-- | Combine two renderables and set a custom URL. This behaves like @combine@,
--   except that for the @url@ field, the given URL is always chosen.
combineWithUrl :: (Renderable a, Renderable b)
               => FilePath
               -> a
               -> b
               -> CombinedRenderable a b
combineWithUrl = CombinedRenderableWithUrl

-- Render combinations.
instance (Renderable a, Renderable b)
         => Renderable (CombinedRenderable a b) where

    -- Add the dependencies.
    getDependencies (CombinedRenderable a b) =
        getDependencies a ++ getDependencies b
    getDependencies (CombinedRenderableWithUrl _ a b) =
        getDependencies a ++ getDependencies b

    -- Take the url from the first renderable, or the specified URL.
    getUrl (CombinedRenderable a _) = getUrl a
    getUrl (CombinedRenderableWithUrl url _ _) = return url

    -- Take a union of the contexts.
    toContext (CombinedRenderable a b) = do
        c1 <- toContext a
        c2 <- toContext b
        return $ c1 `M.union` c2
    toContext (CombinedRenderableWithUrl url a b) = do
        c <- toContext (CombinedRenderable a b)
        return $ M.singleton "url" url `M.union` c
