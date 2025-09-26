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
dbFile <- path.expand(Sys.getenv("DUCKDB_BENCHMARK_DB", "~/database/database-1M_filtered.duckdb"))
cdmSchema <- Sys.getenv("CDM_SCHEMA", "main")
cohortSchema <- Sys.getenv("COHORT_SCHEMA", "cohorts")
cohortTable <- Sys.getenv("COHORT_TABLE", "dlc_cohorts")
cohortIds <- 1

message("Benchmark configuration:")
message("  DuckDB file           : ", dbFile)
message("  CDM schema            : ", cdmSchema)
message("  Cohort schema         : ", cohortSchema)
message("  Cohort table          : ", cohortTable)
message("  Cohort ids            : ", paste(cohortIds, collapse = ", "))

if (!file.exists(dbFile)) {
  stop("DuckDB database not found at ", dbFile)
}

# Connection -----------------------------------------------------------------
connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms = "duckdb",
  server = dbFile
)

connection <- DatabaseConnector::connect(connectionDetails = connectionDetails)
on.exit(DatabaseConnector::disconnect(connection), add = TRUE)

# Settings --------------------------------------------------------------------
temporalSettings <- FeatureExtraction::createTemporalCovariateSettings(
  useDemographicsAge = TRUE,
  useDemographicsGender = TRUE,
  useDemographicsRace = TRUE,
  useDemographicsEthnicity = TRUE,
  useConditionEraGroupStart = TRUE,
  temporalStartDays = -364:0,
  temporalEndDays = -364:0
)

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

message(sprintf("Elapsed: %.2f seconds (user %.2f, system %.2f)", runtime[["elapsed"]], runtime[["user.self"]], runtime[["sys.self"]]))

# Basic row count so we can compare runs.
covariateRowCount <- covariateData$covariates %>%
  dplyr::tally() %>%
  dplyr::collect() %>%
  dplyr::pull(n)

message("Rows in covariates table: ", format(covariateRowCount, big.mark = ","))

# Clean up the Andromeda object so repeated runs do not leak disk space.
Andromeda::close(covariateData)

message("Benchmark completed.")
