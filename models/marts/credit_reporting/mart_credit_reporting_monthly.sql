{{
  config(
    materialized='incremental',
    unique_key='snapshot_id',
    incremental_strategy='merge',
    tags=['mart', 'credit_reporting', 'incremental'],
    on_schema_change='append_new_columns'
  )
}}

/*
  mart_credit_reporting_monthly

  Regulatory-grade monthly credit snapshot per account.

  Designed to feed:
    1. Internal credit dashboards
    2. Equifax / TransUnion monthly trade-line submissions
    3. OSFI/FCAC audit extracts

  Incremental strategy:
    - On each run, reprocesses the last 3 months (late-arriving payments,
      balance corrections) via the incremental_date_filter macro.
    - Merge on snapshot_id ensures idempotency.

  One Big Table pattern: all dimensions and measures in a single wide table
  so downstream consumers (BI, spreadsheet exports) need no further joins.
*/

with features as (
    select * from {{ ref('int_account_monthly_risk_features') }}
    {% if is_incremental() %}
    -- Only reprocess recent months; historical rows are already settled
    where snapshot_month >= (
        select dateadd('month', -3, max(snapshot_month))
        from {{ this }}
    )
    {% endif %}
),

borrowers as (
    select
        borrower_id,
        province_code,
        credit_score_band,
        is_thin_file,
        onboarded_at
    from {{ ref('stg_borrowers') }}
),

risk_bands as (
    select * from {{ ref('risk_bands') }}
),

final as (
    select
        -- Surrogate key (account + month)
        md5(cast(f.account_id as varchar) || '|' || cast(f.snapshot_month as varchar))
                                                     as snapshot_id,

        -- Reporting dimensions
        f.account_id,
        f.borrower_id,
        b.province_code,
        f.product_type,
        f.snapshot_month,
        f.snapshot_month_key,

        -- Account lifecycle
        f.opened_at                                  as account_opened_at,
        f.account_age_months,
        f.account_status,

        -- Credit utilization
        f.statement_balance_cad,
        f.credit_limit_cad,
        f.utilization_rate,
        f.utilization_delta_mom,

        -- Delinquency & roll-rate
        f.days_past_due,
        f.dpd_bucket,
        f.prev_dpd_bucket,
        f.roll_direction,

        -- Payment behaviour
        f.paid_at_least_minimum,
        f.paid_in_full,
        f.made_no_payment,
        f.monthly_settled_amount,
        f.monthly_return_count,
        f.nsf_trailing_3m,

        -- Risk signals
        rb.risk_label                                as credit_score_risk_label,
        b.is_thin_file,
        f.nsf_trailing_3m >= 2                       as is_high_nsf_risk,

        -- Minimum payment shortfall (positive = underpaid)
        greatest(0, f.minimum_payment_cad - f.monthly_settled_amount)
                                                     as payment_shortfall_cad,

        -- Effective loss exposure: balance x (1 - expected recovery)
        -- Recovery rate assumption: 15% on charged-off accounts
        case
            when f.dpd_bucket = 'charge_off'
            then round(f.statement_balance_cad * 0.85, 2)
            else 0
        end                                          as estimated_loss_exposure_cad,

        -- Audit / lineage
        current_timestamp                            as _dbt_loaded_at,
        '{{ invocation_id }}'                        as _dbt_invocation_id

    from features f
    inner join borrowers b
        on f.borrower_id = b.borrower_id
    left join risk_bands rb
        on b.credit_score_band = rb.band_name
)

select * from final
