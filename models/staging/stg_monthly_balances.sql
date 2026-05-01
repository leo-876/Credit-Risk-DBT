{{
  config(
    materialized='view',
    tags=['staging', 'balances']
  )
}}

/*
  stg_monthly_balances
  --------------------
  Standardises the monthly balance snapshot feed.
  Each row = one account x one statement month.
  This is the core event stream that powers vintage curves and
  delinquency roll-rate analysis.
*/

with source as (
    select * from {{ ref('raw_monthly_balances') }}
),

typed as (
    select
        balance_id,
        account_id,
        cast(snapshot_month as date)                           as snapshot_month,
        cast(statement_balance_cad  as decimal(12, 2))         as statement_balance_cad,
        cast(credit_limit_cad       as decimal(12, 2))         as credit_limit_cad,
        cast(utilization_rate       as decimal(6, 4))          as utilization_rate,
        cast(minimum_payment_cad    as decimal(12, 2))         as minimum_payment_cad,
        cast(amount_paid_cad        as decimal(12, 2))         as amount_paid_cad,
        cast(days_past_due          as integer)                as days_past_due
    from source
    where balance_id  is not null
      and account_id  is not null
      and snapshot_month is not null
),

enriched as (
    select
        *,

        -- Payment behaviour flags
        amount_paid_cad >= minimum_payment_cad              as paid_at_least_minimum,
        amount_paid_cad >= statement_balance_cad            as paid_in_full,
        amount_paid_cad = 0                                 as made_no_payment,

        -- DPD buckets
        {{ dpd_bucket('days_past_due') }}                   as dpd_bucket,

        -- Month number as integer key for partitioning / range scans
        cast(strftime(snapshot_month, '%Y%m') as integer)   as snapshot_month_key,

        current_timestamp                                   as _loaded_at

    from typed
)

select * from enriched
