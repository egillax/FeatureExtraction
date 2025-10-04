-- Feature construction
-- For description of covariate_id computation, see extras/TestHashForPostcoordinatedConcepts.R
DROP TABLE IF EXISTS #temp_features;
DROP TABLE IF EXISTS #no_collisions;

{@temporal} ? {
WITH time_bounds AS (
  SELECT min_start_day, max_end_day
  FROM #time_window_bounds
),
base_events AS (
  SELECT
    cohort.cohort_definition_id,
    cohort.subject_id,
    cohort.cohort_start_date,
    cohort.@row_id_field AS row_id,
    @domain_concept_id AS domain_concept_id,
    value_as_concept_id,
    DATEDIFF(DAY, cohort.cohort_start_date, @domain_table.@domain_start_date) AS start_offset,
    DATEDIFF(DAY, cohort.cohort_start_date, @domain_table.@domain_end_date) AS end_offset
  FROM @cohort_table cohort
  INNER JOIN @cdm_database_schema.@domain_table
    ON cohort.subject_id = @domain_table.person_id
  WHERE @domain_concept_id != 0
    AND value_as_concept_id IS NOT NULL
    AND value_as_concept_id != 0
{@excluded_concept_table != ''} ? {
    AND @domain_concept_id NOT IN (SELECT id FROM @excluded_concept_table)
}
{@included_concept_table != ''} ? {
    AND @domain_concept_id IN (SELECT id FROM @included_concept_table)
}
{@cohort_definition_id != -1} ? {
    AND cohort.cohort_definition_id IN (@cohort_definition_id)
}
),
clamped_events AS (
  SELECT be.*,
    CASE WHEN be.start_offset < tb.min_start_day THEN tb.min_start_day ELSE be.start_offset END AS clamped_start_offset,
    CASE WHEN be.end_offset > tb.max_end_day THEN tb.max_end_day ELSE be.end_offset END AS clamped_end_offset
  FROM base_events be
  CROSS JOIN time_bounds tb
  WHERE be.end_offset >= tb.min_start_day
    AND be.start_offset <= tb.max_end_day
),
window_events AS (
  SELECT DISTINCT
    ce.cohort_definition_id,
    ce.subject_id,
    ce.cohort_start_date,
    ce.row_id,
    ce.domain_concept_id,
    ce.value_as_concept_id,
    wm.time_id
  FROM clamped_events ce
  INNER JOIN #atomic_intervals ai
    ON ce.clamped_start_offset <= ai.end_day
    AND ce.clamped_end_offset >= ai.start_day
  INNER JOIN #window_interval_map wm
    ON ai.interval_id = wm.interval_id
)
{@aggregated} ? {
SELECT 
  window_events.domain_concept_id AS @domain_concept_id,
  window_events.value_as_concept_id,
  (CAST(window_events.domain_concept_id * 2654435769 / 4096 AS BIGINT) & 1048575) * 4194304000 +
    (CAST(window_events.value_as_concept_id * 2654435769 / 1024 AS BIGINT) & 4194303) * 1000 +
    @analysis_id AS covariate_id,
  window_events.time_id,
  window_events.cohort_definition_id,
  COUNT(DISTINCT window_events.row_id) AS sum_value
INTO #temp_features
FROM window_events
{@included_cov_table != ''} ? {
WHERE (CAST(window_events.domain_concept_id * 2654435769 / 4096 AS BIGINT) & 1048575) * 4194304000 +
    (CAST(window_events.value_as_concept_id * 2654435769 / 1024 AS BIGINT) & 4194303) * 1000 +
    @analysis_id IN (SELECT id FROM @included_cov_table)
}
GROUP BY window_events.domain_concept_id,
  window_events.value_as_concept_id,
  window_events.cohort_definition_id,
  window_events.time_id;
} : {
SELECT 
  window_events.domain_concept_id AS @domain_concept_id,
  window_events.value_as_concept_id,
  (CAST(window_events.domain_concept_id * 2654435769 / 4096 AS BIGINT) & 1048575) * 4194304000 +
    (CAST(window_events.value_as_concept_id * 2654435769 / 1024 AS BIGINT) & 4194303) * 1000 +
    @analysis_id AS covariate_id,
  window_events.time_id,
  window_events.row_id
INTO #temp_features
FROM window_events
{@included_cov_table != ''} ? {
WHERE (CAST(window_events.domain_concept_id * 2654435769 / 4096 AS BIGINT) & 1048575) * 4194304000 +
    (CAST(window_events.value_as_concept_id * 2654435769 / 1024 AS BIGINT) & 4194303) * 1000 +
    @analysis_id IN (SELECT id FROM @included_cov_table)
}
;
}
} : {
{@aggregated} ? {
SELECT @domain_concept_id,
	value_as_concept_id,
	(CAST(@domain_concept_id * 2654435769 / 4096 AS BIGINT) & 1048575)*4194304000 +
    (CAST(value_as_concept_id * 2654435769 / 1024 AS BIGINT) & 4194303)*1000 + 
	@analysis_id AS covariate_id,
{@temporal} ? {
	time_id,
}	
	cohort_definition_id,
	COUNT(DISTINCT row_id) AS sum_value
INTO #temp_features
FROM (
}
	SELECT @domain_concept_id,
		value_as_concept_id,
{@temporal} ? {
		time_id,
}	
{@aggregated} ? {
		cohort_definition_id,
		cohort.@row_id_field AS row_id
} : {
	(CAST(@domain_concept_id * 2654435769 / 4096 AS BIGINT) & 1048575)*4194304000 +
    (CAST(value_as_concept_id * 2654435769 / 1024 AS BIGINT) & 4194303)*1000 + 
	@analysis_id AS covariate_id,
		cohort.@row_id_field AS row_id
	INTO #temp_features
}
	FROM @cohort_table cohort
	INNER JOIN @cdm_database_schema.@domain_table
		ON cohort.subject_id = @domain_table.person_id
{@temporal} ? {
	INNER JOIN #time_period time_period
		ON @domain_start_date <= DATEADD(DAY, time_period.end_day, cohort.cohort_start_date)
		AND @domain_start_date >= DATEADD(DAY, time_period.start_day, cohort.cohort_start_date)
	WHERE @domain_concept_id != 0
} : {
	WHERE @domain_start_date <= DATEADD(DAY, @end_day, cohort.cohort_start_date)
{@start_day != 'anyTimePrior'} ? {				AND @domain_start_date >= DATEADD(DAY, @start_day, cohort.cohort_start_date)}
		AND @domain_concept_id != 0
}
		AND value_as_concept_id IS NOT NULL
		AND value_as_concept_id != 0
{@excluded_concept_table != ''} ? {		AND @domain_concept_id NOT IN (SELECT id FROM @excluded_concept_table)}
{@included_concept_table != ''} ? {		AND @domain_concept_id IN (SELECT id FROM @included_concept_table)}
{@cohort_definition_id != -1} ? {		AND cohort.cohort_definition_id IN (@cohort_definition_id)}
{@aggregated} ? {
	) grouped_1
}
{@included_cov_table != ''} ? {WHERE (CAST(@domain_concept_id AS BIGINT) * 10000) + (range_group * 1000) + @analysis_id IN (SELECT id FROM @included_cov_table)}
GROUP BY @domain_concept_id,
	value_as_concept_id
{@aggregated} ? {		
	,cohort_definition_id
} : {
	,cohort.@row_id_field
} 
{@temporal} ? {
	,time_id
} 
;


}
SELECT covariate_id,
	MIN(@domain_concept_id) AS @domain_concept_id,
	MIN(value_as_concept_id) AS value_as_concept_id,
	COUNT(*) - 1 AS collisions
