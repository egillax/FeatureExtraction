# Copyright 2025 Observational Health Data Sciences and Informatics
#
# This file is part of FeatureExtraction
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
log_andromeda_event <- function(obj_or_filename, context, event_message) {
  try(
    { # Use try to ensure logging never crashes the process
      ts <- format(Sys.time(), "%Y-%-%d %H:%M:%OS6")
      pid <- Sys.getpid()
      obj_id <- "UNKNOWN_FILE"
      conn_addr <- "UNKNOWN_CONN"

      # Check if we were passed a valid Andromeda object
      if (Andromeda::isAndromeda(obj_or_filename) && try(Andromeda::isValidAndromeda(obj_or_filename), silent = TRUE))      {
          obj_id <- basename(obj_or_filename@dbname)
          # Get the memory address of the R object itself
          conn_addr <- lobstr::obj_addr(obj_or_filename)
      } else if (is.character(obj_or_filename)) {
        # This case handles the finalizer where the object may no longer be valid
        obj_id <- basename(obj_or_filename)
        conn_addr <- "NA_FINALIZED"
      }

      message(sprintf("[AndromedaDiag] [%s] [PID:%s] [OBJ:%s] [CONN:%s] [%s] %s", ts, pid, obj_id, conn_addr, context, event_message))
    },
    silent = TRUE
  )
}



