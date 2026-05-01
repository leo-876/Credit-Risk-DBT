{{
  config(
    materialized='view',
    tags=['staging', 'accounts']
  )
}}

/*
  stg_accounts
  ------------
  Cleans raw account data. Key transformations:
  - Handles nullable closed_at (open accounts have no close date)
  - Derives account age in months (used in vintage analysis)
  - Maps raw status strings to canonical delinquency tiers
*/

with source as (
    select * from {{ ref('raw_accounts') }}
),

cleaned as (
    select
        account_id,
        borrower_id,
        upper(product_type)                                 as product_type,
        cast(opened_at as date)                             as opened_at,
        nullif(cast(closed_at as varchar), '')              as closed_at_raw,
        cast(credit_limit_cad as decimal(12, 2))            as credit_limit_cad,
        lower(account_status)                               as account_status,
        cast(cycle_due_day as integer)                      as cycle_due_day
    from source
    where account_id is not null
      and borrower_id is not null
),

enriched as (
    select
        *,
        case
            when closed_at_raw is not null
            then cast(closed_at_raw as date)
            else null
        end                                                  as closed_at,

        datediff(
            'month',
            opened_at,
            coalesce(cast(closed_at_raw as date), current_date)
        )                                                    as account_age_months,

        -- Map to regulatory delinquency buckets (used in FCAC reporting)
        case account_status
            when 'current'        then 0
            when 'delinquent_30'  then 1
            when 'delinquent_60'  then 2
            when 'delinquent_90'  then 3
            when 'charged_off'    then 4
            when 'closed'         then -1
            else                       -99   -- unknown / data quality flag
        end                                                  as delinquency_bucket,

        account_status in ('delinquent_30', 'delinquent_60',
                           'delinquent_90', 'charged_off')   as is_delinquent,

        account_status = 'charged_off'                       as is_charged_off,

        current_timestamp                                    as _loaded_at

    from cleaned
)

select * from enriched
