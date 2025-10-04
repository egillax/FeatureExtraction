IF OBJECT_ID('tempdb..#groups', 'U') IS NOT NULL
	DROP TABLE #groups;

{@domain_table == 'drug_exposure' | @domain_table == 'drug_era'} ? {
SELECT DISTINCT descendant_concept_id,
  ancestor_concept_id
INTO #groups
FROM @cdm_database_schema.concept_ancestor
INNER JOIN @cdm_database_schema.concept
	ON ancestor_concept_id = concept_id
WHERE ((vocabulary_id = 'ATC'
		AND LEN(concept_code) IN (1, 3, 4, 5))
	OR (standard_concept = 'S' 
{@domain_table == 'drug_era'} ? {		AND concept_class_id = 'Ingredient'}
		AND domain_id = 'Drug'))
	AND concept_id != 0
{@excluded_concept_table != ''} ? {	AND descendant_concept_id NOT IN (SELECT id FROM @excluded_concept_table)}
{@included_concept_table != ''} ? {	AND descendant_concept_id IN (SELECT id FROM @included_concept_table)}
{@excluded_concept_table != ''} ? {	AND ancestor_concept_id NOT IN (SELECT id FROM @excluded_concept_table)}
{@included_concept_table != ''} ? {	AND ancestor_concept_id IN (SELECT id FROM @included_concept_table)}
;
}

{@domain_table == 'condition_occurrence' | @domain_table == 'condition_era'} ? {
SELECT DISTINCT descendant_concept_id,
  ancestor_concept_id
INTO #groups
FROM @cdm_database_schema.concept_ancestor
INNER JOIN (
	SELECT concept_id
	FROM @cdm_database_schema.concept
	INNER JOIN (
	  SELECT *
	  FROM @cdm_database_schema.concept_ancestor
	  WHERE ancestor_concept_id = 441840 /* SNOMED clinical finding */
	  AND (min_levels_of_separation > 2
		OR descendant_concept_id IN (433736, 433595, 441408, 72404, 192671, 137977, 434621, 437312, 439847, 4171917, 438555, 4299449, 375258, 76784, 40483532, 4145627, 434157, 433778, 258449, 313878)
		) 
	) temp
	  ON concept_id = descendant_concept_id
	WHERE concept_name NOT LIKE '%finding'
		AND concept_name NOT LIKE 'Disorder of%'
		AND concept_name NOT LIKE 'Finding of%'
		AND concept_name NOT LIKE 'Disease of%'
		AND concept_name NOT LIKE 'Injury of%'
		AND concept_name NOT LIKE '%by site'
		AND concept_name NOT LIKE '%by body site'
		AND concept_name NOT LIKE '%by mechanism'
		AND concept_name NOT LIKE '%of body region'
		AND concept_name NOT LIKE '%of anatomical site'
		AND concept_name NOT LIKE '%of specific body structure%'
		AND domain_id = 'Condition'
{@excluded_concept_table != ''} ? {		AND concept_id NOT IN (SELECT id FROM @excluded_concept_table)}
{@included_concept_table != ''} ? {		AND concept_id IN (SELECT id FROM @included_concept_table)}
) valid_groups
	ON ancestor_concept_id = valid_groups.concept_id
{@excluded_concept_table != '' | @included_concept_table != ''} ? {
WHERE 
{@excluded_concept_table != ''} ? {	
	ancestor_concept_id NOT IN (SELECT id FROM @excluded_concept_table)
	AND descendant_concept_id NOT IN (SELECT id FROM @excluded_concept_table)
}
{@included_concept_table != ''} ? {
{@excluded_concept_table != ''} ? {	AND } : {	}ancestor_concept_id IN (SELECT id FROM @included_concept_table)
	AND descendant_concept_id IN (SELECT id FROM @included_concept_table)
}
}
;
}