#' Tidy covariate data
#'
#' @details
#' Normalize covariate values by dividing by the max and/or remove redundant covariates and/or remove
#' infrequent covariates. For temporal covariates, redundancy is evaluated per time ID.
#'
#' @param covariateData      An object as generated using the \code{\link{getDbCovariateData}}
#'                           function.
#' @param minFraction        Minimum fraction of the population that should have a non-zero value for a
#'                           covariate for that covariate to be kept. Set to 0 to don't filter on
#'                           frequency.
#' @param normalize          Normalize the covariates? (dividing by the max).
#' @param removeRedundancy   Should redundant covariates be removed?
#'
#' @return An object of class \code{CovariateData}.
#'
#' @examples
#' \donttest{
#' covariateData <- FeatureExtraction::createEmptyCovariateData(
#'   cohortIds = 1,
#'   aggregated = FALSE,
#'   temporal = FALSE
#' )
#'
#' covData <- tidyCovariateData(
#'   covariateData = covariateData,
#'   minFraction = 0.001,
#'   normalize = TRUE,
#'   removeRedundancy = TRUE
#' )
#' }
#'
#' @export
tidyCovariateData <- function(covariateData,
                              minFraction = 0.001,
                              normalize = TRUE,
                              removeRedundancy = TRUE) {
  if (!isCovariateData(covariateData)) {
    stop("Data not of class CovariateData")
  }
  if (!Andromeda::isValidAndromeda(covariateData)) {
    stop("CovariateData object is closed")
  }
  if (isAggregatedCovariateData(covariateData)) {
    stop("Cannot tidy aggregated covariates")
  }
  start <- Sys.time()

  newCovariateData <- Andromeda::andromeda(
    covariateRef = covariateData$covariateRef,
    analysisRef = covariateData$analysisRef
  )
  metaData <- attr(covariateData, "metaData")
  populationSize <- metaData$populationSize
  if (covariateData$covariates %>% count() %>% pull() == 0) {
    newCovariateData$covariates <- covariateData$covariates
  } else {
    newCovariates <- covariateData$covariates
    covariateData$maxValuePerCovariateId <- covariateData$covariates %>%
      group_by(.data$covariateId) %>%
      summarise(maxValue = max(.data$covariateValue, na.rm = TRUE))
    on.exit(covariateData$maxValuePerCovariateId <- NULL)

    if (removeRedundancy || minFraction != 0) {
      covariateData$valueCounts <- covariateData$covariates %>%
        group_by(.data$covariateId) %>%
        summarise(n = count(), nDistinct = n_distinct(.data$covariateValue))
      on.exit(covariateData$valueCounts <- NULL, add = TRUE)
    }

    ignoreCovariateIds <- c()
    deleteCovariateIds <- c()
    if (removeRedundancy) {
      covariateData$binaryCovariateIds <- covariateData$maxValuePerCovariateId %>%
        inner_join(covariateData$valueCounts, by = "covariateId") %>%
        filter(.data$maxValue == 1 & .data$nDistinct == 1) %>%
        select(covariateId = .data$covariateId)
      on.exit(covariateData$binaryCovariateIds <- NULL, add = TRUE)

      if (covariateData$binaryCovariateIds %>% count() %>% pull() != 0) {
        if (isTemporalCovariateData(covariateData)) {
          # Temporal
          covariateData$temporalValueCounts <- covariateData$covariates %>%
            inner_join(covariateData$binaryCovariateIds, by = "covariateId") %>%
            group_by(.data$covariateId, .data$timeId) %>%
            count()
          on.exit(covariateData$temporalValueCounts <- NULL, add = TRUE)

          # First, find all single covariates that, for every timeId, appear in every row with the same value
          covariateData$deleteCovariateTimeIds <- covariateData$temporalValueCounts %>%
            filter(n == populationSize) %>%
            select(.data$covariateId, .data$timeId)
          on.exit(covariateData$deleteCovariateTimeIds <- NULL, add = TRUE)

          # Next, find groups of covariates (analyses) that together cover everyone:
          analysisIds <- covariateData$temporalValueCounts %>%
            anti_join(covariateData$deleteCovariateTimeIds, by = c("covariateId", "timeId")) %>%
            inner_join(covariateData$covariateRef, by = "covariateId") %>%
            group_by(.data$analysisId) %>%
            summarise(n = sum(n, na.rm = TRUE)) %>%
            filter(n == populationSize) %>%
            select(.data$analysisId)

          # For those, find most prevalent covariate, and mark it for deletion:
          valueCounts <- analysisIds %>%
            inner_join(covariateData$covariateRef, by = "analysisId") %>%
            inner_join(covariateData$temporalValueCounts, by = "covariateId") %>%
            select(.data$analysisId, .data$covariateId, .data$timeId, .data$n) %>%
            collect()
          valueCounts <- valueCounts[order(valueCounts$analysisId, -valueCounts$n), ]
          Andromeda::appendToTable(
            covariateData$deleteCovariateTimeIds,
            valueCounts[!duplicated(valueCounts$analysisId), c("covariateId", "timeId")]
          )

          newCovariates <- newCovariates %>%
            anti_join(covariateData$deleteCovariateTimeIds, by = c("covariateId", "timeId"))

          ParallelLogger::logInfo("Removing ", covariateData$deleteCovariateTimeIds %>% count() %>% pull(), " redundant covariate ID - time ID combinations")
        } else {
          # Non-temporal

          # First, find all single covariates that appear in every row with the same value
          toDelete <- covariateData$valueCounts %>%
            inner_join(covariateData$binaryCovariateIds, by = "covariateId") %>%
            filter(.data$n == populationSize) %>%
            select(.data$covariateId) %>%
            collect()
          deleteCovariateIds <- toDelete$covariateId

          # Next, find groups of covariates (analyses) that together cover everyone:
          analysisIds <- covariateData$valueCounts %>%
            inner_join(covariateData$binaryCovariateIds, by = "covariateId") %>%
            filter(!.data$covariateId %in% deleteCovariateIds) %>%
            inner_join(covariateData$covariateRef, by = "covariateId") %>%
            group_by(.data$analysisId) %>%
            summarise(n = sum(n, na.rm = TRUE)) %>%
            filter(.data$n == populationSize) %>%
            select(.data$analysisId)
          # For those, find most prevalent covariate, and mark it for deletion:
          valueCounts <- analysisIds %>%
            inner_join(covariateData$covariateRef, by = "analysisId") %>%
            inner_join(covariateData$valueCounts, by = "covariateId") %>%
            select(.data$analysisId, .data$covariateId, n) %>%
            collect()
          valueCounts <- valueCounts[order(valueCounts$analysisId, -valueCounts$n), ]
          deleteCovariateIds <- c(deleteCovariateIds, valueCounts$covariateId[!duplicated(valueCounts$analysisId)])
          ignoreCovariateIds <- valueCounts$covariateId
          ParallelLogger::logInfo("Removing ", length(deleteCovariateIds), " redundant covariates")
        }
      }
      metaData$deletedRedundantCovariateIds <- deleteCovariateIds
    }
    if (minFraction != 0) {
      minCount <- floor(minFraction * populationSize)
      toDelete <- covariateData$valueCounts %>%
        filter(.data$n < minCount) %>%
        filter(!.data$covariateId %in% ignoreCovariateIds) %>%
        select(.data$covariateId) %>%
        collect()

      metaData$deletedInfrequentCovariateIds <- toDelete$covariateId
      deleteCovariateIds <- c(deleteCovariateIds, toDelete$covariateId)
      ParallelLogger::logInfo("Removing ", nrow(toDelete), " infrequent covariates")
    }

    # When performing both filtering by covariate IDs and normalization, it is *much* faster
    # to apply the filtering to the maxValuePerCovariateId table, and let the inner join 
    # apply the filtering to the covariate table (instead of filtering the covariate table 
    # directly).
    if (normalize) {
      ParallelLogger::logInfo("Normalizing covariates")
      if (length(deleteCovariateIds) > 0) {
      log_andromeda_event(covariateData, "NORMALIZE", "STARTING: Filtering maxValuePerCovariateId table.")
        covariateData$maxValuePerCovariateId <- covariateData$maxValuePerCovariateId %>%
          filter(!.data$covariateId %in% deleteCovariateIds)
      log_andromeda_event(covariateData, "NORMALIZE", "FINISHED: Filtering maxValuePerCovariateId table.")
      }
      log_andromeda_event(newCovariateData, "NORMALIZE", 
                      paste("STARTING: inner_join with maxValuePerCovariateId from source CONN:", 
                            lobstr::obj_addr(covariateData)))
      newCovariates <- newCovariates %>%
        inner_join(covariateData$maxValuePerCovariateId, by = "covariateId") %>%
        mutate(covariateValue = .data$covariateValue / .data$maxValue) %>%
        select(-.data$maxValue)
      log_andromeda_event(newCovariateData, "NORMALIZE", "FINISHED: inner_join and mutate.")
      log_andromeda_event(covariateData, "NORMALIZE", "STARTING: collect() on maxValuePerCovariateId.")
      metaData$normFactors <- covariateData$maxValuePerCovariateId %>%
        collect()
      log_andromeda_event(covariateData, "NORMALIZE", "FINISHED: collect() on maxValuePerCovariateId.")
    } else if (length(deleteCovariateIds) > 0) {
      log_andromeda_event(newCovariateData, "FILTER_ONLY", "STARTING: Filtering newCovariates table.")
  
      newCovariates <- newCovariates %>%
          filter(!.data$covariateId %in% deleteCovariateIds)
      log_andromeda_event(newCovariateData, "FILTER_ONLY", "FINISHED: Filtering newCovariates table.")
    } 
    log_andromeda_event(newCovariateData, "ASSIGN_FINAL", "STARTING: Final assignment to newCovariateData$covariates.")
    newCovariateData$covariates <- newCovariates
    log_andromeda_event(newCovariateData, "ASSIGN_FINAL", "FINISHED: Final assignment to newCovariateData$covariates.")
    if (!is.null(covariateData$timeRef)) {
      log_andromeda_event(newCovariateData, "ASSIGN_FINAL", "STARTING: Final assignment to newCovariateData$timeRef.")
      newCovariateData$timeRef <- covariateData$timeRef
      log_andromeda_event(newCovariateData, "ASSIGN_FINAL", "FINISHED: Final assignment to newCovariateData$timeRef.")
    }
  }

  class(newCovariateData) <- "CovariateData"
  attr(class(newCovariateData), "package") <- "FeatureExtraction"
  attr(newCovariateData, "metaData") <- metaData

  delta <- Sys.time() - start
  ParallelLogger::logInfo("Tidying covariates took ", signif(delta, 3), " ", attr(delta, "units"))

  return(newCovariateData)
}
