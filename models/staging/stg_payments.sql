{{
  config(
    materialized='view',
    tags=['staging', 'payments']
  )
}}

/*
  stg_payments
  ------------
  Cleans raw payment transaction feed.
  Returned/failed payments are preserved with a flag rather than filtered,
  since returned EFTs are significant credit-risk signals.
*/

with source as (
    select * from {{ ref('raw_payments') }}
),

typed as (
    select
        payment_id,
        account_id,
        cast(payment_date as date)                         as payment_date,
        cast(payment_amount_cad as decimal(12, 2))         as payment_amount_cad,
        lower(payment_method)                              as payment_method,
        lower(payment_status)                              as payment_status
    from source
    where payment_id is not null
),

enriched as (
    select
        *,
        payment_status = 'settled'                         as is_settled,
        payment_status = 'returned'                        as is_returned,
        payment_status = 'pending'                         as is_pending,

        -- EFT returns are especially high-risk signals (NSF / fraud indicators)
        payment_status = 'returned'
            and payment_method = 'eft'                     as is_nsf_return,

        date_trunc('month', payment_date)                  as payment_month,

        current_timestamp                                  as _loaded_at

    from typed
)

select * from enriched