-- Feature construction
{@temporal} ? {CREATE INDEX idx_time_period_join ON #time_period (start_day, end_day);}
{@temporal} ? {
WITH
time_window_bounds AS (
	SELECT
		MIN(start_day) AS min_start_day,
		MAX(end_day) AS max_end_day
	FROM #time_period
),
time_window_unique AS (
	SELECT DISTINCT start_day, end_day
	FROM #time_period
)
}
SELECT 
	CAST(ancestor_concept_id AS BIGINT) * 1000 + @analysis_id AS covariate_id,
{@temporal | @temporal_sequence} ? {
	{@temporal} ? {time_period.time_id,} : {time_id,}
}	
{@aggregated} ? {
	cohort_definition_id,
	COUNT(*) AS sum_value
} : {
	row_id,
	1 AS covariate_value 
}
INTO @covariate_table
FROM (
	SELECT DISTINCT ancestor_concept_id,
{@temporal} ? {
		DATEDIFF(DAY, cohort.cohort_start_date, @domain_start_date) AS start_day_offset,
		DATEDIFF(DAY, cohort.cohort_start_date, @domain_end_date) AS end_day_offset,
		CASE
			WHEN DATEDIFF(DAY, cohort.cohort_start_date, @domain_start_date) < time_window_bounds.min_start_day THEN time_window_bounds.min_start_day
			ELSE DATEDIFF(DAY, cohort.cohort_start_date, @domain_start_date)
		END AS clamped_start_offset,
		CASE
			WHEN DATEDIFF(DAY, cohort.cohort_start_date, @domain_end_date) > time_window_bounds.max_end_day THEN time_window_bounds.max_end_day
			ELSE DATEDIFF(DAY, cohort.cohort_start_date, @domain_end_date)
		END AS clamped_end_offset,
}	
{@temporal_sequence} ? {
FLOOR(DATEDIFF(@time_part, @cdm_database_schema.@domain_table.@domain_start_date, cohort.cohort_start_date)*1.0/@time_interval) as time_id,
}
{@aggregated} ? {
		cohort_definition_id,
		cohort.subject_id,
		cohort.cohort_start_date
} : {
		cohort.@row_id_field AS row_id
}	
	FROM @cohort_table cohort
	INNER JOIN @cdm_database_schema.@domain_table
		ON cohort.subject_id = @domain_table.person_id
	INNER JOIN #groups
		ON @domain_concept_id = descendant_concept_id
{@sub_type == 'inpatient'} ? {	
  INNER JOIN @cdm_database_schema.visit_occurrence vo
    ON vo.person_id = @domain_table.person_id
    AND vo.visit_start_date <= @domain_table.@domain_start_date
    AND vo.visit_end_date >= @domain_table.@domain_start_date
  INNER JOIN @cdm_database_schema.concept_ancestor ca
    ON ca.ancestor_concept_id IN (9201, 38004311, 8920, 262)
    AND ca.descendant_concept_id = vo.visit_concept_id
}		
{@temporal} ? {
	CROSS JOIN time_window_bounds
}
	WHERE @domain_concept_id != 0
{@temporal} ? {
	AND DATEDIFF(DAY, cohort.cohort_start_date, @domain_end_date) >= time_window_bounds.min_start_day
	AND DATEDIFF(DAY, cohort.cohort_start_date, @domain_start_date) <= time_window_bounds.max_end_day
} : {
	AND @domain_start_date <= DATEADD(DAY,{@temporal_sequence} ? {@sequence_end_day} :{ @end_day}, cohort.cohort_start_date)
{@start_day != 'anyTimePrior'} ? {				
AND 
{@temporal_sequence} ? {@domain_start_date } : {@domain_end_date }
>= DATEADD(DAY, {@temporal_sequence} ? {@sequence_start_day} : {@start_day}, cohort.cohort_start_date)}
}
{@included_cov_table != ''} ? {		AND CAST(ancestor_concept_id AS BIGINT) * 1000 + @analysis_id IN (SELECT id FROM @included_cov_table)}
{@cohort_definition_id != -1} ? {		AND cohort.cohort_definition_id IN (@cohort_definition_id)}
) temp
{@temporal} ? {
INNER JOIN time_window_unique time_window
	ON temp.clamped_start_offset <= time_window.end_day
	AND temp.clamped_end_offset >= time_window.start_day
INNER JOIN #time_period time_period
	ON time_period.start_day = time_window.start_day
	AND time_period.end_day = time_window.end_day
}
{@aggregated} ? {		
GROUP BY cohort_definition_id,
	ancestor_concept_id
{@temporal | @temporal_sequence} ? {
	{@temporal} ? {,time_period.time_id} : {,time_id}
}	
}
;
TRUNCATE TABLE #groups;

DROP TABLE #groups;

-- Reference construction
INSERT INTO #cov_ref (
	covariate_id,
	covariate_name,
	analysis_id,
	concept_id
	)
SELECT covariate_id,
{@temporal | @temporal_sequence} ? {
	CAST(CONCAT('@domain_table group: ', CASE WHEN concept_name IS NULL THEN 'Unknown concept' ELSE concept_name END {@sub_type == 'inpatient'} ? {, ' (inpatient)'}) AS VARCHAR(512)) AS covariate_name,
} : {
{@start_day == 'anyTimePrior'} ? {
	CAST(CONCAT('@domain_table group (@analysis_name) any time prior through @end_day days relative to index: ', CASE WHEN concept_name IS NULL THEN 'Unknown concept' ELSE concept_name END {@sub_type == 'inpatient'} ? {, ' (inpatient)'}) AS VARCHAR(512)) AS covariate_name,
} : {
	CAST(CONCAT('@domain_table group (@analysis_name) during day @start_day through @end_day days relative to index: ', CASE WHEN concept_name IS NULL THEN 'Unknown concept' ELSE concept_name END {@sub_type == 'inpatient'} ? {, ' (inpatient)'}) AS VARCHAR(512)) AS covariate_name,
}
}
	@analysis_id AS analysis_id,
	CAST((covariate_id - @analysis_id) / 1000 AS INT) AS concept_id
FROM (
	SELECT DISTINCT covariate_id
	FROM @covariate_table
	) t1
LEFT JOIN @cdm_database_schema.concept
	ON concept_id = CAST((covariate_id - @analysis_id) / 1000 AS INT);
	
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
	{@temporal_sequence} ? {@sequence_start_day} : {@start_day}  AS start_day,
}
	{@temporal_sequence} ? {@sequence_end_day} : {@end_day} AS end_day,
}
	CAST('Y' AS VARCHAR(1)) AS is_binary,
	CAST(NULL AS VARCHAR(1)) AS missing_means_zero;	
