# Benchmark temporal covariate extraction against a DuckDB CDM copy.
#
# Required setup --------------------------------------------------------------
# 1. Ensure DuckDB JDBC support is available (DatabaseConnector will download
#    automatically if the driver JARs are missing).
# 2. Populate a cohort table inside the DuckDB database. By default the script
#    expects a table named 'cohort' with the standard fields
#    (subject_id, cohort_definition_id, cohort_start_date, cohort_end_date).
# 3. Adjust the configuration variables below or set the matching environment
#    variables before running, e.g.
#
#      export COHORT_TABLE=my_cohort
#      Rscript extras/benchmark_temporal_duckdb.R
#
# Notes -----------------------------------------------------------------------
# - The benchmark focuses on the heavy temporal window pattern where start and
#   end days are identical and span the previous year (365 single-day windows).
# - Results are fetched into an Andromeda instance; make sure you have
#   sufficient local disk space for the temporary files Andromeda creates.

suppressPackageStartupMessages({
  library(DatabaseConnector)
  library(FeatureExtraction)
  library(dplyr)
  library(Andromeda)
})

# Configuration ---------------------------------------------------------------
postgres <- TRUE
basicQuery <- FALSE
if (postgres) {
  dbServer <- "localhost/cdm"
} else {
  dbServer <- "~/database/database-1M_filtered.duckdb"
  Sys.setenv("CDM_SCHEMA" = "main")
}
cdmSchema <- Sys.getenv("CDM_SCHEMA", "omop")
cohortSchema <- Sys.getenv("COHORT_SCHEMA", "cohorts")
cohortTable <- Sys.getenv("COHORT_TABLE", "dlc_cohorts")
cohortIds <- 1

message("Benchmark configuration:")
message("  DB                    : ", dbServer)
message("  CDM schema            : ", cdmSchema)
message("  Cohort schema         : ", cohortSchema)
message("  Cohort table          : ", cohortTable)
message("  Cohort ids            : ", paste(cohortIds, collapse = ", "))

# Connection -----------------------------------------------------------------
if (postgres) {
  connectionDetails <- DatabaseConnector::createConnectionDetails(
    dbms = "postgresql",
    server = dbServer,
    user = "ohdsi",
    password = "ohdsi",
    port = 5432,
    pathToDriver = "~/database_drivers/"
  )
} else {
  connectionDetails <- DatabaseConnector::createConnectionDetails(
    dbms = "duckdb",
    server = dbServer
  )
}

connection <- DatabaseConnector::connect(connectionDetails = connectionDetails)
on.exit(DatabaseConnector::disconnect(connection), add = TRUE)

# Settings --------------------------------------------------------------------
if (basicQuery) {
  temporalSettings <- FeatureExtraction::createTemporalCovariateSettings(
    useDemographicsAge = TRUE,
    useDemographicsGender = TRUE,
    useDemographicsRace = TRUE,
    useDemographicsEthnicity = TRUE,
    useConditionEraGroupStart = TRUE,
    useDrugEraGroupStart = TRUE,
    temporalStartDays = -364:0,
    temporalEndDays = -364:0
  )
} else {
  temporalSettings <- FeatureExtraction::createTemporalCovariateSettings(
    useDemographicsGender = TRUE,
    useDemographicsAge = TRUE,
    useDemographicsAgeGroup = TRUE,
    useDemographicsRace = TRUE,
    useDemographicsEthnicity = TRUE,
    useDemographicsIndexYear = TRUE,
    useDemographicsIndexMonth = TRUE,
    useDemographicsIndexYearMonth = TRUE,
    useDemographicsPriorObservationTime = TRUE,
    useDemographicsPostObservationTime = TRUE,
    useDemographicsTimeInCohort = TRUE,
    useConditionOccurrence = TRUE,
    useProcedureOccurrence = TRUE,
    useDrugEraStart = TRUE,
    useMeasurement = TRUE,
    useMeasurementValueAsConcept = TRUE,
    useMeasurementRangeGroup = TRUE,
    useConditionEraStart = TRUE,
    useConditionEraOverlap = TRUE,
    useConditionEraGroupStart = TRUE,
    useConditionEraGroupOverlap = TRUE,
    useDrugExposure = FALSE, # leads to too many concept id
    useDrugEraOverlap = FALSE,
    useDrugEraGroupStart = TRUE,
    useDrugEraGroupOverlap = TRUE,
    useObservation = TRUE,
    useObservationValueAsConcept = TRUE,
    useDeviceExposure = TRUE,
    useCharlsonIndex = TRUE,
    useDcsi = TRUE,
    useChads2 = TRUE,
    useChads2Vasc = TRUE,
    useHfrs = FALSE,
    temporalStartDays = c(
      # components displayed in cohort characterization
      -9999, # anytime prior
      -365, # long term prior
      -180, # medium term prior
      -30, # short term prior

      # components displayed in temporal characterization
      -365, # one year prior to -31
      -30, # 30 day prior not including day 0
      0, # index date only
      1, # 1 day after to day 30
      31,
      -9999 # Any time prior to any time future
    ),
    temporalEndDays = c(
      0, # anytime prior
      0, # long term prior
      0, # medium term prior
      0, # short term prior

      # components displayed in temporal characterization
      -31, # one year prior to -31
      -1, # 30 day prior not including day 0
      0, # index date only
      30, # 1 day after to day 30
      365,
      9999 # Any time prior to any time future
    )
  )
}

# Optional: override with more focused concept filters here if desired.

message("Running temporal covariate extraction...")
runtime <- system.time({
  covariateData <- FeatureExtraction::getDbCovariateData(
    connection = connection,
    cdmDatabaseSchema = cdmSchema,
    cohortDatabaseSchema = cohortSchema,
    cohortTable = cohortTable,
    cohortIds = cohortIds,
    covariateSettings = temporalSettings,
    aggregated = FALSE
  )
})

message(sprintf(
  "Elapsed: %.2f seconds (user %.2f, system %.2f)",
  runtime[["elapsed"]],
  runtime[["user.self"]],
  runtime[["sys.self"]]
))

# Basic row count so we can compare runs.
covariateRowCount <- covariateData$covariates %>%
  dplyr::tally() %>%
  dplyr::collect() %>%
  dplyr::pull(n)

message("Rows in covariates table: ", format(covariateRowCount, big.mark = ","))

# Clean up the Andromeda object so repeated runs do not leak disk space.
Andromeda::close(covariateData)

message("Benchmark completed.")
