{{
  config(
    materialized='table',
    tags=['mart', 'risk_monitoring'],
  )
}}

/*
  mart_portfolio_risk_summary
  ---------------------------
  Portfolio-level roll-up consumed by:
    - Credit Risk team weekly review
    - Finance team for loss provisioning (IFRS 9 staging)
    - Executive dashboards

  Aggregates by: snapshot_month x product_type x dpd_bucket

  Key metrics:
    - Account count & balance by delinquency tier
    - Roll rates (% accounts moving worse/better)
    - NSF rate (early fraud/instability indicator)
    - Estimated net credit loss (ECL proxy)
*/

with monthly_data as (
    select * from {{ ref('mart_credit_reporting_monthly') }}
),

-- Compute totals per month/product for rate denominators
monthly_totals as (
    select
        snapshot_month,
        product_type,
        count(distinct account_id)             as total_accounts,
        sum(statement_balance_cad)             as total_balance_cad
    from monthly_data
    group by 1, 2
),

aggregated as (
    select
        m.snapshot_month,
        m.product_type,
        m.dpd_bucket,

        -- Volume
        count(distinct m.account_id)           as account_count,
        sum(m.statement_balance_cad)           as total_balance_cad,
        avg(m.utilization_rate)                as avg_utilization_rate,

        -- Roll-rate breakdown
        count(case when m.roll_direction = 'roll_worse'  then 1 end) as accounts_rolled_worse,
        count(case when m.roll_direction = 'roll_better' then 1 end) as accounts_rolled_better,
        count(case when m.roll_direction = 'stable'      then 1 end) as accounts_stable,

        -- Payment health
        {{ safe_divide(
            'count(case when m.paid_at_least_minimum then 1 end)',
            'count(*)'
        ) }}                                   as pct_paid_minimum,

        {{ safe_divide(
            'count(case when m.paid_in_full then 1 end)',
            'count(*)'
        ) }}                                   as pct_paid_full,

        {{ safe_divide(
            'count(case when m.made_no_payment then 1 end)',
            'count(*)'
        ) }}                                   as pct_no_payment,

        -- NSF signal
        {{ safe_divide(
            'sum(m.monthly_return_count)',
            'count(*)'
        ) }}                                   as avg_nsf_per_account,

        count(case when m.is_high_nsf_risk then 1 end) as high_nsf_risk_accounts,

        -- Loss exposure
        sum(m.estimated_loss_exposure_cad)     as total_estimated_loss_cad,
        sum(m.payment_shortfall_cad)           as total_payment_shortfall_cad,

        -- Thin-file exposure
        count(case when m.is_thin_file then 1 end) as thin_file_account_count

    from monthly_data m
    group by 1, 2, 3
),

with_rates as (
    select
        a.*,
        t.total_accounts,
        t.total_balance_cad                    as portfolio_total_balance_cad,

        -- DPD bucket share of portfolio
        {{ safe_divide('a.account_count', 't.total_accounts') }}
                                               as pct_of_portfolio_by_count,

        {{ safe_divide('a.total_balance_cad', 't.total_balance_cad') }}
                                               as pct_of_portfolio_by_balance,

        -- Roll-worse rate (credit deterioration signal)
        {{ safe_divide('a.accounts_rolled_worse', 'a.account_count') }}
                                               as roll_worse_rate,

        -- Simplified ECL rate
        {{ safe_divide('a.total_estimated_loss_cad', 'a.total_balance_cad') }}
                                               as ecl_rate

    from aggregated a
    inner join monthly_totals t
        on  a.snapshot_month = t.snapshot_month
        and a.product_type   = t.product_type
)

select * from with_rates
order by snapshot_month desc, product_type, dpd_bucket
