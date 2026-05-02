{{
  config(
    materialized='ephemeral',
    tags=['intermediate', 'risk_features']
  )
}}

/*
  int_account_monthly_risk_features
  ----------------------------------
  One row per account x snapshot_month, enriched with:
  - Payment behaviour (3-month trailing)
  - Delinquency roll-rate signals
  - NSF return history
  - Utilization trend

  This is the "feature layer" consumed by both:
    1. mart_credit_reporting_monthly  (regulatory reporting)
    2. mart_portfolio_risk_summary    (internal monitoring)
*/

with balances as (
    select * from {{ ref('stg_monthly_balances') }}
),

payments as (
    select
        account_id,
        payment_month,
        sum(case when is_settled  then payment_amount_cad else 0 end) as settled_amount,
        sum(case when is_returned then 1                 else 0 end) as return_count,
        sum(case when is_nsf_return then 1               else 0 end) as nsf_count,
        count(*)                                                       as total_payment_attempts
    from {{ ref('stg_payments') }}
    group by 1, 2
),

accounts as (
    select
        account_id,
        borrower_id,
        product_type,
        credit_limit_cad,
        account_status,
        delinquency_bucket,
        is_delinquent,
        is_charged_off,
        opened_at,
        account_age_months
    from {{ ref('stg_accounts') }}
),

-- Lag to detect delinquency roll (worse/better/stable)
balance_with_prev as (
    select
        b.*,
        lag(b.dpd_bucket) over (
            partition by b.account_id
            order by b.snapshot_month
        ) as prev_dpd_bucket,
        lag(b.days_past_due) over (
            partition by b.account_id
            order by b.snapshot_month
        ) as prev_days_past_due
    from balances b
),

-- 3-month trailing NSF count (fraud / instability signal)
nsf_trailing as (
    select
        p.account_id,
        p.payment_month,
        sum(p.nsf_count) over (
            partition by p.account_id
            order by p.payment_month
            rows between 2 preceding and current row
        ) as nsf_trailing_3m
    from payments p
),

joined as (
    select
        -- Keys
        bwp.balance_id,
        bwp.account_id,
        acc.borrower_id,
        bwp.snapshot_month,
        bwp.snapshot_month_key,

        -- Account meta
        acc.product_type,
        acc.opened_at,
        acc.account_age_months,
        acc.account_status,

        -- Balance / utilization
        bwp.statement_balance_cad,
        bwp.credit_limit_cad,
        bwp.utilization_rate,
        bwp.minimum_payment_cad,

        -- Delinquency
        bwp.days_past_due,
        bwp.dpd_bucket,
        bwp.prev_dpd_bucket,
        bwp.prev_days_past_due,

        -- Roll-rate classification
        case
            when bwp.prev_dpd_bucket is null         then 'new_account'
            when bwp.days_past_due > coalesce(bwp.prev_days_past_due, 0)
                                                     then 'roll_worse'
            when bwp.days_past_due < coalesce(bwp.prev_days_past_due, 0)
                                                     then 'roll_better'
            else                                          'stable'
        end                                          as roll_direction,

        -- Payment behaviour
        bwp.paid_at_least_minimum,
        bwp.paid_in_full,
        bwp.made_no_payment,
        coalesce(pay.settled_amount, 0)              as monthly_settled_amount,
        coalesce(pay.return_count, 0)                as monthly_return_count,
        coalesce(nsf.nsf_trailing_3m, 0)             as nsf_trailing_3m,

        -- Utilization: simple delta vs prior month
        bwp.utilization_rate - coalesce(
            lag(bwp.utilization_rate) over (
                partition by bwp.account_id
                order by bwp.snapshot_month
            ), bwp.utilization_rate
        )                                            as utilization_delta_mom

    from balance_with_prev bwp
    inner join accounts acc
        on bwp.account_id = acc.account_id
    left join payments pay
        on  bwp.account_id   = pay.account_id
        and date_trunc('month', bwp.snapshot_month) = pay.payment_month
    left join nsf_trailing nsf
        on  bwp.account_id   = nsf.account_id
        and date_trunc('month', bwp.snapshot_month) = nsf.payment_month
)

select * from joined
