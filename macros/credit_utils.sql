/*
  Reusable credit-risk macros shared across models.
  Keeps DPD logic centralised so threshold changes propagate everywhere.
*/


--  dpd_bucket 
-- Maps a days_past_due integer to a regulatory-friendly bucket label.
-- Thresholds are driven by dbt variables so they can be overridden per env.

{% macro dpd_bucket(dpd_col) %}
case
    when {{ dpd_col }} = 0
        then 'current'
    when {{ dpd_col }} between 1 and {{ var('dpd_30_threshold') }}
        then 'dpd_1_30'
    when {{ dpd_col }} between {{ var('dpd_30_threshold') + 1 }}
             and {{ var('dpd_60_threshold') }}
        then 'dpd_31_60'
    when {{ dpd_col }} between {{ var('dpd_60_threshold') + 1 }}
             and {{ var('dpd_90_threshold') }}
        then 'dpd_61_90'
    when {{ dpd_col }} between {{ var('dpd_90_threshold') + 1 }}
             and {{ var('charge_off_threshold') }}
        then 'dpd_91_180'
    when {{ dpd_col }} > {{ var('charge_off_threshold') }}
        then 'charge_off'
    else 'unknown'
end
{% endmacro %}


--  safe_divide 
-- Null-safe division to avoid divide-by-zero in rate calculations.

{% macro safe_divide(numerator, denominator, default=0) %}
case
    when ({{ denominator }}) = 0 or ({{ denominator }}) is null
    then {{ default }}
    else ({{ numerator }}) * 1.0 / ({{ denominator }})
end
{% endmacro %}


--  rolling_window_filter 
-- Standardises the "last N months" filter used across reporting models.
-- Pass a date column and optionally override the lookback via var.

{% macro rolling_window_filter(date_col, lookback_days=none) %}
{% set days = lookback_days if lookback_days else var('reporting_lookback_days') %}
{{ date_col }} >= current_date - interval '{{ days }} days'
{% endmacro %}


--  generate_surrogate_key_from_cols 
-- Generates a surrogate key by hashing concatenated column values.

{% macro credit_surrogate_key(cols) %}
md5(cast({{ cols[0] }} as varchar) || chr(124) || cast({{ cols[1] }} as varchar))
{% endmacro %}


--  is_incremental_or_full 
-- Returns a WHERE clause appropriate to the run mode.
-- Used by incremental models to avoid full-table scans on backfills.

{% macro incremental_date_filter(date_col, lookback_buffer_days=3) %}
{% if is_incremental() %}
    {{ date_col }} >= (
        select dateadd('day', -{{ lookback_buffer_days }}, max({{ date_col }}))
        from {{ this }}
    )
{% endif %}
{% endmacro %}