INTO #no_collisions
FROM (
	SELECT DISTINCT 
		covariate_id,
		@domain_concept_id,
		value_as_concept_id
	FROM #temp_features
	) tmp
GROUP BY covariate_id;

SELECT temp_features.covariate_id,
{@temporal} ? {
	time_id,
}	
{@aggregated} ? {
	cohort_definition_id,
  sum_value
} : {
	row_id,
	1 AS covariate_value 
}
INTO @covariate_table
FROM #temp_features temp_features
INNER JOIN #no_collisions no_collisions
  ON temp_features.covariate_id = no_collisions.covariate_id
    AND temp_features.@domain_concept_id = no_collisions.@domain_concept_id
    AND temp_features.value_as_concept_id = no_collisions.value_as_concept_id;

-- Reference construction
INSERT INTO #cov_ref (
	covariate_id,
	covariate_name,
	analysis_id,
	concept_id,
	value_as_concept_id,
	collisions
	)
SELECT covariate_id,
{@temporal} ? {
	CAST(CONCAT('@domain_table: ', 
							CASE WHEN c1.concept_name IS NULL THEN 'Unknown concept' ELSE c1.concept_name END, 
							' = ', 
							CASE WHEN c2.concept_name IS NULL THEN 'Unknown concept' ELSE c2.concept_name END
			 ) AS VARCHAR(512)) AS covariate_name,
} : {
{@start_day == 'anyTimePrior'} ? {
	CAST(CONCAT('@domain_table any time prior through @end_day days relative to index: ', 
							CASE WHEN c1.concept_name IS NULL THEN 'Unknown concept' ELSE c1.concept_name END, 
							' = ', 
							CASE WHEN c2.concept_name IS NULL THEN 'Unknown concept' ELSE c2.concept_name END
			 ) AS VARCHAR(512)) AS covariate_name,
} : {
	CAST(CONCAT('@domain_table during day @start_day through @end_day days relative to index: ', 
							CASE WHEN c1.concept_name IS NULL THEN 'Unknown concept' ELSE c1.concept_name END, 
							' = ', 
							CASE WHEN c2.concept_name IS NULL THEN 'Unknown concept' ELSE c2.concept_name END
			 ) AS VARCHAR(512)) AS covariate_name,
}
}
	@analysis_id AS analysis_id,
	no_collisions.@domain_concept_id AS concept_id,
	no_collisions.value_as_concept_id AS concept_id,
	no_collisions.collisions
FROM (
	SELECT covariate_id,
	  @domain_concept_id,
	  value_as_concept_id,
	  collisions
	FROM #no_collisions
	) no_collisions
LEFT JOIN @cdm_database_schema.concept c1
	ON c1.concept_id = no_collisions.@domain_concept_id
LEFT JOIN @cdm_database_schema.concept c2
	ON c2.concept_id = no_collisions.value_as_concept_id;
	
INSERT INTO #analysis_ref (
	analysis_id,
	analysis_name,
	domain_id,
{!@temporal} ? {
	start_day,
	end_day,
}
	is_binary,
	missing_means_zero
	)
SELECT @analysis_id AS analysis_id,
	CAST('@analysis_name' AS VARCHAR(512)) AS analysis_name,
	CAST('@domain_id' AS VARCHAR(20)) AS domain_id,
{!@temporal} ? {
{@start_day == 'anyTimePrior'} ? {
	CAST(NULL AS INT) AS start_day,
} : {
	@start_day AS start_day,
}
	@end_day AS end_day,
}
	CAST('Y' AS VARCHAR(1)) AS is_binary,
	CAST(NULL AS VARCHAR(1)) AS missing_means_zero;

TRUNCATE TABLE #temp_features;
DROP TABLE #temp_features;
TRUNCATE TABLE #no_collisions;
DROP TABLE #no_collisions;
