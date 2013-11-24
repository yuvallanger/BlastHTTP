{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Arrows #-}

-- | Searches a provided sequence with the NCBI Blast REST service and returns a blast result in xml format as String
-- The function blastHTTP takes the arguments: program (blastn,blastp,..) database(refseq_genomic, nr,..) querySequence (String of nucleotide,
-- protein characters, depending on the blast program used) and the optional entrezQuery string.
-- For more information on BLAST refer to: http://blast.ncbi.nlm.nih.gov/Blast.cgi
-- Information on the webservice can be found at: http://www.ncbi.nlm.nih.gov/BLAST/developer.shtml
module Bio.BlastHTTP (
                       blastHTTP
                     ) where

import Network.HTTP.Conduit 
import Data.Conduit    
import qualified Data.ByteString.Lazy.Char8 as L8
import Control.Monad.IO.Class (liftIO)    
import qualified Control.Monad as CM
import Text.XML.HXT.Core
import Network
import qualified Data.Conduit.List as CL
import Data.List
import Control.Monad.Error as CM
import Control.Concurrent
import Data.Maybe
import Data.Either

-- | Parse HTML results into Xml Tree datastructure
parseHTML :: String -> IOStateArrow s0 b0 XmlTree
parseHTML html = readString [withParseHTML yes, withWarnings no] html       
   
-- | Gets all subtrees with the specified id attribute
atName :: ArrowXml a => String -> a XmlTree XmlTree
atName elementId = deep (isElem >>> hasAttrValue "name" (== elementId))

-- | Gets all subtrees with the specified id attribute
atId :: ArrowXml a =>  String -> a XmlTree XmlTree
atId elementId = deep (isElem >>> hasAttrValue "id" (== elementId))
      
-- | Send query and parse RID from retrieved HTML 
startSession :: String -> String -> String -> Maybe String -> IO String
startSession program database querySequence entrezQuery = do
  requestXml <- withSocketsDo
      $ sendEntrezQuery program database querySequence entrezQuery
  let requestXMLString = (L8.unpack requestXml)
  rid <- CM.liftM head (runX $ parseHTML requestXMLString //> atId "rid" >>> getAttrValue "value")
  return rid

-- | Send query with or without Entrez query and return response HTML
sendEntrezQuery :: String -> String -> String -> Maybe String -> IO L8.ByteString
sendEntrezQuery program database querySequence entrezQuery 
  | isJust entrezQuery = simpleHttp ("http://www.ncbi.nlm.nih.gov/blast/Blast.cgi?CMD=Put&PROGRAM=" ++ program ++ "&DATABASE=" ++ database ++ "&QUERY=" ++ querySequence ++ "&ENTREZ_QUERY=" ++ (fromJust entrezQuery))
  | otherwise = simpleHttp ("http://www.ncbi.nlm.nih.gov/blast/Blast.cgi?CMD=Put&PROGRAM=" ++ program ++ "&DATABASE=" ++ database ++ "&QUERY=" ++ querySequence)
         
-- | Retrieve session status with RID
retrieveSessionStatus :: String -> IO String 
retrieveSessionStatus rid = do
  statusXml <- withSocketsDo
    $ simpleHttp ("http://www.ncbi.nlm.nih.gov/blast/Blast.cgi?CMD=Get&FORMAT_OBJECT=SearchInfo&RID=" ++ rid)
  let statusXMLString = (L8.unpack statusXml)
  return statusXMLString

-- | Retrieve result in blastxml format with RID 
retrieveResult :: String -> IO String 
retrieveResult rid = do
  statusXml <- withSocketsDo
    $ simpleHttp ("http://www.ncbi.nlm.nih.gov/blast/Blast.cgi?RESULTS_FILE=on&RID=" ++ rid ++ "&FORMAT_TYPE=XML&FORMAT_OBJECT=Alignment&CMD=Get")
  let resultXMLString = (L8.unpack statusXml)
  return resultXMLString

-- | Check if job results are ready and then retrieves results
checkSessionStatus :: String -> Int -> IO String
checkSessionStatus rid counter = do
    let counter2 = counter + 1
    let counter2string = show counter2
    threadDelay 60000000
    status <- retrieveSessionStatus rid
    let readyString = "Status=READY"
    let failureString = "Status=FAILURE"
    let expiredString = "Status=UNKNOWN"
    --CM.when (isInfixOf failureString status)(throwError "Search $rid failed; please report to blast-help at ncbi.nlm.nih.gov.\n")
    --CM.when (isInfixOf expiredString status)(throwError "Search $rid expired.\n")
    results <- waitOrRetrieve (isInfixOf readyString status) rid counter2
    return results

-- | Checks if results are ready, checks again if not or retrieves results if yes
waitOrRetrieve :: Bool -> String -> Int -> IO String
waitOrRetrieve ready rid counter
  | ready  = retrieveResult rid
  | otherwise = checkSessionStatus rid counter


-- | Sends Query and retrieves result on reaching READY status, will return exeption message if no query sequence has been provided 
performQuery :: String -> String -> Maybe String -> Maybe String -> Int -> IO (Either String String)                               
performQuery program database querySequenceMaybe entrezQueryMaybe counter
  | isJust querySequenceMaybe = do 
     rid <- startSession program database (fromJust querySequenceMaybe) entrezQueryMaybe
     result <- checkSessionStatus rid counter
     return (Right result)
  | otherwise = do 
     let exceptionMessage = "Error - no query sequence provided"
     return (Left exceptionMessage)

-- | Retrieve Blast results in BlastXML format from the NCBI REST Blast interface
-- The querySequence has to be provided, all other parameters are optional. It is possible to provide an ENTREZ query string
blastHTTP :: Maybe String -> Maybe String -> Maybe String -> Maybe String -> IO (Either String String)
blastHTTP program database querySequence entrezQuery = do
  let counter = 1
  let defaultProgram = "blastn"
  let defaultDatabase = "refseq_genomic"                  
  let selectedProgram = fromMaybe defaultProgram program
  let selectedDatabase = fromMaybe defaultDatabase database  
  result <- performQuery selectedProgram selectedDatabase querySequence entrezQuery counter
  return result

      
